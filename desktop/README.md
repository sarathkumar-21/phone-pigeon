# PhonePigeon for Windows and Linux

Texts, calls, photos, files, notifications and screen mirroring from your Android phone, on your computer.
Built with [Tauri 2](https://tauri.app): a Rust core (all keys and sockets) and a React user interface.
It speaks exactly the same end-to-end encrypted protocol as the Mac app, so one Android app works with all of them.

| | |
|---|---|
| Pairing | Nearby (mDNS): pick the phone on its "Pair with your computer" screen, compare the six-digit code |
| Link | LAN socket on port 8443 (or the last free port), ChaCha20-Poly1305, X25519 + HKDF, forward-secret re-keys |
| Messages, contacts, call history, notifications | Yes |
| Calls | Dial, answer, decline, end, mute, keypad, auto-redial, scheduled calls and texts. **Audio stays on the phone** (Windows and Linux cannot act as a Bluetooth headset for Android). |
| Photos, files | Browse, search, preview, download (parallel ranges), upload, rename, delete, over pinned-TLS HTTPS |
| Screen mirroring | View, tap, swipe, type. Needs WebCodecs: works on Windows (WebView2) and macOS; on Linux it needs a recent WebKitGTK |
| Relay (cloud) | Not in this version. LAN only |

## Build

Requirements: Node 22 + pnpm, Rust (stable), and on Linux `libwebkit2gtk-4.1-dev libgtk-3-dev libsecret-1-dev libdbus-1-dev`.

```bash
pnpm install
pnpm tauri dev          # run
pnpm tauri build        # installers: .msi/.exe (Windows), .deb/.AppImage/.rpm (Linux)
```

Tests:

```bash
pnpm test                                                  # front end
cargo test --manifest-path src-tauri/Cargo.toml --lib      # crypto, checked against Apple CryptoKit test vectors
```

## Where things live

- `src-tauri/src/crypto.rs`: key derivation, sealing, replay protection, re-keying (byte-compatible with the Mac and Android apps)
- `src-tauri/src/core.rs`: LAN server, nearby pairing, mDNS, phone channels
- `src-tauri/src/media.rs`: pinned-TLS client, downloads, uploads, screen stream
- `src-tauri/src/store.rs`: encrypted state file; keys live in the OS keychain (file fallback with mode 0600)
- `src/lib/store.ts`: app state, protocol handling, scheduler, auto-redial
- `src/views/`: screens

## Testing with an Android emulator

An emulator is behind NAT, so mDNS cannot see it. Forward its ports and point the app at it:

```bash
adb forward tcp:<pairing port> tcp:<pairing port>     # port from `adb logcat | grep _pigeonphone`
adb forward tcp:8444 tcp:8444
PHONEPIGEON_NEARBY_HOST=127.0.0.1:<pairing port> PHONEPIGEON_MEDIA_HOST_OVERRIDE=127.0.0.1 pnpm tauri dev
```

These variables are for testing only.

## Limits

- The app must be open for scheduled items to fire.
- On macOS, an unsigned debug build can trigger a Keychain prompt each time it is rebuilt.
