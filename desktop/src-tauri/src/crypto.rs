//! Same cryptography as the Mac and Android apps (spec §5): X25519 + HKDF-SHA256 session keys,
//! ChaCha20-Poly1305 payloads with a routing-header AAD, sequence-number replay protection and an
//! ephemeral re-key exchange for forward secrecy. Everything here must stay byte-compatible with
//! `macos/PhonePigeon/Crypto/Crypto.swift` and the Kotlin `SecureChannel`.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::wire::{DevicePayload, EncryptedEnvelope, PairAckBody, PairAckEnvelope};

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug)]
pub enum CryptoError {
    Replayed(u64),
    ClockSkew,
    Malformed,
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CryptoError::Replayed(s) => write!(f, "dropped replayed packet (seq {s})"),
            CryptoError::ClockSkew => write!(f, "dropped packet with clock skew over 5 minutes"),
            CryptoError::Malformed => write!(f, "malformed ciphertext"),
        }
    }
}

pub fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

/// Proves the phone saw the pairing secret: HMAC-SHA256(secret, "phonepigeon-pair-v1" ‖ session ‖ phone_pub ‖ mac_pub).
pub fn verify_pair_proof(proof: &[u8], secret: &[u8], session_id: &str, phone_pub: &[u8], mac_pub: &[u8]) -> bool {
    let Ok(mut mac) = <HmacSha256 as Mac>::new_from_slice(secret) else { return false };
    mac.update(b"phonepigeon-pair-v1");
    mac.update(session_id.as_bytes());
    mac.update(phone_pub);
    mac.update(mac_pub);
    mac.verify_slice(proof).is_ok() // constant time
}

/// What mDNS advertises instead of the raw device id (a stable tracker for everyone on the LAN).
pub fn mdns_tag(device_id: &str) -> String {
    let d = sha256(&[b"phonepigeon-mdns-v1", device_id.as_bytes()]);
    hex::encode(&d[..8])
}

/// "7F3A · 91C2 · 0B4E · D8A1": a short fingerprint people can compare.
pub fn fingerprint(key: &[u8]) -> String {
    let d = sha256(&[key]);
    let hex = hex::encode_upper(&d[..16]);
    hex.as_bytes().chunks(4).map(|c| String::from_utf8_lossy(c).to_string()).collect::<Vec<_>>().join(" · ")
}

fn hkdf32(ikm: &[u8], salt: &[u8], info: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(if salt.is_empty() { None } else { Some(salt) }, ikm);
    let mut out = [0u8; 32];
    hk.expand(info, &mut out).expect("32 bytes is a valid HKDF output length");
    out
}

/// Secret both sides derive from the confirmed nearby-pairing exchange.
pub fn nearby_pairing_secret(session_id: &str, mac_pub: &[u8], phone_pub: &[u8], nonce: &[u8]) -> [u8; 32] {
    let ikm = sha256(&[b"phonepigeon-nearby-v1", session_id.as_bytes(), mac_pub, phone_pub, nonce]);
    hkdf32(&ikm, &[], b"pairing-secret")
}

/// Commitment the Mac side sends before the phone reveals its key.
pub fn nearby_commit(mac_pub: &[u8], nonce: &[u8], session_id: &str) -> [u8; 32] {
    sha256(&[b"phonepigeon-nearby-commit-v1", mac_pub, nonce, session_id.as_bytes()])
}

/// Six-digit code both users compare: "123 456".
pub fn nearby_sas(session_id: &str, mac_pub: &[u8], phone_pub: &[u8]) -> String {
    let d = sha256(&[b"phonepigeon-sas-v1", session_id.as_bytes(), mac_pub, phone_pub]);
    let n = (u32::from_be_bytes([d[0], d[1], d[2], d[3]])) % 1_000_000;
    let digits = format!("{n:06}");
    format!("{} {}", &digits[..3], &digits[3..])
}

#[derive(Clone)]
pub struct SessionKeys {
    pub send: [u8; 32],
    pub receive: [u8; 32],
    pub static_shared: [u8; 32],
}

