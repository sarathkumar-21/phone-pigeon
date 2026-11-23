import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(alignment: .top, spacing: 18) {
                    DeviceHeroCard().frame(maxWidth: .infinity)
                    if let otp = app.latestOTP {
                        OTPCard(code: otp.code, sender: otp.sender, date: otp.message.timestamp)
                            .frame(width: 280)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                statsRow
                if !app.sims.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "SIM Cards", symbol: "simcard.2.fill")
                        HStack(spacing: 16) { ForEach(app.sims) { SimCardTile(sim: $0) } }
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    RecentConversationsCard()
                    RecentCallsCard()
                }
                if app.isDemo { DemoPlaygroundCard() }
            }
            .padding(28)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .animation(.smooth, value: app.latestOTP?.code)
        }
        .navigationTitle("Overview")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(Date.now.formatted(date: .complete, time: .omitted)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if app.screen.isBusy { app.stopScreenMirror() } else { app.startScreenMirror() }
            } label: {
                Label(app.screen.isBusy ? (app.screen.state == .waiting ? "Waiting for phone…" : "Stop Mirroring") : "Mirror Screen",
                      systemImage: app.screen.isBusy ? "stop.circle" : "rectangle.on.rectangle")
            }
            .controlSize(.large)
            .help("Show your phone's screen on this Mac (view only — you approve on the phone each time)")
            Button { app.section = .calls } label: { Label("Dialer", systemImage: "circle.grid.3x3.fill") }
                .controlSize(.large)
            Button { app.showNewMessage = true } label: { Label("Compose", systemImage: "square.and.pencil") }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    private var statsRow: some View {
        let today = app.calls.filter { Calendar.current.isDateInToday($0.startedAt) }.count
        let missed = app.calls.filter { $0.direction == .missed && Calendar.current.isDateInToday($0.startedAt) }.count
        return HStack(spacing: 14) {
            StatTile(value: "\(app.unreadTotal)", label: "Unread messages", symbol: "bubble.left.fill", tint: .blue) { app.section = .messages }
            StatTile(value: "\(missed)", label: "Missed today", symbol: "phone.down.fill", tint: .red) { app.section = .calls }
            StatTile(value: "\(today)", label: "Calls today", symbol: "phone.fill", tint: .green) { app.section = .calls }
            StatTile(value: "\(app.contacts.count)", label: "Contacts synced", symbol: "person.2.fill", tint: .purple) { app.callsShowContacts = true; app.section = .calls }
        }
    }
}

// MARK: - Hero

struct DeviceHeroCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 24) {
            PhoneIllustration()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.pairing?.deviceName ?? "Phone").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("\(app.pairing?.manufacturer ?? "") · \(app.pairing?.osVersion ?? "")").foregroundStyle(.secondary)
                }
                ConnectionBadge(mode: app.connection)
                HStack(spacing: 18) {
                    metric(symbol: "internaldrive", title: "Storage", value: app.battery?.storageLabel ?? "—")
                    metric(symbol: "headphones", title: "Call audio", value: app.battery?.bluetoothHfpConnected == true ? "Mac ready" : "Phone")
                    metric(symbol: "lock.shield.fill", title: "Encryption", value: "ChaCha20")
                    metric(symbol: "calendar", title: "Paired", value: app.pairing?.pairedAt.formatted(.dateTime.day().month()) ?? "—")
                }
            }
            Spacer(minLength: 0)
            if let b = app.battery {
                VStack(spacing: 6) {
                    BatteryRing(percent: b.batteryPercent, charging: b.isCharging)
                    Text(b.isCharging ? "Charging" : "Battery").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .card(padding: 22)
    }

    private func metric(symbol: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded, weight: .semibold))
        }
    }
}

struct PhoneIllustration: View {
    @Environment(AppState.self) private var app

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(white: 0.12))
                    .frame(width: 92, height: 170)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.primary, Theme.secondary, Color(hex: "#36D1DC")!],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 82, height: 160)
                    .overlay(alignment: .top) {
                        VStack(spacing: 2) {
                            Capsule().fill(.black).frame(width: 22, height: 6).padding(.top, 6)
                            Text(ctx.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .padding(.top, 14)
                            Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).day().month()))
                                .font(.system(size: 7, weight: .medium))
                                .opacity(0.85)
                            Spacer()
                            HStack(spacing: 4) {
                                ForEach(app.sims) { s in
                                    Circle().fill(s.color).frame(width: 7, height: 7).overlay(Circle().stroke(.white, lineWidth: 1))
                                }
                            }
                            .padding(.bottom, 12)
                        }
                        .foregroundStyle(.white)
                    }
            }
            .shadow(color: Theme.secondary.opacity(0.35), radius: 18, y: 10)
            .rotation3DEffect(.degrees(-8), axis: (x: 0, y: 1, z: 0))
        }
    }
}

