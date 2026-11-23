//! The desktop "hub": the LAN socket phones connect to, the paired phones' encrypted channels and nearby pairing.
//! The UI (TypeScript) never sees keys; it sends protocol bodies to `send` and receives decrypted ones as events.

use crate::crypto::{self, b64, unb64, SecureChannel, SessionKeys};
use crate::media::MediaEndpoint;
use crate::store::{self, PairedDevice, Store};
use crate::wire::{EncryptedEnvelope, PairAckEnvelope, WireFrame};
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Notify};
use x25519_dalek::{PublicKey, StaticSecret};

const MAX_UNAUTHENTICATED: usize = 8;
const HANDSHAKE_DEADLINE: Duration = Duration::from_secs(10);

pub fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

#[derive(Serialize, Clone)]
pub struct PhoneInfo {
    pub id: String,
    pub name: String,
    pub manufacturer: String,
    pub os_version: String,
    pub paired_at_ms: i64,
    pub connected: bool,
    pub host: Option<String>,
    pub fingerprint: String,
    pub media_ready: bool,
}

#[derive(Serialize, Clone)]
pub struct NearbyPhone {
    pub id: String,
    pub name: String,
    pub model: String,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum NearbyState {
    Idle,
    Connecting { phone: String },
    Confirm { phone: String, code: String },
    Finishing { phone: String },
    Failed { message: String },
}

struct Conn {
    tx: mpsc::UnboundedSender<Vec<u8>>,
    host: String,
    kill: Arc<Notify>,
}

struct Phone {
    dev: PairedDevice,
    channel: SecureChannel,
    media: Option<MediaEndpoint>,
}

struct PairingSession {
    session_id: String,
    secret: Vec<u8>,
    expires: Instant,
}

struct Inner {
    identity: StaticSecret,
    device_id: String,
    store: Store,
    phones: HashMap<String, Phone>,
    conns: HashMap<u64, Conn>,
    trusted: HashMap<String, u64>,
    next_conn: u64,
    lan_port: u16,
    pairing: Option<PairingSession>,
    nearby_found: HashMap<String, (NearbyPhone, Vec<std::net::IpAddr>, u16)>,
    nearby_state: NearbyState,
    nearby_cancel: Option<Arc<Notify>>,
    nearby_decision: Option<mpsc::UnboundedSender<bool>>,
    last_resync: HashMap<u64, Instant>,
    dirty: bool,
}

pub struct Core {
    app: AppHandle,
    inner: Mutex<Inner>,
    mdns: Mutex<Option<ServiceDaemon>>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
struct Offer {
    android_device_id: String,
    android_pub_key: String,
    #[serde(default)]
    device_name: String,
}

pub fn device_name() -> String {
    let raw = hostname::get().ok().and_then(|h| h.into_string().ok()).unwrap_or_else(|| "Desktop".into());
    let trimmed = raw.trim_end_matches(".local").trim_end_matches(".lan").trim_end_matches(".home");
    if trimmed.is_empty() { "Desktop".into() } else { trimmed.to_string() }
}

impl Core {
    pub fn new(app: AppHandle) -> Arc<Core> {
        let store = Store::load();
        let identity = store::identity();
        let device_id = store::device_id();
        let mut phones = HashMap::new();
        for d in store.data.devices.clone() {
            if let Some(phone) = Self::build_phone(&identity, &device_id, d) {
                phones.insert(phone.dev.android_device_id.clone(), phone);
            }
        }
        let inner = Inner {
            identity,
            device_id,
            store,
            phones,
            conns: HashMap::new(),
            trusted: HashMap::new(),
            next_conn: 0,
            lan_port: 0,
            pairing: None,
            nearby_found: HashMap::new(),
            nearby_state: NearbyState::Idle,
            nearby_cancel: None,
            nearby_decision: None,
            last_resync: HashMap::new(),
            dirty: false,
        };
        Arc::new(Core { app, inner: Mutex::new(inner), mdns: Mutex::new(None) })
    }

    fn build_phone(identity: &StaticSecret, device_id: &str, dev: PairedDevice) -> Option<Phone> {
        let peer = unb64(&dev.android_public_key)?;
        let keys = SessionKeys::derive(identity, &peer, &dev.session_id)?;
        let channel = SecureChannel::new(keys, &dev.session_id, device_id, &dev.android_device_id, dev.out_seq, dev.in_seq);
        Some(Phone { dev, channel, media: None })
    }

