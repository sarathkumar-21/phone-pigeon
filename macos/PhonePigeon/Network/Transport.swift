import Foundation

/// Frames exchanged over both the cloud WebSocket and the LAN socket.
enum WireFrame: Codable, Sendable {
    case envelope(EncryptedEnvelope)
    case pairAck(PairAckEnvelope)
    case ack(String)

    private enum CodingKeys: String, CodingKey { case envelope, pairAck, ack }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let e = try c.decodeIfPresent(EncryptedEnvelope.self, forKey: .envelope) { self = .envelope(e); return }
        if let p = try c.decodeIfPresent(PairAckEnvelope.self, forKey: .pairAck) { self = .pairAck(p); return }
        self = .ack(try c.decode(String.self, forKey: .ack))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .envelope(let e): try c.encode(e, forKey: .envelope)
        case .pairAck(let p): try c.encode(p, forKey: .pairAck)
        case .ack(let id): try c.encode(id, forKey: .ack)
        }
    }
}

enum TransportLinkState: Equatable {
    case idle, connecting, connected, failed(String)
}

/// Moves opaque frames. Encryption lives one layer up in `SecureChannel`.
protocol FrameTransport: AnyObject {
    var onFrame: ((WireFrame) -> Void)? { get set }
    var onStateChange: ((TransportLinkState) -> Void)? { get set }
    var state: TransportLinkState { get }
    func start()
    func stop()
    func send(_ frame: WireFrame)
}

// MARK: - Length-prefixed framing (LAN)

enum Framing {
    static func frame(_ payload: Data) -> Data {
        var len = UInt32(payload.count).bigEndian
        return Data(bytes: &len, count: 4) + payload
    }

    /// Extracts complete frames from `buffer`, leaving any partial frame in place.
    static func drain(_ buffer: inout Data) -> [Data] {
        var out: [Data] = []
        while buffer.count >= 4 {
            let len = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard buffer.count >= 4 + Int(len) else { break }
            out.append(buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + Int(len)))
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + Int(len))
        }
        return out
    }
}
