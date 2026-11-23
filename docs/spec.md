# Project Specification: Multi-SIM SMS, Call Audio & File Explorer Companion (Android + macOS)

> **Note:** this is the original design spec. The implementation has moved on in places: pairing is now nearby-only (no QR code), the app is named PhonePigeon, and Android uses no CameraX or ML Kit. Where they differ, the README and `docs/security-review.md` are current.

**Version:** 2.0.0  
**Status:** Ready for Development  
**Target Platforms:** Android 10+ (API 29+), macOS 14+ (Sonoma), Linux (Relay Server)

---

## 1. Executive Summary & Goals

This document defines the complete architecture, wire protocols, data models, and implementation details for a production-grade, end-to-end encrypted (E2EE) desktop companion system connecting an **Android smartphone** to a **macOS desktop app**.

### Core Capabilities

1. **Multi-SIM Inventory & Routing:** Automatically detect all active physical SIMs and eSIMs on Android, display carrier labels/colors on macOS, and allow per-message and per-call SIM selection.
2. **Real-Time SMS/MMS Sync:** Bidirectional synchronization of historical threads and real-time incoming/outgoing messages with delivery receipts and OTP auto-copy.
3. **Full Bidirectional Voice Calls on Mac (Incoming & Outgoing):**
   * **Receive & Talk on Mac:** Incoming cellular calls ring natively on macOS (`CallKit`), allowing the user to answer and speak directly using the Mac's microphone and speakers/AirPods.
   * **Dial & Talk from Mac:** Users can dial any number or contact from macOS, pick which SIM card to use (SIM 1 / SIM 2), and immediately talk through the Mac without touching the phone.
4. **Phone Media Gallery & File Explorer:**
   * Browse Android **Photos & Videos** by album/timeline with fast cached thumbnails.
   * Stream videos directly from the phone with timeline scrubbing (HTTP Range requests / `AVPlayer`).
   * Browse the full Android **File System** (Downloads, Documents, DCIM, SD Card), with QuickLook previews, drag-and-drop upload/download between Finder and phone, rename, and delete.
5. **Zero-Knowledge E2EE & Hybrid Transport:** All control messages, SMS, call metadata, and files are end-to-end encrypted. Uses high-speed **Local LAN (mDNS + mTLS)** on the same Wi-Fi and seamlessly falls back to **Cloud Relay / WebRTC P2P** when remote.

---

## 2. System Architecture (Three-Plane Design)

To satisfy OS security constraints and high-bandwidth media transfers without blocking real-time messaging, the system is divided into **three distinct planes**:

```text
+--------------------------------------+         +--------------------------------------+
|             macOS Client             |         |            Android Client            |
|       (Swift + SwiftUI + GRDB)       |         |     (Kotlin + Jetpack Compose)       |
+--------------------------------------+         +--------------------------------------+
| [UI] Messages | Dialer | Gallery/FS  |         | [Svc] Foreground Relay + InCallSvc   |
| [Crypto] X25519 + ChaCha20-Poly1305  |         | [Crypto] X25519 + ChaCha20-Poly1305  |
|                                      |         |                                      |
| PLANE 1: VOICE AUDIO (Bidirectional) |         | PLANE 1: VOICE AUDIO (Bidirectional) |
| [CallKit] + [BT HFP HF Role Daemon]  |<=======>| [Android OS Bluetooth HFP Gateway]   |
| [CoreAudio VoiceProcessingIO Bridge] | BT SCO  | [InCallService Route -> Bluetooth]   |
|                                      |         |                                      |
| PLANE 2: BULK MEDIA & FILE STREAMING |         | PLANE 2: BULK MEDIA & FILE STREAMING |
| [AVPlayer / File Transfer Manager]   |<=======>| [Embedded Ktor mTLS HTTP/2 Server]   |
| [WebRTC DataChannel (Remote P2P)]    | LAN/P2P | [MediaStore + FileSystem + Thumbs]   |
+------------------+-------------------+         +------------------+-------------------+
                   |                                                |
                   |  PLANE 3: CONTROL, SMS & METADATA              |
                   |  Priority 1: Local LAN (mDNS + mTLS TCP)       |
                   |<---------------------------------------------->|
                   |  Priority 2: Remote WSS (E2EE Protobuf)        |
                   v                                                v
          +------------------------------------------------------------------+
          |                     Go Cloud Relay Server                        |
          |  [WebSocket Hub] <---> [Redis Pub/Sub & 24h Offline Queue]       |
          |  [REST Pairing/Auth]   [FCM Push Wakeup]   [COTURN STUN/TURN]    |
          |  [PostgreSQL: Device Public Keys & Pairing Metadata Only]        |
          +------------------------------------------------------------------+
```