    // ------------------------------------------------------------------ lifecycle

    /// Starts the LAN socket, the mDNS advertisement and the background timers.
    pub fn start(self: &Arc<Self>) {
        let core = self.clone();
        tauri::async_runtime::spawn(async move {
            core.run_lan().await;
        });
        let core = self.clone();
        tauri::async_runtime::spawn(async move {
            let mut ticks = 0u64;
            loop {
                tokio::time::sleep(Duration::from_secs(20)).await;
                ticks += 1;
                core.maintenance(ticks);
            }
        });
        self.start_browse();
    }

    fn maintenance(self: &Arc<Self>, ticks: u64) {
        let mut ids = vec![];
        {
            let mut g = self.inner.lock().unwrap();
            if ticks % (6 * 3 * 60) == 0 {
                for p in g.phones.values_mut() {
                    p.channel.schedule_rekey();
                }
            }
            let trusted: Vec<String> = g.trusted.keys().cloned().collect();
            ids.extend(trusted);
            if g.dirty {
                let seqs: Vec<(String, u64, u64)> =
                    g.phones.iter().map(|(id, p)| (id.clone(), p.channel.outgoing_sequence, p.channel.highest_incoming_sequence)).collect();
                for (id, o, i) in seqs {
                    if let Some(d) = g.store.data.devices.iter_mut().find(|d| d.android_device_id == id) {
                        d.out_seq = o;
                        d.in_seq = i;
                    }
                }
                g.store.save();
                g.dirty = false;
            }
        }
        for id in ids {
            self.maybe_rekey(&id);
        }
    }

    fn mark_dirty(g: &mut Inner) {
        g.dirty = true;
    }

    pub fn shutdown(&self) {
        let mut g = self.inner.lock().unwrap();
        let seqs: Vec<(String, u64, u64)> =
            g.phones.iter().map(|(id, p)| (id.clone(), p.channel.outgoing_sequence, p.channel.highest_incoming_sequence)).collect();
        for (id, o, i) in seqs {
            if let Some(d) = g.store.data.devices.iter_mut().find(|d| d.android_device_id == id) {
                d.out_seq = o;
                d.in_seq = i;
            }
        }
        g.store.save();
    }

    // ------------------------------------------------------------------ LAN server

    async fn run_lan(self: Arc<Self>) {
        let saved = self.inner.lock().unwrap().store.data.lan_port;
        // Last port, then the well-known one, then any free port.
        let mut candidates = Vec::new();
        if saved != 0 {
            candidates.push(saved);
        }
        candidates.extend([8443, 0]);
        let mut listener = None;
        for p in candidates {
            if let Ok(l) = TcpListener::bind(("0.0.0.0", p)).await {
                listener = Some(l);
                break;
            }
        }
        let Some(listener) = listener else {
            log::error!("could not open a local port");
            return;
        };
        let port = listener.local_addr().map(|a| a.port()).unwrap_or(8443);
        {
            let mut g = self.inner.lock().unwrap();
            g.lan_port = port;
            if g.store.data.lan_port != port {
                g.store.data.lan_port = port;
                g.store.save();
            }
        }
        self.advertise(port);
        loop {
            let Ok((stream, addr)) = listener.accept().await else { continue };
            let _ = stream.set_nodelay(true);
            let core = self.clone();
            tauri::async_runtime::spawn(async move { core.serve_conn(stream, addr.ip().to_string()).await });
        }
    }

    fn advertise(&self, port: u16) {
        let Ok(daemon) = ServiceDaemon::new() else { return };
        let device_id = self.inner.lock().unwrap().device_id.clone();
        let name = device_name();
        let props = [("h", crypto::mdns_tag(&device_id)), ("v", "1".to_string())];
        // A host name of our own: reusing the computer's name collides with the system's own mDNS records.
        let host = format!("pigeon-{}.local.", &crypto::mdns_tag(&device_id)[..8]);
        if let Ok(info) = ServiceInfo::new("_pigeonmac._tcp.local.", &format!("PhonePigeon · {name}"), &host, "", port, &props[..]) {
            let _ = daemon.register(info.enable_addr_auto());
        }
        *self.mdns.lock().unwrap() = Some(daemon);
    }

