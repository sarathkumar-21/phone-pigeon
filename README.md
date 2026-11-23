<p align="center"><img src="docs/images/icon.png" width="128" alt="PhonePigeon icon: a pigeon holding a phone"></p>

# PhonePigeon

**Your Android phone's messages, calls, photos, files, notifications and screen, delivered to your Mac, Windows or Linux computer. By pigeon. End-to-end encrypted.**

PhonePigeon pairs a multi-SIM Android phone with your computer over your own Wi-Fi (or an optional relay you host). There is no account and no cloud service to sign up for.

![PhonePigeon walkthrough](docs/images/demo.gif)

*Walkthrough of the Mac app, [as a video (MP4)](docs/demo.mp4). Screens show the built-in Demo Phone, so the contacts and messages are made up.*

> **Status: early.** It works end to end on an Android 15 emulator and on a few real phones, but it has had little testing on real hardware. See [What is tested](#what-is-tested) and [Known limitations](#known-limitations) before relying on it.

> [!IMPORTANT]
> ## 🍎 Mac: "Apple could not verify PhonePigeon is free of malware"?
>
> The Mac app is **not notarized** (that needs a paid Apple Developer ID), so macOS blocks the first launch of the downloaded DMG. This is expected, and it is a **one-time step**. Click **Done** (not *Move to Trash*), then do **one** of these:
>
> **Option 1: Terminal (fastest).** After dragging PhonePigeon into Applications, run:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/PhonePigeon.app
> ```
>
> **Option 2: System Settings.** Open **System Settings › Privacy & Security**, scroll down to the PhonePigeon message and click **Open Anyway**, then confirm.
>
> On macOS 15 and later, right-click › Open no longer works. Prefer not to? [Build it from source](#quick-start): a build you make yourself is not quarantined.

## Apps

| App | Where | Notes |
| --- | --- | --- |
| **Android** | `android/` | Kotlin and Jetpack Compose. Shares SMS, calls, contacts, notifications, media and the screen. Android 10+ |
| **Mac** | `macos/` | SwiftUI. The full feature set, including call audio over Bluetooth |
| **Windows and Linux** | `desktop/` | Tauri (Rust and React), same look and same encrypted protocol. LAN only; call audio stays on the phone. See [desktop/README.md](desktop/README.md) |
| **Relay (optional)** | `backend/` | Self-hosted Go server for use away from home Wi-Fi |

## Complete feature list

### Messages
- Read and send **SMS** from either SIM; every message shows the SIM it used and replies go out on the right one
- Conversation list with search (names, numbers and message text), SIM filter, unread filter, pinning, unread badges and mark-as-read
- Delivery status on each sent message (sending, sent, delivered, failed)
- **Verification codes** detected automatically, copied in one click and wiped from the clipboard afterwards
- New message with contact search by name or number; contacts with several numbers list every match to choose from
- **Emoji** picker and **GIF links** in the message box
- **Scheduled texts**, sent later from the computer

![Messages](docs/images/mac-messages.png)

### Calls
- **Dial, answer, decline, end, mute** and use the **keypad** (DTMF) from the computer
- **Small call card** with the contact's photo by default, a bar, or **full window**
- **Recents** synced from the phone's own call history (incoming, outgoing, missed, declined, duration, SIM), with All / Missed filter, search and call back
- Dialer with name or number lookup, SIM choice and a contact book
- **Auto-redial** when nobody answers: choose the wait (5 s to 5 min) and tries (up to 20); off every time the app starts; stoppable at any time
- **Scheduled calls**, optionally with auto-redial
- **Call audio on the Mac** over Bluetooth hands-free (where macOS and the phone allow it), with a switch between Mac, phone speaker and earpiece; **record** a call on the Mac (consent asked first). A built-in **Set up call audio** check tests each requirement and only offers *On Mac* when it can work
- Safety limits: the phone refuses more than 30 computer-started calls in 10 minutes

| | |
| --- | --- |
| ![Calls and dialer](docs/images/mac-calls.png) | ![Contacts](docs/images/mac-contacts.png) |
| Recents and dialer | Contacts with photos |
| ![Incoming call](docs/images/mac-call-incoming.png) | ![Call in progress](docs/images/mac-call-active.png) |
| Incoming call card | Call in progress |
| ![Full-window call](docs/images/mac-call-full.png) | ![Auto-redial](docs/images/mac-auto-redial.png) |
| Full-window call with the contact's photo | Auto-redial, with Call now and Stop |

### Photos and videos
- Albums, an All / Photos / Videos filter, a grid grouped by month with adjustable tile size and a full-size viewer
- Videos stream with seeking; formats the computer cannot play are saved and opened in your default player
- Download, copy, drag out, and upload photos to the phone

![Photos](docs/images/mac-photos.png)

### Files
- Browse the phone's storage as a **list** or **thumbnails**, with breadcrumbs, sortable columns, hidden files and a storage meter
- **Whole-phone search**, new folder, rename, delete, preview, Quick Look
- **Select many files, pictures and whole folders** (⌘A, ⇧-click, ⌘-click) and copy, drag out or download them in one go; drag and drop, copy and paste in both directions, parallel large downloads and a transfer queue with progress and cancel

| | |
| --- | --- |
| ![Files](docs/images/mac-files.png) | ![Files as thumbnails](docs/images/mac-files-grid.png) |
| List with whole-phone search | Thumbnails |

### Notifications
- The phone's other notifications appear on the computer, as a list and as banners; clearing one clears it on the phone
- Phone app icons, one-click code copy, and a rebind that keeps the listener alive on phones that kill background apps

![Notifications](docs/images/mac-overview.png)

### Scheduling
- Send a text or place a call later; manage everything under **Scheduled**
- A text more than 5 minutes late (a call, 2 minutes) is dropped rather than sent late

![Scheduled](docs/images/mac-scheduled.png)

### Screen mirroring and remote control
- See the phone's screen live, approved on the phone every time
- Optional remote control (off by default): click, drag, scroll and type; Back, Home and Recents buttons

![Screen mirroring](docs/images/mac-mirror.png)

### Overview, phones and settings
- Overview: battery, storage, SIM cards, unread, missed and call counts, recent conversations and calls
- **Pair many phones** and switch between them; nearby pairing with a six-digit confirmation code (no QR code)
- Light, dark or match-system theme; notification, call and redial settings; security fingerprints
- Built-in **Demo Phone** to try everything without a phone

| | |
| --- | --- |
| ![Welcome](docs/images/mac-welcome.png) | ![Settings](docs/images/mac-settings.png) |
| First launch | Settings |
| ![Phone settings](docs/images/mac-settings-phone.png) | ![Security](docs/images/mac-settings-security.png) |
| Phone | Security |

### Privacy and security
- End-to-end encrypted: X25519 key exchange, HKDF-SHA256 keys, ChaCha20-Poly1305, replay protection, forward-secret re-keys
- Pairing needs both people to confirm the same six-digit code
- Media and file transfers use HTTPS pinned to a certificate announced over the encrypted channel
- Per-feature switches on the phone: Messages, Calls, Contacts, Notifications, file access (browse, upload, delete), screen mirroring and remote control
- The Mac app runs in the macOS App Sandbox; no account, no analytics

### The Android app
<p>
<img src="docs/images/android-welcome.png" width="200" alt="Android welcome screen">
<img src="docs/images/android-permissions.png" width="200" alt="Android permissions screen">
<img src="docs/images/android-pair.png" width="200" alt="Android nearby pairing screen">
<img src="docs/images/android-mac-access.png" width="200" alt="The phone's computer access switches">
</p>

- One screen to allow every permission, nearby pairing, status of the link, per-feature sharing switches, call-history prompt and a "send call history now" button
- A quirky pigeon launcher icon, with a themed (monochrome) variant for Android 13+

### Windows and Linux
The same look and features as the Mac app, built with Tauri. Call audio stays on the phone, and screen mirroring needs a web view that can decode video.

| | |
| --- | --- |
| ![Overview](docs/images/desktop-overview.png) | ![Messages](docs/images/desktop-messages.png) |
| Overview | Messages |
| ![Calls](docs/images/desktop-calls.png) | ![Scheduled](docs/images/desktop-scheduled.png) |
| Calls and dialer | Scheduled |
| ![Notifications](docs/images/desktop-notifications.png) | ![Settings](docs/images/desktop-settings.png) |
| Notifications | Settings |

*Desktop screenshots use sample data in a browser preview of the real interface.*

## How it fits together

| Folder | What it is |
| --- | --- |
| `macos/` | The Mac app: Swift 6, SwiftUI, CryptoKit, Network.framework, AVFoundation, VideoToolbox. No third-party packages. |
| `desktop/` | The Windows and Linux app: Tauri 2 (Rust core, React interface). Same protocol and look as the Mac app. |
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

You need a computer (Mac with macOS 14 or later, Windows 10 or later, or Linux), an Android phone (Android 10 or later), and both on the same Wi-Fi.

### Download (no build needed)

Get the files from **[Releases](https://github.com/sarathkumar-21/phone-pigeon/releases/latest)**: the Android `.apk`, the Mac `.dmg`, the Windows `.exe` or `.msi`, or the Linux `.deb`, `.AppImage` or `.rpm`.

> [!IMPORTANT]
> **Mac: if macOS refuses to open the app,** run `xattr -dr com.apple.quarantine /Applications/PhonePigeon.app`, or go to **System Settings › Privacy & Security › Open Anyway**. See the box at the [top of this page](#-mac-apple-could-not-verify-phonepigeon-is-free-of-malware).

### Or build from source

```bash
# Mac app (needs Xcode 16+ and `brew install xcodegen`)
cd macos
xcodegen generate
xcodebuild -project PhonePigeon.xcodeproj -scheme PhonePigeon -derivedDataPath build build
mkdir -p ~/Applications && cp -R build/Build/Products/Debug/PhonePigeon.app ~/Applications/
open ~/Applications/PhonePigeon.app

# Windows and Linux app (needs Node 22, pnpm and Rust)
cd ../desktop
pnpm install && pnpm tauri build

# Android app (needs JDK 17 and the Android SDK)
cd ../android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Something not connecting? See the **[FAQ and troubleshooting guide](docs/FAQ.md)**: pairing, reconnecting, re-pairing, notifications, photos and mirroring.

Run the Mac app from `~/Applications` or `/Applications`. macOS refuses to let an app launched from inside `~/Documents` browse the network (Bonjour error `NoAuth`), so the **Nearby phones** list stays empty.

### Pair

Pairing is "nearby" only: there is no QR code and no account.

1. On the phone, open PhonePigeon, tap **Allow all** on the permissions screen and continue to **Pair with your Mac**. Keep that screen open: the phone is visible on the network only while it is showing.
2. On the Mac, choose **File › Add Phone…** (⇧⌘N); on Windows or Linux use **Add phone** in the sidebar. Pick the phone under **Nearby phones**.
3. Both screens show the same six-digit code. If it matches, tap **Codes match** on both.

Try the Mac app without a phone by choosing **Try with a Demo Phone**: a virtual phone that runs the real encrypted protocol, with generated photos, a playable video and a file tree.

### Optional: run a relay

The relay lets paired devices reach each other when they are not on the same network. It only ever sees ciphertext.

```bash
cd backend
go test -race ./...
ADDR=:8080 ALLOW_INSECURE_DEV=1 JWT_SECRET=dev go run ./cmd/server   # in-memory, for development
```

For a real deployment copy `.env.example` to `.env`, fill it in and run `docker compose up -d` (Caddy for TLS, two relay replicas, PostgreSQL, Redis, coturn). Then enter the relay's `wss://` URL under Mac Settings › Connection.

## In detail

**Messages & calls**
- Dual-SIM aware: every message and call shows which SIM it used, and replies go out on the right one.
- Verification codes are detected on the Mac, copied in one click and wiped from the clipboard afterwards.
- **Small by default:** every call starts as a small card in the corner of the window, with the contact's photo (sent once per call, end-to-end encrypted), the timer, and mute, keypad, audio route and record. Shrink it to a bar, or expand it to the full window, which blurs the photo behind a large avatar. Make full window the default in Settings › General › Calls.
- **Auto-redial** is off every time the app starts. Switch it on next to the dialer, choose the wait (5 s to 5 min) and the number of tries (up to 20). If the call ends unanswered (busy, no answer, unreachable) PhonePigeon waits and calls again, with a countdown, **Call now** and **Stop**. It stops when someone answers, when you hang up, or when the phone can't tell whether the call was answered (allow "Call history" on the phone). The phone also refuses more than 30 Mac-started calls in 10 minutes.
- A **Record** button records a call on the Mac when the call audio is routed to the Mac (Android does not let apps record call audio on the phone). You are asked to confirm you may record; recordings are saved in `Music/PhonePigeon Recordings`.
- Call audio uses macOS's Bluetooth hands-free stack, so pair the phone with the Mac over Bluetooth first. **Settings › Phone › Set up call audio…** (or **Fix…** on the call card) checks Bluetooth, the pairing, the phone's hands-free service and the link, and says what to change. macOS and Android do not always agree to do this: if the check fails after a clean pairing, the voice stays on the phone and the **On Mac** button is hidden. Everything else about the call (answer, decline, dial, end, history) still works on the Mac.
- If a call is not answered, the call card goes away when the phone stops ringing, and the missed call is logged.

**Scheduling, emoji and GIFs**
- The clock beside the message box sends a message later; the clock beside the dialer calls later; **Scheduled** in the sidebar lists, sends now or cancels them. They run **while PhonePigeon is open and the phone is connected**: the phone knows nothing about them. A text more than 5 minutes late (a call, 2 minutes) is skipped rather than sent late.
- The emoji button opens a searchable picker with recents. The **GIF** button adds a GIF *link*: SMS can't carry an animated picture, so browse GIPHY or Tenor, copy the link, paste it; phones with RCS or link previews show it animated. PhonePigeon never contacts a GIF service itself.

**Photos & videos**
- Albums, an All / Photos / Videos filter, a grid grouped by month, and a full-size viewer. Videos stream with HTTP Range requests, so seeking is instant.
- Videos that macOS cannot play itself (`.mkv`, `.webm`, `.avi`, `.flv`, `.wmv`…) are saved to Downloads and opened in your default player (install VLC or IINA if you have none).

**Files**
- A **list** or **thumbnails** view (pictures and videos preview on the phone itself), breadcrumbs, sortable columns, hidden files, new folder, rename, delete, Quick Look on **Space**, and a storage meter.
- Search matches names across the **whole phone** (two or more letters; shallowest matches first, up to 500).
- Select several items (**⌘A** for all, **⇧-click** for a range, **⌘-click** to add one): files, pictures and **whole folders**. Drag them to Finder (they download when you drop them; a folder keeps its structure), or use **Copy** / **⌘C** to put real files on the clipboard, or **Download to Downloads**. Drop files or folders onto the table to upload; **⌘V** uploads from the clipboard. Every transfer appears in the transfer queue with progress and a cancel button.
- Large downloads run as parallel 4 MB range requests.

**Notifications**
- The **Notifications** tab and Mac banners mirror the phone's other notifications. This needs **Notification access** on the phone (the permissions screen opens Android's list for you).
- Left out on purpose: ongoing notifications (calls, music, navigation) and group summaries that only repeat their children. The phone's Messages app is included (RCS chats never arrive as SMS); the Mac hides just the banner when the same text already arrived as a message.
- Some phones (vivo, Xiaomi, Huawei…) silently unbind notification listeners to save battery. PhonePigeon asks Android to rebind whenever the app or the Mac link comes up; if notifications still stop, exclude PhonePigeon from battery optimisation.

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
| Mac, Android debug and Android release (R8) builds | Pass |
| Demo phone: full-window calls with photos, auto-redial (unanswered twice, answered on the third try), scheduling, emoji picker | Pass |
| Emulator: nearby pairing, screen mirroring, mirrored-notification path (including the SMS app's) | Pass |

**Not tested yet:** auto-redial and call photos on a real phone with real calls (the demo phone and emulator can't place calls); a scheduled item actually firing at its time; remote control clicks from the Mac window (the switches and the accessibility service were set up, a click from the Mac was not confirmed); two real phones at once; drag and drop and paste/upload in the sandboxed Mac build; mirroring's Stop path and behaviour on a locked screen; notification mirroring on many real phones; call recording end to end; Docker image builds; FCM delivery (needs Firebase credentials); Bluetooth call audio on more than one phone and Mac pair (it was tested on one Android phone with one Mac, where macOS refused the hands-free link and the app hid *On Mac*).

## Known limitations

- **Android phone, Mac or Windows/Linux computer.** There is no iOS client.
- **Same network for photos, files and mirroring.** There is no WebRTC path for them off the LAN yet (the signalling message and coturn config exist).
- **Mac run from a project folder** cannot browse for nearby phones (see Quick start).
- **Call recording** captures what the Mac hears over Bluetooth, so the call audio must be routed to the Mac.
- **Scheduled items and auto-redial live on the Mac:** if the app is closed or the phone is off at the time, a scheduled item is skipped (and you are told), not sent late.
- **GIFs are links**, not pictures: SMS can't carry them, and MMS isn't supported.
- The phone reports a call as connected the moment it starts dialling, so the timer on the call screen can start before the other side answers; auto-redial uses the phone's call log, not that timer.
- Messages are stored in one sealed file on the Mac (ChaCha20-Poly1305, key in the Keychain), not in an SQLCipher database.
- Deleting a file removes it directly; it is not moved to Android's trash.

## Developing

- **Mac:** after changing `macos/project.yml` run `xcodegen generate`. Ad-hoc-signed debug builds change signature on every build, so macOS may ask for Keychain access again; set `DEVELOPMENT_TEAM` in `macos/project.yml` for a stable signature.
- **Android:** debug builds allow `ws://` for a relay on your LAN. Release builds are signed with your own key if you create `android/keystore.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`); otherwise they fall back to the debug key, which is fine for local use only. To make a key: `keytool -genkeypair -keystore ~/.phonepigeon/release.jks -storetype PKCS12 -alias phonepigeon -keyalg RSA -keysize 4096 -validity 10000`. Keep it and its passwords backed up and out of the repo: an app can only be updated in place by an APK signed with the same key.
- **Emulator testing:** the emulator cannot be found by Bonjour from the Mac. Run `adb forward tcp:8444 tcp:8444` and start the Mac app with `PHONEPIGEON_MEDIA_HOST_OVERRIDE=127.0.0.1` in its environment so it reaches the emulator's media server.
- **Relay settings** are environment variables; see `backend/.env.example` and `backend/internal/config`. `JWT_SECRET` must be at least 32 bytes (set `ALLOW_INSECURE_DEV=1` to override for local development only).

Stuck? [docs/FAQ.md](docs/FAQ.md). The design lives in [docs/spec.md](docs/spec.md); where the code differs, the README and [docs/security-review.md](docs/security-review.md) say so. Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). PhonePigeon is an independent project and is not affiliated with or endorsed by Google, Apple or any phone maker.
