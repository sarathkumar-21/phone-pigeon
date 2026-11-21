import CryptoKit
import Foundation

/// A virtual dual-SIM Android phone that speaks the real protocol.
///
/// It owns its own X25519 identity, derives the Android-side session keys and
/// exchanges genuine ChaCha20-Poly1305 envelopes with the Mac, so the full E2EE
/// pipeline is exercised end-to-end without hardware.
final class DemoPhone: FrameTransport {
    var onFrame: ((WireFrame) -> Void)?
    var onStateChange: ((TransportLinkState) -> Void)?
    private(set) var state: TransportLinkState = .idle { didSet { if state != oldValue { onStateChange?(state) } } }

    let androidDeviceId: String
    let publicKey: Data
    private let sessionId: String
    private let pairingSecret: Data
    private let macPublicKey: Data
    private let channel: SecureChannel
    private let keys: SessionKeys
    private var timers: [Task<Void, Never>] = []
    private var battery = DeviceStatusEvent(batteryPercent: 82, isCharging: false, bluetoothHfpConnected: true,
                                            storageFreeBytes: 71_400_000_000, storageTotalBytes: 128_000_000_000)
    private var calls: [String: CallStateEvent] = [:]
    var simulateActivity = true

    static let sims: [SimCardWire] = [
        SimCardWire(subscriptionId: 1, slotIndex: 0, carrierName: "Jio 5G", displayName: "Personal",
                    phoneNumber: "+919876543210", accentColorHex: "#3B6CFF", isDefaultSms: true, isDefaultVoice: true),
        SimCardWire(subscriptionId: 2, slotIndex: 1, carrierName: "Airtel", displayName: "Work",
                    phoneNumber: "+919812345678", accentColorHex: "#FF5B3A", isDefaultSms: false, isDefaultVoice: false),
    ]

    static let contacts: [ContactEntry] = [
        ContactEntry(contactId: "c1", displayName: "Ananya Rao", phoneNumbers: ["+919845012345"]),
        ContactEntry(contactId: "c2", displayName: "Rahul Menon", phoneNumbers: ["+919900112233"]),
        ContactEntry(contactId: "c3", displayName: "Mom", phoneNumbers: ["+919447001122"]),
        ContactEntry(contactId: "c4", displayName: "Priya Sharma", phoneNumbers: ["+919811223344"]),
        ContactEntry(contactId: "c5", displayName: "Arjun Nair", phoneNumbers: ["+919746556677"]),
        ContactEntry(contactId: "c6", displayName: "Dr. Meera Iyer", phoneNumbers: ["+914422334455"]),
        ContactEntry(contactId: "c7", displayName: "Kabir Singh", phoneNumbers: ["+919988776655"]),
        ContactEntry(contactId: "c8", displayName: "Sara Thomas", phoneNumbers: ["+919567889900"]),
        ContactEntry(contactId: "c9", displayName: "Office Desk", phoneNumbers: ["+918041234567"]),
    ]

