import AppKit

/// Containers macOS can't play natively (Matroska, WebM, AVI…). AVPlayer and Quick Look show nothing for them,
/// so they are saved to Downloads and handed to whatever app the Mac has for them (VLC, IINA…).
enum ExternalVideo {
    static let extensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "ogv", "divx", "m2ts", "vob", "rmvb"]
    static let mimeTypes: Set<String> = ["video/x-matroska", "video/webm", "video/x-msvideo", "video/x-flv", "video/x-ms-wmv", "video/mpeg"]

    static func needsExternalPlayer(name: String, mime: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased()) || mimeTypes.contains(mime.lowercased())
    }
}

extension AppState {
    /// Downloads a video the Mac can't play itself into Downloads and opens it with the default app.
    func openWithDefaultPlayer(path: String, mediaId: Int64? = nil, name: String, size: Int64) {
        let media = self.media
        show("Fetching “\(name)” — it will open in your video player…", symbol: "arrow.down.circle.fill", style: .info)
        Task {
            do {
                let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let url = try await media.download(path: path, mediaId: mediaId, name: name, size: size, into: dest)
                if NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) {
                    show("Opened \(url.lastPathComponent) (saved in Downloads)", symbol: "play.rectangle.fill", style: .success)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    show("No app on this Mac can play .\(url.pathExtension). Install VLC or IINA; the file is in Downloads.",
                         symbol: "play.slash.fill", style: .warning)
                }
            } catch {
                show(error.localizedDescription, symbol: "xmark.octagon.fill", style: .error)
            }
        }
    }
}
