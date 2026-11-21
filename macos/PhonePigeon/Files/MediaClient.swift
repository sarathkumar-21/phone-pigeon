import AppKit
import AVFoundation
import CryptoKit
import Foundation
import CoreServices
import ImageIO
import UniformTypeIdentifiers

/// Plane 2 client (spec v2 §6): metadata over the E2EE control channel, bytes over
/// the phone's embedded HTTPS server (cert pinned to `server_cert_sha256`, request
/// authorised with the HKDF-derived bearer token). Never routes media through the relay.
@Observable
final class MediaClient: NSObject {
    enum MediaError: LocalizedError {
        case unavailable, timeout, server(String), http(Int)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Phone media server isn't reachable. Make sure both devices are on the same Wi-Fi."
            case .timeout: "The phone didn't answer in time."
            case .server(let m): m
            case .http(let c): "Phone returned HTTP \(c)."
            }
        }
    }

    /// Sends a control-plane request (wired to AppState.transmit).
    var send: ((PayloadBody) -> Void)?
    private(set) var endpoint: MediaServerEndpoint?
    /// Demo phone: bytes come from an in-process generator instead of HTTPS.
    var demo: DemoMediaStore?

    var isAvailable: Bool { endpoint != nil || demo != nil }
    var storage: DeviceStatusEvent?

    @ObservationIgnored private var pending: [String: (Any) -> Void] = [:]
    @ObservationIgnored private let thumbCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6          // parallel thumbnail fetches
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg, delegate: PinningDelegate(owner: self), delegateQueue: nil)
    }()

    // Transfer queue (spec §6.3)
    var transfers: [Transfer] = []

    // MARK: Endpoint

    func updateEndpoint(_ ep: MediaServerEndpoint, keys: SessionKeys?) {
        var ep = ep
        // Emulator testing only (adb forward → 127.0.0.1). An environment variable, not a saved preference: a stale
        // preference silently redirected every photo and file request to the wrong machine.
        if let host = ProcessInfo.processInfo.environment["PHONEPIGEON_MEDIA_HOST_OVERRIDE"], !host.isEmpty { ep.lanIp = host }
        endpoint = ep
        thumbCache.removeAllObjects()
    }

    func reset() {
        endpoint = nil
        demo = nil
        pending.values.forEach { $0(MediaError.unavailable) }
        pending.removeAll()
        thumbCache.removeAllObjects()
    }

    fileprivate var pinnedHash: Data? { endpoint?.serverCertSha256 }

    // MARK: Control-plane requests

    private func request<T: Sendable>(_ build: (String) -> PayloadBody, as: T.Type) async throws -> T {
        guard isAvailable || send != nil else { throw MediaError.unavailable }
        let id = UUID().uuidString.lowercased()
        return try await withCheckedThrowingContinuation { cont in
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled, let cb = self?.pending.removeValue(forKey: id) { cb(MediaError.timeout) }
            }
            pending[id] = { value in
                timeout.cancel() // don't leave a 20 s sleeper behind for every finished request
                if let v = value as? T { cont.resume(returning: v) }
                else if let e = value as? Error { cont.resume(throwing: e) }
            }
            send?(build(id))
        }
    }

    func listDirectory(_ path: String, includeHidden: Bool = false) async throws -> ListDirectoryResponse {
        let r = try await request({ .listDirReq(ListDirectoryRequest(requestId: $0, path: path, includeHidden: includeHidden)) },
                                  as: ListDirectoryResponse.self)
        if !r.errorMessage.isEmpty { throw MediaError.server(r.errorMessage) }
        return r
    }

    /// Searches the whole phone by name (not just one folder).
    func searchFiles(_ query: String, includeHidden: Bool) async throws -> SearchFilesResponse {
        if let demo { return demo.search(query, includeHidden: includeHidden) }
        let r = try await request({ .searchReq(SearchFilesRequest(requestId: $0, query: query, includeHidden: includeHidden, limit: 500)) },
                                  as: SearchFilesResponse.self)
        if !r.errorMessage.isEmpty { throw MediaError.server(r.errorMessage) }
        return r
    }

    func listGallery(filter: MediaTypeFilter, bucket: String, offset: Int, limit: Int = 120) async throws -> ListMediaGalleryResponse {
        try await request({ .listGalleryReq(ListMediaGalleryRequest(requestId: $0, filter: filter, bucketName: bucket, limit: limit, offset: offset)) },
                          as: ListMediaGalleryResponse.self)
    }

    func fileOp(_ op: FileOpType, _ source: String, _ target: String = "") async throws {
        let r = try await request({ .fileOpReq(FileOperationRequest(requestId: $0, op: op, sourcePath: source, targetPath: target)) },
                                  as: FileOperationResponse.self)
        if !r.success { throw MediaError.server(r.errorMessage.isEmpty ? "Operation failed" : r.errorMessage) }
    }

    func resolve(_ r: ListDirectoryResponse) { pending.removeValue(forKey: r.requestId)?(r) }
    func resolve(_ r: SearchFilesResponse) { pending.removeValue(forKey: r.requestId)?(r) }
    func resolve(_ r: ListMediaGalleryResponse) { pending.removeValue(forKey: r.requestId)?(r) }
    func resolve(_ r: FileOperationResponse) { pending.removeValue(forKey: r.requestId)?(r) }

    // MARK: HTTPS data plane

    private func url(_ path: String, _ query: [URLQueryItem]) -> URL? {
        guard let ep = endpoint else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = ep.lanIp
        c.port = ep.httpsPort
        c.path = path
        c.queryItems = query
        return c.url
    }

    private func authorized(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(endpoint?.sessionBearerToken ?? "")", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Request and pinned certificate hash for the live screen stream (`GET /media/screen`).
    func screenStreamRequest() -> (request: URLRequest, pinnedHash: Data)? {
        guard let u = url("/media/screen", []), let hash = pinnedHash else { return nil }
        var r = authorized(u)
        r.timeoutInterval = 15 // connect/first byte; the stream itself is open-ended
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return (r, hash)
    }

    func fileURL(path: String? = nil, mediaId: Int64? = nil) -> URL? {
        if let mediaId { return url("/media/file", [URLQueryItem(name: "id", value: String(mediaId))]) }
        return url("/media/file", [URLQueryItem(name: "path", value: path ?? "/")])
    }

    func thumbnail(_ item: MediaItem, size: Int = 320) async -> NSImage? {
        let key = "\(item.mediaStoreId)-\(size)" as NSString
        if let img = thumbCache.object(forKey: key) { return img }
        var image: NSImage?
        if let demo { image = demo.thumbnail(for: item) }
        else if let u = url("/media/thumb/\(item.mediaStoreId)", [URLQueryItem(name: "w", value: "\(size)"), URLQueryItem(name: "h", value: "\(size)")]),
                let (data, resp) = try? await session.data(for: authorized(u)),
                (resp as? HTTPURLResponse)?.statusCode == 200 {
            image = NSImage(data: data)
        }
        if let image { thumbCache.setObject(image, forKey: key) }
        return image
    }

    /// The grid thumbnail if it is already cached (used as an instant placeholder in the viewer).
    func cachedThumbnail(_ item: MediaItem) -> NSImage? { thumbCache.object(forKey: "\(item.mediaStoreId)-320" as NSString) }

    @ObservationIgnored private let fullCache = NSCache<NSString, NSImage>()

    /// The real photo, not a thumbnail: fetches the original file and decodes it at up to 4096 px on the long side
    /// (a 50 MP original would otherwise cost hundreds of MB of memory).
    func fullImage(_ item: MediaItem) async -> NSImage? {
        let key = "\(item.mediaStoreId)" as NSString
        if let img = fullCache.object(forKey: key) { return img }
        var image: NSImage?
        if let demo { image = demo.thumbnail(for: item) }
        else if let u = fileURL(mediaId: item.mediaStoreId) {
            var request = authorized(u)
            request.timeoutInterval = 120
            if let (data, resp) = try? await session.data(for: request), (resp as? HTTPURLResponse)?.statusCode == 200 {
                image = await Task.detached(priority: .userInitiated) { Self.decode(data, maxPixels: 4096) }.value
            }
        }
        if let image { fullCache.setObject(image, forKey: key) }
        return image
    }

    nonisolated private static func decode(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // honour EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Downloads a remote file into `destination` (directory) with progress.
    ///
    /// Large files are fetched as parallel 4 MB ranges over several pooled TLS connections and written straight to
    /// their offsets, which keeps a fast Wi-Fi link busy (one stream is limited by a single TLS pipeline on the phone).
    /// Nothing runs byte by byte on the main thread. TLS authenticates every byte, so no extra hash pass is needed.
    @discardableResult
    func download(path: String, mediaId: Int64? = nil, name: String, size: Int64, into destination: URL) async throws -> URL {
        // The name comes from the phone: never let it steer the write outside `destination`.
        let name = Self.safeFileName(name)
        let target = uniqueURL(destination.appendingPathComponent(name, isDirectory: false))
        guard target.standardizedFileURL.deletingLastPathComponent().path == destination.standardizedFileURL.path else {
            throw MediaError.server("Refused an unsafe file name from the phone.")
        }
        let t = Transfer(name: name, direction: .download, total: size)
        transfers.insert(t, at: 0)
        do {
            if let demo {
                try demo.data(for: path, mediaId: mediaId).write(to: target)
            } else {
                guard let u = fileURL(path: path, mediaId: mediaId) else { throw MediaError.unavailable }
                try await fetch(u, size: size, to: target, transfer: t)
            }
            Self.markDownloaded(target)
            t.finish()
            return target
        } catch {
            t.fail(error.localizedDescription)
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    nonisolated private static let segmentSize: Int64 = 4 << 20
    nonisolated private static let parallelSegments = 4

    private func fetch(_ u: URL, size: Int64, to target: URL, transfer t: Transfer) async throws {
        if size > Self.segmentSize {
            let writer = try SegmentWriter(url: target, size: size)
            do {
                try await withThrowingTaskGroup(of: Int64.self) { group in
                    var next: Int64 = 0
                    func enqueue() {
                        guard next < size else { return }
                        let off = next, len = min(Self.segmentSize, size - next)
                        next += len
                        group.addTask {
                            let data = try await self.rangeChunk(u, offset: off, length: len)
                            try await writer.write(data, at: off)
                            return len
                        }
                    }
                    for _ in 0..<Self.parallelSegments { enqueue() }
                    while let n = try await group.next() {
                        t.advance(by: n)
                        if t.isCancelled { group.cancelAll(); throw CancellationError() }
                        enqueue()
                    }
                }
                await writer.close()
            } catch {
                await writer.close()
                throw error
            }
        } else {
            let (data, resp) = try await session.data(for: authorized(u))
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw MediaError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
            try data.write(to: target)
            t.advance(by: Int64(data.count))
        }
    }

    /// One byte range; verifies the phone returned exactly what was asked for.
    private func rangeChunk(_ url: URL, offset: Int64, length: Int64) async throws -> Data {
        var lastError: Error = MediaError.unavailable
        for attempt in 0..<3 { // a dropped pooled connection should not fail a whole transfer
            do {
                let (data, http) = try await rangeData(url, offset: offset, length: length)
                guard (200..<300).contains(http.statusCode) else { throw MediaError.http(http.statusCode) }
                guard Int64(data.count) == length else { throw MediaError.server("The phone sent a short block") }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if case MediaError.http(let c) = error, (400..<500).contains(c) { throw error }
                try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
            }
        }
        throw lastError
    }

    /// Marks a file written from the phone as an internet download so Gatekeeper still vets anything executable.
    nonisolated static func markDownloaded(_ url: URL) {
        var v = URLResourceValues()
        v.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                  kLSQuarantineAgentNameKey as String: "PhonePigeon"]
        var u = url
        try? u.setResourceValues(v)
    }

    /// Uploads a local file into a phone folder (spec §6.2 `PUT /media/upload`), SHA-256 verified by the phone.
    func upload(_ local: URL, toFolder folder: String) async throws {
        let name = local.lastPathComponent
        let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let t = Transfer(name: name, direction: .upload, total: size)
        transfers.insert(t, at: 0)
        let dest = (folder.hasSuffix("/") ? folder : folder + "/") + name
        do {
            if let demo {
                demo.addUpload(name: name, size: size, folder: folder)
            } else {
                guard let u = url("/media/upload", [URLQueryItem(name: "path", value: dest)]) else { throw MediaError.unavailable }
                var req = authorized(u)
                req.httpMethod = "PUT"
                let digest = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: local) }.value
                req.setValue(digest, forHTTPHeaderField: "X-Content-SHA256")
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let delegate = UploadProgress { sent in t.set(sent) }
                let (_, resp) = try await session.upload(for: req, fromFile: local, delegate: delegate)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw MediaError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
                }
                t.sha256 = digest
            }
            t.finish()
        } catch {
            t.fail(error.localizedDescription)
            throw error
        }
    }

    /// Reduces a phone-supplied name to a single, plain path component.
    nonisolated static func safeFileName(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        s = s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != ":" }.map(String.init).joined()
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }          // no "..", no hidden dotfiles such as .zshrc
        if s.isEmpty { s = "Phone file" }
        return String(s.prefix(200))
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = SHA256()
        while let chunk = try fh.read(upToCount: 4 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var i = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i)" + (ext.isEmpty ? "" : ".\(ext)"))
            i += 1
        }
        return candidate
    }

    // MARK: Streaming (AVPlayer with pinned TLS via resource loader)

    @ObservationIgnored private var loaders: [StreamingLoader] = []

    /// AVPlayer can't pin certificates itself, so the asset uses a custom scheme and
    /// every byte-range request is served through our pinned URLSession (spec §6.2 Mode A).
    func playerItem(for item: MediaItem) -> AVPlayerItem? {
        if let demo, let url = demo.videoURL(for: item) { return AVPlayerItem(url: url) }
        guard let real = fileURL(mediaId: item.mediaStoreId),
              var c = URLComponents(url: real, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "phonepigeon-media"
        guard let custom = c.url else { return nil }
        let asset = AVURLAsset(url: custom)
        let loader = StreamingLoader(client: self, realURL: real, mime: item.mimeType)
        loaders.append(loader)
        asset.resourceLoader.setDelegate(loader, queue: .main)
        return AVPlayerItem(asset: asset)
    }

    fileprivate func rangeData(_ url: URL, offset: Int64, length: Int64) async throws -> (Data, HTTPURLResponse) {
        var req = authorized(url)
        req.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
            throw MediaError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return (data, http)
    }
}