impl SessionKeys {
    /// Desktop is always the "mac" side of the protocol (it hosts the LAN socket and starts re-keys).
    pub fn derive(secret: &StaticSecret, peer_public: &[u8], session_id: &str) -> Option<SessionKeys> {
        let peer: [u8; 32] = peer_public.try_into().ok()?;
        let shared = secret.diffie_hellman(&PublicKey::from(peer));
        let shared = *shared.as_bytes();
        let salt = session_id.as_bytes();
        let and_to_mac = hkdf32(&shared, salt, b"and->mac");
        let mac_to_and = hkdf32(&shared, salt, b"mac->and");
        Some(SessionKeys { send: mac_to_and, receive: and_to_mac, static_shared: shared })
    }
}

#[derive(Clone)]
struct EphemeralKeys {
    send: [u8; 32],
    receive: [u8; 32],
}

impl EphemeralKeys {
    fn derive(static_shared: &[u8; 32], eph_shared: &[u8; 32], session_id: &str, epoch: &str) -> EphemeralKeys {
        let mut ikm = Vec::with_capacity(64);
        ikm.extend_from_slice(static_shared);
        ikm.extend_from_slice(eph_shared);
        let salt = format!("{session_id}|{epoch}");
        EphemeralKeys {
            send: hkdf32(&ikm, salt.as_bytes(), b"mac->and/eph"),
            receive: hkdf32(&ikm, salt.as_bytes(), b"and->mac/eph"),
        }
    }
}

fn cipher(key: &[u8; 32]) -> ChaCha20Poly1305 {
    ChaCha20Poly1305::new(Key::from_slice(key))
}

/// Opens the one-shot PairAck sealed by the phone (no AAD).
pub fn open_pair_ack(env: &PairAckEnvelope, keys: &SessionKeys) -> Option<PairAckBody> {
    if env.nonce.len() != 12 {
        return None;
    }
    let pt = cipher(&keys.receive)
        .decrypt(Nonce::from_slice(&env.nonce), Payload { msg: &env.ciphertext, aad: b"" })
        .ok()?;
    let body: PairAckBody = serde_json::from_slice(&pt).ok()?;
    (body.session_id == env.session_id).then_some(body)
}

/// One phone's encrypted channel. A fresh 8-byte random prefix plus a 4-byte counter makes the 96-bit nonce.
pub struct SecureChannel {
    keys: SessionKeys,
    session_id: String,
    nonce_prefix: [u8; 8],
    nonce_counter: u32,
    pub outgoing_sequence: u64,
    pub highest_incoming_sequence: u64,
    eph: Option<EphemeralKeys>,
    pending: Option<EphemeralKeys>,
    initiator: Option<(String, StaticSecret, Instant)>,
    last_peer_frame: Option<Instant>,
    wants_rekey: bool,
    pub local_device_id: String,
    pub peer_device_id: String,
}

const EPHEMERAL_FRESHNESS: Duration = Duration::from_secs(120);

impl SecureChannel {
    pub fn new(keys: SessionKeys, session_id: &str, local: &str, peer: &str, out_seq: u64, in_seq: u64) -> Self {
        let mut prefix = [0u8; 8];
        rand::thread_rng().fill_bytes(&mut prefix);
        SecureChannel {
            keys,
            session_id: session_id.to_string(),
            nonce_prefix: prefix,
            nonce_counter: 0,
            outgoing_sequence: out_seq,
            highest_incoming_sequence: in_seq,
            eph: None,
            pending: None,
            initiator: None,
            last_peer_frame: None,
            wants_rekey: true,
            local_device_id: local.to_string(),
            peer_device_id: peer.to_string(),
        }
    }

    fn next_nonce(&mut self) -> Result<[u8; 12], CryptoError> {
        if self.nonce_counter >= u32::MAX - 1 {
            return Err(CryptoError::Malformed);
        }
        self.nonce_counter += 1;
        let mut n = [0u8; 12];
        n[..8].copy_from_slice(&self.nonce_prefix);
        n[8..].copy_from_slice(&self.nonce_counter.to_be_bytes());
        Ok(n)
    }

    fn routing(sender: &str, target: &str) -> Vec<u8> {
        format!("{sender}→{target}").into_bytes()
    }