### Why Three Planes?
* **Plane 1 (Voice Audio via Bluetooth HFP):** Android blocks third-party apps from reading or injecting raw cellular voice audio streams. Registering macOS as a **Bluetooth Hands-Free Unit (HFP HF)** allows Android to natively route real-time, low-latency wideband cellular audio (`mSBC` 16kHz) to and from the Mac for both incoming and outgoing calls.
* **Plane 2 (Bulk Media & Files):** Streaming a 500MB video or browsing 5,000 photos must never clog the WebSocket control channel or Redis. On LAN, Android serves files directly over an **embedded mTLS HTTP/2 server** supporting `Range` requests for instant video seeking. Off-LAN (remote), clients establish a **WebRTC DataChannel (DTLS-SRTP P2P)** using STUN/TURN for direct E2EE transfers.
* **Plane 3 (Control & SMS):** Lightweight Protobuf frames over LAN mTLS TCP or Cloud WebSockets, with High-Priority FCM wakeup when Android is in Doze mode.

---

## 3. Monorepo Structure

```text
phonepigeon-relay/
├── proto/
│   ├── relay.proto                # Shared wire protocol (SMS, Calls, Files, Signaling)
│   └── buf.yaml                   # Buf CLI config for Go/Kotlin/Swift codegen
├── backend/                       # Go Relay Server + Signaling
│   ├── cmd/server/main.go
│   ├── internal/
│   │   ├── auth/                  # JWT & X25519 device key verification
│   │   ├── ws/                    # Gorilla WebSocket hub & WebRTC ICE signaling relay
│   │   ├── queue/                 # Redis Pub/Sub & 24h offline message store
│   │   ├── fcm/                   # Firebase Admin SDK Doze wakeup dispatcher
│   │   └── db/                    # PostgreSQL migrations & sqlc queries
│   ├── coturn/                    # TURN server config for remote P2P file transfers
│   ├── Dockerfile
│   └── docker-compose.yml
├── android/                       # Kotlin Android App
│   ├── app/src/main/java/com/phonepigeon/
│   │   ├── telephony/             # SubscriptionManager, SmsManager, TelecomManager
│   │   ├── service/               # RelayForegroundService, RelayInCallService, FCMService
│   │   ├── media/                 # Embedded Ktor mTLS HTTP/2 File/Thumbnail/Stream Server
│   │   ├── storage/               # MediaStore indexer, File explorer, Thumbnail cache
│   │   ├── webrtc/                # WebRTC DataChannel peer for remote file access
│   │   ├── crypto/                # Lazysodium X25519 + ChaCha20-Poly1305
│   │   ├── network/               # OkHttp WSS + NSD (mDNS) LAN advertiser
│   │   ├── data/                  # Room DB (SQLCipher) + ContentResolver observers
│   │   └── ui/                    # Jetpack Compose (QR Scanner, Permissions, Status)
│   └── build.gradle.kts
└── macos/                         # Swift macOS App
    ├── PhonePigeon/
    │   ├── App/                   # SwiftUI App lifecycle, MenuBarExtra
    │   ├── Telephony/             # CallKit (CXProvider), Dialer, Bluetooth HFP HF Daemon
    │   ├── Audio/                 # CoreAudio VoiceProcessingIO (AEC/NS) <-> BT SCO Bridge
    │   ├── Files/                 # HTTP/2 LAN Client, WebRTC P2P Client, QuickLook, AVPlayer
    │   ├── Crypto/                # Apple CryptoKit (Curve25519 + ChaChaPoly)
    │   ├── Network/               # URLSessionWebSocketTask + NWBrowser (Bonjour)
    │   ├── Storage/               # GRDB.swift + SQLCipher local store
    │   └── UI/                    # Sidebar: Messages, Calls/Dialer, Photos/Videos, Files
    └── PhonePigeon.xcodeproj
```

---

## 4. Tech Stack & Dependencies

| Component | Language / Framework | Key Libraries |
| :--- | :--- | :--- |
| **Android App** | Kotlin 2.0+, Jetpack Compose, Min SDK 29, Target SDK 35 | `OkHttp` (WSS), `Ktor-Server-CIO` (Embedded LAN File/Media Server), `WebRTC-Android` (Remote P2P Files), `Protobuf-Kotlin`, `Lazysodium-Android`, `Room` + `SQLCipher`, `CameraX` + `MLKit`, `Firebase Messaging` |
| **macOS App** | Swift 6, SwiftUI, Min macOS 14.0 | `CryptoKit`, `SwiftProtobuf`, `GRDB.swift` + `SQLCipher`, `CallKit`, `IOBluetooth`, `CoreAudio` / `AVFoundation` / `AVKit`, `QuickLookUI`, `WebRTC.xcframework`, `Network.framework`, `Sparkle` |
| **Relay Backend** | Go 1.23+ | `gorilla/websocket`, `redis/go-redis`, `jackc/pgx`, `firebase.google.com/go/v4`, `google.golang.org/protobuf`, `coturn` (Dockerized STUN/TURN) |

---

## 5. Deep Dive: Bidirectional Voice Calls on Mac (Incoming & Outgoing)

