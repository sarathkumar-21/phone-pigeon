# Security policy

PhonePigeon handles private data (messages, call logs, photos, files, the phone's screen) and can control a phone remotely, so security reports are welcome and taken seriously.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it privately with GitHub's **Security › Report a vulnerability** form on this repository (private vulnerability reporting). If that is not available, open a public issue that says only "I have a security report" with no details, and a maintainer will arrange a private channel.

Include, if you can:

- the component (Mac app, Android app, relay) and version or commit;
- steps to reproduce, or a proof of concept;
- the impact you expect (for example: "a device on the same Wi-Fi can read the phone's files without pairing").

You can expect an acknowledgement within a week. This is a volunteer project, so fix times vary; critical problems are handled first. Please give us a reasonable time to fix a problem before you disclose it.

## Scope

In scope: the pairing protocol, the end-to-end encryption, the media server on the phone, the relay, the remote-control and screen-mirroring gates, and the Mac app's handling of downloaded files and the clipboard.

Out of scope: attacks that need an already-compromised phone or Mac, physical access to an unlocked device, and denial of service by a device on your own network.

## How the design is meant to hold up

See [docs/security-review.md](docs/security-review.md) for the threat model, the findings from the project's own review and what was fixed. That review was done by the authors, not by an independent party. Treat the project as unaudited until that changes.

## Supported versions

Only the latest commit on `main` receives fixes.
