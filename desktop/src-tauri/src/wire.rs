//! JSON wire types shared with the Mac and Android apps. Keys are snake_case; byte fields are standard base64.

use serde::{Deserialize, Serialize};

mod b64 {
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(v: &Vec<u8>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(v))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD.decode(s).map_err(serde::de::Error::custom)
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct EncryptedEnvelope {
    pub message_id: String,
    pub sender_device_id: String,
    pub target_device_id: String,
    #[serde(with = "b64")]
    pub nonce: Vec<u8>,
    #[serde(with = "b64")]
    pub ciphertext: Vec<u8>,
    #[serde(default)]
    pub server_timestamp_ms: i64,
    #[serde(default)]
    pub requires_wakeup: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct PairAckEnvelope {
    pub session_id: String,
    pub android_device_id: String,
    #[serde(with = "b64")]
    pub android_pub_key: Vec<u8>,
    #[serde(with = "b64")]
    pub nonce: Vec<u8>,
    #[serde(with = "b64")]
    pub ciphertext: Vec<u8>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct PairAckBody {
    pub session_id: String,
    #[serde(default)]
    pub device_name: String,
    #[serde(default)]
    pub manufacturer: String,
    #[serde(default)]
    pub os_version: String,
    /// base64 of the HMAC proof.
    pub proof: String,
}

/// Frames on the LAN socket (4-byte big-endian length prefix, then this JSON).
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "snake_case")]
pub enum WireFrame {
    Envelope(EncryptedEnvelope),
    PairAck(PairAckEnvelope),
    Ack(String),
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct DevicePayload {
    pub sequence_number: u64,
    pub client_timestamp_ms: i64,
    /// One-key object: the protocol's `oneof` (e.g. `{"sms_message": {...}}`).
    pub body: serde_json::Value,
}