This section guarantees that you can **talk and listen directly on your Mac** both when receiving a call and when dialing out from your Mac on a specific SIM.

### 5.1 Bluetooth HFP (Hands-Free Profile) Architecture
* **Role Assignment:**
  * **Android Phone:** Acts as the **Audio Gateway (AG)** (native Android OS Bluetooth stack).
  * **macOS App:** Registers as a **Hands-Free Unit (HF)** (Bluetooth SDP Service Class UUID `0x111E`, HFP v1.7+ with Wideband Speech `mSBC` codec).
* **Pairing Onboarding:** During initial setup, the macOS app guides the user to pair the Android phone over Bluetooth and enables the "Phone Calls" profile on Android's Bluetooth device settings for the Mac.

### 5.2 Outgoing Call Flow (Dialing from Mac on Specific SIM)
Standard Bluetooth HFP `ATD` commands cannot specify which SIM card to use on Dual-SIM phones. We combine our **Control Plane** (for SIM selection) with **Bluetooth HFP** (for voice audio):

1. User opens the macOS Dialer (or clicks a contact), selects **SIM 1** or **SIM 2**, and clicks **Call**.
2. macOS ensures the Bluetooth HFP RFCOMM link to the phone is connected and reports an outgoing call to macOS `CallKit` (`CXStartCallAction`).
3. macOS sends `PlaceCallCommand(subscription_id, phone_number)` over the Control Plane (LAN/WSS).
4. Android receives `PlaceCallCommand`, resolves the `PhoneAccountHandle` for `subscription_id`, and invokes `TelecomManager.placeCall(...)`.
5. **Audio Routing Enforcement:** Android's `RelayInCallService` detects the new outgoing call and checks `callAudioState.route`. If it is not already `ROUTE_BLUETOOTH`, it explicitly calls `requestBluetoothAudio(macBluetoothDevice)` / `setAudioRoute(ROUTE_BLUETOOTH)`.
6. Android opens the Bluetooth eSCO/SCO (`mSBC` 16kHz) audio channel to the Mac.
7. macOS `AudioBridge` routes the incoming SCO audio to the user's active macOS output device (Mac speakers or AirPods) and routes the Mac's microphone through Apple's `VoiceProcessingIO` AudioUnit (providing hardware Acoustic Echo Cancellation & Noise Suppression) back into the Bluetooth SCO uplink.

### 5.3 Incoming Call Flow (Receiving & Talking on Mac)
1. Phone receives an incoming cellular call on SIM 1 or SIM 2.
2. Android sends `CallStateEvent(RINGING_INCOMING, subscription_id, caller_number, contact_name)` over the Control Plane.
3. macOS displays a native `CallKit` (`CXProvider`) incoming call banner showing the caller name, photo, and **SIM badge** (e.g., `Incoming on SIM 2 · Airtel`).
4. User clicks **Answer** on macOS (or presses AirPods stem).
5. macOS sends `CallActionCommand(ANSWER)` over the Control Plane (and/or `ATA` over HFP RFCOMM).
6. Android accepts the call (`Call.answer(VideoProfile.STATE_AUDIO_ONLY)`), routes audio to Bluetooth HFP, and live two-way audio starts immediately on the Mac.
7. **In-Call Controls:** Mute, Hold, Keypad DTMF tones (`0-9, *, #`), End Call, and an **"Audio Output Toggle"** (`Mac` $\leftrightarrow$ `Phone Speaker` $\leftrightarrow$ `Phone Earpiece`) stay synchronized in real time.

### 5.4 Edge Cases & Fallbacks
* **Bluetooth Out of Range:** If the user dials or answers from Mac while the phone is in another room out of Bluetooth range, macOS displays a non-blocking banner: *"Bluetooth audio unavailable — call active on phone."*
* **Echo Cancellation:** Running macOS mic capture through `kAudioUnitSubType_VoiceProcessingIO` prevents the remote caller from hearing their own voice echo through MacBook speakers.

---

## 6. Deep Dive: Phone Media Gallery & File Explorer

This section enables browsing photos, videos, and arbitrary files on the Android device from macOS with native Finder-like speed.

### 6.1 Dual-Mode Browsing
1. **Photos & Videos (Gallery Mode):**
   * Powered by Android `MediaStore.Images` and `MediaStore.Video`.
   * Supports virtual albums (`Camera`, `Screenshots`, `WhatsApp Images`, `Videos`, `Favorites`) and infinite-scroll chronological grid.
   * **Fast Thumbnails:** Android generates and caches `320x320` WebP thumbnails (15–30 KB each) using `ContentResolver.loadThumbnail()`. macOS fetches thumbnails in parallel batches over HTTP/2 multiplexing for 60fps scrolling.
2. **File Explorer Mode:**
   * Powered by Android NIO filesystem traversal rooted at `/storage/emulated/0` (plus mounted SD cards).
   * Supports directory listing, search by filename, sorting (name, size, date modified), creating folders, renaming, deleting (moving to Android Trash where supported), and viewing file metadata.

