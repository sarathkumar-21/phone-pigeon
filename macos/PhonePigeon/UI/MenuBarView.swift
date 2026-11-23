import SwiftUI

/// Menu bar popover: battery, signal, recent threads, quick compose and quick dial (spec §9.1).
struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var mode = 0
    @State private var to = ""
    @State private var text = ""
    @State private var simId: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if app.isPaired {
                header
                if let otp = app.latestOTP { otpRow(otp.code, otp.sender) }
                Picker("", selection: $mode) {
                    Text("Recent").tag(0)
                    Text("Compose").tag(1)
                    Text("Dial").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()

                switch mode {
                case 0: recents
                case 1: compose
                default: dial
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No phone paired").font(.headline)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            Divider()
            HStack {
                Button("Open PhonePigeon") { openMain() }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.borderless).help("Quit")
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { simId = app.defaultSmsSim?.subscriptionId }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.brandGradient).frame(width: 34, height: 34)
                Image(systemName: "iphone.gen3").foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.pairing?.deviceName ?? "").font(.headline)
                ConnectionBadge(mode: app.connection).scaleEffect(0.9, anchor: .leading)
            }
            Spacer()
            if let b = app.battery {
                VStack(alignment: .trailing, spacing: 4) {
                    BatteryGlyph(status: b).font(.callout.weight(.medium))
                    Image(systemName: b.bluetoothHfpConnected ? "headphones" : "headphones.slash")
                        .foregroundStyle(b.bluetoothHfpConnected ? Color.green : Color.secondary)
                        .help(b.bluetoothHfpConnected ? "Bluetooth call audio connected" : "Bluetooth call audio not connected")
                }
            }
        }
    }

    private func otpRow(_ code: String, _ sender: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(code).font(.system(.title3, design: .monospaced, weight: .bold))
                Text(sender).font(.caption).opacity(0.8)
            }
            Spacer()
            Button("Copy") { Clipboard.copySensitive(code, clearAfter: app.settings.otpClearSeconds) }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(Theme.primary)
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var recents: some View {
        VStack(spacing: 2) {
            ForEach(app.sortedThreads.prefix(5)) { t in
                Button {
                    app.open(threadId: t.threadId)
                    openMain()
                } label: {
                    HStack(spacing: 9) {
                        AvatarView(name: t.title, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.callout.weight(t.unreadCount > 0 ? .bold : .medium)).lineLimit(1)
                            Text(t.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        SimPill(sim: app.sim(t.lastMessage?.subscriptionId), compact: true)
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("To (name or number)", text: $to).textFieldStyle(.roundedBorder)
            TextField("Message", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            HStack {
                SimSelector(sims: app.sims, selection: $simId)
                Spacer()
                Button("Send") {
                    guard let target = ContactSearch.target(app.contacts, typed: to) else {
                        app.show("Type a phone number, or the exact name of a contact with one number.", symbol: "person.crop.circle.badge.questionmark", style: .warning)
                        return
                    }
                    if app.send(text, to: target, simId: simId) {
                        text = ""; to = ""
                        app.show("Message sent", symbol: "paperplane.fill", style: .success)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(to.isEmpty || text.isEmpty)
            }
        }
    }

    private var dial: some View {
        VStack(spacing: 10) {
            @Bindable var app = app
            TextField("Number", text: $app.dialerNumber)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .rounded))
                .multilineTextAlignment(.center)
            HStack {
                SimSelector(sims: app.sims, selection: $simId)
                Spacer()
                Button {
                    app.placeCall(app.dialerNumber, simId: simId)
                    app.dialerNumber = ""
                    openMain()
                } label: { Label("Call", systemImage: "phone.fill") }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(app.dialerNumber.isEmpty)
            }
        }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
