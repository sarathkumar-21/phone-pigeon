# PhonePigeon security review

> **Note:** this review was written while the app still paired by QR code. QR pairing has since been removed in favour of nearby pairing with a six-digit confirmation code (see the "New" row in the status table). Findings 1, 3 and 7 and the QR-specific text below describe the old flow and are kept as history. The review was done by the project's authors, not an independent auditor.

Scope: Go relay (`backend/`), Android app (`android/`), Mac app (`macos/`), deployment files. Method: manual source review plus the live runs from earlier testing. Date: 2026-11-20.
Not done: dynamic fuzzing, dependency CVE scan (`govulncheck`, OWASP/Gradle and SwiftPM audit are not installed here), penetration test against a deployed relay.

Threat model used:
- **Malicious relay operator or network attacker** between Mac and phone (the E2EE claim).
- **Other app on the phone.**
- **Other host on the same LAN.**
- **Compromised paired peer** (a hostile Mac must not own the phone beyond what the user granted; a hostile phone must not own the Mac).

## Status (2026-11-20)

All findings are addressed in code. "Verified" says how far each was exercised.

| # | Fix | Verified |
| --- | --- | --- |
| 1 | `pairing_json` read only in debug builds; every pairing stops at a dialog with Mac name, 128-bit key fingerprint and address | Live: dialog shown, **Pair** completed |
| 2 | `MediaClient.safeFileName` plus a parent-folder check on every download; the Mac app is now sandboxed | Hostile names tested standalone; downloads work in the sandbox |
| 3 | QR v2 carries `pairing_secret`; `PairAck` carries an HMAC proof the Mac verifies in constant time; sessions expire | Live pairing succeeded; forged-proof rejection not exercised |
| 4 | Phone accepts only plain numbers for calls/SMS; 20 SMS per minute from the Mac | Regex tested on samples; Mac dialer already strips `*` `#` |
| 5 | `?token=` removed; header only | Relay test |
| 6 | Per-IP rate limit on `challenge`/`register` (`REGISTER_PER_MIN`, honours `TRUST_PROXY`); memory sweep | Relay test |
| 7 | Pairing session is set-if-absent; owner may re-announce; id must be 32+ chars | Relay test |
| 8 | `JWT_SECRET` must be 32+ bytes (`ALLOW_INSECURE_DEV=1` overrides); `jti`; 7-day TTL; unpair revokes both devices' tokens and closes their sockets; clients refresh tokens | Relay test (revocation, re-register); client refresh not exercised past 6 h |
| 9 | Ephemeral X25519 exchange (Mac initiates, 6 h and on reconnect): live traffic uses keys mixing in the discarded ephemeral secret. Static keys stay valid for receiving, so nothing queued at the relay or across a restart can be lost. **Limits:** the handshake, frames sent while the peer is silent for 2 min, and relay-queued frames use static keys, so a later leak of a long-term key can still decrypt those | Live: exchange completed and the phone's frames decrypted under the ephemeral keys |
| 10 | Nonce = 8-byte random prefix + 4-byte counter on both sides | Interop live (every frame) |
| 11 | Media server: 16 connections max, 8 s pre-auth timeout, header limits, upload size capped by free space, `.part` cleanup, JSON escaping | Compiles; downloads work; hostile-client behaviour not load tested |
| 12 | Mac LAN listener: 8 unauthenticated connections max, 10 s to prove the keys, 2 MB buffer before auth | Pairing and reconnects work; flood not tested |
| 13 | App Sandbox + hardened runtime; quarantine flag on downloads | Live: pair, browse, download, Quick Look work sandboxed. Paste/drop upload not re-tested in the sandbox |
| 14 | Phone toggles: Browse/copy (on), Upload/rename (on), Delete (**off** by default); enforced for listings, thumbnails, downloads, uploads, mkdir, rename, delete | Compiles; toggle screen not viewed; denial paths not exercised |
| 15 | `/metrics` only on `METRICS_ADDR`; Redis password; Postgres sslmode switch; coturn secret from `TURN_SECRET` and full private-range deny list; HTTP timeouts and header cap | `go vet`; Compose not started |
| 16 | `BootReceiver` not exported | Manifest |
| 17 | A lost Keystore key now clears the pairing instead of silently replacing the identity | Not triggered |
| 18 | 128-bit fingerprints; Bonjour advertises a hash, not the Mac id; upload JSON escaped | Live: fingerprint shown; discovery works |
| New | Screen mirroring: needs a notification tap plus Android's capture dialog every time; stream only over the pinned-TLS media server (token required, 403 unless a session is active and the phone toggle is on); persistent notification with Stop; Stop also works without a system call; `FLAG_SECURE` windows stay black; view only, no input injection | Start path live on the emulator; Stop path not confirmed (see README) |
| New | Multiple phones: every phone has its own pairing secret, keys and ephemeral exchange; inbound frames are matched to a phone by the (AAD-authenticated) sender id and only a frame that decrypts under that phone's keys marks a LAN connection as that phone; removing a phone drops its channel, caches and media endpoint. The shared relay socket uses the Mac's one device id | Relay test (two phones, one Mac); emulator + demo phone live |
| New | Nearby pairing (no QR): the phone is visible on the LAN only while its pairing screen is open; the Mac commits to its key before it sees the phone's (commit-reveal), both screens show a six-digit code and both users must confirm, then the normal handshake runs with a secret derived from the confirmed exchange. The Mac has no Return-key shortcut for approval and ignores clicks in the first 1.5 s the code is shown | Live on the emulator: list, code on the phone, confirm on both, pairing completed. A forged or mismatching commitment was not exercised |
| New | Notification mirroring: needs Notification access granted in Android settings plus an on/off switch in the app; filters out ongoing, group-summary, SMS and dialer notifications; content travels only over the end-to-end encrypted channel. Remote control: off by default, needs the accessibility service enabled by hand plus a switch in the app, only acts during an approved mirroring session, limited to 30 events per second, never reads screen content | Compiles; not tested on a real phone |
| 19 | Unreadable store is copied to `store.sealed.bak` before anything can overwrite it | Not triggered |

