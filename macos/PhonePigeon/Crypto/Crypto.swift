import CryptoKit
import Foundation
import Security

nonisolated enum Crypto {
    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Proves the phone saw the QR; the secret in it never travels through the relay.
    static func pairProof(secret: Data, sessionId: String, phonePub: Data, macPub: Data) -> Data {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: secret))
        mac.update(data: Data("phonepigeon-pair-v1".utf8))
        mac.update(data: Data(sessionId.utf8))
        mac.update(data: phonePub)
        mac.update(data: macPub)
        return Data(mac.finalize())
    }

    static func verifyPairProof(_ proof: Data, secret: Data, sessionId: String, phonePub: Data, macPub: Data) -> Bool {
        let msg = Data("phonepigeon-pair-v1".utf8) + Data(sessionId.utf8) + phonePub + macPub
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: msg, using: SymmetricKey(data: secret)) // constant time
    }

    /// What Bonjour advertises instead of the raw device id, which would be a stable tracker for everyone on the LAN.
    static func mdnsTag(_ deviceId: String) -> String {
        SHA256.hash(data: Data(("phonepigeon-mdns-v1" + deviceId).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Short, human-comparable fingerprint of a public key, e.g. "7F3A · 91C2 · 0B4E · D8A1".
    static func fingerprint(_ key: Data) -> String {
        let hex = SHA256.hash(data: key).prefix(16).map { String(format: "%02X", $0) }.joined() // 128 bits
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[s..<hex.index(s, offsetBy: 4)])
        }.joined(separator: " · ")
    }
}

// MARK: - Directional session keys (spec §5.1 step 3)

struct SessionKeys: Sendable {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    /// Raw static-static X25519 secret; mixed with an ephemeral secret when the channel re-keys (forward secrecy).
    let staticShared: Data

    enum Role { case mac, android }

    /// `K_and_to_mac = HKDF(S, salt=session_id, info="and->mac")`
    /// `K_mac_to_and = HKDF(S, salt=session_id, info="mac->and")`
    static func derive(privateKey: Curve25519.KeyAgreement.PrivateKey,
                       peerPublicKey: Data,
                       sessionId: String,
                       role: Role) throws -> SessionKeys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let salt = Data(sessionId.utf8)
        let andToMac = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("and->mac".utf8), outputByteCount: 32)
        let macToAnd = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("mac->and".utf8), outputByteCount: 32)
        let raw = shared.withUnsafeBytes { Data($0) }
        switch role {
        case .mac: return SessionKeys(sendKey: macToAnd, receiveKey: andToMac, staticShared: raw)
        case .android: return SessionKeys(sendKey: andToMac, receiveKey: macToAnd, staticShared: raw)
        }
    }
}

/// Keys for one re-key epoch: static secret ‖ fresh ephemeral X25519 secret (spec addition: forward secrecy for live traffic).
struct EphemeralKeys {
    let send: SymmetricKey
    let receive: SymmetricKey
    let epoch: String

    static func derive(staticShared: Data, ephemeralShared: Data, sessionId: String, epoch: String, role: SessionKeys.Role) -> EphemeralKeys {
        let ikm = SymmetricKey(data: staticShared + ephemeralShared)
        let salt = Data("\(sessionId)|\(epoch)".utf8)
        let andToMac = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("and->mac/eph".utf8), outputByteCount: 32)
        let macToAnd = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("mac->and/eph".utf8), outputByteCount: 32)
        switch role {
        case .mac: return EphemeralKeys(send: macToAnd, receive: andToMac, epoch: epoch)
        case .android: return EphemeralKeys(send: andToMac, receive: macToAnd, epoch: epoch)
        }
    }
}

// MARK: - Payload encryption (spec §5.2)

enum SecureChannelError: Error, LocalizedError {
    case replayed(UInt64)
    case clockSkew
    case malformed

    var errorDescription: String? {
        switch self {
        case .replayed(let s): "Dropped replayed packet (seq \(s))."
        case .clockSkew: "Dropped packet with clock skew > 5 minutes."
        case .malformed: "Malformed ciphertext."
        }
    }
}

/// ChaCha20-Poly1305 channel with a 96-bit nonce = 8-byte random prefix ‖ 4-byte counter, plus
/// sequence-number replay protection.
///
/// Forward secrecy (best effort): the Mac periodically starts an ephemeral X25519 exchange (`rekey` payloads,
/// themselves sent under the static keys). Once finished, live traffic is sealed under keys that mix in the
/// ephemeral secret, which is discarded afterwards. Static keys always stay valid for *receiving*, so a restart
/// on either side or a frame queued at the relay can never make a message undecryptable.
final class SecureChannel {
    private let keys: SessionKeys
    private let role: SessionKeys.Role
    private let sessionId: String
    private let noncePrefix: Data
    private var nonceCounter: UInt32 = 0
    private(set) var outgoingSequence: UInt64
    private(set) var highestIncomingSequence: UInt64

