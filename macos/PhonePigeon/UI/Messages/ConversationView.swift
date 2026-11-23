import SwiftUI

struct ConversationView: View {
    @Environment(AppState.self) private var app
    let threadId: String
    /// Only the newest messages are laid out; a thread of thousands of texts made every keystroke and every new message slow.
    @State private var visible = 300

    private var thread: ChatThread? { app.thread(threadId) }

    var body: some View {
        if let thread {
            VStack(spacing: 0) {
                header(thread)
                Divider()
                messages(thread)
                ComposerView(thread: thread)
            }
            .background(backdrop)
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.accentColor.opacity(0.06), .clear], center: .topTrailing, startRadius: 10, endRadius: 600)
        }
    }

    // MARK: Header

    private func header(_ t: ChatThread) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: t.title, imageData: app.contact(for: t.recipient)?.thumbnailJPEG, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.headline)
                HStack(spacing: 6) {
                    if t.contactName != nil {
                        Text(PhoneNumber.pretty(t.recipient)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let sim = app.sim(t.preferredSubId) {
                        Text("Replies via").font(.caption).foregroundStyle(.tertiary)
                        SimPill(sim: sim)
                    }
                }
            }
            Spacer()
            if t.recipient.contains(where: \.isNumber) && !t.recipient.contains("-") {
                Menu {
                    ForEach(app.sims) { sim in
                        Button("Call from \(sim.pillLabel)") { app.placeCall(t.recipient, simId: sim.subscriptionId) }
                    }
                } label: {
                    Label("Call", systemImage: "phone.fill")
                } primaryAction: {
                    app.placeCall(t.recipient, simId: t.preferredSubId)
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Call using \(app.sim(t.preferredSubId)?.pillLabel ?? "default SIM")")
            }
            Menu {
                Button(t.isPinned ? "Unpin Conversation" : "Pin Conversation", systemImage: "pin") { app.togglePin(t.threadId) }
                Button("Copy Number", systemImage: "doc.on.doc") { Clipboard.copy(t.recipient) }
                Divider()
                Button("Delete from Mac", systemImage: "trash", role: .destructive) { app.deleteThread(t.threadId) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Messages

    private func messages(_ t: ChatThread) -> some View {
        let shown = t.messages.count > visible ? Array(t.messages.suffix(visible)) : t.messages
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.timestamp) }
            .sorted { $0.key < $1.key }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    if t.messages.isEmpty {
                        VStack(spacing: 10) {
                            AvatarView(name: t.title, size: 64)
                            Text("Start a conversation with \(t.title)").foregroundStyle(.secondary)
                        }
                        .padding(.top, 80)
                    }
                    if t.messages.count > visible {
                        Button("Show \(min(300, t.messages.count - visible)) earlier messages") { visible += 300 }
                            .buttonStyle(.link).padding(.vertical, 8)
                    }
                    ForEach(groups, id: \.key) { day, msgs in
                        Text(dayLabel(day))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                            .padding(.vertical, 12)
                        ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                            let next = i + 1 < msgs.count ? msgs[i + 1] : nil
                            let prev = i > 0 ? msgs[i - 1] : nil
                            let isLastInRun = next == nil || next!.direction != m.direction || next!.subscriptionId != m.subscriptionId
                                || next!.timestamp.timeIntervalSince(m.timestamp) > 300
                            let isFirstInRun = prev == nil || prev!.direction != m.direction || m.timestamp.timeIntervalSince(prev!.timestamp) > 300
                            MessageBubble(message: m, showMeta: isLastInRun, tail: isLastInRun)
                                .padding(.top, isFirstInRun ? 8 : 0)
                                .id(m.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: t.messages.count) {
                withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
                if NSApp.isActive { app.markRead(threadId: t.threadId) }
            }
        }
    }

    private func dayLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: - Bubble

struct MessageBubble: View {
    @Environment(AppState.self) private var app
    var message: SmsMessage
    var showMeta: Bool
    var tail: Bool
    @State private var copied = false
    @State private var hover = false

    private var outgoing: Bool { message.direction == .outgoing }
    private var otp: String? { outgoing ? nil : OTPDetector.detect(in: message.body) }

    var body: some View {
        HStack {
            if outgoing { Spacer(minLength: 80) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .foregroundStyle(outgoing ? .white : .primary)
                    .background(bubbleBackground)
                    .clipShape(BubbleShape(outgoing: outgoing, tail: tail))
                    .opacity(message.status == .pending ? 0.75 : 1)
                    .contextMenu {
                        Button("Copy Text", systemImage: "doc.on.doc") { Clipboard.copy(message.body) }
                        if let otp { Button("Copy Code \(otp)", systemImage: "key") { copyOTP(otp) } }
                    }

                if let otp {
                    Button { copyOTP(otp) } label: {
                        Label(copied ? "Copied" : "Copy \(otp)", systemImage: copied ? "checkmark" : "key.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(.white)
                            .background(Theme.brandGradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Copies the code and clears the clipboard after \(app.settings.otpClearSeconds)s")
                }

                if showMeta || hover {
                    HStack(spacing: 5) {
                        if app.settings.showSimBadges { SimPill(sim: app.sim(message.subscriptionId)) }
                        Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        if outgoing {
                            Image(systemName: message.status.symbol)
                                .foregroundStyle(message.status == .failed ? .red : (message.status == .delivered ? Color.accentColor : .secondary))
                                .contentTransition(.symbolEffect(.replace))
                            Text(message.status.label)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
                }
            }
            if !outgoing { Spacer(minLength: 80) }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }

    @ViewBuilder private var bubbleBackground: some View {
        if outgoing {
            if let sim = app.sim(message.subscriptionId), app.sims.count > 1 {
                LinearGradient(colors: [sim.color, sim.color.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Theme.brandGradient
            }
        } else {
            Color(nsColor: .controlBackgroundColor).overlay(Color.primary.opacity(0.03))
        }
    }

    private func copyOTP(_ code: String) {
        Clipboard.copySensitive(code, clearAfter: app.settings.otpClearSeconds)
        withAnimation { copied = true }
        Task { try? await Task.sleep(for: .seconds(2)); withAnimation { copied = false } }
    }
}

nonisolated struct BubbleShape: Shape {
    var outgoing: Bool
    var tail: Bool

    func path(in r: CGRect) -> Path {
        let big: CGFloat = 17, small: CGFloat = tail ? 5 : 17
        let radii = outgoing
            ? RectangleCornerRadii(topLeading: big, bottomLeading: big, bottomTrailing: small, topTrailing: big)
            : RectangleCornerRadii(topLeading: big, bottomLeading: small, bottomTrailing: big, topTrailing: big)
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: r)
    }
}

// MARK: - Composer

struct ComposerView: View {
    @Environment(AppState.self) private var app
    let thread: ChatThread
    @State private var text = ""
    @State private var simId: Int?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                SimSelector(sims: app.sims, selection: Binding(get: { simId }, set: { v in
                    simId = v
                    if let v { app.setPreferredSim(v, for: thread.threadId) }
                }), showShortcutHint: true)
                Spacer()
                if !text.isEmpty {
                    Text(SegmentCounter.describe(text)).font(.caption).foregroundStyle(.secondary).transition(.opacity)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ComposeExtras(text: $text, recipient: thread.recipient, simId: simId)
                    .padding(.bottom, 2)
                TextField("Message via \(app.sim(simId)?.carrierName ?? "SMS")", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(focused ? (app.sim(simId)?.color ?? .accentColor).opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 1))
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(canSend ? AnyShapeStyle((app.sim(simId)?.color ?? .accentColor).gradient) : AnyShapeStyle(Color.secondary.opacity(0.3)), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy, value: text.isEmpty)
        .onAppear {
            text = thread.draft
            simId = thread.preferredSubId ?? app.defaultSmsSim?.subscriptionId
            focused = true
        }
        // Sticky SIM: follow the SIM of the latest incoming message (spec §12 dual-SIM reply routing).
        .onChange(of: thread.preferredSubId) { _, new in if let new { withAnimation(.snappy) { simId = new } } }
        .onChange(of: text) { _, new in app.setDraft(new, for: thread.threadId) }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && app.connection.isConnected }

    private func send() {
        guard canSend else {
            if !app.connection.isConnected { app.show("Phone is offline — message not sent", symbol: "wifi.slash", style: .warning) }
            return
        }
        if app.send(text, to: thread.recipient, simId: simId) { text = "" }
    }
}