## Summary

| # | Severity | Component | Finding |
| --- | --- | --- | --- |
| 1 | Critical | Android | Exported `MainActivity` auto-pairs from a `pairing_json` intent extra with no user action |
| 2 | High | Mac | A paired phone can write files anywhere on the Mac through a crafted file name (path traversal in download) |
| 3 | High | Protocol | Malicious relay can man-in-the-middle pairing, because the pairing `session_id` is the only secret and the relay sees it |
| 4 | High | Android | Mac-supplied phone numbers are not validated; USSD/MMI codes (`*21*…#`) can reach `placeCall` |
| 5 | Medium | Relay | `?token=` query-string auth accepted on every endpoint (leaks into logs and proxies) |
| 6 | Medium | Relay | `challenge` and `register` are unauthenticated and not rate limited; each call stores state |
| 7 | Medium | Relay | Pairing session `Put` overwrites an existing key, so a Mac that knows a session id can hijack it |
| 8 | Medium | Relay | JWT secret has no minimum length; ephemeral fallback; no token revocation on unpair; 30 day TTL |
| 9 | Medium | Both apps | Static-static X25519 keys: no forward secrecy; recorded ciphertext (relay queue) decrypts if either identity key leaks |
| 10 | Medium | Both apps | ChaCha20-Poly1305 nonce = 32-bit random prefix + counter that restarts with each process: prefix collision across restarts reuses a nonce |
| 11 | Medium | Android | Media server: unauthenticated connections get one thread each, no cap, no header-count limit (slowloris); upload size unbounded |
| 12 | Medium | Mac | LAN listener: unlimited unauthenticated connections, 16 MB buffer each, no handshake timeout |
| 13 | Medium | Mac | App is not sandboxed; downloaded files carry no quarantine flag |
| 14 | Medium | Android | Unrestricted remote file delete/rename/upload under all storage, and unrestricted SMS recipients, from any holder of the pairing keys |
| 15 | Low | Relay | `/metrics` open when reached directly; Redis has no password; Postgres `sslmode=disable`; coturn denied-peer list incomplete and secret placeholder |
| 16 | Low | Android | `BootReceiver` is exported and ignores the intent action |
| 17 | Low | Android | Identity key silently regenerates if Keystore unwrap fails |
| 18 | Low | Both | 64-bit key fingerprint; Bonjour TXT leaks the Mac's stable `device_id`; unauthenticated `.part` leftovers |
| 19 | Low | Mac | Store decrypt failure returns an empty snapshot; the next save overwrites the old file |

