import SwiftUI

struct ContactsView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""

    private var grouped: [(String, [Contact])] {
        let list = app.sortedContacts.filter {
            query.isEmpty || !ContactSearch.rows([$0], query: query, limit: 1).isEmpty
        }
        let dict = Dictionary(grouping: list) { c -> String in
            guard let f = c.displayName.first, f.isLetter else { return "#" }
            return String(f).uppercased()
        }
        return dict.sorted { $0.key < $1.key }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack {
                        Text("Contacts").font(.system(size: 22, weight: .bold, design: .rounded))
                        Spacer()
                        Text("\(app.contacts.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    SearchField(text: $query, prompt: "Search contacts")
                }
                .padding(14)
                if app.contacts.isEmpty {
                    EmptyStateView(symbol: "person.2.slash", title: "No contacts yet", message: "Contacts sync from your phone after pairing.")
                } else {
                    List(selection: Binding(get: { app.selectedContactId }, set: { app.selectedContactId = $0 })) {
                        ForEach(grouped, id: \.0) { letter, items in
                            Section(letter) {
                                ForEach(items) { c in
                                    HStack(spacing: 10) {
                                        AvatarView(name: c.displayName, imageData: c.thumbnailJPEG, size: 32)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(c.displayName).font(.system(size: 13.5, weight: .medium))
                                            // While searching by number, show the number that matched, not just the first one.
                                            let shown = query.isEmpty ? c.primaryNumber : (ContactSearch.rows([c], query: query, limit: 1).first?.number ?? c.primaryNumber)
                                            Text(PhoneNumber.pretty(shown) + (c.phoneNumbers.count > 1 ? "  ·  +\(c.phoneNumbers.count - 1) more" : ""))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                    .tag(c.contactId)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 320)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            Group {
                if let c = app.contacts.first(where: { $0.contactId == app.selectedContactId }) {
                    ContactDetailView(contact: c).id(c.contactId)
                } else {
                    EmptyStateView(symbol: "person.crop.circle.badge.checkmark", title: "Select a contact",
                                   message: "Call or text anyone from your phone's address book, from either SIM.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Contacts")
    }
}

struct ContactDetailView: View {
    @Environment(AppState.self) private var app
    var contact: Contact

    private var history: [CallLogEntry] {
        app.calls.filter { contact.phoneNumbers.contains(PhoneNumber.normalize($0.remoteAddress)) }
    }
    private var thread: ChatThread? {
        app.threads.first { contact.phoneNumbers.contains($0.recipient) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    AvatarView(name: contact.displayName, imageData: contact.thumbnailJPEG, size: 104)
                    Text(contact.displayName).font(.system(size: 28, weight: .bold, design: .rounded))
                    // With several numbers there is no "the" number: each one has its own buttons below.
                    if contact.phoneNumbers.count == 1 {
                        HStack(spacing: 14) {
                            action("Message", "message.fill", .accentColor) { app.startConversation(with: contact.primaryNumber) }
                            action("Call", "phone.fill", .green) { app.placeCall(contact.primaryNumber, simId: thread?.preferredSubId) }
                            action("Copy", "doc.on.doc.fill", .gray) { Clipboard.copy(contact.primaryNumber) }
                        }
                    }
                }
                .padding(.top, 30)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(contact.phoneNumbers, id: \.self) { n in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("mobile").font(.caption).foregroundStyle(.secondary)
                                Text(PhoneNumber.pretty(n)).font(.system(.body, design: .rounded)).textSelection(.enabled)
                            }
                            Spacer()
                            Button { app.startConversation(with: n) } label: { Image(systemName: "message.fill") }
                                .buttonStyle(.bordered).help("Message \(PhoneNumber.pretty(n))")
                            Button { Clipboard.copy(n) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.bordered).help("Copy \(PhoneNumber.pretty(n))")
                            ForEach(app.sims) { sim in
                                Button { app.placeCall(n, simId: sim.subscriptionId) } label: {
                                    Label(sim.carrierName, systemImage: "phone.fill").font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(sim.color)
                                .help("Call from \(sim.pillLabel)")
                            }
                        }
                        .padding(.vertical, 8)
                        if n != contact.phoneNumbers.last { Divider() }
                    }
                }
                .card()

                if let t = thread, let last = t.lastMessage {
                    Button { app.open(threadId: t.threadId) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Latest message", systemImage: "bubble.left.fill").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(last.timestamp.relativeShort).font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            Text(last.body).font(.callout).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .card()
                    }
                    .buttonStyle(.plain)
                }

                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Call history", systemImage: "phone").font(.subheadline.weight(.semibold))
                        ForEach(history.prefix(6)) { c in
                            HStack {
                                Image(systemName: c.direction.symbol).foregroundStyle(c.direction == .missed ? .red : .secondary).frame(width: 20)
                                Text(c.direction.label)
                                SimPill(sim: app.sim(c.subscriptionId), compact: true)
                                Spacer()
                                if c.duration > 0 { Text(c.duration.callDuration).foregroundStyle(.secondary).monospacedDigit() }
                                Text(c.startedAt.relativeShort).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    .card()
                }
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func action(_ title: String, _ symbol: String, _ tint: Color, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(tint.gradient))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