    init(macPublicKey: Data, macDeviceId: String, sessionId: String, pairingSecret: Data = Data()) throws {
        self.pairingSecret = pairingSecret
        self.macPublicKey = macPublicKey
        let identity: Curve25519.KeyAgreement.PrivateKey
        if let raw = Keychain.data(for: "demo-android-identity"),
           let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            identity = k
        } else {
            identity = Curve25519.KeyAgreement.PrivateKey()
            Keychain.set(identity.rawRepresentation, for: "demo-android-identity")
        }
        androidDeviceId = Keychain.data(for: "demo-android-id").flatMap { String(data: $0, encoding: .utf8) } ?? {
            let id = UUID().uuidString.lowercased()
            Keychain.set(Data(id.utf8), for: "demo-android-id")
            return id
        }()
        publicKey = identity.publicKey.rawRepresentation
        self.sessionId = sessionId
        keys = try SessionKeys.derive(privateKey: identity, peerPublicKey: macPublicKey, sessionId: sessionId, role: .android)
        // Time-based sequence start keeps sequence numbers monotonic across app launches.
        channel = SecureChannel(keys: keys, role: .android, sessionId: sessionId, localDeviceId: androidDeviceId, peerDeviceId: macDeviceId,
                                outgoingSequence: UInt64(Date().timeIntervalSince1970 * 1000))
    }

    static func resetIdentity() {
        Keychain.delete("demo-android-identity")
        Keychain.delete("demo-android-id")
    }

    /// The signed/encrypted handshake message Android sends after scanning the QR.
    func makePairAck() throws -> PairAckEnvelope {
        let proof = Crypto.pairProof(secret: pairingSecret, sessionId: sessionId, phonePub: publicKey, macPub: macPublicKey)
        let body = PairAckBody(sessionId: sessionId, deviceName: "Pixel 9 Pro", manufacturer: "Google", osVersion: "Android 16",
                               proof: proof.base64EncodedString())
        let sealed = try SecureChannel.sealPairAck(body, keys: keys)
        return PairAckEnvelope(sessionId: sessionId, androidDeviceId: androidDeviceId, androidPubKey: publicKey,
                               nonce: sealed.nonce, ciphertext: sealed.ciphertext)
    }

    // MARK: FrameTransport

    func start() {
        state = .connecting
        after(0.6) { [weak self] in
            guard let self else { return }
            self.state = .connected
            self.emit(.simInventory(SimInventorySync(sims: Self.sims)))
            self.emit(.contactSync(ContactSyncBatch(contacts: Self.contacts, isFinalBatch: true)))
            self.emit(.deviceStatus(self.battery))
        }
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.tickBattery()
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 70...140)))
                guard let self, self.simulateActivity else { continue }
                Bool.random() ? self.simulateIncomingMessage() : self.simulateIncomingOTP()
            }
        })
    }

    func stop() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
        state = .idle
    }

    func send(_ frame: WireFrame) {
        guard case .envelope(let env) = frame, let payload = try? channel.open(env) else { return }
        // Small network latency for realism.
        after(0.15) { [weak self] in self?.handle(payload.body) }
    }

    /// Initial history sync, sent once right after pairing.
    func sendHistory() {
        emit(.smsThreadSync(SmsThreadSync(messages: Self.history(), hasMore: false)))
    }

    // MARK: Simulation hooks

    func simulateIncomingCall() {
        let contact = Self.contacts.randomElement()!
        let sim = Self.sims.randomElement()!
        let call = CallStateEvent(callId: UUID().uuidString, subscriptionId: sim.subscriptionId,
                                  remoteAddress: contact.phoneNumbers[0], contactName: contact.displayName,
                                  state: .ringingIncoming, audioRoute: .mac, startedAtMs: 0, isMuted: false)
        calls[call.callId] = call
        emit(.callState(call))
        // Ring for 25s, then give up (missed call).
        after(25) { [weak self] in
            guard let self, var c = self.calls[call.callId], c.state == .ringingIncoming else { return }
            c.state = .disconnected
            self.calls[call.callId] = nil
            self.emit(.callState(c))
        }
    }

    func simulateIncomingMessage() {
        let pool: [(String, String)] = [
            ("+919845012345", "Are we still on for dinner tonight? 🍝"),
            ("+919900112233", "Pushed the build — can you take a look when free?"),
            ("+919447001122", "Did you eat? Call me when you're done with work."),
            ("+919811223344", "Sending the slides in 10 mins!"),
            ("+919746556677", "Match at 7. Bringing snacks 🏏"),
            ("+919567889900", "Landed safely ✈️"),
        ]
        let (addr, body) = pool.randomElement()!
        incoming(address: addr, body: body, sim: Self.sims.randomElement()!.subscriptionId)
    }

    func simulateIncomingOTP() {
        let code = String(Int.random(in: 100_000...999_999))
        let pool = [
            ("AX-HDFCBK", "\(code) is your OTP for txn of INR 2,499.00 at AMAZON. Valid for 5 mins. Do not share it with anyone."),
            ("VM-GOOGLE", "G-\(code) is your Google verification code."),
            ("JD-SWIGGY", "Your Swiggy login code is \(code). Happy ordering!"),
        ]
        let (addr, body) = pool.randomElement()!
        incoming(address: addr, body: body, sim: 1)
    }

    // MARK: Private

    private func handle(_ body: PayloadBody) {
        switch body {
        case .sendSms(let cmd):
            emit(.smsStatus(SmsStatusUpdate(clientRequestId: cmd.clientRequestId, status: .sent, errorReason: "")))
            after(1.4) { [weak self] in
                self?.emit(.smsStatus(SmsStatusUpdate(clientRequestId: cmd.clientRequestId, status: .delivered, errorReason: "")))
            }
            if let reply = Self.autoReply(to: cmd.recipientAddress) {
                after(Double.random(in: 4...8)) { [weak self] in
                    self?.incoming(address: cmd.recipientAddress, body: reply, sim: cmd.subscriptionId)
                }
            }
        case .placeCall(let cmd):
            let name = Self.contacts.first { $0.phoneNumbers.contains(PhoneNumber.normalize(cmd.phoneNumber)) }?.displayName ?? ""
            var call = CallStateEvent(callId: cmd.requestId, subscriptionId: cmd.subscriptionId,
                                      remoteAddress: cmd.phoneNumber, contactName: name,
                                      state: .dialingOutgoing, audioRoute: cmd.routeAudioToMac ? .mac : .earpiece, startedAtMs: 0, isMuted: false)
            calls[call.callId] = call
            emit(.callState(call))
            after(3) { [weak self] in
                guard let self, self.calls[call.callId]?.state == .dialingOutgoing else { return }
                call.state = .active
                call.startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                self.calls[call.callId] = call
                self.emit(.callState(call))
            }
        case .callAction(let cmd):
            guard var call = calls[cmd.callId] else { return }
            switch cmd.action {
            case .answer:
                call.state = .active
                call.startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            case .reject, .endCall:
                call.state = .disconnected
            case .toggleMute:
                call.isMuted.toggle()
            case .sendDtmf:
                return
            case .switchAudioRoute:
                call.audioRoute = cmd.targetAudioRoute
            }
            calls[cmd.callId] = call.state == .disconnected ? nil : call
            emit(.callState(call))
        case .listDirReq(let req):
            emit(.listDirRes(DemoMediaStore.shared.list(req)))
        case .listGalleryReq(let req):
            emit(.listGalleryRes(DemoMediaStore.shared.gallery(req)))
        case .fileOpReq(let req):
            emit(.fileOpRes(DemoMediaStore.shared.apply(req)))
        default:
            break
        }
    }

    private func incoming(address: String, body: String, sim: Int) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        emit(.smsMessage(SmsMessageEvent(localId: UUID().uuidString, threadId: PhoneNumber.threadId(for: address),
                                         subscriptionId: sim, address: address, body: body, direction: .incoming,
                                         status: .delivered, timestampMs: now, isRead: false)))
    }

    private func tickBattery() {
        if battery.isCharging {
            battery.batteryPercent = min(100, battery.batteryPercent + 2)
            if battery.batteryPercent == 100 { battery.isCharging = false }
        } else {
            battery.batteryPercent = max(5, battery.batteryPercent - 1)
            if battery.batteryPercent <= 20 { battery.isCharging = true }
        }
        emit(.deviceStatus(battery))
    }

    private func emit(_ body: PayloadBody) {
        guard state == .connected || state == .connecting, let env = try? channel.seal(body) else { return }
        onFrame?(.envelope(env))
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    private static func autoReply(to address: String) -> String? {
        let replies = ["Sounds good 👍", "On it!", "Haha yes", "Give me 5 mins", "Perfect, thanks!", "Will call you back shortly", "❤️"]
        return contacts.contains { $0.phoneNumbers.contains(PhoneNumber.normalize(address)) } ? replies.randomElement() : nil
    }

    private static func history() -> [SmsMessageEvent] {
        let now = Date().timeIntervalSince1970
        func msg(_ addr: String, _ body: String, _ dir: MessageDirection, minutesAgo: Double, sim: Int, read: Bool = true) -> SmsMessageEvent {
            SmsMessageEvent(localId: UUID().uuidString, threadId: PhoneNumber.threadId(for: addr), subscriptionId: sim,
                            address: addr, body: body, direction: dir, status: .delivered,
                            timestampMs: Int64((now - minutesAgo * 60) * 1000), isRead: read)
        }
        return [
            msg("+919845012345", "Hey! Landed in Bangalore 🛬", .incoming, minutesAgo: 60 * 26, sim: 1),
            msg("+919845012345", "Welcome back! Coffee tomorrow?", .outgoing, minutesAgo: 60 * 26 - 3, sim: 1),
            msg("+919845012345", "Absolutely. Third Wave at 10?", .incoming, minutesAgo: 60 * 26 - 5, sim: 1),
            msg("+919845012345", "See you there ☕️", .outgoing, minutesAgo: 60 * 26 - 6, sim: 1),
            msg("+919845012345", "Also — can you send me the photos from Coorg when you get a sec?", .incoming, minutesAgo: 18, sim: 1, read: false),

            msg("+919900112233", "Standup moved to 11:30 today", .incoming, minutesAgo: 60 * 5, sim: 2),
            msg("+919900112233", "Noted, thanks", .outgoing, minutesAgo: 60 * 5 - 2, sim: 2),
            msg("+919900112233", "PR for the relay hub is up. Mind reviewing before EOD?", .incoming, minutesAgo: 42, sim: 2, read: false),

            msg("+919447001122", "Did you reach home?", .incoming, minutesAgo: 60 * 30, sim: 1),
            msg("+919447001122", "Yes Amma, just now. Will call after dinner", .outgoing, minutesAgo: 60 * 30 - 4, sim: 1),
            msg("+919447001122", "Okay. Eat properly! 🙂", .incoming, minutesAgo: 60 * 30 - 6, sim: 1),

            msg("AX-HDFCBK", "INR 1,250.00 debited from A/c XX4821 on 19-Nov at BLUE TOKAI. Avl bal INR 48,302.11", .incoming, minutesAgo: 60 * 20, sim: 1),
            msg("AX-HDFCBK", "482913 is your OTP for txn of INR 3,999.00 at FLIPKART. Valid for 5 mins. Do not share it with anyone.", .incoming, minutesAgo: 7, sim: 1, read: false),

            msg("+919811223344", "Deck looks great. Minor tweak on slide 6", .incoming, minutesAgo: 60 * 52, sim: 2),
            msg("+919811223344", "Fixed! Sending v3 now", .outgoing, minutesAgo: 60 * 51, sim: 2),

            msg("+919746556677", "Football on Saturday?", .incoming, minutesAgo: 60 * 72, sim: 1),
            msg("+919746556677", "I'm in ⚽️", .outgoing, minutesAgo: 60 * 71, sim: 1),

            msg("VM-AIRTEL", "Your Airtel bill of Rs 599 is due on 25-Nov. Pay via Airtel Thanks app to avoid late fee.", .incoming, minutesAgo: 60 * 9, sim: 2),
            msg("+919567889900", "Boarding now, see you Sunday!", .incoming, minutesAgo: 60 * 100, sim: 1),
        ]
    }
}