## Critical

### 1. Auto-pairing through an exported activity
`android/.../MainActivity.kt:44,69` reads `pairing_json` from the intent, and `ui/PairScreen.kt:98` calls `pair()` on it immediately. `AndroidManifest.xml` has `MainActivity` as `exported="true"`. Any app on an unpaired phone can start it with its own QR JSON, so the phone pairs with the attacker's Mac. That Mac then receives SMS (including one-time codes), call state, contacts and the whole file tree, and can send SMS and place calls.
Fix: delete the extra from release builds (guard with `BuildConfig.DEBUG`). Require an explicit "Pair with <Mac name>, fingerprint …?" confirmation tap for every pairing, including camera scans.

## High

### 2. Mac path traversal on download
`macos/PhonePigeon/Files/MediaClient.swift:146` builds `destination.appendingPathComponent(name)` where `name` comes from the phone (`FileEntry.name`, `MediaItem.displayName`). `appendingPathComponent` keeps `..`. A hostile or compromised paired phone can send `../../Library/LaunchAgents/x.plist` and write outside Downloads. The app has no sandbox, so this is code execution as the user.
Fix: use `URL(fileURLWithPath: name).lastPathComponent`, reject empty, `.`, `..`, names with `/` or NUL, and verify the standardized target still has `destination` as its parent. Apply to `uniqueURL`, the Quick Look cache and the clipboard copy.

### 3. Pairing can be intercepted by the relay
In relay mode the Mac posts `session_id` to `/v1/pairing-sessions` and the phone's `pair_ack` is routed by it. The relay also learns the Mac's public key at registration. `AppState.completePairing` accepts any `pair_ack` whose `session_id` matches and whose ciphertext opens under keys derived from the *claimed* phone key. A relay that knows both values can forge a phone, or sit between the real phone and the Mac and re-encrypt every message. The QR is the only out-of-band channel, but its secret part is sent to the relay.
Fix (pick one, both is better):
1. Put a separate 128-bit `pairing_secret` in the QR that is never sent to the relay. The relay-facing id is `SHA256(secret)`. The phone includes `HMAC(secret, phone_pub ‖ mac_pub)` in the `PairAck`; the Mac verifies it.
2. Show a short authentication string (derived from both public keys) on both screens and require the user to confirm it matches. The apps already display fingerprints; make the check part of pairing.

### 4. Call numbers not validated
`telephony/CallController.kt:153` passes `Uri.fromParts("tel", cmd.phoneNumber, null)` straight to `TelecomManager.placeCall`. Strings such as `*21*5551234#` are MMI/USSD codes (call forwarding, etc.). Same for SMS: `Sms.kt:164` sends to any recipient, including premium short codes.
Fix: accept only `^\+?[0-9 ()-]{3,20}$` for calls, reject `*`/`#`. For SMS recipients, allow digits, `+`, and alphanumeric sender-style short codes only, and add a phone-side rate limit (for example 10 messages per minute) plus a visible log entry.

## Medium