### 6.2 High-Speed Transfer & Video Streaming Transport
Never route media binaries through Redis or the main WebSocket text/control channel.

* **Mode A: Local LAN (Same Wi-Fi) — Embedded mTLS HTTP/2 Server (Default)**
  * Android runs a lightweight **Ktor CIO HTTPS server** bound to its Wi-Fi IP on an ephemeral port advertised via mDNS + Control Plane (`MediaServerEndpoint`).
  * Secured with **mutual TLS (mTLS)** using ephemeral X.509 certificates pinned to the paired X25519 keys, plus a rotating Bearer token.
  * **Endpoints on Android Embedded Server:**
    * `GET /media/thumb/{media_id}?w=320&h=320` — Returns cached WebP thumbnail.
    * `GET /media/file?path={url_encoded_path}` — Full file download with **HTTP `Range` (`206 Partial Content`)** support.
    * `PUT /media/upload?path={dest_path}` — Resumable chunked file upload from macOS to Android.
  * **Instant Video Streaming:** macOS feeds the authenticated LAN URL directly into `AVURLAsset` / `AVPlayer` (with a custom `AVAssetResourceLoaderDelegate` for mTLS trust). Users can play 4K videos straight off the phone and scrub anywhere in the timeline without downloading the entire file first.

* **Mode B: Remote Access (Phone on 5G / Different Wi-Fi) — WebRTC P2P DataChannel**
  * When LAN is unreachable, macOS and Android exchange WebRTC SDP offers/answers and ICE candidates over the existing E2EE Go Relay WebSocket (`WebRtcSignal`).
  * Once connected via P2P (or `coturn` TURN fallback), files and thumbnails stream over an encrypted **WebRTC SCTP DataChannel** in 64 KB chunks with flow control and resume offsets.
  * Optional **"Low-Data Preview"** toggle on macOS instructs Android to transcode/downscale remote photos to 1080p JPEG before transfer over cellular data.

### 6.3 macOS Gallery & File Explorer UX
* **QuickLook Integration:** Pressing `Spacebar` on any image, PDF, audio file, or video in the macOS File Explorer opens native macOS QuickLook (`QLPreviewPanel`).
* **Drag-and-Drop:**
  * Drag files from macOS Finder into any Android folder in the app $\to$ queues background upload with progress bar.
  * Drag photos or files from the app onto the macOS Desktop/Finder $\to$ triggers `NSFilePromiseProvider` background download.
* **Transfer Queue Manager:** Dedicated popover showing active uploads/downloads, transfer speed (MB/s), pause/resume, and SHA-256 integrity verification.

---

## 7. Security & End-to-End Encryption (E2EE)

1. **QR Code Pairing (Out-of-Band Key Exchange):**
   * macOS displays a QR code containing `{ v, session_id, mac_device_id, mac_pub_key, relay_url, lan_host }`.
   * Android scans the QR code, generates its own X25519 keypair, computes the shared secret $S = \text{X25519}(sk_{and}, pk_{mac})$, and derives directional symmetric keys via HKDF-SHA256:
     * $K_{\text{and}\to\text{mac}} = \text{HKDF}(S, \text{salt}=\text{session\_id}, \text{info}=\text{"and->mac"})$
     * $K_{\text{mac}\to\text{and}} = \text{HKDF}(S, \text{salt}=\text{session\_id}, \text{info}=\text{"mac->and"})$
     * $K_{\text{media\_token}} = \text{HKDF}(S, \text{salt}=\text{session\_id}, \text{info}=\text{"media-http-auth"})$
2. **Control Payload Encryption:** `ChaCha20-Poly1305` with 96-bit monotonic nonces and replay protection (`sequence_number`).
3. **Media/File Encryption:**
   * **LAN:** TLS 1.3 mTLS pinned to paired device keys.
   * **Remote P2P:** WebRTC DTLS 1.2/1.3 + optional application-layer chunk encryption with $K_{\text{and}\to\text{mac}}$.
4. **Zero-Knowledge Guarantee:** The Go Relay Server and TURN server never possess decryption keys and cannot inspect SMS text, phone numbers, call logs, photos, or filenames.

---

## 8. Wire Protocol (`proto/relay.proto`)