// MARK: - TLS pinning

private final class PinningDelegate: NSObject, URLSessionDelegate {
    weak var owner: MediaClient?
    init(owner: MediaClient) { self.owner = owner }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return (.cancelAuthenticationChallenge, nil) }
        let der = SecCertificateCopyData(leaf) as Data
        let hash = Data(SHA256.hash(data: der))
        let expected = await MainActor.run { owner?.pinnedHash }
        // Self-signed phone certificate: trust only the exact certificate announced over the E2EE channel.
        if let expected, expected == hash { return (.useCredential, URLCredential(trust: trust)) }
        return (.cancelAuthenticationChallenge, nil)
    }
}

/// Serialises positioned writes from concurrent range tasks into one pre-sized file.
private actor SegmentWriter {
    private let fh: FileHandle
    init(url: URL, size: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fh = try FileHandle(forWritingTo: url)
        if size > 0 { try fh.truncate(atOffset: UInt64(size)) }
    }
    func write(_ data: Data, at offset: Int64) throws {
        try fh.seek(toOffset: UInt64(offset))
        try fh.write(contentsOf: data)
    }
    func close() { try? fh.close() }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let onSent: @MainActor (Int64) -> Void
    init(_ onSent: @escaping @MainActor (Int64) -> Void) { self.onSent = onSent }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let cb = onSent
        Task { @MainActor in cb(totalBytesSent) }
    }
}

