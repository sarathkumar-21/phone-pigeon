import AppKit
import AVFoundation
import CoreMedia
import CryptoKit

// MARK: - Session state (observed by the UI)

@Observable
final class ScreenMirrorSession {
    private(set) var state: ScreenState = .idle
    private(set) var message = ""
    private(set) var width = 0
    private(set) var height = 0
    /// The phone allows touch/keyboard input from the Mac (accessibility service on, Remote control switched on).
    private(set) var control = false

    var isBusy: Bool { state == .waiting || state == .streaming }

    func apply(_ s: ScreenMirrorStatus) {
        state = s.state
        message = s.message
        if s.width > 0 { width = s.width; height = s.height }
        control = s.control
    }
    func begin() { state = .waiting; message = "Waiting for you to approve on your phone…" }
    func reset(_ s: ScreenState = .idle) { state = s }
}

// MARK: - Wire frames

/// One unit of the phone's screen stream: kind 1 = SPS/PPS (Annex B), 2 = key frame, 3 = delta frame.
nonisolated struct ScreenFrame: Sendable {
    let kind: UInt8
    let ptsMicros: UInt64
    let data: Data
}

/// Reads `GET /media/screen`: an open-ended HTTPS response of `kind(1) ‖ length(4 BE) ‖ pts(8 BE) ‖ payload` frames.
/// The certificate is pinned to the hash the phone announced over the end-to-end encrypted channel.
nonisolated final class ScreenStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let pinnedHash: Data
    private let onFrame: @Sendable (ScreenFrame) -> Void
    private let onEnd: @Sendable (Error?) -> Void
    private var buffer = Data()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var finished = false
    private let lock = NSLock()

    init(request: URLRequest, pinnedHash: Data,
         onFrame: @escaping @Sendable (ScreenFrame) -> Void, onEnd: @escaping @Sendable (Error?) -> Void) {
        self.pinnedHash = pinnedHash
        self.onFrame = onFrame
        self.onEnd = onEnd
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForResource = 24 * 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        session = s
        task = s.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        finish(nil)
    }

    private func finish(_ error: Error?) {
        lock.lock(); let already = finished; finished = true; lock.unlock()
        if !already { onEnd(error) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == pinnedHash else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            completionHandler(.cancel)
            finish(MediaClient.MediaError.http(http.statusCode))
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while buffer.count >= 13 {
            let base = buffer.startIndex
            let kind = buffer[base]
            let len = Int(buffer[base + 1]) << 24 | Int(buffer[base + 2]) << 16 | Int(buffer[base + 3]) << 8 | Int(buffer[base + 4])
            guard len >= 0, len <= 8 * 1024 * 1024 else { cancel(); return } // refuse absurd frames from a misbehaving peer
            guard buffer.count >= 13 + len else { break }
            var pts: UInt64 = 0
            for i in 5..<13 { pts = pts << 8 | UInt64(buffer[base + i]) }
            let payload = Data(buffer[(base + 13)..<(base + 13 + len)])
            buffer.removeSubrange(base..<(base + 13 + len))
            onFrame(ScreenFrame(kind: kind, ptsMicros: pts, data: payload))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }
}

// MARK: - H.264 decode + display (pure AppKit, like the video window)

/// A layer-backed view that shows decoded frames and, when the phone allows it, turns mouse and keyboard
/// input into touch/keyboard events for the phone (clicks = taps, drags = swipes, scroll = swipes, keys = typing).
final class ScreenLayerView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var videoSize = CGSize(width: 9, height: 19)
    var controlEnabled = false
    var onInput: ((RemoteInput) -> Void)?

    private var downPoint: CGPoint?
    private var downTime = Date()
    private var scrollAccum = CGSize.zero
    private var scrollAnchor = CGPoint(x: 0.5, y: 0.6)
    private var scrollTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A point in this view as a fraction (0…1, y down) of the phone screen, or nil outside the picture.
    private func normalized(_ p: CGPoint) -> CGPoint? {
        let b = bounds
        guard videoSize.width > 0, videoSize.height > 0, b.width > 0, b.height > 0 else { return nil }
        let scale = min(b.width / videoSize.width, b.height / videoSize.height)
        let w = videoSize.width * scale, h = videoSize.height * scale
        let rect = CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
        guard rect.contains(p) else { return nil }
        return CGPoint(x: (p.x - rect.minX) / w, y: 1 - (p.y - rect.minY) / h)
    }

    private func point(_ event: NSEvent) -> CGPoint? { normalized(convert(event.locationInWindow, from: nil)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = point(event)
        downTime = .now
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard controlEnabled, let start = downPoint, let end = point(event) else { return }
        let held = Date().timeIntervalSince(downTime)
        if hypot(end.x - start.x, end.y - start.y) < 0.012 {
            onInput?(RemoteInput(kind: held > 0.5 ? .longPress : .tap, x: start.x, y: start.y))
        } else {
            onInput?(RemoteInput(kind: .swipe, x: start.x, y: start.y, x2: end.x, y2: end.y,
                                 durationMs: Int(min(800, max(120, held * 1000)))))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard controlEnabled else { return }
        onInput?(RemoteInput(kind: .back)) // right-click = Back, like a phone's back gesture
    }

    override func scrollWheel(with event: NSEvent) {
        guard controlEnabled else { return }
        if scrollAccum == .zero { scrollAnchor = point(event) ?? CGPoint(x: 0.5, y: 0.6) }
        scrollAccum.width += event.scrollingDeltaX
        scrollAccum.height += event.scrollingDeltaY
        scrollTask?.cancel()
        scrollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120)) // one swipe per scroll gesture
            guard let self, !Task.isCancelled else { return }
            let dx = max(-0.6, min(0.6, scrollAccum.width / max(bounds.width, 1)))
            let dy = max(-0.6, min(0.6, scrollAccum.height / max(bounds.height, 1)))
            scrollAccum = .zero
            guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return }
            let end = CGPoint(x: max(0.02, min(0.98, scrollAnchor.x + dx)), y: max(0.02, min(0.98, scrollAnchor.y + dy)))
            onInput?(RemoteInput(kind: .swipe, x: scrollAnchor.x, y: scrollAnchor.y, x2: end.x, y2: end.y, durationMs: 260))
        }
    }

    override func keyDown(with event: NSEvent) {
        guard controlEnabled else { super.keyDown(with: event); return }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 76: onInput?(RemoteInput(kind: .enter))
        case 51: onInput?(RemoteInput(kind: .text, text: "\u{8}"))
        case 53: onInput?(RemoteInput(kind: .back))
        default:
            if let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) {
                onInput?(RemoteInput(kind: .text, text: chars))
            }
        }
    }
}