```protobuf
syntax = "proto3";
package phonepigeon.v1;

option go_package = "github.com/sarathkumar-21/phone-pigeon/backend/gen/relaypb";
option java_package = "dev.phonepigeon.proto";

// Outer unencrypted envelope routed by the Relay Server
message EncryptedEnvelope {
  string message_id = 1;
  string sender_device_id = 2;
  string target_device_id = 3;
  bytes nonce = 4;             // 12-byte ChaCha20-Poly1305 nonce
  bytes ciphertext = 5;        // Encrypted DevicePayload
  int64 server_timestamp_ms = 6;
  bool requires_wakeup = 7;    // Triggers High-Priority FCM if Android offline
}

// Inner decrypted payload (Zero-Knowledge to Server)
message DevicePayload {
  uint64 sequence_number = 1;
  int64 client_timestamp_ms = 2;

  oneof body {
    AckEvent ack = 10;
    // Telephony & SMS
    SimInventorySync sim_inventory = 11;
    SmsThreadSync sms_thread_sync = 12;
    SmsMessageEvent sms_message = 13;
    SendSmsCommand send_sms = 14;
    SmsStatusUpdate sms_status = 15;
    CallStateEvent call_state = 16;
    PlaceCallCommand place_call = 17;
    CallActionCommand call_action = 18;
    ContactSyncBatch contact_sync = 19;
    DeviceStatusEvent device_status = 20;
    // Files, Gallery & Media Transport
    MediaServerEndpoint media_endpoint = 30;
    ListDirectoryRequest list_dir_req = 31;
    ListDirectoryResponse list_dir_res = 32;
    ListMediaGalleryRequest list_gallery_req = 33;
    ListMediaGalleryResponse list_gallery_res = 34;
    FileOperationRequest file_op_req = 35;
    FileOperationResponse file_op_res = 36;
    WebRtcSignal webrtc_signal = 37;
  }
}

message AckEvent { string acked_message_id = 1; }

// --- MULTI-SIM & SMS ---
message SimCard {
  int32 subscription_id = 1;
  int32 slot_index = 2;        // 0 = SIM 1, 1 = SIM 2
  string carrier_name = 3;
  string display_name = 4;
  string phone_number = 5;
  string accent_color_hex = 6;
  bool is_default_sms = 7;
  bool is_default_voice = 8;
}

message SimInventorySync { repeated SimCard sims = 1; }

enum MessageDirection { DIRECTION_UNSPECIFIED = 0; INCOMING = 1; OUTGOING = 2; }
enum MessageStatus { STATUS_UNSPECIFIED = 0; PENDING = 1; SENT = 2; DELIVERED = 3; FAILED = 4; }

message SmsMessageEvent {
  string local_id = 1;
  string thread_id = 2;
  int32 subscription_id = 3;
  string address = 4;
  string body = 5;
  MessageDirection direction = 6;
  MessageStatus status = 7;
  int64 timestamp_ms = 8;
  bool is_read = 9;
}

message SmsThreadSync {
  repeated SmsMessageEvent messages = 1;
  bool has_more = 2;
}

message SendSmsCommand {
  string client_request_id = 1;
  int32 subscription_id = 2;
  string recipient_address = 3;
  string body = 4;
}

message SmsStatusUpdate {
  string client_request_id = 1;
  MessageStatus status = 2;
  string error_reason = 3;
}

// --- VOICE CALLS & AUDIO ROUTING ---
enum CallState {
  CALL_STATE_UNSPECIFIED = 0;
  RINGING_INCOMING = 1;
  DIALING_OUTGOING = 2;
  ACTIVE = 3;
  HOLDING = 4;
  DISCONNECTED = 5;
}

enum AudioRoute {
  AUDIO_ROUTE_UNSPECIFIED = 0;
  MAC_BLUETOOTH_HFP = 1;
  PHONE_EARPIECE = 2;
  PHONE_SPEAKER = 3;
  WIRED_HEADSET = 4;
}

message CallStateEvent {
  string call_id = 1;
  int32 subscription_id = 2;
  string remote_address = 3;
  string contact_name = 4;
  CallState state = 5;
  AudioRoute audio_route = 6;
  int64 started_at_ms = 7;
  bool is_muted = 8;
}

message PlaceCallCommand {
  string request_id = 1;
  int32 subscription_id = 2;
  string phone_number = 3;
  bool route_audio_to_mac = 4;     // True by default when dialing from Mac
}

enum CallAction {
  CALL_ACTION_UNSPECIFIED = 0;
  ANSWER = 1;
  REJECT = 2;
  END_CALL = 3;
  TOGGLE_MUTE = 4;
  SEND_DTMF = 5;
  SWITCH_AUDIO_ROUTE = 6;
}

message CallActionCommand {
  string call_id = 1;
  CallAction action = 2;
  string dtmf_digit = 3;
  AudioRoute target_audio_route = 4;
}

// --- CONTACTS & DEVICE STATUS ---
message ContactEntry {
  string contact_id = 1;
  string display_name = 2;
  repeated string phone_numbers = 3;
  bytes thumbnail_jpeg = 4;
}

message ContactSyncBatch {
  repeated ContactEntry contacts = 1;
  bool is_final_batch = 2;
}

message DeviceStatusEvent {
  int32 battery_percent = 1;
  bool is_charging = 2;
  bool bluetooth_hfp_connected = 3;
  int64 storage_free_bytes = 4;
  int64 storage_total_bytes = 5;
}

// --- MEDIA GALLERY & FILE EXPLORER ---
message MediaServerEndpoint {
  string lan_ip = 1;
  int32 https_port = 2;
  string session_bearer_token = 3;
  bytes server_cert_sha256 = 4;    // Pinning hash for mTLS
}

message FileEntry {
  string path = 1;                 // Relative to storage root, e.g. "/DCIM/Camera/IMG_01.jpg"
  string name = 2;
  bool is_directory = 3;
  int64 size_bytes = 4;
  string mime_type = 5;
  int64 modified_at_ms = 6;
  int32 child_count = 7;           // Populated if is_directory == true
}

message ListDirectoryRequest {
  string request_id = 1;
  string path = 2;                 // "/" for root (/storage/emulated/0)
  bool include_hidden = 3;
}

message ListDirectoryResponse {
  string request_id = 1;
  string path = 2;
  repeated FileEntry entries = 3;
  string error_message = 4;
}

enum MediaTypeFilter { MEDIA_ALL = 0; MEDIA_IMAGES = 1; MEDIA_VIDEOS = 2; }

message MediaItem {
  int64 media_store_id = 1;
  string path = 2;
  string display_name = 3;
  string bucket_name = 4;          // Album name (e.g., "Camera", "Screenshots")
  string mime_type = 5;
  int64 size_bytes = 6;
  int32 width = 7;
  int32 height = 8;
  int64 duration_ms = 9;           // > 0 for videos
  int64 date_taken_ms = 10;
}

message ListMediaGalleryRequest {
  string request_id = 1;
  MediaTypeFilter filter = 2;
  string bucket_name = 3;          // Empty = All albums
  int32 limit = 4;                 // Default 100
  int32 offset = 5;
}

message ListMediaGalleryResponse {
  string request_id = 1;
  repeated MediaItem items = 2;
  repeated string available_buckets = 3;
  bool has_more = 4;
}

enum FileOpType { FILE_OP_UNSPECIFIED = 0; MKDIR = 1; RENAME = 2; DELETE = 3; }

message FileOperationRequest {
  string request_id = 1;
  FileOpType op = 2;
  string source_path = 3;
  string target_path = 4;          // Used for RENAME
}

message FileOperationResponse {
  string request_id = 1;
  bool success = 2;
  string error_message = 3;
}

// WebRTC Signaling for off-LAN P2P file/media transfer
message WebRtcSignal {
  string session_id = 1;
  string signal_type = 2;          // "offer", "answer", "ice_candidate"
  string payload_json = 3;
}
```

