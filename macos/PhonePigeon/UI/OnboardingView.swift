import CoreImage.CIFilterBuiltins
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var step = 0

    var body: some View {
        ZStack {
            AnimatedBackdrop()
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: PairingStep(onBack: {
                        if app.isPaired { app.showAddPhone = false } else { step = 0 } // adding another phone: back to the app
                    })
                    default: EmptyView()
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .padding(40)
            .animation(.spring(duration: 0.5), value: step)
        }
        .onAppear {
            // "Add Phone…": go straight to a fresh pairing code.
            if app.isPaired { step = 1 }
        }
    }

    private var welcome: some View {
        VStack(spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 110, height: 110)
                    .shadow(color: Color(hex: "#6B5BF9")!.opacity(0.5), radius: 30, y: 14)
                Image(systemName: "iphone.and.arrow.forward.inward")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 10) {
                Text("Your phone, on your Mac.")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("Texts, calls and verification codes from every SIM — end-to-end encrypted.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                feature("simcard.2.fill", "Dual-SIM aware", "Every message and call shows which SIM it used. Reply from the right one automatically.", .orange)
                feature("lock.shield.fill", "Zero-knowledge", "X25519 + ChaCha20-Poly1305. The relay only ever sees ciphertext.", .green)
                feature("key.viewfinder", "OTP in one click", "Verification codes are detected locally and wiped from the clipboard after use.", .purple)
                feature("phone.connection.fill", "Calls on your Mac", "Answer, dial and talk through your Mac over Bluetooth Hands-Free.", .blue)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 940)

            HStack(spacing: 12) {
                Button { step = 1 } label: {
                    Label("Pair Android Phone", systemImage: "dot.radiowaves.left.and.right").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                Button { app.pairWithDemoPhone() } label: {
                    Label("Try with a Demo Phone", systemImage: "sparkles").frame(minWidth: 200)
                }
                .controlSize(.extraLarge)
            }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .padding(18)
        .glassBackground(cornerRadius: 18)
    }
}

struct PairingStep: View {
    @Environment(AppState.self) private var app
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add your Android phone").font(.system(size: 32, weight: .bold, design: .rounded))
                Text("No code to scan: your phone shows up here when it's ready.").font(.title3).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                stepRow(1, "Install PhonePigeon on your phone", "Get it from Google Play or GitHub Releases, and allow its permissions.")
                stepRow(2, "Open it and tap “Pair with your Mac”", "Keep that screen open. Your phone and this Mac need to be on the same Wi-Fi.")
                stepRow(3, "Pick your phone below", "Both screens show the same six-digit code. Check it matches, then confirm on both.")
            }

            nearbyPanel

            HStack(spacing: 10) {
                Button { app.cancelPairing(); onBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .controlSize(.large)
                Button { app.pairWithDemoPhone() } label: { Label("Use a Demo Phone", systemImage: "sparkles") }
                    .controlSize(.large)
                    .help("Pair with a virtual phone that runs the real encrypted protocol")
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .onAppear { app.nearby.browser.start() }
        .onDisappear {
            app.nearby.browser.stop()
            if app.nearby.isBusy { app.nearby.cancel() }
        }
    }

    /// Phones on this Wi-Fi that are showing "Pair with your Mac".
    private var nearbyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nearby phones", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            switch app.nearby.state {
            case .idle, .failed:
                if case .failed(let message) = app.nearby.state {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                if app.nearby.browser.phones.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking for phones… open PhonePigeon on your phone and go to “Pair with your Mac”.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(app.nearby.browser.phones) { phone in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(phone.name).font(.body.weight(.semibold))
                                if !phone.model.isEmpty { Text(phone.model).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Pair") { app.nearby.begin(phone) }.buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    }
                }
            case .connecting(let name):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Contacting \(name)…").font(.callout) }
                Button("Cancel") { app.nearby.cancel() }
            case .confirm(let phone, let code):
                Text("Check that \(phone) shows this same code, then tap Codes match on both.").font(.callout).foregroundStyle(.secondary)
                Text(code).font(.system(size: 40, weight: .bold, design: .monospaced)).frame(maxWidth: .infinity)
                HStack {
                    Button("Cancel") { app.nearby.cancel() }
                    // No Return-key shortcut on purpose: a stray keypress or click must not approve a pairing.
                    Button("Codes match") { app.nearby.confirm() }.buttonStyle(.borderedProminent)
                }
            case .finishing(let name):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Waiting for \(name) to confirm…").font(.callout) }
                Button("Cancel") { app.nearby.cancel() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBackground(cornerRadius: 16)
    }

    private func stepRow(_ n: Int, _ title: String, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.system(.callout, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.brandGradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct AnimatedBackdrop: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let blobs: [(Color, Double, Double, Double)] = [
                    (Color(hex: "#6B5BF9")!, 0.25, 0.3, 0.13),
                    (Color(hex: "#3B8CFF")!, 0.75, 0.35, 0.10),
                    (Color(hex: "#36D1DC")!, 0.55, 0.8, 0.08),
                    (Color(hex: "#FF5B3A")!, 0.15, 0.85, 0.06),
                ]
                for (i, b) in blobs.enumerated() {
                    let x = size.width * (b.1 + 0.08 * sin(t * b.3 + Double(i)))
                    let y = size.height * (b.2 + 0.08 * cos(t * b.3 * 1.3 + Double(i)))
                    let r = max(size.width, size.height) * 0.38
                    gc.fill(Path(ellipseIn: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)), with: .color(b.0.opacity(0.22)))
                }
            }
            .blur(radius: 90)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }
}
