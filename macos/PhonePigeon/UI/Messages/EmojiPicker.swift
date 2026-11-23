import SwiftUI

// MARK: - Compose toolbar (emoji, GIF link, schedule)

/// The three small buttons next to a message box. Used by the conversation composer and the New Message sheet.
struct ComposeExtras: View {
    @Binding var text: String
    /// Who the message is for (needed to schedule it); empty hides the schedule button.
    var recipient: String
    var simId: Int?
    var onScheduled: () -> Void = {}

    @State private var showEmoji = false
    @State private var showGIF = false
    @State private var showSchedule = false

    private var canSchedule: Bool {
        PhoneNumber.isDialable(recipient) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 2) {
            Button { showEmoji.toggle() } label: {
                Image(systemName: "face.smiling").font(.system(size: 16)).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Emoji")
            .popover(isPresented: $showEmoji, arrowEdge: .top) { EmojiPicker { text += $0 } }

            Button { showGIF.toggle() } label: {
                Text("GIF").font(.system(size: 10, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.secondary, lineWidth: 1.3))
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Add a GIF link")
            .popover(isPresented: $showGIF, arrowEdge: .top) { GIFLinkPicker { link in
                text += (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + link
            } }

            if !recipient.isEmpty {
                Button { showSchedule.toggle() } label: {
                    Image(systemName: "clock").font(.system(size: 15)).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(canSchedule ? Color.secondary : Color.secondary.opacity(0.4))
                .help(canSchedule ? "Send later…" : "Write a message to schedule it")
                .disabled(!canSchedule)
                .popover(isPresented: $showSchedule, arrowEdge: .top) {
                    SchedulePopover(kind: .sms, address: recipient, text: text, simId: simId) {
                        text = ""
                        onScheduled()
                    }
                }
            }
        }
    }
}

// MARK: - Emoji

enum EmojiCatalog {
    static let categories: [(name: String, symbol: String, emoji: [String])] = [
        ("Smileys", "face.smiling", chars("😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩😘😗😚😙😋😛😜🤪😝🤑🤗🤭🤫🤔🤐🤨😐😑😶🙄😏😣😥😮🤯😪😫🥱😴😌😎🤓🥳🥺😢😭😤😠😡🤬😱😨😰😓🤒🤕🤢🤮🥵🥶😷")),
        ("People", "hand.wave", chars("👋🤚🖐✋🖖👌🤌🤏✌️🤞🤟🤘🤙👈👉👆👇☝️👍👎✊👊🤛🤜👏🙌👐🤲🙏✍️💅💪🦾🧠👀👁👅👄👶🧒👦👧🧑👱👨👩🧔👴👵🙍🙎🙅🙆💁🙋🙇🤦🤷🧑‍💻🧑‍🍳🧑‍🎓")),
        ("Hearts", "heart", chars("❤️🧡💛💚💙💜🖤🤍🤎💔❣️💕💞💓💗💖💘💝💟☮️✨⭐️🌟💫🔥💥💯💢💦💨🎉🎊🎈🎁🏆🥇")),
        ("Nature", "leaf", chars("🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🐔🐧🐦🦆🦉🐴🦄🐝🦋🐢🐍🐙🐠🐬🐳🌵🎄🌲🌳🌴🌱🍀🌿🍁🍂🌸🌹🌻🌞🌙🌈☀️⛅️☁️🌧⚡️❄️🌊")),
        ("Food", "fork.knife", chars("🍏🍎🍊🍋🍌🍉🍇🍓🍒🥭🍍🥥🥝🍅🥑🌽🥕🍞🧀🍳🥞🍔🍟🍕🌭🌮🌯🍝🍜🍣🍤🍩🍪🎂🍰🍫🍬🍭☕️🍵🍺🍷🥂🍹🥤")),
        ("Activity", "figure.run", chars("⚽️🏀🏈⚾️🎾🏐🏉🏏🏓🏸🥊🎯🎳🎮🎲🎧🎤🎸🎹🥁🎬🎨🏊🚴🧘🎣🏄🏆")),
        ("Travel", "airplane", chars("🚗🚕🚙🚌🏎🚓🚑🚒🚲🛵🏍✈️🚀🛸🚁⛵️🚢🏠🏢🏥🏦🏨🏖🏝🏔🗻🌆🌃🌉🎡🎢")),
        ("Objects", "lightbulb", chars("⌚️📱💻⌨️🖥🖨📷🎥📞☎️📺⏰💡🔋🔌💰💳💎🔧🔨🧰🔒🔑📦✉️📝📌📎📚🎓✏️🖊🧹🛒🚪")),
        ("Symbols", "checkmark.seal", chars("✅❌❓❗️‼️⚠️🚫♻️✔️➕➖➡️⬅️⬆️⬇️🔄🔔🔕🔊🆗🆒🆕🆓💬💭🗯")),
    ]

    /// Splits on grapheme clusters, so flags and joined emoji (👩‍💻) stay whole.
    private static func chars(_ s: String) -> [String] { s.map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// Unicode's own name for the emoji's first character ("GRINNING FACE"), lowercased, for search.
    static func name(_ emoji: String) -> String {
        emoji.unicodeScalars.first?.properties.name?.lowercased() ?? ""
    }

    private static let recentKey = "recentEmoji"
    static var recents: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }
    static func remember(_ e: String) {
        var list = recents.filter { $0 != e }
        list.insert(e, at: 0)
        UserDefaults.standard.set(Array(list.prefix(24)), forKey: recentKey)
    }
}

struct EmojiPicker: View {
    var pick: (String) -> Void
    @State private var query = ""
    @State private var category = 0
    @State private var recents = EmojiCatalog.recents

    private var shown: [String] {
        if !query.isEmpty {
            let q = query.lowercased()
            return EmojiCatalog.categories.flatMap(\.emoji).filter { EmojiCatalog.name($0).contains(q) }
        }
        return category < 0 ? recents : EmojiCatalog.categories[category].emoji
    }

    var body: some View {
        VStack(spacing: 8) {
            SearchField(text: $query, prompt: "Search emoji")
            if query.isEmpty {
                HStack(spacing: 2) {
                    if !recents.isEmpty { tab(-1, "clock") }
                    ForEach(EmojiCatalog.categories.indices, id: \.self) { tab($0, EmojiCatalog.categories[$0].symbol) }
                }
            }
            ScrollView {
                if shown.isEmpty {
                    Text("No emoji found").foregroundStyle(.secondary).padding(.top, 40)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 2), count: 8), spacing: 2) {
                        ForEach(shown, id: \.self) { e in
                            Button {
                                pick(e)
                                EmojiCatalog.remember(e)
                                recents = EmojiCatalog.recents
                            } label: { Text(e).font(.system(size: 22)).frame(width: 34, height: 34).contentShape(Rectangle()) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(height: 200)
            HStack {
                Spacer()
                Button("More…") { NSApp.orderFrontCharacterPalette(nil) }
                    .buttonStyle(.link).font(.caption)
                    .help("Open the macOS emoji and symbols viewer")
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { if recents.isEmpty { category = 0 } else { category = -1 } }
    }

    private func tab(_ index: Int, _ symbol: String) -> some View {
        Button { category = index } label: {
            Image(systemName: symbol).font(.system(size: 13))
                .frame(width: 30, height: 26)
                .background(category == index ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(category == index ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - GIF links

/// SMS can't carry an animated picture itself, so a GIF goes out as a link. Phones with RCS, WhatsApp-style apps or link
/// previews show it animated. PhonePigeon never talks to a GIF service: browse one yourself, copy its link, paste it here.
struct GIFLinkPicker: View {
    var insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var clipboardLink: String?

    private var valid: Bool { Self.validate(link) != nil }

    static func validate(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count <= 500, !s.contains(" "), let url = URL(string: s), url.scheme?.lowercased() == "https",
              let host = url.host, host.contains(".") else { return nil }
        return url.absoluteString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add a GIF", systemImage: "play.rectangle.fill").font(.headline)
            Text("Texts can't hold an animated picture, so it is sent as a link. Find one, copy its link, then paste it here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Browse GIPHY") { NSWorkspace.shared.open(URL(string: "https://giphy.com/")!) }
                Button("Browse Tenor") { NSWorkspace.shared.open(URL(string: "https://tenor.com/")!) }
            }
            .controlSize(.small)
            TextField("https://…", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if let clipboardLink, clipboardLink != link {
                Button { link = clipboardLink } label: { Label("Use the link you copied", systemImage: "doc.on.clipboard") }
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Link", action: add).buttonStyle(.borderedProminent).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), let ok = Self.validate(s) { clipboardLink = ok; link = ok }
        }
    }

    private func add() {
        guard let ok = Self.validate(link) else { return }
        insert(ok)
        dismiss()
    }
}