---

## 9. Database Schemas

### 9.1 Cloud Relay Server (PostgreSQL)
Stores **only** device identity, public keys, pairing links, and FCM tokens. Zero user content.

```sql
CREATE TABLE devices (
    device_id UUID PRIMARY KEY,
    platform VARCHAR(16) NOT NULL CHECK (platform IN ('ANDROID', 'MACOS')),
    public_key BYTEA NOT NULL,
    fcm_token TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE pairings (
    pairing_id UUID PRIMARY KEY,
    android_device_id UUID NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    macos_device_id UUID NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (android_device_id, macos_device_id)
);
```

### 9.2 Local Client Store (SQLite + SQLCipher on macOS & Android)
```sql
CREATE TABLE sim_cards (
    subscription_id INTEGER PRIMARY KEY,
    slot_index INTEGER NOT NULL,
    carrier_name TEXT NOT NULL,
    display_name TEXT NOT NULL,
    phone_number TEXT,
    accent_color_hex TEXT NOT NULL,
    is_default_sms INTEGER DEFAULT 0,
    is_default_voice INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1
);

CREATE TABLE contacts (
    phone_e164 TEXT PRIMARY KEY,
    contact_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    thumbnail_blob BLOB,
    updated_at INTEGER NOT NULL
);

CREATE TABLE threads (
    thread_id TEXT PRIMARY KEY,
    recipient_e164 TEXT NOT NULL,
    contact_name TEXT,
    last_snippet TEXT,
    last_timestamp_ms INTEGER NOT NULL,
    preferred_sub_id INTEGER,
    unread_count INTEGER DEFAULT 0
);

CREATE TABLE messages (
    message_id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL REFERENCES threads(thread_id) ON DELETE CASCADE,
    subscription_id INTEGER NOT NULL,
    address_e164 TEXT NOT NULL,
    body TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('INCOMING', 'OUTGOING')),
    status TEXT NOT NULL CHECK (status IN ('PENDING', 'SENT', 'DELIVERED', 'FAILED')),
    timestamp_ms INTEGER NOT NULL,
    dedup_hash TEXT UNIQUE
);

CREATE TABLE call_history (
    call_id TEXT PRIMARY KEY,
    subscription_id INTEGER NOT NULL,
    remote_e164 TEXT NOT NULL,
    contact_name TEXT,
    direction TEXT NOT NULL CHECK (direction IN ('INCOMING', 'OUTGOING', 'MISSED')),
    duration_sec INTEGER DEFAULT 0,
    timestamp_ms INTEGER NOT NULL
);

-- Local thumbnail & file metadata cache on macOS for instant gallery reopening
CREATE TABLE media_cache (
    media_store_id INTEGER PRIMARY KEY,
    remote_path TEXT NOT NULL,
    bucket_name TEXT,
    mime_type TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    duration_ms INTEGER DEFAULT 0,
    date_taken_ms INTEGER NOT NULL,
    local_thumb_path TEXT,
    cached_at_ms INTEGER NOT NULL
);

CREATE INDEX idx_messages_thread_time ON messages(thread_id, timestamp_ms DESC);
CREATE INDEX idx_media_date ON media_cache(date_taken_ms DESC);
```

