import SwiftUI

// MARK: - Time picker popover (used by the composer and the dialer)

struct SchedulePopover: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var kind: ScheduledKind
    var address: String
    var text = ""
    var simId: Int?
    var onScheduled: () -> Void = {}

    @State private var date = SchedulePopover.defaultTime()
    @State private var redial = false

    static func defaultTime() -> Date {
        let t = Date().addingTimeInterval(3600)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: t)
        return Calendar.current.date(from: c).map { $0.addingTimeInterval(3600) } ?? t
    }

    private var presets: [(String, Date)] {
        var out: [(String, Date)] = [("In 30 min", .now.addingTimeInterval(1800)), ("In 1 hour", .now.addingTimeInterval(3600))]
        let cal = Calendar.current
        if let tonight = cal.date(bySettingHour: 18, minute: 0, second: 0, of: .now), tonight > .now.addingTimeInterval(120) {
            out.append(("Tonight 6 PM", tonight))
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: .now), let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            out.append(("Tomorrow 9 AM", nine))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(kind == .sms ? "Send later" : "Call later", systemImage: "clock.badge.checkmark.fill").font(.headline)
            HStack(spacing: 8) {
                AvatarView(name: app.displayName(for: address), imageData: app.contact(for: address)?.thumbnailJPEG, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.displayName(for: address)).font(.callout.weight(.medium)).lineLimit(1)
                    if kind == .sms { Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            FlowChips(items: presets.map(\.0)) { i in date = presets[i].1 }
            DatePicker("", selection: $date, in: Date().addingTimeInterval(ScheduleLimits.minLead)..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            if kind == .call {
                Toggle(isOn: $redial) { Label("Redial if nobody answers", systemImage: "arrow.triangle.2.circlepath") }
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Tries again every \(app.settings.autoRedialDelay) s, up to \(app.settings.autoRedialMaxAttempts) times (set in Settings)")
            }
            Text("Runs while PhonePigeon is open and the phone is connected.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Schedule") {
                    if app.schedule(kind, to: address, body: text, simId: simId, at: date, autoRedial: redial) {
                        onScheduled()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { redial = app.settings.autoRedialEnabled }
    }
}

/// A row of small tappable chips.
struct FlowChips: View {
    var items: [String]
    var pick: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    Text(items[i]).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Scheduled list

struct ScheduledView: View {
    @Environment(AppState.self) private var app
    @State private var showNew = false

    private var upcoming: [ScheduledItem] { app.scheduled.filter { $0.status == .pending }.sorted { $0.fireAt < $1.fireAt } }
    private var history: [ScheduledItem] {
        app.scheduled.filter { $0.status != .pending }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scheduled").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Texts and calls PhonePigeon sends later").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !history.isEmpty {
                    Button("Clear History") { app.clearFinishedScheduled() }.controlSize(.small)
                }
                Button { showNew = true } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            Divider()

            if app.scheduled.isEmpty {
                EmptyStateView(symbol: "clock.badge.checkmark.fill", title: "Nothing scheduled",
                               message: "Write a message and tap the clock to send it later, or schedule a call from the dialer. They run while PhonePigeon is open and your phone is connected.",
                               action: ("Schedule Something", { showNew = true }))
            } else {
                List {
                    if !upcoming.isEmpty {
                        Section("Upcoming") { ForEach(upcoming) { ScheduledRow(item: $0) } }
                    }
                    if !history.isEmpty {
                        Section("History") { ForEach(history) { ScheduledRow(item: $0) } }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Scheduled")
        .sheet(isPresented: $showNew) { NewScheduleSheet() }
    }
}

struct ScheduledRow: View {
    @Environment(AppState.self) private var app
    var item: ScheduledItem

    private var tint: Color {
        switch item.status {
        case .pending: .accentColor
        case .sent: .green
        case .failed, .missed: .red
        case .cancelled: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.14)).frame(width: 38, height: 38)
                Image(systemName: item.kind == .sms ? "bubble.left.fill" : "phone.fill").foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.displayName(for: item.address)).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    SimPill(sim: app.sim(item.subscriptionId), compact: true)
                    if item.autoRedial { Image(systemName: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary).help("Redials if nobody answers") }
                }
                Text(item.kind == .sms ? item.body : "Call").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.caption2)
                    Text(item.fireAt.formatted(date: .abbreviated, time: .shortened))
                    if item.status == .pending {
                        Text("· \(item.fireAt.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("· \(item.status.label)").foregroundStyle(tint)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let note = item.note, item.status != .sent { Text(note).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            if item.status == .pending {
                IconButton(symbol: item.kind == .sms ? "paperplane.fill" : "phone.fill", help: item.kind == .sms ? "Send now" : "Call now", tint: .green) {
                    app.runScheduledNow(item.id)
                }
                IconButton(symbol: "xmark", help: "Cancel", tint: .red) { app.cancelScheduled(item.id) }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - New scheduled item

struct NewScheduleSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ScheduledKind = .sms
    @State private var to = ""
    @State private var text = ""
    @State private var simId: Int?
    @State private var date = SchedulePopover.defaultTime()
    @State private var redial = false

    private var suggestions: [ContactNumber] { ContactSearch.rows(app.sortedContacts, query: to, limit: 40) }
    private var targetNumber: String? { ContactSearch.target(app.sortedContacts, typed: to) }
    private var target: String { targetNumber ?? to }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Schedule").font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            Picker("", selection: $kind) {
                Label("Message", systemImage: "bubble.left.fill").tag(ScheduledKind.sms)
                Label("Call", systemImage: "phone.fill").tag(ScheduledKind.call)
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack {
                Text("To:").foregroundStyle(.secondary)
                TextField("Name or phone number", text: $to).textFieldStyle(.plain)
            }
            .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            if !suggestions.isEmpty && !suggestions.contains(where: { PhoneNumber.normalize($0.number) == PhoneNumber.normalize(to) }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions) { row in
                            Button { to = row.number } label: {
                                HStack(spacing: 6) {
                                    AvatarView(name: row.contact.displayName, imageData: row.contact.thumbnailJPEG, size: 20)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(row.contact.displayName).font(.caption)
                                        Text(PhoneNumber.pretty(row.number)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                                    }
                                }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            SimSelector(sims: app.sims, selection: $simId)

            if kind == .sms {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Message", text: $text, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(3...7)
                        .padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        ComposeExtras(text: $text, recipient: "")
                        Spacer()
                        Text(SegmentCounter.describe(text)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Toggle(isOn: $redial) { Label("Redial if nobody answers", systemImage: "arrow.triangle.2.circlepath") }
                    .toggleStyle(.switch)
            }

            DatePicker("When", selection: $date, in: Date().addingTimeInterval(ScheduleLimits.minLead)..., displayedComponents: [.date, .hourAndMinute])
            Text("Runs while PhonePigeon is open and your phone is connected. A message or call that is more than a few minutes late is skipped, never sent late.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Schedule") {
                    if app.schedule(kind, to: target, body: text, simId: simId, at: date, autoRedial: redial) { dismiss() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(targetNumber == nil || (kind == .sms && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(22)
        .frame(width: 470)
        .onAppear {
            simId = app.defaultSmsSim?.subscriptionId
            redial = app.settings.autoRedialEnabled
        }
        .onChange(of: kind) { _, new in simId = (new == .sms ? app.defaultSmsSim : app.defaultVoiceSim)?.subscriptionId }
    }
}
