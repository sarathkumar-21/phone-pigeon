import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style browser of the phone's file system (spec v2 §6.1.2, §6.3, §11.1.4).
struct FilesView: View {
    @Environment(AppState.self) private var app
    @State private var path = "/"
    @State private var history: [String] = []
    @State private var entries: [FileEntry] = []
    @State private var selection = Set<FileEntry.ID>()
    @State private var lastClicked: FileEntry.ID?
    @State private var query = ""
    @State private var showHidden = false
    @State private var loading = false
    @State private var error: String?
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
    @State private var previewURL: URL?
    @State private var renaming: FileEntry?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var deleting: [FileEntry] = []
    @State private var dropTargeted = false
    // Whole-phone search (two or more characters), as opposed to filtering the open folder.
    @State private var searchResults: [FileEntry]?
    @State private var searching = false
    @State private var searchTruncated = false
    @State private var searchError: String?
    /// "list" (the table) or "grid" (thumbnails). Remembered between launches.
    @AppStorage("filesViewMode") private var viewMode = "list"

    private var isGlobalSearch: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    private var media: MediaClient { app.media }

    private var visible: [FileEntry] {
        let filtered: [FileEntry]
        if isGlobalSearch { filtered = searchResults ?? [] }
        else { filtered = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        // Folders first, then the user's chosen sort.
        return filtered.sorted(using: sortOrder).sorted { $0.isDirectory && !$1.isDirectory }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            statusBar
        }
        .navigationTitle("Files")
        .task(id: "\(path)|\(showHidden)|\(media.isAvailable)") { await load() }
        .task(id: "\(query)|\(showHidden)|\(media.isAvailable)") { await runSearch() }
        .quickLookPreview($previewURL)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let r = renaming { op(.rename, r.path, parent(of: r.path) + newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Folder name", text: $newName)
            Button("Create") { op(.mkdir, join(path, newName)) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting.count == 1 ? "“\(deleting[0].name)”" : "\(deleting.count) items") from your phone?",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Delete", role: .destructive) {
                let list = deleting
                Task { for e in list { try? await media.fileOp(.delete, e.path) }; await load() }
            }
        } message: { Text("This removes the files from the phone's storage.") }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { goBack() } label: { Image(systemName: "chevron.left") }.disabled(history.isEmpty).help("Back")
            Button { navigate(parent(of: path)) } label: { Image(systemName: "arrow.up") }.disabled(path == "/").help("Enclosing folder")
            breadcrumbs
            Spacer(minLength: 8)
            Picker("View", selection: $viewMode) {
                Image(systemName: "list.bullet").tag("list").help("List")
                Image(systemName: "square.grid.2x2").tag("grid").help("Thumbnails")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 76)
            .help("Show files as a list or as thumbnails")
            SearchField(text: $query, prompt: "Search the whole phone").frame(width: 230)
            Menu {
                Toggle("Show Hidden Files", isOn: $showHidden)
                Divider()
                Button("New Folder…", systemImage: "folder.badge.plus") { newName = "untitled folder"; creatingFolder = true }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button { pasteFromMac() } label: { Image(systemName: "doc.on.clipboard") }
                .help("Paste files or images from the Mac clipboard into this folder (⌘V)")
                .disabled(!media.isAvailable)
            Button { pickUpload() } label: { Label("Upload", systemImage: "arrow.up.doc.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(!media.isAvailable)
            TransfersButton()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var breadcrumbs: some View {
        let parts = path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                crumb("Internal storage", "/", icon: "internaldrive.fill", last: parts.isEmpty)
                ForEach(parts.indices, id: \.self) { i in
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    crumb(parts[i], "/" + parts[0...i].joined(separator: "/"), icon: "folder.fill", last: i == parts.count - 1)
                }
            }
        }
    }

    private func crumb(_ title: String, _ target: String, icon: String, last: Bool) -> some View {
        Button { navigate(target) } label: {
            Label(title, systemImage: icon)
                .font(.callout.weight(last ? .semibold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(last ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(last ? Color.accentColor : .primary)
    }

    // MARK: Table

    @ViewBuilder private var content: some View {
        if !media.isAvailable {
            EmptyStateView(symbol: "wifi.exclamationmark", title: "Phone files unavailable",
                           message: "Files stream directly from your phone over Wi-Fi. Connect both devices to the same network.")
        } else if let error {
            EmptyStateView(symbol: "lock.trianglebadge.exclamationmark", title: "Can't open this folder", message: error,
                           action: ("Try Again", { Task { await load() } }))
        } else {
            Group { if viewMode == "grid" { grid } else { table } }
            .onKeyPress(.space) {
                if let e = visible.first(where: { selection.contains($0.id) && !$0.isDirectory }) { open(e); return .handled }
                return .ignored
            }
            .overlay {
                if (loading && entries.isEmpty && !isGlobalSearch) || (searching && visible.isEmpty) { ProgressView() }
                if !loading && !searching && visible.isEmpty {
                    Text(isGlobalSearch ? (searchError ?? "No matches on the phone") : (query.isEmpty ? "This folder is empty" : "No matches"))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .background(Color.accentColor.opacity(0.06))
                        .overlay(Label("Drop to upload to \(path == "/" ? "Internal storage" : (path as NSString).lastPathComponent)",
                                       systemImage: "arrow.up.doc.fill").font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                uploadProviders(providers)
                return true
            }
            // ⌘C copies phone files to the Mac pasteboard; ⌘V pastes Mac files/images into this folder.
            .onCopyCommand {
                copySelection()
                return []
            }
            .onPasteCommand(of: [.fileURL, .image]) { providers in uploadProviders(providers) }
        }
    }

    private var table: some View {
        Table(of: FileEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { e in
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: e)).foregroundStyle(tint(for: e)).frame(width: 18)
                    Text(e.name).lineLimit(1)
                    if e.isDirectory && e.childCount > 0 {
                        Text("\(e.childCount)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 220, ideal: 360)
            TableColumn("Folder") { e in
                // Only meaningful for search results, which come from all over the phone.
                Text(isGlobalSearch ? displayFolder(of: e.path) : "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .width(min: isGlobalSearch ? 140 : 0, ideal: isGlobalSearch ? 220 : 0, max: isGlobalSearch ? 400 : 0)
            TableColumn("Size", value: \.sizeBytes) { e in
                Text(e.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: e.sizeBytes, countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(90)
            TableColumn("Kind", value: \.mimeType) { e in
                Text(kind(e)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Date Modified", value: \.modifiedAtMs) { e in
                Text(e.modifiedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 170)
        } rows: {
            ForEach(visible) { e in
                TableRow(e)
                    .itemProvider { media.dragProvider(for: PhoneFileRef(e)) }
            }
        }
        .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
            let picked = visible.filter { ids.contains($0.id) }
            if picked.count == 1, let e = picked.first {
                Button(e.isDirectory ? "Open" : "Quick Look", systemImage: e.isDirectory ? "folder" : "eye") { open(e) }
                Button("Rename…", systemImage: "pencil") { newName = e.name; renaming = e }
                if isGlobalSearch {
                    Button("Show in Folder", systemImage: "arrow.turn.up.right") { navigate(parent(of: e.path)) }
                }
            }
            if !picked.isEmpty {
                Button(picked.count > 1 ? "Copy \(picked.count) Items" : "Copy", systemImage: "doc.on.doc") { copy(picked) }
                Button("Download to Downloads", systemImage: "arrow.down.circle") { downloadFiles(picked) }
            }
            if MediaClient.pasteboardHasUploadable() {
                Button("Paste from Mac", systemImage: "doc.on.clipboard") { pasteFromMac() }
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = picked }
        } primaryAction: { ids in
            if let e = visible.first(where: { ids.contains($0.id) }) { open(e) }
        }
    }

    // MARK: Thumbnails (grid)

    private let gridColumns = [GridItem(.adaptive(minimum: 128, maximum: 168), spacing: 14, alignment: .top)]

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(visible) { e in
                    FileTile(entry: e, selected: selection.contains(e.id), showFolder: isGlobalSearch ? displayFolder(of: e.path) : nil,
                             symbol: symbol(for: e), tint: tint(for: e), media: media)
                        .onTapGesture(count: 2) { open(e) }
                        .onTapGesture {
                            let flags = NSEvent.modifierFlags
                            if flags.contains(.shift), let last = lastClicked,
                               let a = visible.firstIndex(where: { $0.id == last }), let b = visible.firstIndex(where: { $0.id == e.id }) {
                                selection.formUnion(visible[min(a, b)...max(a, b)].map(\.id))
                            } else if flags.contains(.command) {
                                if selection.contains(e.id) { selection.remove(e.id) } else { selection.insert(e.id) }
                                lastClicked = e.id
                            } else {
                                lastClicked = e.id
                                selection = [e.id]
                            }
                        }
                        .onDrag { media.dragProvider(for: PhoneFileRef(e)) }
                        .contextMenu { tileMenu(e) }
                }
            }
            .padding(16)
        }
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = [] })
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(characters: ["a"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(visible.map(\.id)); return .handled
        }
    }

    @ViewBuilder private func tileMenu(_ e: FileEntry) -> some View {
        let picked = selection.contains(e.id) ? visible.filter { selection.contains($0.id) } : [e]
        if picked.count == 1 {
            Button(e.isDirectory ? "Open" : "Quick Look", systemImage: e.isDirectory ? "folder" : "eye") { open(e) }
            Button("Rename…", systemImage: "pencil") { newName = e.name; renaming = e }
            if isGlobalSearch {
                Button("Show in Folder", systemImage: "arrow.turn.up.right") { navigate(parent(of: e.path)) }
            }
        }
        if !picked.isEmpty {
            Button(picked.count > 1 ? "Copy \(picked.count) Items" : "Copy", systemImage: "doc.on.doc") { copy(picked) }
            Button("Download to Downloads", systemImage: "arrow.down.circle") { downloadFiles(picked) }
        }
        if MediaClient.pasteboardHasUploadable() {
            Button("Paste from Mac", systemImage: "doc.on.clipboard") { pasteFromMac() }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { deleting = picked }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(isGlobalSearch ? "\(visible.count) match\(visible.count == 1 ? "" : "es") on the phone\(searchTruncated ? " (showing the first ones — narrow the search)" : "")"
                                : "\(visible.count) items").font(.caption).foregroundStyle(.secondary)
            if searching { ProgressView().controlSize(.small); Text("Searching the phone…").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let s = app.battery, s.storageTotalBytes > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: s.storageTotalBytes - s.storageFreeBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: s.storageTotalBytes, countStyle: .file)) used")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: s.storageUsedFraction)
                    .progressViewStyle(.linear).frame(width: 140)
                    .tint(s.storageUsedFraction > 0.9 ? .red : .accentColor)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: Actions

    private func load() async {
        guard media.isAvailable else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await media.listDirectory(path, includeHidden: showHidden)
            withAnimation(.snappy) { entries = r.entries }
            selection = []
        } catch {
            self.error = error.localizedDescription
            entries = []
        }
    }

    /// Debounced whole-phone search; a newer query cancels the older request (and the phone stops walking for it).
    private func runSearch() async {
        guard isGlobalSearch, media.isAvailable else { searchResults = nil; searching = false; searchError = nil; return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        searchError = nil
        defer { searching = false }
        do {
            let r = try await media.searchFiles(query.trimmingCharacters(in: .whitespaces), includeHidden: showHidden)
            guard !Task.isCancelled else { return }
            searchResults = r.entries
            searchTruncated = r.truncated
        } catch {
            if Task.isCancelled { return }
            searchResults = []
            searchError = error.localizedDescription
        }
    }

    private func displayFolder(of path: String) -> String {
        let p = parent(of: path)
        return p == "/" ? "Internal storage" : "Internal storage" + p
    }

    private func navigate(_ target: String) {
        guard target != path else { return }
        history.append(path)
        path = target
        query = ""
    }

    private func goBack() { if let last = history.popLast() { path = last } }

    private func open(_ e: FileEntry) {
        if e.isDirectory { navigate(e.path); return }
        if ExternalVideo.needsExternalPlayer(name: e.name, mime: e.mimeType) {
            app.openWithDefaultPlayer(path: e.path, name: e.name, size: e.sizeBytes)
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PhonePigeonPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        Task {
            do {
                previewURL = try await media.download(path: e.path, name: e.name, size: e.sizeBytes, into: tmp)
            } catch {
                app.show(error.localizedDescription, symbol: "xmark.octagon.fill", style: .error)
            }
        }
    }

    private func downloadFiles(_ list: [FileEntry]) {
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        Task {
            var n = 0
            for e in list { if (try? await media.downloadTree(PhoneFileRef(e), into: dest)) != nil { n += 1 } }
            app.show(n > 0 ? "Saved \(n) item\(n == 1 ? "" : "s") to Downloads" : "Download failed",
                     symbol: n > 0 ? "arrow.down.circle.fill" : "xmark.octagon.fill", style: n > 0 ? .success : .error)
        }
    }

    private func pickUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Upload"
        panel.message = "Choose files to copy to \(path) on your phone"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    private func upload(_ urls: [URL]) {
        let folder = path
        Task { report(await media.uploadFiles(urls, toFolder: folder)) }
    }

    private func uploadProviders(_ providers: [NSItemProvider]) {
        let folder = path
        Task { report(await media.uploadProviders(providers, toFolder: folder)) }
    }

    private func pasteFromMac() {
        let folder = path
        Task {
            let r = await media.uploadPasteboard(toFolder: folder)
            if r.total == 0 { app.show("Clipboard has no files or images", symbol: "doc.on.clipboard", style: .info) } else { report(r) }
        }
    }

    private func report(_ r: (ok: Int, total: Int)) {
        guard r.total > 0 else { return }
        app.show("Copied \(r.ok) of \(r.total) to phone", symbol: "arrow.up.circle.fill", style: r.ok == r.total ? .success : .warning)
        Task { await load() }
    }

    private func copySelection() { copy(visible.filter { selection.contains($0.id) }) }

    private func copy(_ list: [FileEntry]) {
        let files = list.map(PhoneFileRef.init)
        guard !files.isEmpty else { return }
        app.show("Copying \(files.count) item\(files.count == 1 ? "" : "s")…", symbol: "doc.on.doc", style: .info)
        Task {
            let n = await media.copyToPasteboard(files)
            app.show(n > 0 ? "Copied \(n) item\(n == 1 ? "" : "s") — paste anywhere on your Mac" : "Copy failed",
                     symbol: "doc.on.doc.fill", style: n > 0 ? .success : .error)
        }
    }

    private func op(_ kind: FileOpType, _ src: String, _ dst: String = "") {
        Task {
            do { try await media.fileOp(kind, src, dst); await load() }
            catch { app.show(error.localizedDescription, symbol: "xmark.octagon.fill", style: .error) }
        }
    }

    // MARK: Helpers

    private func parent(of p: String) -> String {
        let parent = (p as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : (parent.hasSuffix("/") ? parent : parent + "/")
    }

    private func join(_ dir: String, _ name: String) -> String { (dir.hasSuffix("/") ? dir : dir + "/") + name }

    private func symbol(for e: FileEntry) -> String {
        if e.isDirectory {
            switch e.name {
            case "DCIM", "Pictures": return "photo.stack.fill"
            case "Download": return "arrow.down.circle.fill"
            case "Documents": return "doc.on.doc.fill"
            case "Music", "Recordings": return "music.note.list"
            case "Movies": return "film.stack.fill"
            default: return "folder.fill"
            }
        }
        let m = e.mimeType
        if m.hasPrefix("image/") { return "photo.fill" }
        if m.hasPrefix("video/") { return "film.fill" }
        if m.hasPrefix("audio/") { return "waveform" }
        if m == "application/pdf" { return "doc.richtext.fill" }
        if m.contains("zip") || m.contains("compressed") { return "doc.zipper" }
        if m.contains("android.package") { return "shippingbox.fill" }
        if m.hasPrefix("text/") { return "doc.plaintext.fill" }
        return "doc.fill"
    }

    private func tint(for e: FileEntry) -> Color {
        if e.isDirectory { return .accentColor }
        let m = e.mimeType
        if m.hasPrefix("image/") { return .pink }
        if m.hasPrefix("video/") { return .purple }
        if m.hasPrefix("audio/") { return .orange }
        if m == "application/pdf" { return .red }
        if m.contains("android.package") { return .green }
        return .secondary
    }

    private func kind(_ e: FileEntry) -> String {
        if e.isDirectory { return "Folder" }
        return UTType(mimeType: e.mimeType)?.localizedDescription?.capitalized ?? e.mimeType
    }
}


/// One file or folder in the thumbnail view: a picture or video shows a thumbnail from the phone, everything else its icon.
private struct FileTile: View {
    let entry: FileEntry
    let selected: Bool
    var showFolder: String?
    let symbol: String
    let tint: Color
    let media: MediaClient
    @State private var thumb: NSImage?

    private var hasThumb: Bool { !entry.isDirectory && (entry.mimeType.hasPrefix("image/") || entry.mimeType.hasPrefix("video/")) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol).font(.system(size: 40, weight: .regular)).foregroundStyle(tint)
                }
                if hasThumb && entry.mimeType.hasPrefix("video/") {
                    Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.45), in: Circle())
                }
                if entry.isDirectory && entry.childCount > 0 {
                    Text("\(entry.childCount)").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6)
                }
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            VStack(spacing: 1) {
                Text(entry.name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(selected ? Color.accentColor.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                if let showFolder { Text(showFolder).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                else if !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: entry.id) {
            guard hasThumb else { return }
            thumb = await media.thumbnail(path: entry.path, modifiedMs: entry.modifiedAtMs, mime: entry.mimeType)
        }
    }
}