---

## 10. Android Client Implementation Details

### 10.1 Required Permissions (`AndroidManifest.xml`)
* **SMS & Calls:** `READ_SMS`, `SEND_SMS`, `RECEIVE_SMS`, `READ_PHONE_STATE`, `READ_PHONE_NUMBERS`, `CALL_PHONE`, `READ_CALL_LOG`, `ANSWER_PHONE_CALLS`, `READ_CONTACTS`
* **Bluetooth Audio:** `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` (API 31+)
* **Photos, Videos & Files:**
  * Android 13+: `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_AUDIO`
  * Full File Explorer: `MANAGE_EXTERNAL_STORAGE` (All Files Access via `Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`)
* **Background & Network:** `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `FOREGROUND_SERVICE_PHONE_CALL`, `FOREGROUND_SERVICE_DATA_SYNC`, `POST_NOTIFICATIONS`, `INTERNET`, `ACCESS_NETWORK_STATE`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`

> **Distribution Note:** Because the app uses `READ_SMS`, `SEND_SMS`, `CALL_LOG`, and `MANAGE_EXTERNAL_STORAGE`, plan for **Direct Signed APK Distribution** (website / GitHub Releases / Obtainium) as the primary full-featured build, and optionally a Play Store build compliant with Google's *Cross-device SMS/Call sync* and *MediaStore-only* photo picker policies.

### 10.2 Multi-SIM Telephony & Call Audio Control
* **SIM Inventory:** Observe `SubscriptionManager.OnSubscriptionsChangedListener` and push `SimInventorySync`.
* **SMS Sending/Receiving:** Use `SmsManager.createForSubscriptionId(subId)` for multipart sending; combine `SMS_RECEIVED_ACTION` `BroadcastReceiver` + `ContentObserver` on `content://mms-sms/` with deduplication hashing.
* **Call Control & Bluetooth Audio Routing:**
  * Implement `RelayInCallService` (extending `android.telecom.InCallService`) so the app can monitor exact call states (`DIALING`, `RINGING`, `ACTIVE`, `HOLDING`, `DISCONNECTED`), send DTMF tones, mute, and **explicitly route audio to the paired Mac Bluetooth device** via `requestBluetoothAudio(macDevice)`.
  * Fallback for users who prefer not to set a Companion/Dialer role: use `TelecomManager.placeCall()`, `acceptRingingCall()`, `endCall()`, and `TelephonyCallback.CallStateListener` (Android OS still auto-routes audio to the connected Mac Bluetooth HFP profile).

### 10.3 Embedded LAN Media & File Server (`Ktor CIO`)
* Starts automatically when Android connects to Wi-Fi and a paired Mac is reachable.
* **Security:** Rejects any request missing the valid `Authorization: Bearer <session_bearer_token>` header and enforces path canonicalization (`file.canonicalPath.startsWith(rootPath)`) to prevent path traversal (`../`) attacks.
* **Streaming:** Uses `call.respondOutputStream` / Ktor `PartialContent` plugin so macOS `AVPlayer` gets accurate `Accept-Ranges: bytes` and `Content-Range` headers for instant video scrubbing.

---

## 11. macOS Client Implementation Details

### 11.1 Navigation & UI Structure
A unified 4-tab macOS `NavigationSplitView` + `MenuBarExtra` companion:
1. **Messages:** Thread list, search, color-coded SIM pills, sticky SIM reply picker (`Cmd+1`/`Cmd+2`), and OTP notification quick-copy.
2. **Calls & Dialer:** Recent call history with SIM badges, full numeric keypad + contact autocomplete, SIM selector dropdown, and Bluetooth HFP Audio status indicator (*"Mac Audio Ready"*).
3. **Photos & Videos:** Apple Photos-style responsive grid, album sidebar, video duration badges, inline `AVPlayer` streaming viewer, multi-select batch download.
4. **Files:** Finder-style column/list browser of the Android filesystem with breadcrumb bar, storage usage meter, QuickLook (`Spacebar`), and drag-and-drop upload/download.

### 11.2 Bluetooth HFP & CoreAudio Bridge
* **SDP & RFCOMM:** Registers macOS Bluetooth Hands-Free Unit service (`0x111E`), handles AT command negotiation (`AT+BRSF`, `AT+BAC=1,2` for CVSD + mSBC wideband speech, `AT+CIND`, `AT+CMER`), and manages the SCO audio link.
* **Audio Routing:** Uses `CoreAudio` + `AVAudioEngine` with `VoiceProcessingIO` to bridge Bluetooth SCO frames to the user's current macOS default input/output devices (dynamically handling AirPods or external mic hot-swaps mid-call).

