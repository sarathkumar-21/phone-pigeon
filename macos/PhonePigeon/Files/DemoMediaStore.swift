import AppKit
import AVFoundation
import Foundation

/// Synthetic photo library + file system for the demo phone. Responses to
/// list/file-op requests still travel through the encrypted DemoPhone channel;
/// only the bytes (thumbnails, downloads) are generated in-process.
final class DemoMediaStore {
    static let shared = DemoMediaStore()

    private(set) var items: [MediaItem] = []
    private var tree: [String: [FileEntry]] = [:]
    private var videoCache: [Int64: URL] = [:]

    private init() { seed() }

    // MARK: Gallery

    func gallery(_ req: ListMediaGalleryRequest) -> ListMediaGalleryResponse {
        let filtered = items.filter { i in
            (req.bucketName.isEmpty || i.bucketName == req.bucketName) &&
            (req.filter == .all || (req.filter == .videos) == i.isVideo)
        }
        let page = Array(filtered.dropFirst(req.offset).prefix(req.limit))
        return ListMediaGalleryResponse(requestId: req.requestId, items: page,
                                        availableBuckets: Array(Set(items.map(\.bucketName))).sorted(),
                                        hasMore: req.offset + page.count < filtered.count)
    }

    func thumbnail(for item: MediaItem) -> NSImage { render(item, size: CGSize(width: 320, height: 320)) }

