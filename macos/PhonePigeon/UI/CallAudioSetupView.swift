import SwiftUI

/// Guided check for taking phone calls on the Mac over Bluetooth. Tests each requirement in turn and says what to do about the first that fails.
struct CallAudioSetupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var steps: [AudioRouter.CheckStep] = []
    @State private var running = false
    @State private var checked = false

    private var allOK: Bool { checked && !steps.isEmpty && steps.allSatisfy { $0.state == .ok } }
    private var failedStep: AudioRouter.CheckStep? { steps.first { $0.state == .failed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up call audio").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("To talk on your Mac, your phone must trust it as a Bluetooth headset. This checks each step.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        icon(step.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.headline)
                            if !step.detail.isEmpty { Text(step.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
                if steps.isEmpty { Text("Press Check to begin.").foregroundStyle(.secondary) }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassBackground(cornerRadius: 14)

            if allOK {
                Label("All set. Start or answer a call and choose On Mac.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else if failedStep?.id == 3 || failedStep?.id == 2 {
                fixSteps
            }

            HStack {
                Button("Open Bluetooth Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(u) }
                }
                Spacer()
                Button("Done") { dismiss() }
                Button { Task { await check() } } label: {
                    if running { ProgressView().controlSize(.small) } else { Text(checked ? "Check Again" : "Check") }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(running)
            }
        }
        .padding(24).frame(width: 520)
        .task { await check() }
    }

    private var fixSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fix it on the phone").font(.headline)
            Group {
                Text("1. On this Mac open System Settings › Bluetooth and leave it open, so the Mac is visible.")
                Text("2. On the phone open Settings › Bluetooth. Tap this Mac and choose Forget (or Unpair).")
                Text("3. On the phone tap Pair new device, choose this Mac, and accept the pairing code on both screens.")
                Text("4. On the phone open this Mac's settings and switch on Phone calls (call audio).")
                Text("5. Also forget the phone in this Mac's Bluetooth list, then press Check Again.")
            }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Pair it from the phone, not from the Mac: the phone only grants call audio to a device it paired with itself.")
                .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text("If this still fails after a clean pairing, macOS can't take call audio from this phone. Calls still work: you can answer, dial and end them here, and the voice stays on the phone. The On Mac button is hidden until this check passes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func icon(_ s: AudioRouter.CheckStep.State) -> some View {
        switch s {
        case .pending: ProgressView().controlSize(.small).frame(width: 20)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 20)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).frame(width: 20)
        }
    }

    private func check() async {
        running = true
        let name = app.callPhone?.pairing.deviceName ?? app.current?.pairing.deviceName
        await app.audio.runCheck(preferredName: name) { steps = $0 }
        running = false; checked = true
    }
}