### 11.3 Distribution & Entitlements
* Distribute as a **Notarized `.dmg`** signed with a Developer ID Application certificate, with **Sparkle 2** auto-updates (outside the Mac App Store to allow unrestricted `IOBluetooth` HFP SDP registration and local filesystem drag-and-drop).
* **Entitlements:** `network.client`, `network.server`, `device.bluetooth`, `device.audio-input`, `files.user-selected.read-write`, `files.downloads.read-write`.

---

## 12. Phased Implementation Roadmap (10 Weeks)

### Phase 1: Foundation, Relay & E2EE (Weeks 1–2)
- [ ] Initialize monorepo and configure `buf` Protobuf codegen for Go, Kotlin, and Swift.
- [ ] Build Go Relay Server (PostgreSQL, Redis Pub/Sub + offline queue, WebSocket Hub, FCM wakeup).
- [ ] Implement X25519 QR Code pairing and ChaCha20-Poly1305 encryption on Android & macOS.

### Phase 2: Multi-SIM SMS Engine (Weeks 3–4)
- [ ] Android: `SubscriptionManager` inventory, `SmsManager` multi-SIM send/receive, deduplication, `RelayForegroundService`.
- [ ] macOS: GRDB/SQLCipher store, Messages UI, sticky SIM selector, Contact sync, OTP auto-copy.

### Phase 3: Bidirectional Voice Calls on Mac (Weeks 5–7)
- [ ] Android: Multi-SIM `TelecomManager.placeCall`, `RelayInCallService`, Bluetooth audio routing enforcement.
- [ ] macOS: `CallKit` (`CXProvider`) incoming/outgoing call UI and Dialer pad with SIM selector.
- [ ] macOS: Bluetooth HFP Hands-Free Unit (HF) daemon (`mSBC` wideband) + `CoreAudio` `VoiceProcessingIO` mic/speaker bridge.

### Phase 4: Phone Media Gallery & File Explorer (Weeks 8–9)
- [ ] Android: `MediaStore` gallery indexer, WebP thumbnail cache, NIO File Explorer, and embedded Ktor mTLS HTTP/2 server with `Range` support.
- [ ] macOS: Photos/Videos grid, `AVPlayer` streaming, Finder-style File Explorer, QuickLook, and drag-and-drop transfer queue.
- [ ] Remote P2P: Integrate WebRTC DataChannel + `coturn` fallback for off-LAN file browsing and downloads.

### Phase 5: Hardening & Production Release (Week 10)
- [ ] Stress test dual-SIM edge cases, Bluetooth reconnects, LAN $\leftrightarrow$ 5G handoffs, and 4K video streaming.
- [ ] Package notarized macOS `.dmg` (Sparkle) and signed Android release APK.

---

## 13. QA & Acceptance Testing Matrix

| Test Scenario | Expected Behavior |
| :--- | :--- |
| **Incoming Call $\to$ Talk on Mac** | Phone rings on SIM 2 $\to$ macOS CallKit banner shows SIM 2 + caller $\to$ click Answer $\to$ two-way voice audio flows through Mac mic & speakers/AirPods within 1s with zero echo. |
| **Dial from Mac (SIM 1 vs SIM 2) $\to$ Talk on Mac** | Select SIM 1 in macOS Dialer $\to$ click Call $\to$ Android dials out on SIM 1 and routes SCO audio to Mac automatically; user speaks directly into Mac. |
| **Mid-Call Audio Handoff** | Toggle audio button in macOS call bar from `Mac` to `Phone Speaker` $\to$ audio switches cleanly to phone without dropping the call. |
| **4K Video Streaming from Phone (LAN)** | Click a 1GB 4K video in macOS Gallery $\to$ playback begins in <1s via HTTP `Range` streaming; scrubbing to 50% seeks immediately without full download. |
| **File Explorer Drag & Drop** | Drag a 200MB PDF/ZIP from macOS Finder into `/Downloads` on the phone $\to$ transfers over LAN mTLS at Wi-Fi line speed with SHA-256 verification. |
| **Remote Photo Browse (Off-LAN / 5G)** | Disconnect Mac from home Wi-Fi $\to$ WebRTC DataChannel establishes P2P link $\to$ macOS browses phone albums and downloads photos E2EE. |
| **Dual-SIM SMS Sticky Reply** | Incoming SMS on SIM 2 sets macOS composer to SIM 2 automatically; switching to SIM 1 via `Cmd+1` sends via SIM 1. |
| **Android Deep Doze Wakeup** | Phone screen off for 2 hours $\to$ user dials a call or sends SMS from Mac $\to$ FCM wakes Android and executes within 3 seconds. |