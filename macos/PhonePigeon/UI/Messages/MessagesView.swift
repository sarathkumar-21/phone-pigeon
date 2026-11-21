import SwiftUI

struct MessagesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ThreadListView()
                .frame(width: 330)
            Divider()
            Group {
                if let t = app.thread(app.selectedThreadId) {
                    ConversationView(threadId: t.threadId).id(t.threadId)
                } else {
                    EmptyStateView(symbol: "bubble.left.and.text.bubble.right.fill",
                                   title: "Pick a conversation",
                                   message: "Messages from every SIM on your phone appear here, end-to-end encrypted.",
                                   action: ("New Message", { app.showNewMessage = true }))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Messages")
    }
}

// MARK: - Thread list

struct ThreadListView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var unreadOnly = false

    private var filtered: [ChatThread] {
        app.sortedThreads.filter { t in
            (app.simFilter == nil || t.messages.contains { $0.subscriptionId == app.simFilter }) &&
            (!unreadOnly || t.unreadCount > 0) &&
            (query.isEmpty || t.title.localizedCaseInsensitiveContains(query) || t.recipient.contains(query) ||
             t.messages.contains { $0.body.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("Messages").font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()
                    Menu {
                        Toggle("Unread only", isOn: $unreadOnly)
                        Divider()
                        Button("Mark all as read") { app.markAllRead() }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    IconButton(symbol: "square.and.pencil", help: "New message (⌘N)") { app.showNewMessage = true }
                }
                SearchField(text: $query, prompt: "Search messages")
                Picker("SIM", selection: $app.simFilter) {
                    Text("All SIMs").tag(Int?.none)
                    ForEach(app.sims) { Text($0.carrierName).tag(Int?.some($0.subscriptionId)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if filtered.isEmpty {
                EmptyStateView(symbol: query.isEmpty ? "tray" : "magnifyingglass",
                               title: query.isEmpty ? "Nothing here" : "No results",
                               message: query.isEmpty ? "No conversations match this filter." : "Try a different name, number or word.")
            } else {
                List(selection: Binding(get: { app.selectedThreadId }, set: { id in
                    app.selectedThreadId = id
                    if let id { app.markRead(threadId: id) }
                })) {
                    ForEach(filtered) { t in
                        ThreadRow(thread: t, query: query)
                            .tag(t.threadId)
                            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                            .contextMenu {
                                Button(t.isPinned ? "Unpin" : "Pin", systemImage: t.isPinned ? "pin.slash" : "pin") { app.togglePin(t.threadId) }
                                Button("Mark as Read", systemImage: "envelope.open") { app.markRead(threadId: t.threadId) }
                                Button("Call", systemImage: "phone") { app.placeCall(t.recipient, simId: t.preferredSubId) }
                                Button("Copy Number", systemImage: "doc.on.doc") { Clipboard.copy(t.recipient) }
                                Divider()
                                Button("Delete from Mac", systemImage: "trash", role: .destructive) { app.deleteThread(t.threadId) }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

struct ThreadRow: View {
    @Environment(AppState.self) private var app
    var thread: ChatThread
    var query: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack(alignment: .topLeading) {
                AvatarView(name: thread.title, size: 42)
                if thread.unreadCount > 0 {
                    Circle().fill(Color.accentColor).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                        .offset(x: -2, y: -2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if thread.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                    Text(thread.title).font(.system(size: 13.5, weight: thread.unreadCount > 0 ? .bold : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(thread.lastTimestamp.relativeShort).font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    Text(snippet)
                        .font(.system(size: 12.5))
                        .foregroundStyle(thread.unreadCount > 0 ? .primary : .secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    if app.settings.showSimBadges { SimPill(sim: app.sim(thread.lastMessage?.subscriptionId), compact: true) }
                    if let last = thread.lastMessage, OTPDetector.detect(in: last.body) != nil, last.direction == .incoming {
                        Label("Code", systemImage: "key.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.purple)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.purple.opacity(0.1), in: Capsule())
                    }
                    if thread.unreadCount > 1 {
                        Spacer()
                        Text("\(thread.unreadCount)").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private var snippet: String {
        guard let last = thread.lastMessage else { return thread.draft.isEmpty ? "No messages yet" : "Draft: \(thread.draft)" }
        if !thread.draft.isEmpty { return "Draft: \(thread.draft)" }
        return (last.direction == .outgoing ? "You: " : "") + last.body
    }
}

// MARK: - New message

struct NewMessageSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var body_ = ""
    @State private var simId: Int?
    @FocusState private var focus: Field?
    enum Field { case to, body }

    private var suggestions: [Contact] {
        guard !to.isEmpty else { return Array(app.sortedContacts.prefix(6)) }
        return app.sortedContacts.filter { $0.displayName.localizedCaseInsensitiveContains(to) || $0.phoneNumbers.contains { $0.contains(to.filter(\.isNumber)) && !to.filter(\.isNumber).isEmpty } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Message").font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            HStack {
                Text("To:").foregroundStyle(.secondary)
                TextField("Name or phone number", text: $to).textFieldStyle(.plain).focused($focus, equals: .to)
                    .onSubmit { focus = .body }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            if focus == .to || to.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(suggestions) { c in
                            Button {
                                to = c.primaryNumber
                                focus = .body
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(name: c.displayName, size: 30)
                                    VStack(alignment: .leading) {
                                        Text(c.displayName).font(.callout.weight(.medium))
                                        Text(PhoneNumber.pretty(c.primaryNumber)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 180)
            }

            SimSelector(sims: app.sims, selection: $simId, showShortcutHint: true)

            TextField("Message", text: $body_, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(4...8)
                .focused($focus, equals: .body)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Text(SegmentCounter.describe(body_)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    let target = suggestions.first(where: { $0.displayName.caseInsensitiveCompare(to) == .orderedSame })?.primaryNumber ?? to
                    if app.send(body_, to: target, simId: simId) {
                        app.open(threadId: PhoneNumber.threadId(for: target))
                        dismiss()
                    }
                } label: { Label("Send", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(to.isEmpty || body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            simId = app.defaultSmsSim?.subscriptionId
            focus = .to
        }
    }
}

enum SegmentCounter {
    static func describe(_ text: String) -> String {
        guard !text.isEmpty else { return "SMS · 160 characters per part" }
        let gsm = text.unicodeScalars.allSatisfy { $0.isASCII }
        let single = gsm ? 160 : 70, multi = gsm ? 153 : 67
        let n = text.count
        let parts = n <= single ? 1 : Int(ceil(Double(n) / Double(multi)))
        let remaining = (n <= single ? single : parts * multi) - n
        return "\(remaining) left · \(parts) part\(parts == 1 ? "" : "s")\(gsm ? "" : " · Unicode")"
    }
}