// MARK: - Tiles

struct StatTile: View {
    var value: String
    var label: String
    var symbol: String
    var tint: Color
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .card(padding: 14)
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.snappy(duration: 0.2), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct OTPCard: View {
    var code: String
    var sender: String
    var date: Date
    @Environment(AppState.self) private var app
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Verification code", systemImage: "key.viewfinder").font(.subheadline.weight(.semibold))
                Spacer()
                Text(date.formatted(date: .omitted, time: .shortened)).font(.caption).opacity(0.8)
            }
            HStack(spacing: 6) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .frame(width: 30, height: 40)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            Text("From \(sender)").font(.caption).opacity(0.85)
            Button {
                Clipboard.copySensitive(code, clearAfter: app.settings.otpClearSeconds)
                withAnimation { copied = true }
                Task { try? await Task.sleep(for: .seconds(2)); withAnimation { copied = false } }
            } label: {
                Label(copied ? "Copied — clears in \(app.settings.otpClearSeconds)s" : "Copy \(code)",
                      systemImage: copied ? "checkmark" : "doc.on.doc.fill")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(Theme.primary)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxHeight: .infinity)
        .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .shadow(color: Theme.primary.opacity(0.35), radius: 14, y: 8)
    }
}

struct RecentConversationsCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recent Conversations", symbol: "bubble.left.and.bubble.right",
                          trailing: AnyView(Button("See all") { app.section = .messages }.buttonStyle(.link)))
                .padding(.bottom, 4)
            let items = Array(app.sortedThreads.prefix(5))
            if items.isEmpty {
                Text("No conversations yet").foregroundStyle(.secondary).padding(.vertical, 20).frame(maxWidth: .infinity)
            }
            ForEach(items) { t in
                Button { app.open(threadId: t.threadId) } label: {
                    HStack(spacing: 10) {
                        AvatarView(name: t.title, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.callout.weight(t.unreadCount > 0 ? .semibold : .regular)).lineLimit(1)
                            Text(t.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(t.lastTimestamp.relativeShort).font(.caption2).foregroundStyle(.secondary)
                            if t.unreadCount > 0 {
                                Text("\(t.unreadCount)").font(.caption2.bold()).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct RecentCallsCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recent Calls", symbol: "phone",
                          trailing: AnyView(Button("See all") { app.section = .calls }.buttonStyle(.link)))
                .padding(.bottom, 4)
            if app.calls.isEmpty {
                Text("No calls yet").foregroundStyle(.secondary).padding(.vertical, 20).frame(maxWidth: .infinity)
            }
            ForEach(app.calls.prefix(5)) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.direction.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(c.direction == .missed || c.direction == .rejected ? .red : .secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.05), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.callout).foregroundStyle(c.direction == .missed ? .red : .primary).lineLimit(1)
                        HStack(spacing: 5) {
                            SimPill(sim: app.sim(c.subscriptionId), compact: true)
                            Text(c.direction.label + (c.duration > 0 ? " · \(c.duration.callDuration)" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(c.startedAt.relativeShort).font(.caption2).foregroundStyle(.secondary)
                    Button { app.placeCall(c.remoteAddress, simId: c.subscriptionId) } label: {
                        Image(systemName: "phone.fill").foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Call back from \(app.sim(c.subscriptionId)?.pillLabel ?? "default SIM")")
                }
                .padding(.vertical, 3)
            }
        }
        .card()
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct DemoPlaygroundCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Demo Playground", symbol: "sparkles")
                Toggle("Random activity", isOn: $app.settings.demoSimulateActivity).toggleStyle(.switch).controlSize(.small)
            }
            Text("You're paired with a virtual dual-SIM phone that speaks the real encrypted protocol. Trigger events to see how PhonePigeon reacts.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { app.demoIncomingCall() } label: { Label("Incoming call", systemImage: "phone.arrow.down.left.fill") }
                Button { app.demoIncomingMessage() } label: { Label("Incoming SMS", systemImage: "message.fill") }
                Button { app.demoIncomingOTP() } label: { Label("OTP message", systemImage: "key.fill") }
            }
            .controlSize(.large)
        }
        .card()
    }
}
