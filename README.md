# PhonePigeon

**Your Android phone's messages, calls, photos, files, notifications and screen, delivered to your Mac. By pigeon. End-to-end encrypted.**

PhonePigeon pairs a multi-SIM Android phone with a Mac, over your own Wi-Fi (or an optional relay you host). There is no account and no cloud service to sign up for.

- **Messages:** read and send SMS from either SIM, with one-click copy for verification codes.
- **Calls:** dial, answer and hang up from the Mac, switch the audio between the Mac, the phone speaker and the earpiece, and record a call on the Mac.
- **Photos & videos:** browse the gallery by album and month, view photos at full size, stream videos, drag items to Finder.
- **Files:** a Finder-style browser of the phone's storage with whole-phone search, drag and drop and copy/paste in both directions.
- **Notifications:** the phone's other notifications show up on the Mac, and clearing one on the Mac clears it on the phone.
- **Screen mirroring:** see the phone's screen on the Mac and, if you opt in, control it with the mouse and keyboard.
- **Many phones:** pair as many phones as you like and switch between them.

> **Status: early.** It works end to end on an Android 15 emulator and on a few real phones, but it has had little testing on real hardware. See [What is tested](#what-is-tested) and [Known limitations](#known-limitations) before relying on it.

## How it fits together

| Folder | What it is |
| --- | --- |
| `macos/` | The Mac app: Swift 6, SwiftUI, CryptoKit, Network.framework, AVFoundation, VideoToolbox. No third-party packages. |
| `android/` | The Android app: Kotlin, Jetpack Compose, OkHttp, Tink. Min SDK 29, target SDK 35. |
| `backend/` | An optional Go relay for when the devices are not on the same network (WebSocket hub, PostgreSQL, Redis, FCM wake-ups), with Docker Compose, Caddy and coturn. |
| `proto/` | The shared wire schema, `relay.proto`. |
| `docs/` | The design spec and the security review. |

```
Control   (end-to-end encrypted)  Mac ⇄ phone   LAN TCP (the Mac listens; Bonjour _pigeonmac._tcp)  or  your relay (WSS)
Media     (photos, files, screen) Mac → phone   HTTPS on the phone (Keystore certificate, pinned) + HKDF bearer token
Voice                             phone → Mac   Bluetooth hands-free (handled by the system)
```

## Quick start

You need a Mac (macOS 14 or later), an Android phone (Android 10 or later) and both on the same Wi-Fi.

### 1. Build and install

```bash
# Mac app (needs Xcode 16+ and `brew install xcodegen`)
cd macos
xcodegen generate
xcodebuild -project PhonePigeon.xcodeproj -scheme PhonePigeon -derivedDataPath build build
mkdir -p ~/Applications && cp -R build/Build/Products/Debug/PhonePigeon.app ~/Applications/
open ~/Applications/PhonePigeon.app

# Android app (needs JDK 17 and the Android SDK)
cd ../android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Run the Mac app from `~/Applications` or `/Applications`. macOS refuses to let an app launched from inside `~/Documents` browse the network (Bonjour error `NoAuth`), so the **Nearby phones** list stays empty.

### 2. Pair

Pairing is "nearby" only: there is no QR code and no account.

1. On the phone, open PhonePigeon, tap **Allow all** on the permissions screen and continue to **Pair with your Mac**. Keep that screen open: the phone is visible on the network only while it is showing.
2. On the Mac, choose **File › Add Phone…** (⇧⌘N) and pick the phone under **Nearby phones**.
3. Both screens show the same six-digit code. If it matches, tap **Codes match** on both.

Try the Mac app without a phone by choosing **Try with a Demo Phone**: a virtual phone that runs the real encrypted protocol, with generated photos, a playable video and a file tree.

### 3. Optional: run a relay

The relay lets paired devices reach each other when they are not on the same network. It only ever sees ciphertext.

```bash
cd backend
go test -race ./...
ADDR=:8080 ALLOW_INSECURE_DEV=1 JWT_SECRET=dev go run ./cmd/server   # in-memory, for development
```

For a real deployment copy `.env.example` to `.env`, fill it in and run `docker compose up -d` (Caddy for TLS, two relay replicas, PostgreSQL, Redis, coturn). Then enter the relay's `wss://` URL under Mac Settings › Connection.

## What it can do

**Messages & calls**
- Dual-SIM aware: every message and call shows which SIM it used, and replies go out on the right one.
- Verification codes are detected on the Mac, copied in one click and wiped from the clipboard afterwards.
- A **Record** button records a call on the Mac when the call audio is routed to the Mac (Android does not let apps record call audio on the phone). You are asked to confirm you may record; recordings are saved in `Music/PhonePigeon Recordings`.
- Call audio uses macOS's Bluetooth hands-free stack, so pair the phone with the Mac over Bluetooth first.

**Photos & videos**
- Albums, an All / Photos / Videos filter, a grid grouped by month, and a full-size viewer. Videos stream with HTTP Range requests, so seeking is instant.
- Videos that macOS cannot play itself (`.mkv`, `.webm`, `.avi`, `.flv`, `.wmv`…) are saved to Downloads and opened in your default player (install VLC or IINA if you have none).

**Files**
- Breadcrumbs, sortable columns, hidden files, new folder, rename, delete, Quick Look on **Space**, and a storage meter.
- Search matches names across the **whole phone** (two or more letters; shallowest matches first, up to 500).
- Drag rows to Finder (the file downloads when you drop it); drop files onto the table to upload; **⌘C** copies real files to the clipboard; **⌘V** uploads from the clipboard. Every transfer appears in the transfer queue with progress and a cancel button.
- Large downloads run as parallel 4 MB range requests.

**Notifications**
- The **Notifications** tab and Mac banners mirror the phone's other notifications. This needs **Notification access** on the phone (the permissions screen opens Android's list for you).
- Left out on purpose: ongoing notifications (calls, music, navigation), group summaries, and the SMS and dialer apps (messages and calls already arrive natively).

