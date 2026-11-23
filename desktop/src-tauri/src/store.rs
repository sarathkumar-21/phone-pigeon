//! On-disk state. Identity keys and the storage key live in the OS keychain (macOS Keychain, Windows Credential
//! Manager, Linux Secret Service); when that is unavailable (headless Linux) they fall back to 0600 files.
//! The data file itself is sealed with ChaCha20-Poly1305, so message history never sits on disk in clear text.

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use x25519_dalek::StaticSecret;

const SERVICE: &str = "dev.phonepigeon.desktop";

pub fn data_dir() -> PathBuf {
    let base = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    let dir = base.join("PhonePigeon");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn write_private(path: &PathBuf, data: &[u8]) {
    let _ = std::fs::write(path, data);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
}

/// A secret kept in the OS keychain, or in a private file when there is no keychain.
fn secret(account: &str, make: impl FnOnce() -> Vec<u8>) -> Vec<u8> {
    let entry = keyring::Entry::new(SERVICE, account).ok();
    if let Some(e) = &entry {
        if let Ok(v) = e.get_secret() {
            return v;
        }
    }
    let file = data_dir().join(format!(".{account}.key"));
    if let Ok(v) = std::fs::read(&file) {
        if !v.is_empty() {
            return v;
        }
    }
    let fresh = make();
    let stored = entry.as_ref().map(|e| e.set_secret(&fresh).is_ok()).unwrap_or(false);
    if !stored {
        write_private(&file, &fresh);
    }
    fresh
}

pub fn identity() -> StaticSecret {
    let raw = secret("x25519-identity", || {
        let mut b = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut b);
        b.to_vec()
    });
    let arr: [u8; 32] = raw.try_into().unwrap_or([7u8; 32]);
    StaticSecret::from(arr)
}

pub fn device_id() -> String {
    String::from_utf8(secret("device-id", || uuid::Uuid::new_v4().to_string().into_bytes())).unwrap_or_else(|_| uuid::Uuid::new_v4().to_string())
}

fn storage_key() -> [u8; 32] {
    let raw = secret("store-key", || {
        let mut b = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut b);
        b.to_vec()
    });
    raw.try_into().unwrap_or([9u8; 32])
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct PairedDevice {
    pub android_device_id: String,
    pub device_name: String,
    pub manufacturer: String,
    pub os_version: String,
    /// base64 X25519 public key.
    pub android_public_key: String,
    pub session_id: String,
    pub paired_at_ms: i64,
    #[serde(default)]
    pub out_seq: u64,
    #[serde(default)]
    pub in_seq: u64,
}

#[derive(Serialize, Deserialize, Default)]
pub struct StoreData {
    pub devices: Vec<PairedDevice>,
    /// Opaque per-phone UI state (messages, contacts, calls…), sealed together with the rest.
    pub snapshots: HashMap<String, String>,
    #[serde(default)]
    pub settings: String,
    /// Last LAN port in use: tried first so a phone that remembers `host:port` keeps connecting after a restart.
    #[serde(default)]
    pub lan_port: u16,
}

pub struct Store {
    path: PathBuf,
    key: [u8; 32],
    pub data: StoreData,
}

impl Store {
    pub fn load() -> Store {
        let path = data_dir().join("store.bin");
        let key = storage_key();
        let data = std::fs::read(&path)
            .ok()
            .and_then(|raw| {
                if raw.len() < 12 {
                    return None;
                }
                let (nonce, ct) = raw.split_at(12);
                let pt = ChaCha20Poly1305::new(Key::from_slice(&key)).decrypt(Nonce::from_slice(nonce), ct).ok()?;
                serde_json::from_slice(&pt).ok()
            })
            .unwrap_or_default();
        Store { path, key, data }
    }

    pub fn save(&self) {
        let Ok(pt) = serde_json::to_vec(&self.data) else { return };
        let mut nonce = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce);
        let Ok(ct) = ChaCha20Poly1305::new(Key::from_slice(&self.key)).encrypt(Nonce::from_slice(&nonce), pt.as_slice()) else { return };
        let mut out = nonce.to_vec();
        out.extend_from_slice(&ct);
        let tmp = self.path.with_extension("tmp");
        write_private(&tmp, &out);
        let _ = std::fs::rename(&tmp, &self.path); // atomic replace: a crash never leaves a half-written store
    }
}
