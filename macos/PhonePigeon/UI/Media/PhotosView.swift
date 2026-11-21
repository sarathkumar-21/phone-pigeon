import AVKit
import SwiftUI

/// Apple Photos–style grid of the phone's MediaStore (spec v2 §6.1, §11.1.3).
struct PhotosView: View {
    @Environment(AppState.self) private var app
    @State private var items: [MediaItem] = []
    @State private var buckets: [String] = []
    @State private var bucket = ""
    @State private var filter: MediaTypeFilter = .all
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var selection: Set<Int64> = []
    @State private var viewing: MediaItem?
    @State private var tile: CGFloat = 150
    @State private var dropTargeted = false

    private var media: MediaClient { app.media }

    var body: some View {
        HStack(spacing: 0) {
            albums.frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                content
            }
        }
        .navigationTitle("Photos & Videos")
        .task(id: "\(bucket)|\(filter.rawValue)|\(media.isAvailable)") { await reload() }
        .sheet(item: $viewing) { MediaViewer(item: $0, items: items) }
    }

    // MARK: Albums

    private var albums: some View {
        List(selection: Binding(get: { bucket }, set: { bucket = $0 ?? "" })) {
            Section("Library") {
                Label("All Photos", systemImage: "photo.on.rectangle.angled").tag("")
            }
            if !buckets.isEmpty {
                Section("Albums") {
                    ForEach(buckets, id: \.self) { b in
                        Label(b, systemImage: icon(for: b)).tag(b)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func icon(for bucket: String) -> String {
        switch bucket.lowercased() {
        case let b where b.contains("camera"): "camera.fill"
        case let b where b.contains("screenshot"): "camera.viewfinder"
        case let b where b.contains("whatsapp"): "message.fill"
        case let b where b.contains("video") || b.contains("movie"): "film.stack"
        case let b where b.contains("download"): "arrow.down.circle.fill"
        default: "rectangle.stack.fill"
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bucket.isEmpty ? "All Photos" : bucket).font(.system(size: 20, weight: .bold, design: .rounded))
                Text("\(items.count)\(hasMore ? "+" : "") items").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $filter) {
                Text("All").tag(MediaTypeFilter.all)
                Text("Photos").tag(MediaTypeFilter.images)
                Text("Videos").tag(MediaTypeFilter.videos)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            Slider(value: $tile, in: 90...260).frame(width: 110).help("Thumbnail size")
            if !selection.isEmpty {
                Button { downloadSelection() } label: {
                    Label("Download \(selection.count)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .transition(.scale.combined(with: .opacity))
            }
            TransfersButton()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .animation(.snappy, value: selection.isEmpty)
    }

    // MARK: Grid

    @ViewBuilder private var content: some View {
        if !media.isAvailable {
            EmptyStateView(symbol: "wifi.exclamationmark", title: "Phone media unavailable",
                           message: "Photos and files stream directly from your phone over Wi-Fi. Connect both devices to the same network.")
        } else if let error, items.isEmpty {
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't load photos", message: error,
                           action: ("Try Again", { Task { await reload() } }))
        } else if items.isEmpty && loading {
            ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            EmptyStateView(symbol: "photo.on.rectangle", title: "No photos", message: "Nothing in this album yet.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(months, id: \.0) { title, group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: tile, maximum: tile * 1.5), spacing: 4)], spacing: 4) {
                                ForEach(group) { item in
                                    MediaTile(item: item, selected: selection.contains(item.id))
                                        .onDrag { media.dragProvider(for: PhoneFileRef(item)) }
                                        .onTapGesture(count: 2) { open(item) }
                                        .onTapGesture { toggle(item) }
                                        .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                                        .contextMenu {
                                            Button("Open", systemImage: "eye") { open(item) }
                                            Button("Copy", systemImage: "doc.on.doc") { copy(selection.contains(item.id) ? selected : [item]) }
                                            Button("Download", systemImage: "arrow.down.circle") { download([item]) }
                                        }
                                }
                            }
                        } header: {
                            Text(title).font(.headline)
                                .padding(.horizontal, 6).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.bar)
                        }
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
            .animation(.smooth, value: tile)
            .onCopyCommand { copy(selected); return [] }
            .onPasteCommand(of: [.fileURL, .image]) { importProviders($0) }
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { importProviders($0); return true }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .background(Color.accentColor.opacity(0.06))
                        .overlay(Label("Drop to add to the phone's Pictures/PhonePigeon album", systemImage: "photo.badge.plus")
                            .font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor))
                        .padding(8).allowsHitTesting(false)
                }
            }
        }
    }

    private var selected: [MediaItem] { items.filter { selection.contains($0.id) } }

    private func copy(_ list: [MediaItem]) {
        guard !list.isEmpty else { return }
        Task {
            let n = await media.copyToPasteboard(list.map(PhoneFileRef.init))
            app.show(n > 0 ? "Copied \(n) item\(n == 1 ? "" : "s") — paste anywhere on your Mac" : "Copy failed",
                     symbol: "doc.on.doc.fill", style: n > 0 ? .success : .error)
        }
    }

    /// Mac → phone: photos dropped or pasted here go to /Pictures/PhonePigeon (media-scanned on the phone).
    private func importProviders(_ providers: [NSItemProvider]) {
        Task {
            try? await media.fileOp(.mkdir, "/Pictures/PhonePigeon")
            let r = await media.uploadProviders(providers, toFolder: "/Pictures/PhonePigeon")
            if r.total > 0 {
                app.show("Added \(r.ok) of \(r.total) to the phone", symbol: "photo.badge.plus", style: r.ok == r.total ? .success : .warning)
                await reload()
            }
        }
    }

    private var months: [(String, [MediaItem])] {
        var out: [(String, [MediaItem])] = []
        let f = DateFormatter(); f.dateFormat = "LLLL yyyy"
        for item in items {
            let key = f.string(from: item.dateTaken)
            if out.last?.0 == key { out[out.count - 1].1.append(item) } else { out.append((key, [item])) }
        }
        return out
    }

    /// Videos open in a native player window (streamed with Range requests); photos in the sheet viewer.
    private func open(_ item: MediaItem) {
        if item.isVideo {
            if ExternalVideo.needsExternalPlayer(name: item.displayName, mime: item.mimeType) {
                app.openWithDefaultPlayer(path: item.path, mediaId: item.mediaStoreId, name: item.displayName, size: item.sizeBytes)
            } else if let pi = media.playerItem(for: item) {
                VideoWindowController.show(title: item.displayName,
                                           subtitle: "\(item.bucketName) · \(Double(item.durationMs / 1000).callDuration)", item: pi)
            } else {
                app.show("Couldn't open video", symbol: "exclamationmark.triangle.fill", style: .error)
            }
        } else {
            viewing = item
        }
    }

    private func toggle(_ item: MediaItem) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) || !selection.isEmpty {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            open(item)
        }
    }

    // MARK: Loading

    private func reload() async {
        guard media.isAvailable else { return }
        items = []; hasMore = true; selection = []; error = nil
        await loadMore()
    }

    private func loadMore() async {
        guard hasMore, !loading, media.isAvailable else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await media.listGallery(filter: filter, bucket: bucket, offset: items.count)
            items += r.items
            hasMore = r.hasMore
            if !r.availableBuckets.isEmpty { buckets = r.availableBuckets }
        } catch {
            self.error = error.localizedDescription
            hasMore = false
        }
    }

    private func downloadSelection() {
        download(items.filter { selection.contains($0.id) })
        selection = []
    }

    private func download(_ list: [MediaItem]) {
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        Task {
            var ok = 0
            for item in list {
                if (try? await media.download(path: item.path, mediaId: item.mediaStoreId, name: item.displayName,
                                              size: item.sizeBytes, into: dest)) != nil { ok += 1 }
            }
            app.show("Downloaded \(ok) of \(list.count) to Downloads", symbol: "arrow.down.circle.fill", style: ok == list.count ? .success : .warning)
        }
    }
}