    async fn serve_conn(self: Arc<Self>, stream: TcpStream, host: String) {
        let (mut rd, mut wr) = stream.into_split();
        let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let kill = Arc::new(Notify::new());
        let id;
        {
            let mut g = self.inner.lock().unwrap();
            let unauth = g.conns.keys().filter(|k| !g.trusted.values().any(|v| v == *k)).count();
            if unauth >= MAX_UNAUTHENTICATED {
                return; // anyone on the LAN can open a socket: cap the ones that have not proven the pairing keys
            }
            g.next_conn += 1;
            id = g.next_conn;
            g.conns.insert(id, Conn { tx: tx.clone(), host: host.trim_start_matches("::ffff:").to_string(), kill: kill.clone() });
        }
        // Writer.
        let k2 = kill.clone();
        let writer = tauri::async_runtime::spawn(async move {
            while let Some(buf) = rx.recv().await {
                if wr.write_all(&buf).await.is_err() {
                    break;
                }
            }
            let _ = wr.shutdown().await;
            k2.notify_one();
        });
        // Deadline: a socket that never delivers a frame that decrypts is dropped.
        let core = self.clone();
        let k3 = kill.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(HANDSHAKE_DEADLINE).await;
            let authed = core.inner.lock().unwrap().trusted.values().any(|v| *v == id);
            if !authed {
                k3.notify_one();
            }
        });
        // Reader.
        let mut buf: Vec<u8> = Vec::new();
        let mut chunk = vec![0u8; 64 * 1024];
        'outer: loop {
            tokio::select! {
                _ = kill.notified() => break,
                n = rd.read(&mut chunk) => {
                    let Ok(n) = n else { break };
                    if n == 0 { break }
                    buf.extend_from_slice(&chunk[..n]);
                    let authed = self.inner.lock().unwrap().trusted.values().any(|v| *v == id);
                    let limit = if authed { 16 * 1024 * 1024 } else { 2 * 1024 * 1024 };
                    if buf.len() > limit { break }
                    while buf.len() >= 4 {
                        let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
                        if len == 0 {
                            buf.drain(..4);
                            let _ = tx.send(vec![0, 0, 0, 0]); // keep-alive: echo it so the phone can tell the link is alive
                            continue;
                        }
                        if len > limit { break 'outer }
                        if buf.len() < 4 + len { break }
                        let frame: Vec<u8> = buf[4..4 + len].to_vec();
                        buf.drain(..4 + len);
                        if let Ok(f) = serde_json::from_slice::<WireFrame>(&frame) {
                            self.handle_frame(id, f);
                        }
                    }
                }
            }
        }
        writer.abort();
        self.drop_conn(id);
    }

    fn drop_conn(&self, id: u64) {
        let changed;
        {
            let mut g = self.inner.lock().unwrap();
            g.conns.remove(&id);
            let who: Vec<String> = g.trusted.iter().filter(|(_, v)| **v == id).map(|(k, _)| k.clone()).collect();
            changed = !who.is_empty();
            for w in who {
                g.trusted.remove(&w);
            }
        }
        if changed {
            self.emit_phones();
        }
    }

    fn send_raw_frame(&self, conn: u64, frame: &WireFrame) {
        let g = self.inner.lock().unwrap();
        if let (Some(c), Ok(body)) = (g.conns.get(&conn), serde_json::to_vec(frame)) {
            let mut out = (body.len() as u32).to_be_bytes().to_vec();
            out.extend_from_slice(&body);
            let _ = c.tx.send(out);
        }
    }

    fn trust(&self, conn: u64, device: &str) {
        let mut g = self.inner.lock().unwrap();
        if g.trusted.get(device) == Some(&conn) {
            return;
        }
        if let Some(old) = g.trusted.insert(device.to_string(), conn) {
            if let Some(c) = g.conns.get(&old) {
                c.kill.notify_one(); // a reconnect replaces the old socket
            }
        }
        drop(g);
        self.emit_phones();
    }

    // ------------------------------------------------------------------ frames

