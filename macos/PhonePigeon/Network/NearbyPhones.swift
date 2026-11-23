import CryptoKit
import Foundation
import Network

/// A phone on the same network that is showing PhonePigeon's "Pair with your Mac" screen.
struct NearbyPhone: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let endpoint: NWEndpoint
}

/// Finds phones advertising `_pigeonphone._tcp` (Android only advertises while its pairing screen is open).
@Observable
final class NearbyBrowser {
    private(set) var phones: [NearbyPhone] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_pigeonphone._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [NearbyPhone] = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                var model = ""
                if case .bonjour(let txt) = r.metadata { model = txt["model"] ?? "" }
                let display = name.hasPrefix("PhonePigeon · ") ? String(name.dropFirst("PhonePigeon · ".count)) : name
                return NearbyPhone(id: "\(r.endpoint)", name: display, model: model, endpoint: r.endpoint)
            }.sorted { $0.name < $1.name }
            // The same service can be reported once per network interface (Wi-Fi, AirDrop link…): show each phone once.
            var seen = Set<String>()
            let unique = found.filter { seen.insert($0.name).inserted }
            MainActor.assumeIsolated { self?.phones = unique }
        }
        b.stateUpdateHandler = { _ in }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        phones = []
    }
}

/// Mac side of nearby pairing. See the Android `NearbyPairing` for the protocol and the reasoning:
/// commit → offer → reveal → both users confirm a six-digit code → the normal encrypted PairAck handshake.
@Observable
final class NearbyPairingFlow {
    enum State: Equatable {
        case idle
        case connecting(String)
        case confirm(phone: String, code: String)
        case finishing(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    let browser = NearbyBrowser()

    @ObservationIgnored weak var host: AppState?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var phoneName = ""
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var step = 0 // 0 awaiting offer, 1 awaiting phone decision
    @ObservationIgnored private var codeShownAt = Date.distantFuture

    var isBusy: Bool { state != .idle && !isFailed }
    private var isFailed: Bool { if case .failed = state { true } else { false } }

    // MARK: Messages

    private struct Hello: Codable { var type = "hello"; var v = 1; var commit: String; var macName: String }
    private struct Offer: Decodable {
        var androidDeviceId: String; var androidPubKey: String; var deviceName: String; var manufacturer: String; var osVersion: String
    }
    private struct Reveal: Codable {
        var type = "reveal"; var macDeviceId: String; var macPubKey: String; var nonce: String; var sessionId: String
        var relayUrl: String; var lanHost: String?; var macName: String
    }
    private struct Decision: Codable { var type = "decision"; var accepted: Bool }

    private var sessionId = ""
    private var nonce = Data()
    private var macPub = Data()

    // MARK: Flow

    func begin(_ phone: NearbyPhone) {
        guard !isBusy, let host else { return }
        cleanUp()
        phoneName = phone.name
        state = .connecting(phone.name)
        step = 0
        buffer = Data()
        sessionId = UUID().uuidString.lowercased()
        nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        macPub = host.macIdentity.publicKey.rawRepresentation

        // Commit to our key before the phone reveals its own, so nobody in the middle can pick keys that make the codes match.
        let commit = Data(SHA256.hash(data: Data("phonepigeon-nearby-commit-v1".utf8) + macPub + nonce + Data(sessionId.utf8)))
        let c = NWConnection(to: phone.endpoint, using: .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch s {
                case .ready:
                    self.send(Hello(commit: commit.base64EncodedString(), macName: AppState.macName))
                    self.receive()
                case .failed(let e): self.fail("Couldn't reach the phone (\(e.localizedDescription)).")
                case .waiting: break
                default: break
                }
            }
        }
        c.start(queue: .main)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(150))
            if !Task.isCancelled { self?.fail("The phone didn't answer in time.") }
        }
    }

    /// The user confirms the code matches on this Mac.
    func confirm() {
        guard case .confirm(let name, _) = state else { return }
        // The code must be on screen long enough to be read before a click can approve it.
        guard Date().timeIntervalSince(codeShownAt) > 1.5 else { return }
        send(Decision(accepted: true))
        state = .finishing(name)
    }

    func cancel() {
        if connection != nil { send(Decision(accepted: false)) }
        cleanUp()
        host?.clearNearbyPairing()
        state = .idle
    }

    /// Called by AppState when the phone's PairAck was accepted.
    func completed() {
        cleanUp()
        state = .idle
    }

    func dismissFailure() { if isFailed { state = .idle } }

    // MARK: Transport

    private func send<T: Encodable>(_ message: T) {
        guard let connection, let body = try? PayloadCodec.encode(message), body.count < 4096 else { return }
        var len = UInt32(body.count).bigEndian
        connection.send(content: Data(bytes: &len, count: 4) + body, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, self.connection != nil else { return }
                if let data { self.buffer.append(data); self.drain() }
                if done || error != nil {
                    if case .finishing = self.state { return } // the phone closes once it has what it needs
                    if self.state != .idle { self.fail("The phone closed the connection.") }
                } else { self.receive() }
            }
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let len = Int(buffer[buffer.startIndex]) << 24 | Int(buffer[buffer.startIndex + 1]) << 16 | Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            guard len > 0, len <= 4096 else { fail("The phone sent something unexpected."); return }
            guard buffer.count >= 4 + len else { return }
            let body = Data(buffer[(buffer.startIndex + 4)..<(buffer.startIndex + 4 + len)])
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + len))
            handle(body)
        }
    }

    private func handle(_ body: Data) {
        guard let host else { return }
        switch step {
        case 0:
            guard let offer = try? PayloadCodec.decode(Offer.self, from: body),
                  let phonePub = Data(base64Encoded: offer.androidPubKey), phonePub.count == 32 else { fail("The phone sent an invalid key."); return }
            let name = offer.deviceName.isEmpty ? phoneName : offer.deviceName
            let sas = Data(SHA256.hash(data: Data("phonepigeon-sas-v1".utf8) + Data(sessionId.utf8) + macPub + phonePub))
            let n = (UInt32(sas[0]) << 24 | UInt32(sas[1]) << 16 | UInt32(sas[2]) << 8 | UInt32(sas[3])) % 1_000_000
            let digits = String(format: "%06d", n)
            let code = "\(digits.prefix(3)) \(digits.dropFirst(3))"
            let secret = Data(HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: Data(SHA256.hash(data: Data("phonepigeon-nearby-v1".utf8) + Data(sessionId.utf8) + macPub + phonePub + nonce))),
                salt: Data(), info: Data("pairing-secret".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) })
            let payload = host.prepareNearbyPairing(sessionId: sessionId, secret: secret)
            send(Reveal(macDeviceId: host.macDeviceId, macPubKey: macPub.base64EncodedString(), nonce: nonce.base64EncodedString(),
                        sessionId: sessionId, relayUrl: payload.relayUrl, lanHost: payload.lanHost, macName: AppState.macName))
            step = 1
            codeShownAt = .now
            state = .confirm(phone: name, code: code)
        default:
            guard let d = try? PayloadCodec.decode(Decision.self, from: body) else { return }
            if !d.accepted { fail("The phone declined or the codes didn't match.") }
            // Accepted: the phone now runs the encrypted pairing; AppState calls `completed()` when it lands.
        }
    }

    private func fail(_ message: String) {
        guard state != .idle else { return }
        cleanUp()
        host?.clearNearbyPairing()
        state = .failed(message)
    }

    private func cleanUp() {
        timeout?.cancel(); timeout = nil
        connection?.cancel(); connection = nil
        buffer = Data()
    }
}