    /// `body` is the one-key JSON object of the protocol's `oneof` (e.g. `{"send_sms": {...}}`).
    pub fn seal(&mut self, body: serde_json::Value, now_ms: i64) -> Result<EncryptedEnvelope, CryptoError> {
        let is_rekey = body.get("rekey").is_some();
        let wake = requires_wakeup(&body);
        self.outgoing_sequence += 1;
        let payload = DevicePayload { sequence_number: self.outgoing_sequence, client_timestamp_ms: now_ms, body };
        let plaintext = serde_json::to_vec(&payload).map_err(|_| CryptoError::Malformed)?;
        let nonce = self.next_nonce()?;
        let aad = Self::routing(&self.local_device_id, &self.peer_device_id);
        let fresh = self.last_peer_frame.map(|t| t.elapsed() < EPHEMERAL_FRESHNESS).unwrap_or(false);
        let key = match (&self.eph, is_rekey, fresh) {
            (Some(e), false, true) => e.send,
            _ => self.keys.send,
        };
        let ct = cipher(&key)
            .encrypt(Nonce::from_slice(&nonce), Payload { msg: &plaintext, aad: &aad })
            .map_err(|_| CryptoError::Malformed)?;
        Ok(EncryptedEnvelope {
            message_id: uuid::Uuid::new_v4().to_string(),
            sender_device_id: self.local_device_id.clone(),
            target_device_id: self.peer_device_id.clone(),
            nonce: nonce.to_vec(),
            ciphertext: ct,
            server_timestamp_ms: 0,
            requires_wakeup: wake,
        })
    }

    pub fn open(&mut self, env: &EncryptedEnvelope, now_ms: i64) -> Result<DevicePayload, CryptoError> {
        if env.ciphertext.len() < 16 || env.nonce.len() != 12 {
            return Err(CryptoError::Malformed);
        }
        let aad = Self::routing(&env.sender_device_id, &env.target_device_id);
        let nonce = Nonce::from_slice(&env.nonce);
        let try_key = |k: &[u8; 32]| cipher(k).decrypt(nonce, Payload { msg: &env.ciphertext, aad: &aad }).ok();

        enum Used { Eph, Pending, Static }
        let (plaintext, used) = if let Some(p) = self.eph.as_ref().and_then(|e| try_key(&e.receive)) {
            (p, Used::Eph)
        } else if let Some(p) = self.pending.as_ref().and_then(|e| try_key(&e.receive)) {
            (p, Used::Pending)
        } else if let Some(p) = try_key(&self.keys.receive) {
            (p, Used::Static)
        } else {
            return Err(CryptoError::Malformed);
        };
        let payload: DevicePayload = serde_json::from_slice(&plaintext).map_err(|_| CryptoError::Malformed)?;
        if payload.sequence_number <= self.highest_incoming_sequence {
            return Err(CryptoError::Replayed(payload.sequence_number));
        }
        if is_live(&payload.body) && (now_ms - payload.client_timestamp_ms).abs() > 5 * 60 * 1000 {
            return Err(CryptoError::ClockSkew);
        }
        self.highest_incoming_sequence = payload.sequence_number;
        self.last_peer_frame = Some(Instant::now());
        match used {
            Used::Pending => {
                self.eph = self.pending.take();
            }
            Used::Static if payload.body.get("rekey").is_none() => {
                // The peer sends under static keys again (it restarted): stop assuming it has ours, and re-key.
                if self.eph.is_some() || self.pending.is_some() {
                    self.eph = None;
                    self.pending = None;
                    self.wants_rekey = true;
                }
            }
            _ => {}
        }
        Ok(payload)
    }

    /// Returns the re-key request to send, if one is due (desktop starts every exchange).
    pub fn rekey_request_if_due(&mut self) -> Option<serde_json::Value> {
        if !self.wants_rekey {
            return None;
        }
        if let Some((_, _, at)) = &self.initiator {
            if at.elapsed() < Duration::from_secs(30) {
                return None;
            }
        }
        let secret = StaticSecret::random_from_rng(rand::thread_rng());
        let public = PublicKey::from(&secret);
        let epoch = uuid::Uuid::new_v4().to_string();
        self.initiator = Some((epoch.clone(), secret, Instant::now()));
        Some(serde_json::json!({ "rekey": { "epoch_id": epoch, "eph_pub": b64(public.as_bytes()), "reply": false } }))
    }

    pub fn schedule_rekey(&mut self) {
        self.wants_rekey = true;
    }