@MainActor
final class ScreenWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let view = ScreenLayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 760))
    private var format: CMVideoFormatDescription?
    private var closedByUs = false
    var onUserClose: (() -> Void)?
    private var navButtons: [NSButton] = []
    var onInput: ((RemoteInput) -> Void)? {
        didSet { view.onInput = onInput }
    }
    /// Whether the phone currently accepts touch and keyboard input from this Mac.
    var controlEnabled = false {
        didSet {
            view.controlEnabled = controlEnabled
            window.subtitle = controlEnabled ? "Screen mirroring · click, drag, scroll and type to control" : "Screen mirroring · view only"
            navButtons.forEach { $0.isEnabled = controlEnabled }
        }
    }

    init(title: String, width: Int, height: Int) {
        window = NSWindow(contentRect: Self.contentRect(width: width, height: height),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.contentView = view
        window.title = title
        window.subtitle = "Screen mirroring · view only"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.delegate = self
        applyAspect(width: width, height: height)
        window.center()
        addNavigationButtons()
    }

    /// Back / Home / Recents, like the phone's navigation bar (active only when control is allowed).
    private func addNavigationButtons() {
        func button(_ symbol: String, _ tip: String, _ kind: InputKind) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: nil, action: nil)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            b.isEnabled = false
            b.target = self
            b.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            b.action = #selector(navTapped(_:))
            return b
        }
        navButtons = [button("chevron.backward", "Back", .back), button("circle", "Home", .home), button("square.on.square", "Recent apps", .recents)]
        let stack = NSStackView(views: navButtons)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func navTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let kind = InputKind(rawValue: raw) else { return }
        onInput?(RemoteInput(kind: kind))
    }

    private static func contentRect(width: Int, height: Int) -> NSRect {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let aspect = CGFloat(max(width, 1)) / CGFloat(max(height, 1))
        var h = min(CGFloat(height > 0 ? height : 760), screen.height * 0.8)
        var w = h * aspect
        if w > screen.width * 0.8 { w = screen.width * 0.8; h = w / aspect }
        return NSRect(x: 0, y: 0, width: w, height: h)
    }

    private func applyAspect(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        view.videoSize = CGSize(width: width, height: height)
        window.contentAspectRatio = NSSize(width: width, height: height)
        window.setContentSize(Self.contentRect(width: width, height: height).size)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func resize(width: Int, height: Int) { applyAspect(width: width, height: height) }

    func close() {
        closedByUs = true
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !closedByUs { onUserClose?() }
    }

    // MARK: Frames

    func handle(_ frame: ScreenFrame) {
        switch frame.kind {
        case 1: configure(frame.data)
        case 2, 3: display(frame)
        default: break
        }
    }

    /// Splits an Annex-B buffer (00 00 01 / 00 00 00 01 start codes) into NAL units.
    nonisolated static func nalUnits(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(start: Int, payload: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append((i, i + 3)); i += 3 }
            else if i + 4 <= b.count, b[i] == 0, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, i + 4)); i += 4 }
            else { i += 1 }
        }
        return starts.enumerated().map { idx, s in
            let end = idx + 1 < starts.count ? starts[idx + 1].start : b.count
            return Data(b[s.payload..<end])
        }
    }

    private func configure(_ annexB: Data) {
        let nals = Self.nalUnits(annexB)
        guard let sps = nals.first(where: { ($0.first ?? 0) & 0x1F == 7 }), let pps = nals.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return }
        var fd: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let pointers = [spsBuf.bindMemory(to: UInt8.self).baseAddress!, ppsBuf.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let fd else { return }
        format = fd
        view.displayLayer.flush()
    }

    private func display(_ frame: ScreenFrame) {
        guard let format else { return }
        // Annex B → AVCC (4-byte length prefixes); parameter sets and access-unit delimiters are carried by `format`.
        var avcc = Data()
        for nal in Self.nalUnits(frame.data) {
            guard let h = nal.first else { continue }
            let type = h & 0x1F
            if type == 7 || type == 8 || type == 9 { continue }
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4)); avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block,
              avcc.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }) == kCMBlockBufferNoErr
        else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(frame.ptsMicros), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if frame.kind == 3 {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        if view.displayLayer.status == .failed { view.displayLayer.flush() }
        view.displayLayer.enqueue(sample)
    }
}