    fn handle_frame(self: &Arc<Self>, conn: u64, frame: WireFrame) {
        match frame {
            WireFrame::PairAck(ack) => self.complete_pairing(conn, ack),
            WireFrame::Envelope(env) => self.handle_envelope(conn, env),
            WireFrame::Ack(_) => {}
        }
    }

    fn handle_envelope(self: &Arc<Self>, conn: u64, env: EncryptedEnvelope) {
        let phone_id = env.sender_device_id.clone();
        let result;
        let resync;
        {
            let mut g = self.inner.lock().unwrap();
            let connected = g.trusted.contains_key(&phone_id);
            let Some(phone) = g.phones.get_mut(&phone_id) else { return };
            result = phone.channel.open(&env, now_ms());
            resync = if result.is_err() && !connected {
                let recent = g.last_resync.get(&conn).map(|t| t.elapsed() < Duration::from_secs(5)).unwrap_or(false);
                if recent {
                    None
                } else {
                    g.last_resync.insert(conn, Instant::now());
                    let phone = g.phones.get_mut(&phone_id).unwrap();
                    phone.channel.seal(serde_json::json!({"ack": {"acked_message_id": "resync"}}), now_ms()).ok()
                }
            } else {
                None
            };
            Self::mark_dirty(&mut g);
        }
        match result {
            Ok(payload) => {
                self.trust(conn, &phone_id);
                self.handle_body(&phone_id, payload.body);
                self.maybe_rekey(&phone_id);
            }
            Err(e) => {
                log::warn!("dropped envelope {}: {e}", env.message_id);
                if let Some(env) = resync {
                    // We restarted and lost the forward-secret keys: tell the phone instead of waiting minutes.
                    self.send_raw_frame(conn, &WireFrame::Envelope(env));
                }
            }
        }
    }

