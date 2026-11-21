import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ConnectionSettings().tabItem { Label("Connection", systemImage: "network") }
            DeviceSettings().tabItem { Label("Phone", systemImage: "iphone.gen3") }
            SecuritySettings().tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        Form {
            Section("Notifications") {
                Toggle("Show message notifications", isOn: $app.settings.notificationsEnabled)
                Toggle("Show the phone's other notifications", isOn: $app.settings.showPhoneNotifications)
                Picker("Clear copied codes after", selection: $app.settings.otpClearSeconds) {
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("2 minutes").tag(120)
                    Text("Never").tag(0)
                }
            }
            Section("Calls") {
                Toggle("Open calls full-window, with the contact's photo", isOn: $app.settings.fullWindowCalls)
                Text("Off by default: a call starts as a small card. Auto-redial is always off until you switch it on at the dialer.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Wait between tries", selection: $app.settings.autoRedialDelay) {
                    ForEach(RedialLimits.delays, id: \.self) { Text($0 >= 60 ? "\($0 / 60) min" : "\($0) s").tag($0) }
                }
                Picker("Give up after", selection: $app.settings.autoRedialMaxAttempts) {
                    ForEach(RedialLimits.attempts, id: \.self) { Text("\($0) tries").tag($0) }
                }
            }
            Section("Theme") {
                ThemePicker()
                Toggle("Tint windows with the theme", isOn: $app.settings.tintWindows)
                Picker("Appearance", selection: $app.settings.appearance) {
                    Text("Match system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section("Messages") {
                Toggle("Show SIM badges on messages", isOn: $app.settings.showSimBadges)
            }
            Section("Shortcuts") {
                LabeledContent("New message", value: "⌘N")
                LabeledContent("Switch SIM in composer", value: "⌘1 / ⌘2")
                LabeledContent("Send", value: "Return")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionSettings: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                LabeledContent("Status") { ConnectionBadge(mode: app.connection) }
            }
            Section {
                Toggle("Prefer local network (Bonjour)", isOn: $app.settings.lanEnabled)
                Toggle("Use encrypted cloud relay", isOn: $app.settings.cloudEnabled)
                TextField("Relay URL", text: $app.settings.relayURL)
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Transport")
            } footer: {
                Text("When both devices share a Wi-Fi network PhonePigeon talks to your phone directly. Otherwise end-to-end encrypted envelopes go through the relay, which wakes your phone with a push if it's dozing.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reconnect Now") { app.reconnect() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeviceSettings: View {
    @Environment(AppState.self) private var app
    @State private var removeTarget: String?

    var body: some View {
        Form {
            Section("Paired phones") {
                ForEach(app.phones) { ph in
                    HStack(spacing: 10) {
                        Image(systemName: ph.id == app.current?.id ? "checkmark.circle.fill" : "iphone")
                            .foregroundStyle(ph.id == app.current?.id ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ph.name).font(.body.weight(.medium))
                            Text(ph.connection.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ph.id != app.current?.id { Button("Show") { app.selectPhone(ph.id) } }
                        Button(role: .destructive) { removeTarget = ph.id } label: { Image(systemName: "trash") }
                            .help("Unpair \(ph.name)")
                    }
                }
                Button { app.showAddPhone = true } label: { Label("Add Phone…", systemImage: "plus") }
            }
            if let p = app.pairing {
                Section("Selected phone") {
                    LabeledContent("Name", value: p.deviceName)
                    LabeledContent("Model", value: "\(p.manufacturer) · \(p.osVersion)")
                    LabeledContent("Paired", value: p.pairedAt.formatted(date: .abbreviated, time: .shortened))
                    if let b = app.battery {
                        LabeledContent("Battery") { BatteryGlyph(status: b) }
                    }
                }
                Section("SIM cards") {
                    ForEach(app.sims) { sim in
                        LabeledContent {
                            Text(sim.phoneNumber.map(PhoneNumber.pretty) ?? "—").monospacedDigit()
                        } label: {
                            HStack { SimPill(sim: sim); Text(sim.displayName) }
                        }
                    }
                }
                Section("Bluetooth call audio") {
                    LabeledContent("Hands-Free", value: app.audio.status.label)
                    Button("Check Bluetooth") { app.audio.refresh(preferredName: p.deviceName) }
                }
            } else {
                Text("No phone paired.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Unpair \(app.phone(withId: removeTarget)?.name ?? "phone")?",
                            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
            Button("Unpair and Erase Local Data", role: .destructive) { if let id = removeTarget { app.removePhone(id) }; removeTarget = nil }
        } message: {
            Text("Messages, calls and contacts cached on this Mac will be erased. Nothing is deleted from your phone.")
        }
    }
}

private struct SecuritySettings: View {
    @Environment(AppState.self) private var app
    @State private var confirmRotate = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Key exchange", value: "X25519 (Curve25519)")
                LabeledContent("Cipher", value: "ChaCha20-Poly1305")
                LabeledContent("Key derivation", value: "HKDF-SHA256, directional")
                LabeledContent("Local store", value: "Sealed with Keychain key")
            } header: { Text("End-to-end encryption") }
            Section("Fingerprints") {
                LabeledContent("This Mac") { Text(app.securityFingerprint).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                ForEach(app.phones) { ph in
                    LabeledContent(ph.name) { Text(ph.peerFingerprint).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                }
            }
            Section {
                Button("Generate New Identity Key…", role: .destructive) { confirmRotate = true }
            } footer: {
                Text("Rotating the key unpairs all your phones. You'll need to scan a new QR code for each.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Generate a new identity key?", isPresented: $confirmRotate) {
            Button("Rotate Key and Unpair", role: .destructive) { app.rotateIdentity() }
        }
    }
}