    /// A picture for a file in the demo file tree (the demo tree has no real pictures, so one is drawn from the path).
    func thumbnail(forFile path: String) -> NSImage {
        let id = Int64(abs(path.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }) % 997)
        let item = MediaItem(mediaStoreId: id, path: path, displayName: (path as NSString).lastPathComponent, bucketName: "Camera",
                             mimeType: "image/jpeg", sizeBytes: 0, width: 640, height: 640, durationMs: 0, dateTakenMs: 0)
        return render(item, size: CGSize(width: 256, height: 256))
    }

    func data(for path: String, mediaId: Int64?) -> Data {
        if let mediaId, let item = items.first(where: { $0.mediaStoreId == mediaId }) {
            if item.isVideo, let url = videoURL(for: item), let d = try? Data(contentsOf: url) { return d }
            return png(render(item, size: CGSize(width: item.width / 2, height: item.height / 2)))
        }
        if let item = items.first(where: { $0.path == path }) { return data(for: path, mediaId: item.mediaStoreId) }
        let name = (path as NSString).lastPathComponent
        return Data("PhonePigeon demo file: \(name)\n\nThis file lives on the virtual demo phone.\n".utf8)
    }

    /// Generates (once) a short H.264 clip so AVPlayer has something real to play.
    func videoURL(for item: MediaItem) -> URL? {
        guard item.isVideo else { return nil }
        if let u = videoCache[item.mediaStoreId] { return u }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phonepigeon-demo-\(item.mediaStoreId).mp4")
        if !FileManager.default.fileExists(atPath: url.path) { Self.writeVideo(to: url, hue: Double(item.mediaStoreId % 12) / 12) }
        videoCache[item.mediaStoreId] = url
        return url
    }

    // MARK: File explorer

    func list(_ req: ListDirectoryRequest) -> ListDirectoryResponse {
        let p = normalize(req.path)
        guard let entries = tree[p] else {
            return ListDirectoryResponse(requestId: req.requestId, path: p, entries: [], errorMessage: "No such folder")
        }
        let visible = entries.filter { req.includeHidden || !$0.name.hasPrefix(".") }
        return ListDirectoryResponse(requestId: req.requestId, path: p, entries: visible, errorMessage: "")
    }

    /// Name search over the demo tree.
    func search(_ query: String, includeHidden: Bool) -> SearchFilesResponse {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return SearchFilesResponse(requestId: "", entries: []) }
        let hits = tree.values.flatMap { $0 }.filter { $0.name.localizedCaseInsensitiveContains(q) && (includeHidden || !$0.name.hasPrefix(".")) }
        return SearchFilesResponse(requestId: "", entries: Array(hits.prefix(500)))
    }

    func apply(_ req: FileOperationRequest) -> FileOperationResponse {
        let src = normalize(req.sourcePath)
        let parent = (src as NSString).deletingLastPathComponent
        switch req.op {
        case .mkdir:
            let name = (src as NSString).lastPathComponent
            tree[parent, default: []].append(entry(parent, name, dir: true, size: 0))
            tree[src] = []
        case .rename:
            let newName = (normalize(req.targetPath) as NSString).lastPathComponent
            if let i = tree[parent]?.firstIndex(where: { $0.path == src }) {
                tree[parent]![i].name = newName
                tree[parent]![i].path = (parent == "/" ? "" : parent) + "/" + newName
            }
        case .delete:
            tree[parent]?.removeAll { $0.path == src }
            tree[src] = nil
        case .unspecified:
            return FileOperationResponse(requestId: req.requestId, success: false, errorMessage: "Unknown operation")
        }
        return FileOperationResponse(requestId: req.requestId, success: true, errorMessage: "")
    }

    func addUpload(name: String, size: Int64, folder: String) {
        let f = normalize(folder)
        tree[f, default: []].removeAll { $0.name == name }
        tree[f, default: []].append(entry(f, name, dir: false, size: size))
    }

    // MARK: Seeding

    private func normalize(_ p: String) -> String {
        var s = p.isEmpty ? "/" : p
        if !s.hasPrefix("/") { s = "/" + s }
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func entry(_ parent: String, _ name: String, dir: Bool, size: Int64, daysAgo: Double = 0) -> FileEntry {
        let path = (parent == "/" ? "" : parent) + "/" + name
        let ext = (name as NSString).pathExtension.lowercased()
        let mime = dir ? "inode/directory" : (["jpg": "image/jpeg", "png": "image/png", "mp4": "video/mp4", "pdf": "application/pdf",
                                                 "zip": "application/zip", "txt": "text/plain", "apk": "application/vnd.android.package-archive",
                                                 "mp3": "audio/mpeg", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"][ext] ?? "application/octet-stream")
        return FileEntry(path: path, name: name, isDirectory: dir, sizeBytes: size, mimeType: mime,
                         modifiedAtMs: Int64((Date().timeIntervalSince1970 - daysAgo * 86400) * 1000),
                         childCount: dir ? 0 : 0)
    }

    private func seed() {
        let now = Date().timeIntervalSince1970
        let buckets: [(String, Int, Bool)] = [("Camera", 34, false), ("Screenshots", 10, false), ("WhatsApp Images", 14, false), ("Videos", 6, true)]
        var id: Int64 = 1000
        for (bucket, count, videos) in buckets {
            for i in 0..<count {
                id += 1
                let isVideo = videos || (bucket == "Camera" && i % 9 == 4)
                let landscape = i % 3 != 0
                let name = isVideo ? String(format: "VID_2026%04d.mp4", Int(id)) : String(format: "IMG_2026%04d.jpg", Int(id))
                let rel = bucket == "Camera" ? "/DCIM/Camera" : (bucket == "Screenshots" ? "/Pictures/Screenshots" : (bucket == "Videos" ? "/Movies" : "/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images"))
                items.append(MediaItem(mediaStoreId: id, path: rel + "/" + name, displayName: name, bucketName: bucket,
                                       mimeType: isVideo ? "video/mp4" : "image/jpeg",
                                       sizeBytes: isVideo ? Int64.random(in: 8_000_000...180_000_000) : Int64.random(in: 900_000...6_000_000),
                                       width: landscape ? 4032 : 3024, height: landscape ? 3024 : 4032,
                                       durationMs: isVideo ? Int64.random(in: 4_000...95_000) : 0,
                                       dateTakenMs: Int64((now - Double(id - 1000) * 3600 * 7.3) * 1000)))
            }
        }
        items.sort { $0.dateTakenMs > $1.dateTakenMs }

        tree["/"] = ["Alarms", "Android", "DCIM", "Documents", "Download", "Movies", "Music", "Pictures", "Recordings"]
            .map { entry("/", $0, dir: true, size: 0, daysAgo: 3) } + [entry("/", ".nomedia", dir: false, size: 0, daysAgo: 90)]
        tree["/DCIM"] = [entry("/DCIM", "Camera", dir: true, size: 0, daysAgo: 0.2)]
        tree["/DCIM/Camera"] = items.filter { $0.bucketName == "Camera" }.map {
            var e = entry("/DCIM/Camera", $0.displayName, dir: false, size: $0.sizeBytes); e.modifiedAtMs = $0.dateTakenMs; return e
        }
        tree["/Download"] = [
            entry("/Download", "Boarding-Pass-BLR-DEL.pdf", dir: false, size: 284_211, daysAgo: 1),
            entry("/Download", "Invoice_Nov2026.pdf", dir: false, size: 118_904, daysAgo: 2),
            entry("/Download", "project-assets.zip", dir: false, size: 48_220_113, daysAgo: 6),
            entry("/Download", "notes.txt", dir: false, size: 2_311, daysAgo: 9),
            entry("/Download", "phonepigeon-1.0.0.apk", dir: false, size: 26_202_071, daysAgo: 0.1),
        ]
        tree["/Documents"] = [
            entry("/Documents", "Resume_2026.docx", dir: false, size: 92_004, daysAgo: 30),
            entry("/Documents", "Lease Agreement.pdf", dir: false, size: 1_884_330, daysAgo: 120),
            entry("/Documents", "Receipts", dir: true, size: 0, daysAgo: 12),
        ]
        tree["/Documents/Receipts"] = [entry("/Documents/Receipts", "coffee.jpg", dir: false, size: 401_224, daysAgo: 12)]
        tree["/Music"] = [entry("/Music", "Voice memo — standup.mp3", dir: false, size: 3_402_118, daysAgo: 4)]
        tree["/Movies"] = items.filter { $0.bucketName == "Videos" }.map { entry("/Movies", $0.displayName, dir: false, size: $0.sizeBytes) }
        tree["/Pictures"] = [entry("/Pictures", "Screenshots", dir: true, size: 0, daysAgo: 1)]
        tree["/Pictures/Screenshots"] = items.filter { $0.bucketName == "Screenshots" }.map { entry("/Pictures/Screenshots", $0.displayName, dir: false, size: $0.sizeBytes) }
        for key in ["/Alarms", "/Android", "/Recordings"] { tree[key] = [] }
        // child counts
        for (parent, entries) in tree {
            tree[parent] = entries.map { e in var e = e; if e.isDirectory { e.childCount = tree[e.path]?.count ?? 0 }; return e }
        }
    }

    // MARK: Rendering

    private func render(_ item: MediaItem, size: CGSize) -> NSImage {
        let seed = Double(item.mediaStoreId % 97) / 97
        let scenes: [(NSColor, NSColor, String)] = [
            (.systemOrange, .systemPink, "sun.horizon.fill"), (.systemTeal, .systemBlue, "water.waves"),
            (.systemGreen, .systemTeal, "leaf.fill"), (.systemPurple, .systemIndigo, "moon.stars.fill"),
            (.systemYellow, .systemOrange, "fork.knife"), (.systemBlue, .systemPurple, "building.2.fill"),
            (.systemMint, .systemGreen, "mountain.2.fill"), (.systemRed, .systemOrange, "flame.fill"),
        ]
        let scene = item.bucketName == "Screenshots" ? (NSColor.windowBackgroundColor, NSColor.controlAccentColor, "rectangle.on.rectangle")
            : scenes[Int(item.mediaStoreId) % scenes.count]
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSGradient(colors: [scene.0.blended(withFraction: seed * 0.3, of: .black) ?? scene.0, scene.1])?.draw(in: rect, angle: 35 + seed * 90)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.55, y: size.height * 0.5, width: size.width * 0.7, height: size.width * 0.7)).fill()
        if let symbol = NSImage(systemSymbolName: scene.2, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size.width * 0.28, weight: .semibold)) {
            let tinted = NSImage(size: symbol.size, flipped: false) { r in
                symbol.draw(in: r); NSColor.white.withAlphaComponent(0.9).set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
        }
        img.unlockFocus()
        return img
    }

    private func png(_ image: NSImage) -> Data {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func writeVideo(to url: URL, hue: Double) {
        let w = 640, h = 360, fps: Int32 = 24, frames = 24 * 4
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32ARGB, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                let t = Double(f) / Double(frames)
                let c1 = NSColor(hue: (hue + t * 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.9, alpha: 1).cgColor
                let c2 = NSColor(hue: (hue + 0.5 + t * 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.6, alpha: 1).cgColor
                let grad = CGGradient(colorsSpace: nil, colors: [c1, c2] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                let r = 40.0 + 20 * sin(t * .pi * 4)
                ctx.fillEllipse(in: CGRect(x: Double(w) * t - r, y: Double(h) / 2 - r, width: r * 2, height: r * 2))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }
}