**Screen mirroring**
- Choose **Mirror Screen** on the Overview page. The phone shows a notification; tap it and accept Android's own capture dialog. Nothing is captured before you do, and it needs approval every time. A persistent notification with a **Stop** button shows while it runs, and windows that block screenshots (banking apps) appear black.
- The phone encodes H.264 and streams it over the same pinned-TLS media server, so it stays on your network. You can keep using the phone while it is mirrored.
- **Remote control is off by default.** To control the phone from the mirror window, switch on **Remote control** on the phone's home screen *and* enable the "PhonePigeon remote control" accessibility service in Android settings (a powerful permission; Android warns you). Click = tap, drag and scroll = swipe, right-click = Back, typing goes into the focused field, and the title bar has Back / Home / Recents. The phone ignores all input unless a mirroring session you approved is running.

**Privacy switches on the phone** (home screen): Messages, Calls, Contacts, Notifications, and for Mac access to files: Browse and copy, Upload and rename, Delete (**off** by default), Screen mirroring, Remote control (**off** by default).

## Security in short

- Devices hold X25519 keys; every message is sealed with ChaCha20-Poly1305 under HKDF-derived directional keys, with the routing header authenticated and replay protection. A relay only sees ciphertext and routing headers.
- Live traffic gets forward secrecy through an ephemeral key exchange. (The handshake itself, frames sent while the peer is silent for two minutes, and frames queued at a relay use the long-term keys.)
- Nearby pairing needs both people to confirm a six-digit code. The Mac commits to its key before it sees the phone's, so someone in the middle cannot choose keys that make the codes match.
- The phone's media server uses a Keystore-backed certificate that the Mac pins, plus an HKDF-derived bearer token, and confines every path to the phone's storage.
- The Mac app is sandboxed with the hardened runtime.

Read the full [threat model and review](docs/security-review.md). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## What is tested

| Area | Result |
| --- | --- |
| Relay unit and integration tests (`go test -race`): proof of possession, key takeover refused, single-use pairing sessions, routing and offline queue, FCM wake-up throttling, rate limits, token revocation, two phones paired to one Mac, routing across instances via Redis (miniredis) | Pass locally |
| Relay store against PostgreSQL 17 and the in-memory store | Pass |
| Mac ↔ relay ↔ Android 15 emulator: pairing, sync, live SMS over the cloud path | Pass |
| Mac ↔ Android 15 emulator: nearby pairing, sync, files, photos, 200 MB transfer, screen mirroring, notifications path | Pass |
| Mac, Android debug and Android release (R8) builds | Pass locally |

**Not tested yet:** two real phones at once; drag and drop and paste/upload in the sandboxed Mac build; mirroring's Stop path and behaviour on a locked screen; remote control and notification mirroring on many real phones; call recording end to end; Docker image builds; FCM delivery (needs Firebase credentials); Bluetooth call audio.

## Known limitations

- **Android only, Mac only.** There is no iOS, Windows or Linux client.
- **Same network for photos, files and mirroring.** There is no WebRTC path for them off the LAN yet (the signalling message and coturn config exist).
- **Mac run from a project folder** cannot browse for nearby phones (see Quick start).
- **Call recording** captures what the Mac hears over Bluetooth, so the call audio must be routed to the Mac.
- Messages are stored in one sealed file on the Mac (ChaCha20-Poly1305, key in the Keychain), not in an SQLCipher database.
- Deleting a file removes it directly; it is not moved to Android's trash.

## Developing

- **Mac:** after changing `macos/project.yml` run `xcodegen generate`. Ad-hoc-signed debug builds change signature on every build, so macOS may ask for Keychain access again; set `DEVELOPMENT_TEAM` in `macos/project.yml` for a stable signature.
- **Android:** debug builds allow `ws://` for a relay on your LAN. Release builds are signed with your own key if you create `android/keystore.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`); otherwise they fall back to the debug key, which is fine for local use only.
- **Emulator testing:** the emulator cannot be found by Bonjour from the Mac. Run `adb forward tcp:8444 tcp:8444` and start the Mac app with `PHONEPIGEON_MEDIA_HOST_OVERRIDE=127.0.0.1` in its environment so it reaches the emulator's media server.
- **Relay settings** are environment variables; see `backend/.env.example` and `backend/internal/config`. `JWT_SECRET` must be at least 32 bytes (set `ALLOW_INSECURE_DEV=1` to override for local development only).

The design lives in [docs/spec.md](docs/spec.md); where the code differs, the README and [docs/security-review.md](docs/security-review.md) say so. Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). PhonePigeon is an independent project and is not affiliated with or endorsed by Google, Apple or any phone maker.