    // Re-key state
    private var eph: EphemeralKeys?
    private var pending: EphemeralKeys?
    private var initiator: (epoch: String, priv: Curve25519.KeyAgreement.PrivateKey, at: Date)?
    private var lastPeerFrame: Date = .distantPast
    /// Peers that have spoken within this window are assumed to hold the ephemeral keys.
    private let ephemeralFreshness: TimeInterval = 120
    private(set) var wantsRekey: Bool
    private var loggedEphemeralUse = false

    let localDeviceId: String
    let peerDeviceId: String

    init(keys: SessionKeys, role: SessionKeys.Role, sessionId: String, localDeviceId: String, peerDeviceId: String,
         outgoingSequence: UInt64 = 0, highestIncomingSequence: UInt64 = 0) {
        self.keys = keys
        self.role = role
        self.sessionId = sessionId
        self.localDeviceId = localDeviceId
        self.peerDeviceId = peerDeviceId
        self.outgoingSequence = outgoingSequence
        self.highestIncomingSequence = highestIncomingSequence
        self.wantsRekey = role == .mac
        var prefix = Data(count: 8)
        _ = prefix.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        self.noncePrefix = prefix
    }

    private func nextNonce() throws -> ChaChaPoly.Nonce {
        guard nonceCounter < UInt32.max - 1 else { throw SecureChannelError.malformed } // a fresh channel/epoch is needed long before this
        nonceCounter += 1
        var counter = nonceCounter.bigEndian
        return try ChaChaPoly.Nonce(data: noncePrefix + Data(bytes: &counter, count: 4))
    }

    private func isRekey(_ body: PayloadBody) -> Bool { if case .rekey = body { return true }; return false }

