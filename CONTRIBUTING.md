# Contributing to PhonePigeon

Thanks for helping. This is a small project with three parts (Mac app, Android app, Go relay), so most changes touch one of them.

## Before you start

- Read the [README](README.md) and skim [docs/spec.md](docs/spec.md).
- For anything bigger than a bug fix, open an issue first so we can agree on the approach.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.
- By contributing you agree your work is released under the [MIT license](LICENSE) and that you follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setting up

| Part | You need | Build and test |
| --- | --- | --- |
| `backend/` | Go 1.26+ | `cd backend && go vet ./... && go test -race ./...` |
| `android/` | JDK 17, Android SDK 36 | `cd android && ./gradlew :app:assembleDebug :app:assembleRelease` |
| `macos/` | macOS 14+, Xcode 16+, `brew install xcodegen` | `cd macos && xcodegen generate && xcodebuild -project PhonePigeon.xcodeproj -scheme PhonePigeon build` |

The Xcode project is generated from `macos/project.yml` and is not committed. Edit `project.yml`, not the project.

The Mac app must run from `~/Applications` or `/Applications` for nearby-phone discovery to work. See "Developing" in the README for emulator testing.

## Making a change

1. Fork, then branch from `main`.
2. Keep the change focused. Do not mix a refactor with a fix.
3. Add or update tests when you touch the relay or the crypto. The wire format is shared by all three parts: if you change `proto/relay.proto`, the envelope handling in `macos/PhonePigeon/Crypto`, `android/.../crypto` or `backend/internal/api`, change every side and say so in the pull request.
4. Run the build and tests for each part you touched (table above). CI runs them too.
5. Open a pull request using the template and describe how you tested it. If you could not test on a real phone, say so.

## Code style

- **Kotlin:** idiomatic Kotlin, Jetpack Compose, no new dependency without a reason. The release APK is about 3 MB and we would like to keep it small.
- **Swift:** Swift 6 strict concurrency, SwiftUI first and AppKit where SwiftUI falls short. No third-party packages.
- **Go:** `gofmt`, `go vet`, standard library first.
- Comments explain why, not what.
- Do not log message text, phone numbers, file names or keys.

## Security-sensitive changes

Take extra care, and call it out in the pull request, when a change touches: pairing, key handling, envelope sealing, the media server's authentication or path checks, the permission toggles on the phone, remote control, or what the relay stores.

Rules we hold to:

- Nothing is captured, mirrored or controlled without an explicit, visible user action on the phone.
- Defaults stay safe: delete access and remote control are off until the user turns them on.
- The relay never sees plaintext and never stores more than ciphertext, routing metadata and what it needs for rate limits.

## Reporting bugs

Use the bug report template. Include the Mac and Android versions, the phone model, whether you use the relay, and the steps to reproduce.
