import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Records a call on the Mac.
///
/// Android doesn't let third-party apps capture call audio, so this records what the *Mac* hears while the
/// call audio is routed here over Bluetooth hands-free:
///  - your voice from the microphone, and
///  - the caller's voice from the system audio output (ScreenCaptureKit, audio only — no screen content is kept).
/// The two are mixed into one `.m4a` in `~/Music/PhonePigeon Recordings`.
/// If "Screen & System Audio Recording" isn't allowed, only your side is recorded and the UI says so.
@Observable
final class CallRecorder {
    enum RecorderError: LocalizedError {
        case microphoneDenied, nothingRecorded, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Allow microphone access for PhonePigeon in System Settings › Privacy & Security to record calls."
            case .nothingRecorded: "No audio was captured."
            case .exportFailed(let m): "Couldn't save the recording: \(m)"
            }
        }
    }

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// False when only the microphone is being captured (system audio permission missing).
    private(set) var includesCaller = false

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var micSink: AudioFileSink?
    @ObservationIgnored private var systemSink: AudioFileSink?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var label = "Call"

    // MARK: Start / stop

    func start(label: String) async throws {
        guard !isRecording else { return }
        guard await Self.microphoneAllowed() else { throw RecorderError.microphoneDenied }
        self.label = label
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhonePigeonRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Your voice.
        let mic = AudioFileSink(url: dir.appendingPathComponent("mic.caf"))
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0), block: Self.tapHandler(mic))
        try engine.start()
        self.engine = engine
        micSink = mic

        // The caller's voice: system audio output.
        includesCaller = false
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
            let sink = AudioFileSink(url: dir.appendingPathComponent("system.caf"))
            if let s = try? await Self.startSystemAudio(into: sink) {
                stream = s.stream; tap = s.tap; systemSink = sink; includesCaller = true
            }
        }
        startedAt = .now
        isRecording = true
    }

    /// Stops and returns the finished `.m4a`.
    func stop() async throws -> URL {
        guard isRecording else { throw RecorderError.nothingRecorded }
        isRecording = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil; tap = nil
        micSink?.close(); systemSink?.close()
        let mic = micSink, system = systemSink, began = startedAt ?? .now
        micSink = nil; systemSink = nil; startedAt = nil

        let out = try Self.outputURL(label: label, date: began)
        try await Self.mix(mic: mic, system: system, to: out)
        if let dir = mic?.url.deletingLastPathComponent() { try? FileManager.default.removeItem(at: dir) }
        return out
    }

    // MARK: Helpers

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    nonisolated private static func tapHandler(_ sink: AudioFileSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.write(buffer) }
    }

    nonisolated private static func startSystemAudio(into sink: AudioFileSink) async throws -> (stream: SCStream, tap: SystemAudioTap) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.nothingRecorded }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2; config.height = 2 // audio only: the picture is never kept
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let tap = SystemAudioTap(sink: sink)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: tap)
        try stream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: DispatchQueue(label: "phonepigeon.recording.system"))
        try await stream.startCapture()
        return (stream, tap)
    }

    private static func outputURL(label: String, date: Date) throws -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("PhonePigeon Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = MediaClient.safeFileName(label).replacingOccurrences(of: "/", with: "-")
        return music.appendingPathComponent("\(safe) \(f.string(from: date)).m4a")
    }

    /// Lays both captures on one timeline (aligned by when each produced its first audio) and exports AAC.
    nonisolated private static func mix(mic: AudioFileSink?, system: AudioFileSink?, to out: URL) async throws {
        let composition = AVMutableComposition()
        let sources = [mic, system].compactMap { $0 }.filter { $0.hasAudio }
        guard !sources.isEmpty else { throw RecorderError.nothingRecorded }
        let origin = sources.compactMap(\.firstFrameAt).min() ?? .now
        for s in sources {
            let asset = AVURLAsset(url: s.url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let duration = try await asset.load(.duration)
            let offset = max(0, (s.firstFrameAt ?? origin).timeIntervalSince(origin))
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: CMTime(seconds: offset, preferredTimescale: 600))
        }
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.exportFailed("the audio encoder isn't available")
        }
        export.outputURL = out
        export.outputFileType = .m4a
        let box = UncheckedBox(export)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in box.value.exportAsynchronously { c.resume() } }
        guard box.value.status == .completed else {
            throw RecorderError.exportFailed(box.value.error?.localizedDescription ?? "export failed")
        }
    }
}

private nonisolated final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// Thread-safe PCM file writer fed from audio threads.
nonisolated final class AudioFileSink: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: Int64 = 0
    private(set) var firstFrameAt: Date?

    init(url: URL) { self.url = url }

    var hasAudio: Bool { lock.lock(); defer { lock.unlock() }; return frames > 0 }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
            firstFrameAt = .now
        }
        guard let file, (try? file.write(from: buffer)) != nil else { return }
        frames += Int64(buffer.frameLength)
    }

    func close() { lock.lock(); file = nil; lock.unlock() } // releasing the AVAudioFile finalises the header
}

nonisolated final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sink: AudioFileSink
    init(sink: AudioFileSink) { self.sink = sink }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcm(from: sampleBuffer) else { return }
        sink.write(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}

    private static func pcm(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
