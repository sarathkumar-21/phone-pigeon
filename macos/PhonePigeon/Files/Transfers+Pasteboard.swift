import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A phone file reference that can be dragged, copied or downloaded.
struct PhoneFileRef: Sendable {
    var path: String
    var mediaId: Int64?
    var name: String
    var size: Int64
    var mimeType: String
    var isDirectory = false

    init(_ e: FileEntry) { path = e.path; mediaId = nil; name = e.name; size = e.sizeBytes; mimeType = e.mimeType; isDirectory = e.isDirectory }
    init(_ m: MediaItem) { path = m.path; mediaId = m.mediaStoreId; name = m.displayName; size = m.sizeBytes; mimeType = m.mimeType }
}

/// Drag-and-drop and copy/paste between the phone and the Mac.
///
/// Phone → Mac: drag (file promise, fetched on drop) or ⌘C (files land on the
/// pasteboard as real file URLs, so ⌘V in Finder/Mail/Slack pastes them).
/// Mac → Phone: drop or ⌘V of Finder files, images or screenshots into a phone folder.
extension MediaClient {
    private var stagingDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhonePigeonClipboard/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Phone → Mac

    /// NSItemProvider whose bytes are downloaded only when the drop actually happens.
    func dragProvider(for ref: PhoneFileRef) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = ref.name
        let type = ref.isDirectory ? UTType.folder : (UTType(mimeType: ref.mimeType) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] done in
            Task { @MainActor in
                guard let self else { done(nil, false, MediaError.unavailable); return }
                do { done(try await self.downloadTree(ref, into: self.stagingDir), false, nil) }
                catch { done(nil, false, error) }
            }
            return nil
        }
        return provider
    }

    /// Downloads a file, or a whole folder (recursively, keeping its structure) into `dir`. Returns the local file or folder.
    /// A file that fails inside a folder is skipped so the rest still arrives.
    @discardableResult
    func downloadTree(_ r: PhoneFileRef, into dir: URL, depth: Int = 0) async throws -> URL {
        guard r.isDirectory else { return try await download(path: r.path, mediaId: r.mediaId, name: r.name, size: r.size, into: dir) }
        guard depth < 24 else { throw MediaError.server("Folder is nested too deeply.") }
        let local = uniqueURL(dir.appendingPathComponent(Self.safeFileName(r.name), isDirectory: true))
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let listing = try await listDirectory(r.path, includeHidden: true)
        for e in listing.entries { _ = try? await downloadTree(PhoneFileRef(e), into: local, depth: depth + 1) }
        return local
    }

    /// ⌘C on phone files: fetch them, then put real file URLs on the general pasteboard.
    func copyToPasteboard(_ refs: [PhoneFileRef]) async -> Int {
        let dir = stagingDir
        var urls: [URL] = []
        for r in refs {
            if let u = try? await downloadTree(r, into: dir) { urls.append(u) }
        }
        guard !urls.isEmpty else { return 0 }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        // A single image is also offered as image data, so it pastes into Messages/Slack/Notes inline.
        if urls.count == 1, let img = NSImage(contentsOf: urls[0]), let tiff = img.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        return urls.count
    }

    // MARK: Mac → Phone

    /// Uploads whatever the pasteboard / drop holds: file URLs, or raw image data (e.g. a screenshot copied with ⌃⇧⌘4).
    func uploadProviders(_ providers: [NSItemProvider], toFolder folder: String) async -> (ok: Int, total: Int) {
        var files: [URL] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await Self.loadFileURL(p) {
                files.append(url)
            } else if p.canLoadObject(ofClass: NSImage.self), let url = await Self.loadImageAsPNG(p, into: stagingDir) {
                files.append(url)
            }
        }
        return await uploadFiles(files, toFolder: folder)
    }

    func uploadFiles(_ urls: [URL], toFolder folder: String) async -> (ok: Int, total: Int) {
        var ok = 0, total = 0
        for u in urls {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // Folders: create the folder on the phone, then copy its files.
                let remote = (folder.hasSuffix("/") ? folder : folder + "/") + u.lastPathComponent
                try? await fileOp(.mkdir, remote)
                let children = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                let r = await uploadFiles(children, toFolder: remote)
                ok += r.ok; total += r.total
            } else {
                total += 1
                if (try? await upload(u, toFolder: folder)) != nil { ok += 1 }
            }
        }
        return (ok, total)
    }

    static func pasteboardHasUploadable() -> Bool {
        let pb = NSPasteboard.general
        return pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) || pb.canReadObject(forClasses: [NSImage.self])
    }

    /// ⌘V via the menu command: read the general pasteboard directly.
    func uploadPasteboard(toFolder folder: String) async -> (ok: Int, total: Int) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return await uploadFiles(urls, toFolder: folder)
        }
        if let image = pb.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let url = Self.writePNG(image, into: stagingDir) {
            return await uploadFiles([url], toFolder: folder)
        }
        return (0, 0)
    }

    private static func loadFileURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    private static func loadImageAsPNG(_ p: NSItemProvider, into dir: URL) async -> URL? {
        let image: NSImage? = await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in cont.resume(returning: obj as? NSImage) }
        }
        return image.flatMap { writePNG($0, into: dir) }
    }

    private static func writePNG(_ image: NSImage, into dir: URL) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Pasted Image \(f.string(from: .now)).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }
}