    fn handle_body(self: &Arc<Self>, phone_id: &str, body: serde_json::Value) {
        if let Some(r) = body.get("rekey") {
            let epoch = r.get("epoch_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let eph = r.get("eph_pub").and_then(|v| v.as_str()).and_then(unb64).unwrap_or_default();
            let reply = r.get("reply").and_then(|v| v.as_bool()).unwrap_or(false);
            let out = {
                let mut g = self.inner.lock().unwrap();
                g.phones.get_mut(phone_id).and_then(|p| p.channel.handle_rekey(&epoch, &eph, reply))
            };
            if let Some(out) = out {
                self.transmit(phone_id, out);
            }
            return;
        }
        if let Some(m) = body.get("media_endpoint") {
            if let Some(ep) = MediaEndpoint::from_json(m) {
                let mut g = self.inner.lock().unwrap();
                if let Some(p) = g.phones.get_mut(phone_id) {
                    p.media = Some(ep);
                }
            }
            self.emit_phones();
        }
        if body.get("ack").is_some() {
            return;
        }
        let _ = self.app.emit("payload", serde_json::json!({ "phone_id": phone_id, "body": body }));
    }

    fn maybe_rekey(self: &Arc<Self>, phone_id: &str) {
        let req = {
            let mut g = self.inner.lock().unwrap();
            if !g.trusted.contains_key(phone_id) {
                return;
            }
            g.phones.get_mut(phone_id).and_then(|p| p.channel.rekey_request_if_due())
        };
        if let Some(req) = req {
            self.transmit(phone_id, req);
        }
    }

    /// Seals `body` for one phone and sends it on that phone's verified socket. Returns false when it is offline.
    pub fn transmit(&self, phone_id: &str, body: serde_json::Value) -> bool {
        let (conn, env) = {
            let mut g = self.inner.lock().unwrap();
            let Some(conn) = g.trusted.get(phone_id).copied() else { return false };
            let Some(phone) = g.phones.get_mut(phone_id) else { return false };
            let Ok(env) = phone.channel.seal(body, now_ms()) else { return false };
            Self::mark_dirty(&mut g);
            (conn, env)
        };
        self.send_raw_frame(conn, &WireFrame::Envelope(env));
        true
    }

    // ------------------------------------------------------------------ pairing

    fn complete_pairing(self: &Arc<Self>, conn: u64, ack: PairAckEnvelope) {
        let outcome = {
            let mut g = self.inner.lock().unwrap();
            let Some(session) = g.pairing.as_ref().filter(|s| s.session_id == ack.session_id && s.expires > Instant::now()) else { return };
            let secret = session.secret.clone();
            let mac_pub = PublicKey::from(&g.identity);
            let Some(keys) = SessionKeys::derive(&g.identity, &ack.android_pub_key, &ack.session_id) else { return };
            let Some(body) = crypto::open_pair_ack(&ack, &keys) else { return };
            // The secret never traveled over the network, so only the phone in the confirmed exchange can produce this proof.
            let Some(proof) = unb64(&body.proof) else { return };
            if !crypto::verify_pair_proof(&proof, &secret, &ack.session_id, &ack.android_pub_key, mac_pub.as_bytes()) {
                log::warn!("rejected a pairing request with an invalid proof");
                return;
            }
            let dev = PairedDevice {
                android_device_id: ack.android_device_id.clone(),
                device_name: body.device_name.clone(),
                manufacturer: body.manufacturer.clone(),
                os_version: body.os_version.clone(),
                android_public_key: b64(&ack.android_pub_key),
                session_id: ack.session_id.clone(),
                paired_at_ms: now_ms(),
                out_seq: 0,
                in_seq: 0,
            };
            let Some(phone) = Self::build_phone(&g.identity, &g.device_id, dev.clone()) else { return };
            g.store.data.devices.retain(|d| d.android_device_id != dev.android_device_id);
            g.store.data.devices.push(dev.clone());
            g.store.save();
            g.phones.insert(dev.android_device_id.clone(), phone); // same device id = re-pair: new keys, history kept
            g.pairing = None;
            g.nearby_state = NearbyState::Idle;
            g.nearby_decision = None;
            dev
        };
        self.trust(conn, &outcome.android_device_id);
        // Encrypted confirmation: proves to the phone that this side derived the same keys.
        self.transmit(&outcome.android_device_id, serde_json::json!({"ack": {"acked_message_id": ack.session_id}}));
        let _ = self.app.emit("nearby", NearbyState::Idle);
        let _ = self.app.emit("paired", &outcome.android_device_id);
        self.emit_phones();
    }

    pub fn nearby_phones(&self) -> Vec<NearbyPhone> {
        let g = self.inner.lock().unwrap();
        let mut seen = std::collections::HashSet::new();
        let mut v: Vec<NearbyPhone> = g.nearby_found.values().map(|(p, _, _)| p.clone()).filter(|p| seen.insert(p.name.clone())).collect();
        v.sort_by(|a, b| a.name.cmp(&b.name));
        v
    }

    fn start_browse(self: &Arc<Self>) {
        // Emulator testing only: `PHONEPIGEON_NEARBY_HOST=127.0.0.1:39253` lists a phone that mDNS cannot reach (adb forward).
        if let Ok(spec) = std::env::var("PHONEPIGEON_NEARBY_HOST") {
            if let Some((ip, port)) = spec.rsplit_once(':') {
                if let (Ok(ip), Ok(port)) = (ip.parse::<std::net::IpAddr>(), port.parse::<u16>()) {
                    let p = NearbyPhone { id: format!("test-{spec}"), name: "Test phone".into(), model: spec.clone() };
                    self.inner.lock().unwrap().nearby_found.insert(p.id.clone(), (p, vec![ip], port));
                }
            }
        }
        let Ok(daemon) = ServiceDaemon::new() else { return };
        let Ok(receiver) = daemon.browse("_pigeonphone._tcp.local.") else { return };
        let core = self.clone();
        std::thread::spawn(move || {
            let _keep = daemon; // the daemon must outlive the receiver
            while let Ok(ev) = receiver.recv() {
                match ev {
                    ServiceEvent::ServiceResolved(info) => {
                        let fullname = info.get_fullname().to_string();
                        let inst = fullname.split("._pigeonphone").next().unwrap_or(&fullname).to_string();
                        let name = inst.strip_prefix("PhonePigeon · ").unwrap_or(&inst).to_string();
                        let model = info.get_property_val_str("model").unwrap_or("").to_string();
                        let addrs: Vec<std::net::IpAddr> = info.get_addresses().iter().copied().collect();
                        let entry = (NearbyPhone { id: fullname.clone(), name, model }, addrs, info.get_port());
                        core.inner.lock().unwrap().nearby_found.insert(fullname, entry);
                        let _ = core.app.emit("nearby_list", core.nearby_phones());
                    }
                    ServiceEvent::ServiceRemoved(_, fullname) => {
                        core.inner.lock().unwrap().nearby_found.remove(&fullname);
                        let _ = core.app.emit("nearby_list", core.nearby_phones());
                    }
                    _ => {}
                }
            }
        });
    }

    fn set_nearby(&self, state: NearbyState) {
        self.inner.lock().unwrap().nearby_state = state.clone();
        let _ = self.app.emit("nearby", state);
    }

    pub fn nearby_state(&self) -> NearbyState {
        self.inner.lock().unwrap().nearby_state.clone()
    }

    /// Mac-style nearby pairing: commit → offer → reveal → both people confirm a six-digit code → encrypted PairAck.
    pub fn nearby_begin(self: &Arc<Self>, id: String) {
        let (target, mac_pub, device_id, lan_port) = {
            let g = self.inner.lock().unwrap();
            if !matches!(g.nearby_state, NearbyState::Idle | NearbyState::Failed { .. }) {
                return;
            }
            let Some((p, addrs, port)) = g.nearby_found.get(&id).cloned() else { return };
            (
                (p, addrs, port),
                PublicKey::from(&g.identity).as_bytes().to_vec(),
                g.device_id.clone(),
                g.lan_port,
            )
        };
        let (phone, addrs, port) = target;
        let cancel = Arc::new(Notify::new());
        let (dec_tx, mut dec_rx) = mpsc::unbounded_channel::<bool>();
        {
            let mut g = self.inner.lock().unwrap();
            g.nearby_cancel = Some(cancel.clone());
            g.nearby_decision = Some(dec_tx);
        }
        self.set_nearby(NearbyState::Connecting { phone: phone.name.clone() });
        let core = self.clone();
        tauri::async_runtime::spawn(async move {
            let run = core.clone().nearby_run(phone.name.clone(), addrs, port, mac_pub, device_id, lan_port, &mut dec_rx);
            tokio::select! {
                _ = cancel.notified() => {}
                r = tokio::time::timeout(Duration::from_secs(150), run) => {
                    match r {
                        Ok(Ok(())) => {}
                        Ok(Err(m)) => core.set_nearby(NearbyState::Failed { message: m }),
                        Err(_) => core.set_nearby(NearbyState::Failed { message: "The phone didn't answer in time.".into() }),
                    }
                }
            }
        });
    }

    async fn nearby_run(
        self: Arc<Self>, phone_name: String, addrs: Vec<std::net::IpAddr>, port: u16, mac_pub: Vec<u8>, device_id: String, lan_port: u16,
        decisions: &mut mpsc::UnboundedReceiver<bool>,
    ) -> Result<(), String> {
        let mut stream = None;
        for a in &addrs {
            if let Ok(Ok(s)) = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect((*a, port))).await {
                stream = Some(s);
                break;
            }
        }
        let mut stream = stream.ok_or("Couldn't reach the phone. Both devices need to be on the same Wi-Fi.")?;
        let session_id = uuid::Uuid::new_v4().to_string();
        let mut nonce = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut nonce);
        // Commit to our key before the phone reveals its own, so nobody in the middle can pick keys that make the codes match.
        let commit = crypto::nearby_commit(&mac_pub, &nonce, &session_id);
        let hello = serde_json::json!({"type": "hello", "v": 1, "commit": b64(&commit), "mac_name": device_name()});
        write_msg(&mut stream, &hello).await?;