struct MediaTile: View {
    @Environment(AppState.self) private var app
    let item: MediaItem
    let selected: Bool
    @State private var image: NSImage?
    @State private var hover = false
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Color.primary.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    // scaledToFill overflows the tile; `clipped` only hides the overflow visually, so without this the
                    // overflowing part of a lower row's image kept catching clicks meant for the row above.
                    Image(nsImage: image).resizable().scaledToFill().transition(.opacity).allowsHitTesting(false)
                } else if failed {
                    // Never spin forever: say it failed and let a click try again.
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.title3)
                        Text("Couldn't load").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { failed = false; attempt += 1 }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Label(Double(item.durationMs / 1000).callDuration, systemImage: "play.fill")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor).padding(5)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.snappy(duration: 0.15), value: hover)
            .onHover { hover = $0 }
            .task(id: "\(item.id)-\(attempt)") {
                let img = await app.media.thumbnail(item)
                withAnimation(.easeOut(duration: 0.2)) { image = img; failed = img == nil }
            }
            .help("\(item.displayName) · \(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))")
    }
}

/// Full-size viewer: images are fetched in full; videos stream with byte-range requests.
struct MediaViewer: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var item: MediaItem
    let items: [MediaItem]
    @State private var image: NSImage?
    @State private var isFullSize = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(.headline)
                    Text("\(item.bucketName) · \(item.dateTaken.formatted(date: .abbreviated, time: .shortened)) · \(item.width)×\(item.height) · \(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                Button { step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                Button { save() } label: { Label("Download", systemImage: "arrow.down.circle") }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Grid thumbnails are small; say so while the real photo is on its way, or if it couldn't be fetched.
                if !isFullSize {
                    HStack(spacing: 6) {
                        if failed { Image(systemName: "exclamationmark.triangle.fill") } else { ProgressView().controlSize(.small) }
                        Text(failed ? "Couldn't load the full photo" : "Loading full size…").font(.caption)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(12)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .task(id: item.id) { await load() }
    }

    private func step(_ d: Int) {
        guard let i = items.firstIndex(of: item) else { return }
        let n = i + d
        if items.indices.contains(n) { item = items[n] }
    }

    private func load() async {
        isFullSize = false
        failed = false
        image = app.media.cachedThumbnail(item) // instant, blurry placeholder
        let current = item.id
        if let full = await app.media.fullImage(item), current == item.id {
            image = full
            isFullSize = true
        } else if current == item.id {
            failed = true
            if image == nil { image = await app.media.thumbnail(item) }
        }
    }

    private func save() {
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let it = item
        Task {
            do {
                let url = try await app.media.download(path: it.path, mediaId: it.mediaStoreId, name: it.displayName, size: it.sizeBytes, into: dest)
                app.show("Saved \(url.lastPathComponent) to Downloads", symbol: "checkmark.circle.fill", style: .success)
            } catch {
                app.show(error.localizedDescription, symbol: "xmark.octagon.fill", style: .error)
            }
        }
    }
}

/// Transfer queue popover (spec §6.3).
struct TransfersButton: View {
    @Environment(AppState.self) private var app
    @State private var open = false

    var body: some View {
        let running = app.media.transfers.filter { $0.state == .running }.count
        Button { open.toggle() } label: {
            Image(systemName: running > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                .font(.title3)
                .symbolEffect(.pulse, isActive: running > 0)
                .overlay(alignment: .topTrailing) {
                    if running > 0 {
                        Text("\(running)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(3).background(Color.accentColor, in: Circle()).offset(x: 6, y: -6)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Transfers")
        .popover(isPresented: $open, arrowEdge: .bottom) { TransfersList().frame(width: 360) }
    }
}

struct TransfersList: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { app.media.transfers.removeAll { $0.state != .running } }
                    .buttonStyle(.link).disabled(app.media.transfers.isEmpty)
            }
            .padding(14)
            Divider()
            if app.media.transfers.isEmpty {
                Text("No transfers yet").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(app.media.transfers) { t in
                            TimelineView(.periodic(from: .now, by: 0.5)) { _ in row(t) }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
    }

    private func row(_ t: Transfer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: t.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2).foregroundStyle(t.direction == .upload ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                ProgressView(value: t.fraction).progressViewStyle(.linear)
                Group {
                    switch t.state {
                    case .running: Text("\(ByteCountFormatter.string(fromByteCount: t.done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: t.total, countStyle: .file)) · \(t.speed)")
                    case .done: Text(t.sha256.map { "Verified · SHA-256 \($0.prefix(12))…" } ?? "Done")
                    case .failed(let m): Text(m).foregroundStyle(.red)
                    case .cancelled: Text("Cancelled")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if t.state == .running {
                Button { t.cancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            } else if t.state == .done {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