5. **Query-string token.** `api/server.go` `authed` falls back to `?token=` for all routes. Remove it; clients already send `Authorization`. Tokens in URLs end up in Caddy and proxy logs.
6. **Unauthenticated registration flood.** `/v1/devices/challenge` writes a Redis or memory key (2 min TTL) per call and `register` upserts unlimited device rows. Add a per-IP rate limit (Caddy `rate_limit` or an in-app limiter), a cap on live challenges, and a cap on devices per IP per day.
7. **Pairing session overwrite.** `pairingSession` uses `Put`. Use set-if-absent so a second Mac cannot replace the Mac bound to a live `session_id`. Also enforce a minimum id entropy (UUID v4 or 128 random bits).
8. **Token hygiene.** `config.Load` accepts any `JWT_SECRET` (the README example uses `dev`). Refuse to start with fewer than 32 bytes unless `ALLOW_INSECURE_DEV=1`. Add a `jti` plus a Redis revocation list checked in `authed` and on WebSocket upgrade, and revoke on unpair. Shorten the TTL to a few days and re-run the proof-of-possession flow on expiry.
9. **No forward secrecy.** All session keys derive from long-term X25519 identities. Add an ephemeral X25519 exchange per connection (or per N hours) mixed into the HKDF (Noise-style `XX`/`IK`) so past traffic stays secret after a key leak. The relay's 24 h offline queue makes this realistic.
10. **Nonce reuse risk.** `SecureChannel` starts its counter at 0 with a new random 4-byte prefix per instance. After roughly 65 000 channel creations a prefix repeats and, since counters overlap, a nonce repeats under the same key. ChaCha20-Poly1305 nonce reuse leaks plaintext XOR and the authenticator key. Fix: persist the counter (like the sequence number), or use a 12-byte random nonce with a per-key message limit, or derive the nonce from the (persisted, monotonic) sequence number.
11. **Phone media server DoS.** `MediaServer.kt` runs `newCachedThreadPool` and reads headers before authenticating. Cap concurrent connections (for example 16), cap header count and total header bytes, and shorten the pre-auth read timeout to a few seconds. Reject `Content-Length` above a configured maximum or above free space; remove `.part` files on any failure (currently only on hash mismatch).
12. **Mac LAN listener.** `LANTransport.swift` accepts any number of connections and keeps each one forever until it sends a frame that decrypts. Cap pending connections, drop any connection that has not authenticated within 10 s, and lower the per-connection buffer to the largest legitimate frame.
13. **Mac hardening.** Add the App Sandbox with only `network.client`, `network.server`, `files.downloads.read-write`, `device.bluetooth`, `device.audio-input`, and `files.user-selected.read-write`. Set `com.apple.quarantine` on files written to Downloads so Gatekeeper treats them like web downloads.
14. **Blast radius of a compromised Mac.** Anyone holding the pairing keys can delete or overwrite any file under `/storage/emulated/0`, upload files, and send SMS. Consider: per-capability toggles beside the existing SMS/calls/contacts switches (Files read, Files write, Files delete), a phone-side confirmation or notification for deletes and bulk operations, and a hold-to-send for SMS to unknown numbers.

## Low

15. **Deployment.** `/metrics` is blocked by Caddy but open on `relay:8080` to the Compose network. Bind it to a separate admin port. Redis runs without `requirepass` and without TLS; Postgres uses `sslmode=disable` (fine on the private Compose network, wrong if you ever split hosts). `coturn/turnserver.conf` still has a placeholder secret and denies only RFC 1918 IPv4; add `127.0.0.0-127.255.255.255`, `169.254.0.0-169.254.255.255`, `::1`, `fc00::/7`, `fe80::/10`. The HTTP server sets `ReadHeaderTimeout` only; add `IdleTimeout` and `MaxHeaderBytes`.
16. **BootReceiver.** Set `exported="false"` (the system still delivers `BOOT_COMPLETED`) or check `intent.action`.
17. **Identity key.** `PairingStore.privateKey` swallows an unwrap failure and creates a new key. Treat it as a fatal state (mark pairing invalid, ask to re-pair) rather than replace the key silently.
18. **Smaller items.** Fingerprints show 64 bits; show 128. Bonjour TXT exposes the Mac's UUID to the whole LAN; send a salted hash instead. The upload response builds JSON by string interpolation; escape the path.
19. **Store resilience.** `EncryptedStore.load` returns an empty snapshot on any failure and the next `save` overwrites the file. Keep the old file as `.bak` and surface an error.

## Things that are done well
- Proof-of-possession registration; device id bound to its first key; single-use challenge and pairing session (`GETDEL`).
- Sender-spoof check and pairing check on every routed frame; the relay only sees ciphertext and routing headers.
- Routing header bound as AAD; sequence-number replay guard; 5-minute skew limit on live commands.
- Media plane: certificate pinning to a hash received over the E2EE channel, HMAC bearer, `canonicalFile` path confinement (symlink safe), Range handling, SHA-256 verification, atomic uploads.
- No cleartext in release (`usesCleartextTraffic=false`), `allowBackup=false`, private key wrapped by the Android Keystore, Mac key and store key in the Keychain (`ThisDeviceOnly`), non-root distroless container image, `MaxBytesReader` on JSON bodies, parameterized SQL, and OTP clipboard auto-clear.