    func seal(_ body: PayloadBody) throws -> EncryptedEnvelope {
        outgoingSequence += 1
        let payload = DevicePayload(sequenceNumber: outgoingSequence,
                                    clientTimestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                                    body: body)
        let plaintext = try PayloadCodec.encode(payload)
        let nonce = try nextNonce()
        let routing = Data((localDeviceId + "→" + peerDeviceId).utf8) // bind routing header as AAD
        let useEphemeral = eph != nil && !isRekey(body) && Date().timeIntervalSince(lastPeerFrame) < ephemeralFreshness
        let key = useEphemeral ? eph!.send : keys.sendKey
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: routing)
        return EncryptedEnvelope(messageId: UUID().uuidString.lowercased(),
                                 senderDeviceId: localDeviceId,
                                 targetDeviceId: peerDeviceId,
                                 nonce: Data(nonce),
                                 ciphertext: box.ciphertext + box.tag,
                                 serverTimestampMs: 0,
                                 requiresWakeup: body.requiresWakeup)
    }

    func open(_ envelope: EncryptedEnvelope) throws -> DevicePayload {
        guard envelope.ciphertext.count >= 16 else { throw SecureChannelError.malformed }
        let nonce = try ChaChaPoly.Nonce(data: envelope.nonce)
        let ct = envelope.ciphertext.dropLast(16)
        let tag = envelope.ciphertext.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let routing = Data((envelope.senderDeviceId + "→" + envelope.targetDeviceId).utf8)

        enum Used { case eph, pending, `static` }
        var plaintext: Data?
        var used = Used.static
        if let e = eph, let p = try? ChaChaPoly.open(box, using: e.receive, authenticating: routing) { plaintext = p; used = .eph }
        else if let n = pending, let p = try? ChaChaPoly.open(box, using: n.receive, authenticating: routing) { plaintext = p; used = .pending }
        else { plaintext = try ChaChaPoly.open(box, using: keys.receiveKey, authenticating: routing) }
        let payload = try PayloadCodec.decode(DevicePayload.self, from: plaintext!)

        guard payload.sequenceNumber > highestIncomingSequence else {
            throw SecureChannelError.replayed(payload.sequenceNumber)
        }
        if payload.body.isLive {
            let skew = abs(Date().timeIntervalSince1970 * 1000 - Double(payload.clientTimestampMs))
            if skew > 5 * 60 * 1000 { throw SecureChannelError.clockSkew }
        }
        highestIncomingSequence = payload.sequenceNumber
        lastPeerFrame = .now
        switch used {
        case .eph:
            if !loggedEphemeralUse { loggedEphemeralUse = true; Trace.log("peer is using forward-secret (ephemeral) keys") }
        case .pending: eph = pending; pending = nil
        case .static where !isRekey(payload.body):
            // The peer is sending under static keys (it restarted or was offline): stop assuming it has ours, and re-key.
            if eph != nil || pending != nil { eph = nil; pending = nil; wantsRekey = role == .mac }
        default: break
        }
        return payload
    }

    // MARK: Re-keying

    /// Mac only: call after a frame was accepted (or on a timer). Returns the rekey request to send, if one is due.
    func rekeyRequestIfDue() -> PayloadBody? {
        guard role == .mac, wantsRekey else { return nil }
        if let i = initiator, Date().timeIntervalSince(i.at) < 30 { return nil } // one in flight; retry after 30 s without an answer
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let epoch = UUID().uuidString.lowercased()
        initiator = (epoch, priv, .now)
        return .rekey(RekeyMessage(epochId: epoch, ephPub: priv.publicKey.rawRepresentation, reply: false))
    }

    func scheduleRekey() { if role == .mac { wantsRekey = true } }

    /// Handles a peer's rekey message; returns a payload to send back, if any.
    func handleRekey(_ m: RekeyMessage) -> PayloadBody? {
        switch (role, m.reply) {
        case (.android, false):
            guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: m.ephPub) else { return nil }
            let priv = Curve25519.KeyAgreement.PrivateKey()
            guard let shared = try? priv.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes({ Data($0) }) else { return nil }
            pending = EphemeralKeys.derive(staticShared: keys.staticShared, ephemeralShared: shared, sessionId: sessionId, epoch: m.epochId, role: role)
            return .rekey(RekeyMessage(epochId: m.epochId, ephPub: priv.publicKey.rawRepresentation, reply: true))
        case (.mac, true):
            guard let i = initiator, i.epoch == m.epochId,
                  let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: m.ephPub),
                  let shared = try? i.priv.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes({ Data($0) }) else { return nil }
            eph = EphemeralKeys.derive(staticShared: keys.staticShared, ephemeralShared: shared, sessionId: sessionId, epoch: m.epochId, role: role)
            initiator = nil
            wantsRekey = false
            loggedEphemeralUse = false
            Trace.log("ephemeral key exchange completed")
            // First message under the new keys: lets the phone promote its pending keys right away.
            return .ack(AckEvent(ackedMessageId: m.epochId))
        default:
            return nil
        }
    }

    var hasEphemeralKeys: Bool { eph != nil }

    // Pair-ack helpers (single-shot, uses receive/send key directly)
    static func sealPairAck(_ body: PairAckBody, keys: SessionKeys) throws -> (nonce: Data, ciphertext: Data) {
        let box = try ChaChaPoly.seal(try PayloadCodec.encode(body), using: keys.sendKey)
        return (Data(box.nonce), box.ciphertext + box.tag)
    }

    static func openPairAck(_ env: PairAckEnvelope, keys: SessionKeys) throws -> PairAckBody {
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: env.nonce),
                                           ciphertext: env.ciphertext.dropLast(16),
                                           tag: env.ciphertext.suffix(16))
        let body = try PayloadCodec.decode(PairAckBody.self, from: ChaChaPoly.open(box, using: keys.receiveKey))
        guard body.sessionId == env.sessionId else { throw SecureChannelError.malformed }
        return body
    }
}

// MARK: - Keychain

enum Keychain {
    /// One keychain namespace per app identity, so a second copy of the app (a test or screenshot build) can never touch another one's keys.
    private static let service = Bundle.main.bundleIdentifier ?? "dev.phonepigeon.mac"

    static func data(for account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    /// Long-term Curve25519 identity for this Mac (spec §5.1 step 1).
    static func macIdentity() -> Curve25519.KeyAgreement.PrivateKey {
        if let raw = data(for: "mac-x25519-identity"),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        set(key.rawRepresentation, for: "mac-x25519-identity")
        return key
    }

    static func rotateMacIdentity() {
        delete("mac-x25519-identity")
    }

    /// Symmetric key protecting the on-disk store (stand-in for SQLCipher).
    static func storageKey() -> SymmetricKey {
        if let raw = data(for: "local-store-key"), raw.count == 32 { return SymmetricKey(data: raw) }
        let key = SymmetricKey(size: .bits256)
        set(key.withUnsafeBytes { Data($0) }, for: "local-store-key")
        return key
    }

    static func macDeviceId() -> String {
        if let raw = data(for: "mac-device-id"), let s = String(data: raw, encoding: .utf8) { return s }
        let id = UUID().uuidString.lowercased()
        set(Data(id.utf8), for: "mac-device-id")
        return id
    }
}

/// Tiny event trace (no message content, no keys) in the app's temp folder; used to verify protocol steps in tests.
nonisolated enum Trace {
    static func log(_ line: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phonepigeon-trace.log")
        let entry = "\(ISO8601DateFormatter().string(from: .now)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(entry.utf8)) }
        else { try? Data(entry.utf8).write(to: url) }
    }
}