        let offer_raw = read_msg(&mut stream).await?;
        let offer: Offer = serde_json::from_slice(&offer_raw).map_err(|_| "The phone sent an invalid key.")?;
        let phone_pub = unb64(&offer.android_pub_key).filter(|k| k.len() == 32).ok_or("The phone sent an invalid key.")?;
        let name = if offer.device_name.is_empty() { phone_name } else { offer.device_name.clone() };
        let code = crypto::nearby_sas(&session_id, &mac_pub, &phone_pub);
        let secret = crypto::nearby_pairing_secret(&session_id, &mac_pub, &phone_pub, &nonce);
        {
            let mut g = self.inner.lock().unwrap();
            g.pairing = Some(PairingSession { session_id: session_id.clone(), secret: secret.to_vec(), expires: Instant::now() + Duration::from_secs(180) });
        }
        let lan_host = local_ip_address::local_ip().ok().map(|ip| format!("{ip}:{lan_port}"));
        let reveal = serde_json::json!({
            "type": "reveal", "mac_device_id": device_id, "mac_pub_key": b64(&mac_pub), "nonce": b64(&nonce),
            "session_id": session_id, "relay_url": "", "lan_host": lan_host, "mac_name": device_name(),
        });
        write_msg(&mut stream, &reveal).await?;
        let shown = Instant::now();
        self.set_nearby(NearbyState::Confirm { phone: name.clone(), code });

