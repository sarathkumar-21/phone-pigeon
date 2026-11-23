import Foundation
import Network

/// Local-network transport (spec §2, priority 1).
///
/// The Mac is the LAN server: it listens on TCP (port 8443 when free) and
/// advertises `_pigeonmac._tcp` with a `device_id` TXT record. The phone finds it
/// via NSD — or uses the `lan_host` from the pairing QR — and keeps one socket open.
///
/// Frames are 4-byte big-endian length-prefixed JSON. Everything inside is an
/// E2EE envelope (ChaCha20-Poly1305 with routing header as AAD + replay guard),
/// so the socket itself carries no plaintext. Improvisation over certificate
/// mutual-TLS: authentication comes from the pairing keys — a connection only
/// becomes the trusted peer after it delivers a frame that decrypts.
final class LANServer {
    var onStateChange: ((TransportLinkState) -> Void)?
    /// Fired whenever a phone becomes (or stops being) an authenticated peer.
    var onPeersChanged: (() -> Void)?
    /// Frame plus the connection it arrived on, so the caller can `trust` it once verified.
    var onFrameFrom: ((WireFrame, ObjectIdentifier) -> Void)?
    private(set) var state: TransportLinkState = .idle { didSet { if state != oldValue { onStateChange?(state) } } }
    private(set) var port: UInt16?

    private let deviceId: String
    private let serviceName: String
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Peer] = [:]
    /// Authenticated phones: Android device id → the connection that proved it holds that phone's keys.
    private var trusted: [String: ObjectIdentifier] = [:]
    private var hosts: [String: String] = [:]

    private final class Peer {
        let connection: NWConnection
        var buffer = Data()
        init(_ c: NWConnection) { connection = c }
    }

    init(deviceId: String, serviceName: String) {
        self.deviceId = deviceId
        self.serviceName = serviceName
    }

    var isListening: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
            tcp.noDelay = true
        }
        let l = (try? NWListener(using: params, on: 8443)) ?? (try? NWListener(using: params))
        guard let l else { state = .failed("Could not open a local port"); return }
        var txt = NWTXTRecord()
        txt["h"] = Crypto.mdnsTag(deviceId)
        txt["v"] = "1"
        l.service = NWListener.Service(name: serviceName, type: "_pigeonmac._tcp", txtRecord: txt)
        l.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch s {
                case .ready: self.port = self.listener?.port?.rawValue; if self.trusted.isEmpty { self.state = .connecting }
                case .failed(let e): self.state = .failed(e.localizedDescription); self.listener = nil
                default: break
                }
            }
        }
        l.newConnectionHandler = { [weak self] c in
            MainActor.assumeIsolated { self?.accept(c) }
        }
        l.start(queue: .main)
        listener = l
        state = .connecting
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.connection.cancel() }
        connections.removeAll()
        trusted = [:]
        hosts = [:]
        port = nil
        state = .idle
    }

    /// Sends to one verified phone's connection only.
    func send(_ frame: WireFrame, to deviceId: String) {
        guard let id = trusted[deviceId], let peer = connections[id], let data = try? PayloadCodec.encode(frame) else { return }
        peer.connection.send(content: Framing.frame(data), completion: .contentProcessed { _ in })
    }

    /// Answers on a specific connection even if it is not authenticated yet (used to tell a phone to resync its keys).
    func sendRaw(_ frame: WireFrame, via id: ObjectIdentifier) {
        guard let peer = connections[id], let data = try? PayloadCodec.encode(frame) else { return }
        peer.connection.send(content: Framing.frame(data), completion: .contentProcessed { _ in })
    }

    func isConnected(_ deviceId: String) -> Bool { trusted[deviceId] != nil }
    func host(for deviceId: String) -> String? { hosts[deviceId] }

    /// Marks a connection as the authenticated phone `deviceId` after one of its frames decrypted / its PairAck verified.
    func trust(_ id: ObjectIdentifier, as deviceId: String) {
        guard connections[id] != nil, trusted[deviceId] != id else { return }
        if let old = trusted[deviceId], old != id { connections[old]?.connection.cancel() } // a reconnect replaces the old socket
        trusted[deviceId] = id
        if case .hostPort(let host, _) = connections[id]?.connection.endpoint {
            hosts[deviceId] = "\(host)".replacingOccurrences(of: "::ffff:", with: "")
        }
        state = .connected
        onPeersChanged?()
    }

    // MARK: Private

    private static let maxUnauthenticated = 8
    private static let handshakeDeadline: TimeInterval = 10

    private func accept(_ c: NWConnection) {
        // Anyone on the LAN can open a socket: cap the ones that have not proven the pairing keys yet.
        let unauthenticated = connections.keys.filter { !trusted.values.contains($0) }.count
        guard unauthenticated < Self.maxUnauthenticated else { c.cancel(); return }
        let peer = Peer(c)
        let id = ObjectIdentifier(peer)
        connections[id] = peer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handshakeDeadline) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.connections[id] != nil, !self.trusted.values.contains(id) else { return }
                self.connections[id]?.connection.cancel() // never sent a frame that decrypted
            }
        }
        c.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated {
                switch s {
                case .ready: self?.receive(id)
                case .failed, .cancelled: self?.drop(id)
                default: break
                }
            }
        }
        c.start(queue: .main)
    }

    private func drop(_ id: ObjectIdentifier) {
        connections[id] = nil
        if let device = trusted.first(where: { $0.value == id })?.key {
            trusted[device] = nil
            hosts[device] = nil
            if trusted.isEmpty { state = listener == nil ? .idle : .connecting }
            onPeersChanged?()
        }
    }

    private func receive(_ id: ObjectIdentifier) {
        guard let peer = connections[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, let peer = self.connections[id] else { return }
                if let data {
                    peer.buffer.append(data)
                    let limit = self.trusted.values.contains(id) ? 16 * 1024 * 1024 : 2 * 1024 * 1024
                    if peer.buffer.count > limit { peer.connection.cancel(); return }
                    for f in Framing.drain(&peer.buffer) {
                        if f.isEmpty { // the phone's keep-alive ping: echo it so the phone can tell the link is alive
                            peer.connection.send(content: Data(count: 4), completion: .contentProcessed { _ in })
                            continue
                        }
                        guard let frame = try? PayloadCodec.decode(WireFrame.self, from: f) else { continue }
                        self.onFrameFrom?(frame, id)
                    }
                }
                if done || error != nil { peer.connection.cancel() } else { self.receive(id) }
            }
        }
    }
}