// MARK: - AVAssetResourceLoader bridge

private final class StreamingLoader: NSObject, AVAssetResourceLoaderDelegate {
    weak var client: MediaClient?
    let realURL: URL
    let mime: String

    init(client: MediaClient, realURL: URL, mime: String) {
        self.client = client
        self.realURL = realURL
        self.mime = mime
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        Task { @MainActor in await self.serve(loadingRequest) }
        return true
    }

    private func serve(_ req: AVAssetResourceLoadingRequest) async {
        guard let client else { req.finishLoading(with: MediaClient.MediaError.unavailable); return }
        do {
            let dataReq = req.dataRequest
            let offset = dataReq?.requestedOffset ?? 0
            let wanted = Int64(dataReq?.requestsAllDataToEndOfResource == true ? 2 * 1024 * 1024 : (dataReq?.requestedLength ?? 2))
            let length = max(2, min(wanted, 4 * 1024 * 1024))
            let (data, http) = try await client.rangeData(realURL, offset: offset, length: length)
            if let info = req.contentInformationRequest {
                info.contentType = UTType(mimeType: mime)?.identifier ?? AVFileType.mp4.rawValue
                info.isByteRangeAccessSupported = true
                if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                    info.contentLength = total
                } else {
                    info.contentLength = Int64(data.count)
                }
            }
            dataReq?.respond(with: data)
            req.finishLoading()
        } catch {
            req.finishLoading(with: error)
        }
    }
}

// MARK: - Transfers

@Observable
final class Transfer: Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable { case running, done, failed(String), cancelled }

    let id = UUID()
    let name: String
    let direction: Direction
    let total: Int64
    let started = Date()
    private(set) var done: Int64 = 0
    private(set) var state: State = .running
    var sha256: String?
    var isCancelled: Bool { state == .cancelled }

    init(name: String, direction: Direction, total: Int64) {
        self.name = name
        self.direction = direction
        self.total = total
    }

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : (state == .done ? 1 : 0) }
    var speed: String {
        let secs = max(0.2, Date().timeIntervalSince(started))
        return ByteCountFormatter.string(fromByteCount: Int64(Double(done) / secs), countStyle: .file) + "/s"
    }

    func advance(by n: Int64) { done += n }
    func set(_ n: Int64) { done = n }
    func finish() { done = max(done, total); state = .done }
    func fail(_ m: String) { if state == .running { state = .failed(m) } }
    func cancel() { if state == .running { state = .cancelled } }
}