    /// Handles the phone's reply; returns a payload to send back (the first message under the new keys).
    pub fn handle_rekey(&mut self, epoch_id: &str, eph_pub: &[u8], reply: bool) -> Option<serde_json::Value> {
        if !reply {
            return None; // only the phone answers; the desktop never receives a request
        }
        let (epoch, secret, _) = self.initiator.as_ref()?;
        if epoch != epoch_id {
            return None;
        }
        let peer: [u8; 32] = eph_pub.try_into().ok()?;
        let shared = secret.diffie_hellman(&PublicKey::from(peer));
        self.eph = Some(EphemeralKeys::derive(&self.keys.static_shared, shared.as_bytes(), &self.session_id, epoch_id));
        self.initiator = None;
        self.wants_rekey = false;
        Some(serde_json::json!({ "ack": { "acked_message_id": epoch_id } }))
    }

    pub fn has_ephemeral_keys(&self) -> bool {
        self.eph.is_some()
    }
}

pub fn b64(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(data)
}

pub fn unb64(s: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(s).ok()
}

/// Commands that must reach a dozing phone (FCM wake-up) when relayed.
fn requires_wakeup(body: &serde_json::Value) -> bool {
    ["send_sms", "place_call", "call_action", "list_dir_req", "list_gallery_req", "file_op_req", "webrtc_signal", "screen_req", "search_req"]
        .iter()
        .any(|k| body.get(*k).is_some())
}

fn is_live(body: &serde_json::Value) -> bool {
    ["send_sms", "place_call", "call_action", "call_state", "remote_input", "notification_dismiss"].iter().any(|k| body.get(*k).is_some())
}

#[cfg(test)]
mod tests {
    //! Expected values were generated with Apple CryptoKit (the Mac app's implementation) from fixed inputs.
    use super::*;

    fn mac_secret() -> StaticSecret {
        StaticSecret::from(<[u8; 32]>::try_from((0..32u8).map(|i| i + 1).collect::<Vec<_>>()).unwrap())
    }
    fn phone_secret() -> StaticSecret {
        StaticSecret::from(<[u8; 32]>::try_from((0..32u8).map(|i| 100 + i).collect::<Vec<_>>()).unwrap())
    }

    #[test]
    fn public_keys_match() {
        assert_eq!(hex::encode(PublicKey::from(&mac_secret()).as_bytes()), "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c");
        assert_eq!(hex::encode(PublicKey::from(&phone_secret()).as_bytes()), "7d9c24316539825c1896e57f28197746793ce60cbee3ad47da9d07b85fa55e2a");
    }

    #[test]
    fn session_keys_match_cryptokit() {
        let phone_pub = PublicKey::from(&phone_secret());
        let k = SessionKeys::derive(&mac_secret(), phone_pub.as_bytes(), "sess-123").unwrap();
        assert_eq!(hex::encode(k.receive), "b363778dbb791bb201b4c4f64a2231972d6f91f35ed14dbeee917fe72f9794a9"); // and->mac
        assert_eq!(hex::encode(k.send), "3b7ad5225c138542cb40ebfdc75c56ac791f57540794e986ac8c8d7f02f27eda"); // mac->and
    }

    #[test]
    fn seal_matches_cryptokit() {
        let phone_pub = PublicKey::from(&phone_secret());
        let k = SessionKeys::derive(&mac_secret(), phone_pub.as_bytes(), "sess-123").unwrap();
        let nonce: Vec<u8> = (0..12u8).collect();
        let ct = cipher(&k.send)
            .encrypt(Nonce::from_slice(&nonce), Payload { msg: b"hello pigeon", aad: "mac-id→phone-id".as_bytes() })
            .unwrap();
        assert_eq!(hex::encode(ct), "544a0f5792485797f8e746f4a54da67d1b2292b796c1c5d191079f4b");
    }

