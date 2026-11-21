import SwiftUI

struct CallsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            Picker("", selection: $app.callsShowContacts) {
                Label("Recents & Dialer", systemImage: "phone.fill").tag(false)
                Label("Contacts", systemImage: "person.crop.circle.fill").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320).padding(.vertical, 10)
            Divider()
            if app.callsShowContacts {
                ContactsView()
            } else {
                HStack(spacing: 0) {
                    CallLogView().frame(width: 360)
                    Divider()
                    DialerView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Calls & Dialer")
    }
}

struct CallLogView: View {
    @Environment(AppState.self) private var app
    @State private var filter = 0
    @State private var query = ""

    private var entries: [CallLogEntry] {
        app.calls.filter {
            (filter == 0 || $0.direction == .missed || $0.direction == .rejected) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.remoteAddress.contains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("Recents").font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()
                    Menu {
                        Button("Clear call history on Mac", role: .destructive) { app.clearCallLog() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                SearchField(text: $query, prompt: "Search calls")
                Picker("Filter", selection: $filter) {
                    Text("All").tag(0)
                    Text("Missed").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(14)

            if entries.isEmpty {
                EmptyStateView(symbol: "phone.badge.waveform", title: "No calls", message: "Calls made or received on any SIM will show here.")
            } else {
                List {
                    ForEach(groupedEntries, id: \.0) { title, items in
                        Section(title) {
                            ForEach(items) { CallRow(entry: $0) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var groupedEntries: [(String, [CallLogEntry])] {
        var out: [(String, [CallLogEntry])] = []
        for e in entries {
            let key = Calendar.current.isDateInToday(e.startedAt) ? "Today"
                : Calendar.current.isDateInYesterday(e.startedAt) ? "Yesterday" : "Earlier"
            if out.last?.0 == key { out[out.count - 1].1.append(e) } else { out.append((key, [e])) }
        }
        return out
    }
}

struct CallRow: View {
    @Environment(AppState.self) private var app
    var entry: CallLogEntry
    @State private var hover = false

    var body: some View {
        HStack(spacing: 11) {
            AvatarView(name: entry.title, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(entry.direction == .missed ? .red : .primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: entry.direction.symbol).font(.system(size: 9.5))
                    Text(entry.direction.label + (entry.duration > 0 ? " · \(entry.duration.callDuration)" : ""))
                    if entry.recordingFile != nil { Image(systemName: "waveform").foregroundStyle(.red).help("Recorded") }
                    SimPill(sim: app.sim(entry.subscriptionId), compact: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if hover {
                HStack(spacing: 6) {
                    IconButton(symbol: "message.fill", help: "Message", tint: .accentColor) { app.startConversation(with: entry.remoteAddress) }
                    IconButton(symbol: "phone.fill", help: "Call back", tint: .green) { app.placeCall(entry.remoteAddress, simId: entry.subscriptionId) }
                }
                .transition(.opacity)
            } else {
                Text(entry.startedAt.relativeShort).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture(count: 2) { app.placeCall(entry.remoteAddress, simId: entry.subscriptionId) }
        .contextMenu {
            ForEach(app.sims) { sim in
                Button("Call from \(sim.pillLabel)") { app.placeCall(entry.remoteAddress, simId: sim.subscriptionId) }
            }
            Button("Send Message") { app.startConversation(with: entry.remoteAddress) }
            if let file = entry.recordingFile, FileManager.default.fileExists(atPath: file) {
                Divider()
                Button("Play Recording", systemImage: "play.fill") { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
                Button("Show Recording in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
            }
            Button("Copy Number") { Clipboard.copy(entry.remoteAddress) }
        }
    }
}

// MARK: - Dialer

struct DialerView: View {
    @Environment(AppState.self) private var app
    @State private var simId: Int?
    @FocusState private var focused: Bool

    private let keys: [(String, String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", ""),
    ]

    private var match: Contact? {
        let digits = app.dialerNumber.filter(\.isNumber)
        guard digits.count >= 3 else { return nil }
        return app.contacts.first { c in c.phoneNumbers.contains { $0.filter(\.isNumber).hasSuffix(digits) || $0.filter(\.isNumber).contains(digits) } }
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            VStack(spacing: 6) {
                TextField("", text: $app.dialerNumber, prompt: Text("Enter number").foregroundStyle(.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(call)
                    .frame(height: 44)
                Group {
                    if let match {
                        Button { app.dialerNumber = match.primaryNumber } label: {
                            HStack(spacing: 6) {
                                AvatarView(name: match.displayName, size: 20)
                                Text(match.displayName).font(.callout.weight(.medium))
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(" ").font(.callout)
                    }
                }
                .frame(height: 22)
            }
            .frame(maxWidth: 320)

            Grid(horizontalSpacing: 22, verticalSpacing: 16) {
                ForEach(0..<4) { row in
                    GridRow {
                        ForEach(0..<3) { col in
                            let k = keys[row * 3 + col]
                            DialKey(digit: k.0, letters: k.1) { press(k.0) }
                        }
                    }
                }
            }

            SimSelector(sims: app.sims, selection: $simId)

            HStack(spacing: 30) {
                Color.clear.frame(width: 44, height: 44)
                Button(action: call) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 70, height: 70)
                        .background(Circle().fill(Color.green.gradient))
                        .shadow(color: .green.opacity(0.4), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(app.dialerNumber.isEmpty || app.activeCall != nil)
                .help("Call from \(app.sim(simId)?.pillLabel ?? "default SIM")")
                Button {
                    if !app.dialerNumber.isEmpty { app.dialerNumber.removeLast() }
                } label: {
                    Image(systemName: "delete.left.fill").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .opacity(app.dialerNumber.isEmpty ? 0 : 1)
            }
            Spacer(minLength: 10)
        }
        .padding(24)
        .onAppear {
            simId = app.defaultVoiceSim?.subscriptionId
            focused = true
        }
    }

    private func press(_ d: String) {
        if let call = app.activeCall, call.state == .active { app.performCallAction(.sendDtmf, digit: d) }
        app.dialerNumber.append(d)
    }

    private func call() {
        guard !app.dialerNumber.isEmpty else { return }
        app.placeCall(app.dialerNumber, simId: simId)
        app.dialerNumber = ""
    }
}

struct DialKey: View {
    var digit: String
    var letters: String
    var size: CGFloat = 70
    var action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button {
            action()
            withAnimation(.easeOut(duration: 0.08)) { pressed = true }
            Task { try? await Task.sleep(for: .milliseconds(120)); withAnimation { pressed = false } }
        } label: {
            VStack(spacing: -1) {
                Text(digit).font(.system(size: size * 0.4, weight: .regular, design: .rounded))
                Text(letters.isEmpty ? " " : letters).font(.system(size: size * 0.13, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(pressed ? 0.18 : (hover ? 0.1 : 0.06))))
            .contentShape(Circle())
            .scaleEffect(pressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