        // Wait for the user to confirm here (the code must be readable for a moment first) and for the phone's decision.
        // The socket is read by its own task: reading inside `select!` could drop half a frame when the other branch wins.
        let (mut rd, mut wr) = stream.into_split();
        let (msg_tx, mut msg_rx) = mpsc::unbounded_channel::<Result<Vec<u8>, String>>();
        let reader = tauri::async_runtime::spawn(async move {
            loop {
                let r = read_msg_from(&mut rd).await;
                let stop = r.is_err();
                if msg_tx.send(r).is_err() || stop {
                    break;
                }
            }
        });
        let mut confirmed = false;
        let outcome: Result<(), String> = loop {
            tokio::select! {
                d = decisions.recv() => {
                    match d {
                        Some(true) if !confirmed => {
                            if shown.elapsed() < Duration::from_millis(1500) { continue }
                            if let Err(e) = write_msg_to(&mut wr, &serde_json::json!({"type": "decision", "accepted": true})).await { break Err(e) }
                            confirmed = true;
                            self.set_nearby(NearbyState::Finishing { phone: name.clone() });
                        }
                        Some(false) | None => {
                            let _ = write_msg_to(&mut wr, &serde_json::json!({"type": "decision", "accepted": false})).await;
                            break Err("Pairing was cancelled.".into());
                        }
                        _ => {}
                    }
                }
                m = msg_rx.recv() => {
                    match m {
                        Some(Ok(raw)) => {
                            let v: serde_json::Value = serde_json::from_slice(&raw).unwrap_or_default();
                            if v.get("accepted").and_then(|a| a.as_bool()) == Some(false) {
                                break Err("The phone declined or the codes didn't match.".into());
                            }
                        }
                        Some(Err(e)) if !confirmed => break Err(e),
                        None if !confirmed => break Err("The phone closed the connection.".into()),
                        _ => break Ok(()), // the phone closes once it has what it needs
                    }
                }
            }
        };
        reader.abort();
        outcome
    }

    pub fn nearby_confirm(&self) {
        if let Some(tx) = &self.inner.lock().unwrap().nearby_decision {
            let _ = tx.send(true);
        }
    }

    pub fn nearby_cancel(&self) {
        let (cancel, decision) = {
            let mut g = self.inner.lock().unwrap();
            g.pairing = None;
            (g.nearby_cancel.take(), g.nearby_decision.take())
        };
        if let Some(d) = decision {
            let _ = d.send(false);
        }
        if let Some(c) = cancel {
            c.notify_waiters();
        }
        self.set_nearby(NearbyState::Idle);
    }

    pub fn nearby_dismiss(&self) {
        let mut g = self.inner.lock().unwrap();
        if matches!(g.nearby_state, NearbyState::Failed { .. }) {
            g.nearby_state = NearbyState::Idle;
            drop(g);
            let _ = self.app.emit("nearby", NearbyState::Idle);
        }
    }

    // ------------------------------------------------------------------ queries

    pub fn phones(&self) -> Vec<PhoneInfo> {
        let g = self.inner.lock().unwrap();
        let mut v: Vec<PhoneInfo> = g
            .phones
            .values()
            .map(|p| {
                let conn = g.trusted.get(&p.dev.android_device_id);
                PhoneInfo {
                    id: p.dev.android_device_id.clone(),
                    name: p.dev.device_name.clone(),
                    manufacturer: p.dev.manufacturer.clone(),
                    os_version: p.dev.os_version.clone(),
                    paired_at_ms: p.dev.paired_at_ms,
                    connected: conn.is_some(),
                    host: conn.and_then(|c| g.conns.get(c)).map(|c| c.host.clone()),
                    fingerprint: crypto::fingerprint(&unb64(&p.dev.android_public_key).unwrap_or_default()),
                    media_ready: p.media.is_some(),
                }
            })
            .collect();
        v.sort_by_key(|p| p.paired_at_ms);
        v
    }

    pub fn emit_phones(&self) {
        let _ = self.app.emit("phones", self.phones());
    }

    pub fn own_fingerprint(&self) -> String {
        let g = self.inner.lock().unwrap();
        crypto::fingerprint(PublicKey::from(&g.identity).as_bytes())
    }

    pub fn media_endpoint(&self, phone_id: &str) -> Option<MediaEndpoint> {
        self.inner.lock().unwrap().phones.get(phone_id).and_then(|p| p.media.clone())
    }

    pub fn remove_phone(&self, phone_id: &str) {
        {
            let mut g = self.inner.lock().unwrap();
            g.phones.remove(phone_id);
            if let Some(c) = g.trusted.remove(phone_id).and_then(|c| g.conns.get(&c).map(|c| c.kill.clone())) {
                c.notify_one();
            }
            g.store.data.devices.retain(|d| d.android_device_id != phone_id);
            g.store.data.snapshots.remove(phone_id);
            g.store.save();
        }
        self.emit_phones();
    }

    pub fn snapshot_load(&self, phone_id: &str) -> Option<String> {
        self.inner.lock().unwrap().store.data.snapshots.get(phone_id).cloned()
    }

    pub fn snapshot_save(&self, phone_id: &str, json: String) {
        let mut g = self.inner.lock().unwrap();
        if g.phones.contains_key(phone_id) {
            g.store.data.snapshots.insert(phone_id.to_string(), json);
            g.store.save();
        }
    }

    pub fn settings_load(&self) -> String {
        self.inner.lock().unwrap().store.data.settings.clone()
    }

    pub fn settings_save(&self, json: String) {
        let mut g = self.inner.lock().unwrap();
        g.store.data.settings = json;
        g.store.save();
    }

    pub fn lan_port(&self) -> u16 {
        self.inner.lock().unwrap().lan_port
    }
}