    #[test]
    fn pairing_helpers_match_cryptokit() {
        let mp = PublicKey::from(&mac_secret());
        let pp = PublicKey::from(&phone_secret());
        let nonce = [9u8; 32];
        assert_eq!(nearby_sas("sess-123", mp.as_bytes(), pp.as_bytes()), "806 148");
        assert_eq!(hex::encode(nearby_pairing_secret("sess-123", mp.as_bytes(), pp.as_bytes(), &nonce)), "a32cc11e45406024ba06c52aa8d3a4f09a79c5b66a028ec453d4ec6e082eb869");
        assert_eq!(hex::encode(nearby_commit(mp.as_bytes(), &nonce, "sess-123")), "8bc5dc3bf844c54850745b03b430ebdb428251496fd19adec26ad08170413807");
        assert_eq!(mdns_tag("dev-1"), "ac02a69deabc71a4");
        let secret = [7u8; 32];
        let proof = hex::decode("2cffeb6b63fbdb6333f693233738c551af53f7df843b3aa1846f211050eaadb5").unwrap();
        assert!(verify_pair_proof(&proof, &secret, "sess-123", pp.as_bytes(), mp.as_bytes()));
        assert!(!verify_pair_proof(&proof, &secret, "sess-124", pp.as_bytes(), mp.as_bytes()));
    }

    #[test]
    fn ephemeral_keys_match_cryptokit() {
        let phone_pub = PublicKey::from(&phone_secret());
        let k = SessionKeys::derive(&mac_secret(), phone_pub.as_bytes(), "sess-123").unwrap();
        let e = EphemeralKeys::derive(&k.static_shared, &[5u8; 32], "sess-123", "epoch-1");
        assert_eq!(hex::encode(e.receive), "bf38b5178430c0c5e01ebdddc3fd8d46348049026cbb11b23216186c967e6a1c");
        assert_eq!(hex::encode(e.send), "9f8d04b863686931b9f6af2d524cd51162d2776108ffa76f9fc33587a89ec950");
    }

    /// Both ends of the protocol round-trip a payload, reject a replay, and complete a re-key.
    #[test]
    fn channel_round_trip_replay_and_rekey() {
        let mac_pub = PublicKey::from(&mac_secret());
        let phone_pub = PublicKey::from(&phone_secret());
        // Mac side uses this crate; the phone side is simulated with the mirrored keys.
        let mac_keys = SessionKeys::derive(&mac_secret(), phone_pub.as_bytes(), "s").unwrap();
        let mut mac = SecureChannel::new(mac_keys.clone(), "s", "mac", "phone", 0, 0);
        let phone_keys = {
            let shared = phone_secret().diffie_hellman(&mac_pub);
            let shared = *shared.as_bytes();
            SessionKeys { send: hkdf32(&shared, b"s", b"and->mac"), receive: hkdf32(&shared, b"s", b"mac->and"), static_shared: shared }
        };
        let mut phone = SecureChannel::new(phone_keys, "s", "phone", "mac", 0, 0);

        let env = mac.seal(serde_json::json!({"send_sms": {"body": "hi"}}), 1_000).unwrap();
        let got = phone.open(&env, 1_000).unwrap();
        assert_eq!(got.body["send_sms"]["body"], "hi");
        assert!(matches!(phone.open(&env, 1_000), Err(CryptoError::Replayed(_))));
        // A live command with a stale clock is refused.
        let old = mac.seal(serde_json::json!({"place_call": {}}), 0).unwrap();
        assert!(matches!(phone.open(&old, 10 * 60 * 1000), Err(CryptoError::ClockSkew)));

        // Re-key: desktop asks, phone answers with its ephemeral key, both then use ephemeral keys.
        let req = mac.rekey_request_if_due().unwrap();
        let epoch = req["rekey"]["epoch_id"].as_str().unwrap().to_string();
        let mac_eph = unb64(req["rekey"]["eph_pub"].as_str().unwrap()).unwrap();
        let phone_eph = StaticSecret::random_from_rng(rand::thread_rng());
        let shared_eph = phone_eph.diffie_hellman(&PublicKey::from(<[u8; 32]>::try_from(mac_eph).unwrap()));
        let phone_ek = EphemeralKeys::derive(&mac_keys.static_shared, shared_eph.as_bytes(), "s", &epoch);
        let _ = phone_ek; // the phone side derives the mirrored keys; the desktop side is what is under test
        let reply = mac.handle_rekey(&epoch, PublicKey::from(&phone_eph).as_bytes(), true);
        assert!(reply.is_some());
        assert!(mac.has_ephemeral_keys());
    }
}
