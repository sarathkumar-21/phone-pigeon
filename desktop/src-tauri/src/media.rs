//! HTTPS data plane to the phone's media server. The phone's certificate is self-signed: the only certificate
//! trusted is the exact one whose SHA-256 the phone announced over the end-to-end encrypted channel.

use futures_util::StreamExt;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tauri::{AppHandle, Emitter};

#[derive(Clone, Debug)]
pub struct MediaEndpoint {
    pub ip: String,
    pub port: u16,
    pub token: String,
    pub cert_sha256: Vec<u8>,
}

impl MediaEndpoint {
    pub fn from_json(v: &serde_json::Value) -> Option<MediaEndpoint> {
        let mut ip = v.get("lan_ip")?.as_str()?.to_string();
        if let Ok(over) = std::env::var("PHONEPIGEON_MEDIA_HOST_OVERRIDE") {
            if !over.is_empty() {
                ip = over; // emulator testing only (adb forward)
            }
        }
        Some(MediaEndpoint {
            ip,
            port: v.get("https_port")?.as_u64()? as u16,
            token: v.get("session_bearer_token")?.as_str()?.to_string(),
            cert_sha256: crate::crypto::unb64(v.get("server_cert_sha256")?.as_str()?)?,
        })
    }

    pub fn url(&self, path: &str, query: &str) -> String {
        let host = if self.ip.contains(':') { format!("[{}]", self.ip) } else { self.ip.clone() };
        if query.is_empty() {
            format!("https://{host}:{}{path}", self.port)
        } else {
            format!("https://{host}:{}{path}?{query}", self.port)
        }
    }

    pub fn client(&self) -> Option<reqwest::Client> {
        #[derive(Debug)]
        struct Pin(Vec<u8>);
        impl ServerCertVerifier for Pin {
            fn verify_server_cert(
                &self, end_entity: &CertificateDer<'_>, _i: &[CertificateDer<'_>], _n: &ServerName<'_>, _o: &[u8], _now: UnixTime,
            ) -> Result<ServerCertVerified, rustls::Error> {
                let hash = Sha256::digest(end_entity.as_ref());
                // Self-signed phone certificate: trust only the exact certificate announced over the E2EE channel.
                if subtle::ConstantTimeEq::ct_eq(hash.as_slice(), self.0.as_slice()).into() {
                    Ok(ServerCertVerified::assertion())
                } else {
                    Err(rustls::Error::General("certificate does not match the pinned hash".into()))
                }
            }
            fn verify_tls12_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
                rustls::crypto::verify_tls12_signature(m, c, d, &rustls::crypto::ring::default_provider().signature_verification_algorithms)
            }
            fn verify_tls13_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
                rustls::crypto::verify_tls13_signature(m, c, d, &rustls::crypto::ring::default_provider().signature_verification_algorithms)
            }
            fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
                rustls::crypto::ring::default_provider().signature_verification_algorithms.supported_schemes()
            }
        }
        let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .ok()?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(Pin(self.cert_sha256.clone())))
            .with_no_client_auth();
        reqwest::Client::builder()
            .use_preconfigured_tls(cfg)
            .pool_max_idle_per_host(6)
            .connect_timeout(std::time::Duration::from_secs(8))
            .build()
            .ok()
    }

    pub fn authorized(&self, client: &reqwest::Client, url: &str) -> reqwest::RequestBuilder {
        client.get(url).bearer_auth(&self.token)
    }
}

/// Reduces a phone-supplied name to a single, plain path component (never lets it steer a write elsewhere).
pub fn safe_file_name(raw: &str) -> String {
    let last = raw.replace('\\', "/").split('/').filter(|s| !s.is_empty()).last().unwrap_or("").to_string();
    let mut s: String = last.chars().filter(|c| (*c as u32) >= 0x20 && *c as u32 != 0x7F && !":*?\"<>|".contains(*c)).collect();
    s = s.trim().to_string();
    while s.starts_with('.') {
        s.remove(0); // no "..", no hidden dotfiles
    }
    if s.is_empty() {
        s = "Phone file".into();
    }
    s.chars().take(200).collect()
}

fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let p = dir.join(name);
    if !p.exists() {
        return p;
    }
    let path = Path::new(name);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
    let ext = path.extension().and_then(|s| s.to_str());
    let mut i = 1;
    loop {
        let candidate = match ext {
            Some(e) => dir.join(format!("{stem} {i}.{e}")),
            None => dir.join(format!("{stem} {i}")),
        };
        if !candidate.exists() {
            return candidate;
        }
        i += 1;
    }
}

#[derive(Serialize, Clone)]
pub struct TransferEvent {
    pub id: String,
    pub name: String,
    pub direction: &'static str,
    pub total: u64,
    pub done: u64,
    /// "running", "done", "failed"
    pub state: &'static str,
    pub error: Option<String>,
    pub path: Option<String>,
}

const SEGMENT: u64 = 4 << 20;
const PARALLEL: usize = 4;

fn write_at(file: &std::fs::File, buf: &[u8], offset: u64) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileExt;
        file.write_all_at(buf, offset)
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::FileExt;
        let mut done = 0;
        while done < buf.len() {
            let n = file.seek_write(&buf[done..], offset + done as u64)?;
            done += n;
        }
        Ok(())
    }
}

/// Downloads a phone file into `dir`. Big files are fetched as parallel 4 MB ranges and written to their offsets.
pub async fn download(
    app: AppHandle, ep: MediaEndpoint, id: String, path: String, media_id: Option<i64>, name: String, size: u64, dir: PathBuf,
) -> Result<PathBuf, String> {
    let name = safe_file_name(&name);
    let target = unique_path(&dir, &name);
    if target.parent() != Some(dir.as_path()) {
        return Err("Refused an unsafe file name from the phone.".into());
    }
    let client = ep.client().ok_or("Couldn't prepare a secure connection.")?;
    let query = match media_id {
        Some(i) => format!("id={i}"),
        None => format!("path={}", urlencode(&path)),
    };
    let url = ep.url("/media/file", &query);
    let emit = |done: u64, state: &'static str, error: Option<String>, p: Option<String>| {
        let _ = app.emit(
            "transfer",
            TransferEvent { id: id.clone(), name: name.clone(), direction: "download", total: size, done, state, error, path: p },
        );
    };
    emit(0, "running", None, None);
    let result: Result<(), String> = async {
        if size > SEGMENT {
            let file = std::fs::OpenOptions::new().create(true).write(true).open(&target).map_err(|e| e.to_string())?;
            file.set_len(size).map_err(|e| e.to_string())?;
            let file = Arc::new(file);
            let done = Arc::new(std::sync::atomic::AtomicU64::new(0));
            let ranges: Vec<(u64, u64)> = (0..size).step_by(SEGMENT as usize).map(|o| (o, SEGMENT.min(size - o))).collect();
            let mut stream = futures_util::stream::iter(ranges.into_iter().map(|(off, len)| {
                let client = client.clone();
                let ep = ep.clone();
                let url = url.clone();
                let file = file.clone();
                async move {
                    let mut last = String::from("failed");
                    for attempt in 0..3u64 {
                        let resp = ep.authorized(&client, &url).header("Range", format!("bytes={}-{}", off, off + len - 1)).send().await;
                        match resp {
                            Ok(r) if r.status().is_success() => match r.bytes().await {
                                Ok(b) if b.len() as u64 == len => {
                                    let f = file.clone();
                                    return tokio::task::spawn_blocking(move || write_at(&f, &b, off))
                                        .await
                                        .map_err(|e| e.to_string())
                                        .and_then(|r| r.map_err(|e| e.to_string()))
                                        .map(|_| len);
                                }
                                Ok(_) => last = "The phone sent a short block".into(),
                                Err(e) => last = e.to_string(),
                            },
                            Ok(r) => {
                                last = format!("HTTP {}", r.status());
                                if r.status().is_client_error() {
                                    break;
                                }
                            }
                            Err(e) => last = e.to_string(),
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(200 * (attempt + 1))).await;
                    }
                    Err(last)
                }
            }))
            .buffer_unordered(PARALLEL);
            while let Some(r) = stream.next().await {
                let n = r?;
                let total = done.fetch_add(n, std::sync::atomic::Ordering::Relaxed) + n;
                emit(total, "running", None, None);
            }
        } else {
            let r = ep.authorized(&client, &url).send().await.map_err(|e| e.to_string())?;
            if !r.status().is_success() {
                return Err(format!("HTTP {}", r.status()));
            }
            let b = r.bytes().await.map_err(|e| e.to_string())?;
            std::fs::write(&target, &b).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
    .await;
    match result {
        Ok(()) => {
            emit(size, "done", None, Some(target.to_string_lossy().to_string()));
            Ok(target)
        }
        Err(e) => {
            let _ = std::fs::remove_file(&target);
            emit(0, "failed", Some(e.clone()), None);
            Err(e)
        }
    }
}

/// Uploads a local file into a phone folder (`PUT /media/upload`), SHA-256 verified by the phone.
pub async fn upload(app: AppHandle, ep: MediaEndpoint, id: String, local: PathBuf, folder: String) -> Result<(), String> {
    let name = local.file_name().and_then(|n| n.to_str()).unwrap_or("file").to_string();
    let meta = std::fs::metadata(&local).map_err(|e| e.to_string())?;
    let size = meta.len();
    let dest = format!("{}{}", if folder.ends_with('/') { folder.clone() } else { format!("{folder}/") }, name);
    let emit = |done: u64, state: &'static str, error: Option<String>| {
        let _ = app.emit(
            "transfer",
            TransferEvent { id: id.clone(), name: name.clone(), direction: "upload", total: size, done, state, error, path: None },
        );
    };
    emit(0, "running", None);
    let local2 = local.clone();
    let digest = tokio::task::spawn_blocking(move || -> std::io::Result<String> {
        use std::io::Read;
        let mut f = std::fs::File::open(local2)?;
        let mut h = Sha256::new();
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = f.read(&mut buf)?;
            if n == 0 {
                break;
            }
            h.update(&buf[..n]);
        }
        Ok(hex::encode(h.finalize()))
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(|e| e.to_string())?;
    let client = ep.client().ok_or("Couldn't prepare a secure connection.")?;
    let file = tokio::fs::File::open(&local).await.map_err(|e| e.to_string())?;
    let r = client
        .put(ep.url("/media/upload", &format!("path={}", urlencode(&dest))))
        .bearer_auth(&ep.token)
        .header("X-Content-SHA256", digest)
        .header("Content-Type", "application/octet-stream")
        .header("Content-Length", size)
        .body(reqwest::Body::from(file))
        .send()
        .await;
    match r {
        Ok(r) if r.status().is_success() => {
            emit(size, "done", None);
            Ok(())
        }
        Ok(r) => {
            let e = format!("HTTP {}", r.status());
            emit(0, "failed", Some(e.clone()));
            Err(e)
        }
        Err(e) => {
            emit(0, "failed", Some(e.to_string()));
            Err(e.to_string())
        }
    }
}

pub fn urlencode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Reads `GET /media/screen`: `kind(1) ‖ length(4 BE) ‖ pts(8 BE) ‖ payload` frames, forwarded to the UI as events.
pub async fn screen_stream(app: AppHandle, ep: MediaEndpoint, phone_id: String) -> Result<(), String> {
    let client = ep.client().ok_or("Couldn't prepare a secure connection.")?;
    let resp = ep
        .authorized(&client, &ep.url("/media/screen", ""))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }
    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    while let Some(chunk) = stream.next().await {
        buf.extend_from_slice(&chunk.map_err(|e| e.to_string())?);
        loop {
            if buf.len() < 13 {
                break;
            }
            let kind = buf[0];
            let len = u32::from_be_bytes([buf[1], buf[2], buf[3], buf[4]]) as usize;
            if len > 8 * 1024 * 1024 {
                return Err("The phone sent an oversized frame.".into());
            }
            if buf.len() < 13 + len {
                break;
            }
            let pts = u64::from_be_bytes(buf[5..13].try_into().unwrap());
            let data = crate::crypto::b64(&buf[13..13 + len]);
            buf.drain(..13 + len);
            let _ = app.emit("screen_frame", serde_json::json!({ "phone_id": phone_id, "kind": kind, "pts": pts, "data": data }));
        }
    }
    Ok(())
}
