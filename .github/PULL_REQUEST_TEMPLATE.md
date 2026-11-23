## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Parts touched

- [ ] Mac app (`macos/`)
- [ ] Android app (`android/`)
- [ ] Relay (`backend/`)
- [ ] Wire format or crypto (changed on every side)
- [ ] Docs only

## How I tested it

<!-- Commands you ran, and the devices used (for example "Pixel 8, Android 15, Mac mini M2, LAN only"). If you could not test on a real phone, say so. -->

## Checklist

- [ ] `go vet ./... && go test -race ./...` passes (if the relay changed)
- [ ] `./gradlew :app:assembleDebug :app:assembleRelease` passes (if Android changed)
- [ ] The Mac app builds (if macOS changed)
- [ ] No message text, phone numbers, file names or keys are logged
- [ ] Security-sensitive behaviour (pairing, permissions, remote control, media server) is called out above