async fn write_msg(s: &mut TcpStream, v: &serde_json::Value) -> Result<(), String> {
    let body = serde_json::to_vec(v).map_err(|e| e.to_string())?;
    if body.len() >= 4096 {
        return Err("message too large".into());
    }
    let mut out = (body.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(&body);
    s.write_all(&out).await.map_err(|_| "The phone closed the connection.".to_string())
}

async fn write_msg_to(w: &mut tokio::net::tcp::OwnedWriteHalf, v: &serde_json::Value) -> Result<(), String> {
    let body = serde_json::to_vec(v).map_err(|e| e.to_string())?;
    if body.len() >= 4096 {
        return Err("message too large".into());
    }
    let mut out = (body.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(&body);
    w.write_all(&out).await.map_err(|_| "The phone closed the connection.".to_string())
}

async fn read_msg_from(r: &mut tokio::net::tcp::OwnedReadHalf) -> Result<Vec<u8>, String> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len).await.map_err(|_| "The phone closed the connection.".to_string())?;
    let n = u32::from_be_bytes(len) as usize;
    if n == 0 || n > 4096 {
        return Err("The phone sent something unexpected.".into());
    }
    let mut body = vec![0u8; n];
    r.read_exact(&mut body).await.map_err(|_| "The phone closed the connection.".to_string())?;
    Ok(body)
}

async fn read_msg(s: &mut TcpStream) -> Result<Vec<u8>, String> {
    let mut len = [0u8; 4];
    s.read_exact(&mut len).await.map_err(|_| "The phone closed the connection.".to_string())?;
    let n = u32::from_be_bytes(len) as usize;
    if n == 0 || n > 4096 {
        return Err("The phone sent something unexpected.".into());
    }
    let mut body = vec![0u8; n];
    s.read_exact(&mut body).await.map_err(|_| "The phone closed the connection.".to_string())?;
    Ok(body)
}
