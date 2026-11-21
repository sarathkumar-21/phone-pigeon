import CryptoKit
import Foundation

/// Cloud relay transport (spec §10): X25519 proof-of-possession registration → JWT →
/// WebSocket. Frames sent while disconnected are buffered and flushed on connect.
final class RelayTransport: FrameTransport {
    var onFrame: ((WireFrame) -> Void)?
    var onStateChange: ((TransportLinkState) -> Void)?
    private(set) var state: TransportLinkState = .idle { didSet { if state != oldValue { onStateChange?(state) } } }

    private let wsURL: URL
    private let deviceId: String
    private let identity: Curve25519.KeyAgreement.PrivateKey
    private var task: URLSessionWebSocketTask?
    private var token: String?
    private var tokenIssued = Date.distantPast
    private var pingTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var stopped = true
    private var outbox: [Data] = []
    private var pendingSession: String?
    private let session = URLSession(configuration: .default)

    init(wsURL: URL, deviceId: String, identity: Curve25519.KeyAgreement.PrivateKey) {
        self.wsURL = wsURL
        self.deviceId = deviceId
        self.identity = identity
    }

    func start() {
        guard stopped else { return }
        stopped = false
        Task { await connect() }
    }

    func stop() {
        stopped = true
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    func send(_ frame: WireFrame) {
        guard let data = try? PayloadCodec.encode(frame) else { return }
        guard let task, state == .connected else {
            outbox.append(data)
            if outbox.count > 500 { outbox.removeFirst(outbox.count - 500) }
            return
        }
        task.send(.data(data)) { _ in }
    }

    /// Announces the QR session so the phone can redeem it (`POST /v1/pairing-sessions`).
    func openPairingSession(_ sessionId: String) {
        pendingSession = sessionId
        if token != nil { Task { await postPairingSession() } }
    }

    // MARK: REST

    private var restBase: URL {
        var c = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)!
        c.scheme = wsURL.scheme == "ws" ? "http" : "https"
        c.path = ""
        c.query = nil
        return c.url!
    }

    private func post<T: Decodable>(_ path: String, _ body: some Encodable, auth: Bool = false, as: T.Type) async throws -> T {
        var req = URLRequest(url: restBase.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try PayloadCodec.encode(body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey:
                String(data: data, encoding: .utf8) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        if T.self == Empty.self { return Empty() as! T }
        return try PayloadCodec.decode(T.self, from: data)
    }

    private struct Empty: Codable {}
    private struct ChallengeReq: Encodable { let deviceId: String; let platform = "MACOS"; let publicKey: Data }
    private struct ChallengeRes: Decodable { let challengeId: String; let serverPublicKey: Data; let nonce: Data }
    private struct RegisterReq: Encodable { let challengeId: String; let proof: Data }
    private struct RegisterRes: Decodable { let token: String }
    private struct SessionReq: Encodable { let sessionId: String }

    /// Proves possession of the X25519 identity: HMAC(X25519(sk, server_eph), ctx ‖ device_id ‖ nonce).
    private func register() async throws -> String {
        let ch = try await post("v1/devices/challenge", ChallengeReq(deviceId: deviceId, publicKey: identity.publicKey.rawRepresentation),
                                as: ChallengeRes.self)
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ch.serverPublicKey)
        let shared = try identity.sharedSecretFromKeyAgreement(with: serverKey).withUnsafeBytes { SymmetricKey(data: Data($0)) }
        var mac = HMAC<SHA256>(key: shared)
        mac.update(data: Data("phonepigeon-register-v1".utf8))
        mac.update(data: Data(deviceId.utf8))
        mac.update(data: ch.nonce)
        let proof = Data(mac.finalize())
        return try await post("v1/devices/register", RegisterReq(challengeId: ch.challengeId, proof: proof), as: RegisterRes.self).token
    }

    private func postPairingSession() async {
        guard let sid = pendingSession else { return }
        _ = try? await post("v1/pairing-sessions", SessionReq(sessionId: sid), auth: true, as: Empty.self)
    }

    // MARK: Socket

    private func connect() async {
        guard !stopped else { return }
        state = .connecting
        do {
            // Tokens are short-lived and revoked on unpair: refresh before they age out.
            if token == nil || Date().timeIntervalSince(tokenIssued) > 6 * 3600 {
                token = try await register()
                tokenIssued = .now
            }
            await postPairingSession()
            var req = URLRequest(url: wsURL)
            req.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
            let t = session.webSocketTask(with: req)
            task = t
            t.resume()
            // First successful receive or ping proves the upgrade worked.
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                t.sendPing { err in if let err { c.resume(throwing: err) } else { c.resume() } }
            }
            state = .connected
            reconnectAttempt = 0
            for d in outbox { t.send(.data(d)) { _ in } }
            outbox.removeAll()
            startPing()
            await receiveLoop(t)
        } catch {
            // A rejected token surfaces differently for REST (401) and the WebSocket upgrade: after two failures, re-prove the key.
            if (error as? URLError)?.code == .userAuthenticationRequired || reconnectAttempt >= 2 { token = nil }
            state = .failed(error.localizedDescription)
        }
        scheduleReconnect()
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) async {
        while !stopped {
            do {
                let msg = try await t.receive()
                let data: Data? = switch msg {
                case .data(let d): d
                case .string(let s): Data(s.utf8)
                @unknown default: nil
                }
                if let data, let frame = try? PayloadCodec.decode(WireFrame.self, from: data) { onFrame?(frame) }
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                self?.task?.sendPing { _ in }
            }
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.connect()
        }
    }
}
