import AppKit
import CryptoKit
import SwiftUI

struct AppSettings: Codable, Equatable {
    var notificationsEnabled = true
    var otpClearSeconds = 60
    var relayURL = "wss://relay.yourdomain.com/v1/ws"
    var lanEnabled = true
    var cloudEnabled = true
    var demoSimulateActivity = true
    var enterToSend = true
    var showSimBadges = true
    var showPhoneNotifications = true

    init() {}
    /// Settings saved by older versions lack newer keys: keep what is there and default the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        notificationsEnabled = get(.notificationsEnabled, true)
        otpClearSeconds = get(.otpClearSeconds, 60)
        relayURL = get(.relayURL, "wss://relay.yourdomain.com/v1/ws")
        lanEnabled = get(.lanEnabled, true)
        cloudEnabled = get(.cloudEnabled, true)
        demoSimulateActivity = get(.demoSimulateActivity, true)
        enterToSend = get(.enterToSend, true)
        showSimBadges = get(.showSimBadges, true)
        showPhoneNotifications = get(.showPhoneNotifications, true)
    }
    private enum CodingKeys: String, CodingKey {
        case notificationsEnabled, otpClearSeconds, relayURL, lanEnabled, cloudEnabled, demoSimulateActivity, enterToSend, showSimBadges, showPhoneNotifications
    }
}

struct Toast: Identifiable, Equatable {
    enum Style { case info, success, warning, error }
    let id = UUID()
    var message: String
    var symbol: String
    var style: Style = .info
}

struct PairingSession: Equatable {
    var sessionId: String
    var payload: PairingQRPayload
    var json: String
    var expiresAt: Date

    static func == (a: Self, b: Self) -> Bool { a.sessionId == b.sessionId }
}

@Observable
final class AppState {
    enum Section: String, Hashable, CaseIterable, Identifiable {
        case overview, messages, calls, photos, files, notifications
        var id: String { rawValue }
        /// The four tabs of spec v2 §11.1; the device overview opens from the sidebar header.
        static let tabs: [Section] = [.messages, .calls, .photos, .files, .notifications]
        var title: String {
            switch self {
            case .overview: "Overview"
            case .messages: "Messages"
            case .calls: "Calls & Dialer"
            case .photos: "Photos & Videos"
            case .files: "Files"
            case .notifications: "Notifications"
            }
        }
        var symbol: String {
            switch self {
            case .overview: "iphone.gen3"
            case .messages: "bubble.left.and.bubble.right.fill"
            case .calls: "phone.fill"
            case .photos: "photo.on.rectangle.angled"
            case .files: "folder.fill"
            case .notifications: "bell.badge.fill"
            }
        }
    }

    // Navigation (shared across phones)
    var section: Section = .overview
    var callsShowContacts = false
    var showNewMessage = false
    var dialerNumber = ""
    /// Show the pairing screen even though phones are already paired ("Add Phone…").
    var showAddPhone = false

    // Phones
    private(set) var phones: [PhoneSession] = []
    var selectedPhoneId: String?

    /// The phone whose data the main window shows.
    var current: PhoneSession? { phones.first { $0.id == selectedPhoneId } ?? phones.first }
    /// The phone that owns the call card: a ringing call first, then any active call, else the selected phone.
    var callPhone: PhoneSession? {
        phones.first { $0.activeCall?.state == .ringingIncoming } ?? phones.first { $0.activeCall != nil } ?? current
    }

    // UI feedback
    var toast: Toast?
    var pairingSession: PairingSession?
    var settings: AppSettings {
        didSet {
            saveSettings()
            if settings.demoSimulateActivity != oldValue.demoSimulateActivity {
                for p in phones { p.demo?.simulateActivity = settings.demoSimulateActivity }
            }
        }
    }

    // Shared services
    let audio = AudioRouter()
    let recorder = CallRecorder()
    @ObservationIgnored private(set) var recordingCallId: String?
    @ObservationIgnored private var recordingPhoneId: String?
    private(set) var macDeviceId = Keychain.macDeviceId()
    private(set) var macIdentity = Keychain.macIdentity()

    private let store = EncryptedStore()
    /// ONE LAN listener and ONE relay socket serve every phone (a second relay socket with the same Mac id would
    /// replace the first). Frames are routed by the sender's device id.
    private var lan: LANServer?
    private var relay: RelayTransport?

    private static let placeholderMedia = MediaClient()
    private static let placeholderScreen = ScreenMirrorSession()

    init() {        settings = (UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }) ?? AppSettings()
        let snap = store.load()
        NotificationManager.shared.appState = self
        for ps in snap.phones {
            let phone = PhoneSession(pairing: ps.pairing, snapshot: ps, host: self)
            phones.append(phone)
            phone.establish(outgoingSeq: ps.outgoingSequence, incomingSeq: ps.incomingSequence)
        }
        selectedPhoneId = snap.selectedPhoneId.flatMap { id in phones.contains { $0.id == id } ? id : nil } ?? phones.first?.id
        attachTransports()
        updateConnectionModes()
        nearby.host = self
    }

    // MARK: - Current-phone forwarders (keep the views unchanged)

    var isPaired: Bool { !phones.isEmpty }
    var pairing: PairedDevice? { current?.pairing }
    var sims: [SimCard] { current?.sims ?? [] }
    var contacts: [Contact] { current?.contacts ?? [] }
    var threads: [ChatThread] { current?.threads ?? [] }
    var calls: [CallLogEntry] { current?.calls ?? [] }
    var battery: DeviceStatusEvent? { current?.battery }
    var connection: ConnectionMode { current?.connection ?? .offline }
    var media: MediaClient { current?.media ?? Self.placeholderMedia }
    var screen: ScreenMirrorSession { current?.screen ?? Self.placeholderScreen }
    var activeCall: CallSession? { callPhone?.activeCall }
    var callSeenAt: Date {
        get { current?.callSeenAt ?? .now }
        set { current?.callSeenAt = newValue }
    }
    var selectedThreadId: String? {
        get { current?.selectedThreadId }
        set { current?.selectedThreadId = newValue }
    }
    var selectedContactId: String? {
        get { current?.selectedContactId }
        set { current?.selectedContactId = newValue }
    }
    var simFilter: Int? {
        get { current?.simFilter }
        set { current?.simFilter = newValue }
    }
    var sortedThreads: [ChatThread] { current?.sortedThreads ?? [] }
    var sortedContacts: [Contact] { current?.sortedContacts ?? [] }
    var unreadTotal: Int { current?.unreadTotal ?? 0 }
    var missedSinceSeen: Int { current?.missedSinceSeen ?? 0 }
    var defaultSmsSim: SimCard? { current?.defaultSmsSim }
    var defaultVoiceSim: SimCard? { current?.defaultVoiceSim }
    var peerFingerprint: String? { current?.peerFingerprint }
    var isDemo: Bool { current?.isDemo == true }
    var securityFingerprint: String { Crypto.fingerprint(macIdentity.publicKey.rawRepresentation) }

    // Phone notifications (current phone)
    var notifications: [PhoneNotification] { current?.notifications ?? [] }
    func appIcon(for package: String) -> NSImage? { current?.appIcons[package] }
    func dismissNotification(_ key: String) { current?.dismissNotification(key) }
    func clearNotifications() { current?.clearNotifications() }
    var notificationCount: Int { current?.notifications.count ?? 0 }

    func sim(_ id: Int?) -> SimCard? { current?.sim(id) }
    func contact(for address: String) -> Contact? { current?.contact(for: address) }
    func displayName(for address: String) -> String { current?.displayName(for: address) ?? PhoneNumber.pretty(address) }
    func thread(_ id: String?) -> ChatThread? { current?.thread(id) }

    /// The newest verification code across every phone (menu bar / quick copy).
    var latestOTP: (code: String, message: SmsMessage, sender: String)? {
        phones.compactMap { p in p.latestOTP.map { (p, $0) } }
            .max { $0.1.message.timestamp < $1.1.message.timestamp }
            .map { p, otp in (otp.code, otp.message, phones.count > 1 ? "\(otp.sender) · \(p.name)" : otp.sender) }
    }

    func phone(withId id: String?) -> PhoneSession? { phones.first { $0.id == id } }

    // Commands act on the selected phone (calls on the phone that owns the call).
    @discardableResult func send(_ body: String, to address: String, simId: Int?) -> Bool { current?.send(body, to: address, simId: simId) ?? false }
    func reply(threadId: String, body: String) { current?.reply(threadId: threadId, body: body) }
    func placeCall(_ number: String, simId: Int?) { current?.placeCall(number, simId: simId) }
    func performCallAction(_ action: CallAction, digit: String = "") { callPhone?.performCallAction(action, digit: digit) }
    func setAudioRoute(_ route: AudioRoute) { callPhone?.setAudioRoute(route) }
    func startScreenMirror() { current?.startScreenMirror() }
    func stopScreenMirror() { current?.stopScreenMirror() }
    func open(threadId: String) { current?.open(threadId: threadId) }
    func startConversation(with address: String) { current?.startConversation(with: address) }
    func markRead(threadId: String) { current?.markRead(threadId: threadId) }
    func markAllRead() { current?.markAllRead() }
    func togglePin(_ threadId: String) { current?.togglePin(threadId) }
    func deleteThread(_ threadId: String) { current?.deleteThread(threadId) }
    func setPreferredSim(_ simId: Int, for threadId: String) { current?.setPreferredSim(simId, for: threadId) }
    func setDraft(_ text: String, for threadId: String) { current?.setDraft(text, for: threadId) }
    func clearCallLog() { current?.clearCallLog() }
    func demoIncomingCall() { current?.demoIncomingCall() }
    func demoIncomingMessage() { current?.demoIncomingMessage() }
    func demoIncomingOTP() { current?.demoIncomingOTP() }

    // Phone-addressed variants for notification actions (the notification may belong to a phone that isn't selected).
    func open(phoneId: String?, threadId: String) {
        guard let p = phone(withId: phoneId) ?? current else { return }
        selectPhone(p.id)
        p.open(threadId: threadId)
    }
    func reply(phoneId: String?, threadId: String, body: String) { (phone(withId: phoneId) ?? current)?.reply(threadId: threadId, body: body) }
    func markRead(phoneId: String?, threadId: String) { (phone(withId: phoneId) ?? current)?.markRead(threadId: threadId) }
    func performCallAction(phoneId: String?, _ action: CallAction) { (phone(withId: phoneId) ?? callPhone)?.performCallAction(action) }

    func selectPhone(_ id: String) {
        guard phones.contains(where: { $0.id == id }) else { return }
        selectedPhoneId = id
        showAddPhone = false
        persist()
    }

    // MARK: - Pairing (spec §5.1)

    func beginPairing() {
        let lanServer = settings.lanEnabled ? ensureLAN() : nil
        let sessionId = UUID().uuidString.lowercased()
        var secretBytes = Data(count: 32)
        _ = secretBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let host = lanServer.flatMap { l in Self.localIPAddress().map { "\($0):\(l.port ?? 8443)" } }
        let payload = PairingQRPayload(sessionId: sessionId, macDeviceId: macDeviceId,
                                       macPubKey: macIdentity.publicKey.rawRepresentation.base64EncodedString(),
                                       relayUrl: settings.relayURL, lanHost: host, macName: Self.macName,
                                       pairingSecret: secretBytes.base64EncodedString())
        let json = (try? PayloadCodec.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        pairingSession = PairingSession(sessionId: sessionId, payload: payload, json: json, expiresAt: .now.addingTimeInterval(300))
        // The shared relay socket also announces the session so a phone off the LAN can redeem it.
        ensureRelay()?.openPairingSession(sessionId)
    }

    // MARK: Nearby pairing (no QR)

    /// A second, separate pairing session for a phone picked from the nearby list. Its secret comes from the
    /// confirmed code exchange, so the QR code on screen (and its secret) stays valid and untouched.
    var nearbySession: PairingSession?
    let nearby = NearbyPairingFlow()

    @discardableResult
    func prepareNearbyPairing(sessionId: String, secret: Data) -> PairingQRPayload {
        let lanServer = settings.lanEnabled ? ensureLAN() : nil
        let host = lanServer.flatMap { l in Self.localIPAddress().map { "\($0):\(l.port ?? 8443)" } }
        let payload = PairingQRPayload(sessionId: sessionId, macDeviceId: macDeviceId,
                                       macPubKey: macIdentity.publicKey.rawRepresentation.base64EncodedString(),
                                       relayUrl: settings.relayURL, lanHost: host, macName: Self.macName,
                                       pairingSecret: secret.base64EncodedString())
        nearbySession = PairingSession(sessionId: sessionId, payload: payload, json: "", expiresAt: .now.addingTimeInterval(180))
        ensureRelay()?.openPairingSession(sessionId)
        return payload
    }

    func clearNearbyPairing() { nearbySession = nil }

    private func pairingSession(for id: String) -> PairingSession? {
        if let s = pairingSession, s.sessionId == id { return s }
        if let s = nearbySession, s.sessionId == id { return s }
        return nil
    }

    func cancelPairing() {
        pairingSession = nil
        if showAddPhone && !phones.isEmpty { showAddPhone = false }
        releaseTransportsIfIdle()
    }

    /// Simulates the Android phone scanning the QR code.
    func pairWithDemoPhone() {
        if let existing = phones.first(where: \.isDemo) { selectPhone(existing.id); cancelPairing(); return }
        if pairingSession == nil { beginPairing() }
        guard let session = pairingSession else { return }
        do {
            let phone = try DemoPhone(macPublicKey: macIdentity.publicKey.rawRepresentation, macDeviceId: macDeviceId, sessionId: session.sessionId,
                                      pairingSecret: Data(base64Encoded: session.payload.pairingSecret) ?? Data())
            let ack = try phone.makePairAck()
            _ = completePairing(ack, transport: phone)
        } catch {
            show("Pairing failed: \(error.localizedDescription)", symbol: "xmark.octagon.fill", style: .error)
        }
    }

    /// Adds a new phone, or re-pairs an existing one that presents the same device id.
    @discardableResult
    private func completePairing(_ ack: PairAckEnvelope, transport: DemoPhone?) -> PhoneSession? {
        guard let session = pairingSession(for: ack.sessionId), session.expiresAt > .now else { return nil }
        do {
            let keys = try SessionKeys.derive(privateKey: macIdentity, peerPublicKey: ack.androidPubKey, sessionId: ack.sessionId, role: .mac)
            let body = try SecureChannel.openPairAck(ack, keys: keys)
            // The relay sees the session id but not the secret in the QR, so only the scanning phone can produce this proof.
            guard let secret = Data(base64Encoded: session.payload.pairingSecret), let proof = Data(base64Encoded: body.proof),
                  Crypto.verifyPairProof(proof, secret: secret, sessionId: ack.sessionId, phonePub: ack.androidPubKey,
                                         macPub: macIdentity.publicKey.rawRepresentation) else {
                NSLog("PhonePigeon: rejected a pairing request with an invalid proof")
                return nil
            }
            let device = PairedDevice(androidDeviceId: ack.androidDeviceId, macDeviceId: macDeviceId, deviceName: body.deviceName,
                                      manufacturer: body.manufacturer, osVersion: body.osVersion, androidPublicKey: ack.androidPubKey,
                                      sessionId: ack.sessionId, pairedAt: .now, isDemo: transport != nil)
            let phone: PhoneSession
            if let existing = phones.first(where: { $0.id == device.androidDeviceId }) {
                existing.shutdown()          // new keys: drop the old channel, keep the history
                existing.pairing = device
                phone = existing
            } else {
                phone = PhoneSession(pairing: device, host: self)
                phones.append(phone)
            }
            phone.demo = transport
            if pairingSession?.sessionId == ack.sessionId { pairingSession = nil }   // one-shot: the next phone needs a new code
            if nearbySession?.sessionId == ack.sessionId { nearbySession = nil; nearby.completed() }
            phone.establish(outgoingSeq: 0, incomingSeq: 0)
            if transport == nil { attachTransports() }
            if transport != nil {
                transport?.sendHistory()
                phone.seedDemoCallLog()
            }
            selectedPhoneId = phone.id
            showAddPhone = false
            persist()
            if transport == nil { offerToRemoveDuplicates(of: phone) }
            updateConnectionModes()
            withAnimation(.spring(duration: 0.5)) { section = .overview }
            show("Paired with \(body.deviceName)", symbol: "checkmark.seal.fill", style: .success)
            return phone
        } catch {
            show("Could not verify phone: \(error.localizedDescription)", symbol: "exclamationmark.shield.fill", style: .error)
            return nil
        }
    }

    /// Reinstalling the Android app gives the phone a new identity, which shows up here as a second copy of the same phone.
    private func offerToRemoveDuplicates(of phone: PhoneSession) {
        let stale = phones.filter { $0.id != phone.id && !$0.isDemo && $0.pairing.deviceName == phone.pairing.deviceName &&
                                    $0.pairing.manufacturer == phone.pairing.manufacturer && $0.connection != .demo }
        guard !stale.isEmpty else { return }
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Remove the old “\(phone.name)”?"
            alert.informativeText = stale.count == 1
                ? "You already had a phone with this name. If it's the same phone after reinstalling the app, the old entry can't connect any more. Removing it also deletes its saved messages on this Mac."
                : "You already had \(stale.count) phones with this name. If they are the same phone after reinstalling the app, the old entries can't connect any more. Removing them also deletes their saved messages on this Mac."
            alert.addButton(withTitle: "Remove Old")
            alert.addButton(withTitle: "Keep Both")
            if alert.runModal() == .alertFirstButtonReturn { stale.forEach { removePhone($0.id) } }
        }
    }

    /// Phones that are not connected right now, other than the one on screen (old pairings, test phones).
    var offlinePhones: [PhoneSession] {
        phones.filter { $0.id != current?.id && $0.connection == .offline }
    }

    func removeOfflinePhones() {
        let list = offlinePhones
        guard !list.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(list.count) offline phone\(list.count == 1 ? "" : "s")?"
        alert.informativeText = list.map(\.name).joined(separator: ", ") + "\n\nTheir saved messages on this Mac are deleted too. They can be paired again at any time."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { list.forEach { removePhone($0.id) } }
    }

    /// Removes the selected phone.
    func unpair() { if let id = current?.id { removePhone(id) } }

    /// Asks before removing, because it also deletes that phone's saved messages on this Mac.
    func confirmRemovePhone(_ id: String) {
        guard let phone = phones.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(phone.name)”?"
        alert.informativeText = phone.isDemo
            ? "The demo phone and its sample data are removed."
            : "Its saved messages, calls and contacts on this Mac are deleted, and it stops connecting. You can pair it again at any time."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { removePhone(id) }
    }

    func removePhone(_ id: String) {
        guard let i = phones.firstIndex(where: { $0.id == id }) else { return }
        let phone = phones.remove(at: i)
        if phone.isDemo { DemoPhone.resetIdentity() }
        if recordingPhoneId == id, recorder.isRecording { Task { await finishRecording() } }
        phone.shutdown()
        if selectedPhoneId == id { selectedPhoneId = phones.first?.id }
        showAddPhone = false
        section = .overview
        releaseTransportsIfIdle()
        if phones.isEmpty { store.wipe() } else { persist() }
        updateConnectionModes()
    }

    func rotateIdentity() {
        for p in phones { removePhone(p.id) }
        lan?.stop(); relay?.stop(); lan = nil; relay = nil
        Keychain.rotateMacIdentity()
        macIdentity = Keychain.macIdentity()
        // The relay binds device_id ↔ public key; a new key needs a new device id.
        Keychain.delete("mac-device-id")
        macDeviceId = Keychain.macDeviceId()
        show("New encryption identity generated", symbol: "key.fill", style: .success)
    }

    // MARK: - Shared transports

    /// The relay URL shipped in settings is a placeholder until a server is deployed.
    private var relayConfigured: Bool {
        settings.cloudEnabled && !settings.relayURL.contains("yourdomain") && URL(string: settings.relayURL) != nil
    }

    static var macName: String { Host.current().localizedName ?? "Mac" }

    /// The Mac is the LAN server (Bonjour `_pigeonmac._tcp`); used for pairing and for every phone's session.
    @discardableResult
    private func ensureLAN() -> LANServer {
        if let lan { lan.start(); return lan }
        let l = LANServer(deviceId: macDeviceId, serviceName: "PhonePigeon · \(Self.macName)")
        l.onFrameFrom = { [weak self] frame, id in self?.handleLAN(frame, from: id) }
        l.onStateChange = { [weak self] _ in self?.lanStateChanged() }
        l.onPeersChanged = { [weak self] in self?.updateConnectionModes() }
        lan = l
        l.start()
        return l
    }

    @discardableResult
    private func ensureRelay() -> RelayTransport? {
        guard relayConfigured, let url = URL(string: settings.relayURL) else { return nil }
        if let relay { return relay }
        let r = RelayTransport(wsURL: url, deviceId: macDeviceId, identity: macIdentity)
        r.onFrame = { [weak self] in self?.handleRelay($0) }
        r.onStateChange = { [weak self] _ in self?.updateConnectionModes() }
        relay = r
        r.start()
        return r
    }

    /// Starts the shared sockets when at least one real (non-demo) phone is paired.
    private func attachTransports() {
        guard phones.contains(where: { !$0.isDemo }) else { return }
        if settings.lanEnabled { ensureLAN() }
        ensureRelay()
    }

    private func releaseTransportsIfIdle() {
        guard pairingSession == nil, !phones.contains(where: { !$0.isDemo }) else { return }
        lan?.stop(); relay?.stop()
        lan = nil; relay = nil
    }

    @ObservationIgnored private var lastResync: [ObjectIdentifier: Date] = [:]

    private func handleLAN(_ frame: WireFrame, from id: ObjectIdentifier) {
        switch frame {
        case .pairAck(let ack):
            if let phone = completePairing(ack, transport: nil) {
                lan?.trust(id, as: phone.id)
                // Encrypted confirmation: proves to the phone that this Mac derived the same keys.
                phone.transmit(.ack(AckEvent(ackedMessageId: ack.sessionId)))
            }
        case .envelope(let env):
            guard let phone = phone(withId: env.senderDeviceId) else { return } // not one of our phones
            if phone.receive(frame) {
                lan?.trust(id, as: phone.id)
                phone.maybeRekey() // the first frame on a connection arrives before it is trusted, so a request sent from `receive` would be dropped
            } else if lan?.isConnected(phone.id) != true, let reply = phone.resyncFrame(),
                      Date().timeIntervalSince(lastResync[id] ?? .distantPast) > 5 {
                // This phone is talking under keys we no longer have (we restarted): tell it, instead of waiting minutes.
                lastResync[id] = .now
                lan?.sendRaw(reply, via: id)
            }
        case .ack:
            break
        }
    }

    private func handleRelay(_ frame: WireFrame) {
        switch frame {
        case .pairAck(let ack):
            if let phone = completePairing(ack, transport: nil) {
                phone.transmit(.ack(AckEvent(ackedMessageId: ack.sessionId))) // encrypted confirmation back over the relay
            }
        case .envelope(let env):
            phone(withId: env.senderDeviceId)?.receive(frame)
        case .ack:
            break
        }
    }

    private func lanStateChanged() {
        // If port 8443 was busy the listener picked another one — refresh the QR code.
        if let s = pairingSession, let port = lan?.port, let host = s.payload.lanHost, !host.hasSuffix(":\(port)") {
            beginPairing()
        }
        updateConnectionModes()
    }

    func reconnect() {
        guard phones.contains(where: { !$0.isDemo }) else { return }
        lan?.stop(); relay?.stop()
        lan = nil; relay = nil
        attachTransports()
        updateConnectionModes()
    }

    func linkConnected(for phone: PhoneSession) -> Bool {
        phone.isDemo || lan?.isConnected(phone.id) == true || relay?.state == .connected
    }

    func updateConnectionModes() {
        for p in phones {
            let old = p.connection
            let new: ConnectionMode
            if let d = p.demo { new = d.state == .connected ? .demo : (d.state == .connecting ? .connecting : .offline) }
            else if let lan, lan.isConnected(p.id) { new = .lan(host: lan.host(for: p.id) ?? "LAN") }
            else if let relay, relay.state == .connected { new = .cloud }
            else if lan?.state == .connecting || relay?.state == .connecting { new = .connecting }
            else { new = .offline }
            guard new != old else { continue }
            p.connection = new
            if case .lan = new { show("\(p.name) connected over Wi-Fi", symbol: "wifi", style: .success) }
        }
    }

    /// LAN first, cloud relay as fallback (spec §2 transport modes).
    func sendFrame(_ frame: WireFrame, for phone: PhoneSession) {
        if let demo = phone.demo { demo.send(frame) }
        else if let lan, lan.isConnected(phone.id) { lan.send(frame, to: phone.id) }
        else if let relay { relay.send(frame) } // relay queues + FCM-wakes the phone when it's offline
    }

    // MARK: - Call recording (Mac side; one recording at a time)

    func toggleRecording() {
        guard let phone = callPhone, let call = phone.activeCall else { return }
        if recorder.isRecording { Task { await finishRecording() }; return }
        guard call.state == .active else { show("Start recording once the call is answered.", symbol: "record.circle", style: .warning); return }
        guard call.audioOnMac else {
            show("Move the call audio to your Mac to record it — Android doesn't allow recording on the phone.", symbol: "record.circle", style: .warning)
            return
        }
        guard Self.confirmRecordingConsent() else { return }
        Task {
            do {
                try await recorder.start(label: call.title)
                recordingCallId = call.id
                recordingPhoneId = phone.id
                if recorder.includesCaller {
                    show("Recording this call", symbol: "record.circle.fill", style: .success)
                } else {
                    show("Recording your voice only. Allow Screen & System Audio Recording for PhonePigeon in System Settings to capture the caller too.",
                         symbol: "mic.fill", style: .warning)
                }
            } catch {
                show(error.localizedDescription, symbol: "xmark.octagon.fill", style: .error)
            }
        }
    }

    /// Called by a phone when one of its calls ends.
    func callEnded(phone: PhoneSession, callId: String) {
        if recorder.isRecording, recordingCallId == callId, recordingPhoneId == phone.id { Task { await finishRecording() } }
    }

    private func finishRecording() async {
        let callId = recordingCallId, phoneId = recordingPhoneId
        recordingCallId = nil; recordingPhoneId = nil
        do {
            let url = try await recorder.stop()
            if let callId, let phone = phone(withId: phoneId) { phone.attachRecording(callId: callId, path: url.path) }
            persist()
            show("Recording saved to Music › PhonePigeon Recordings", symbol: "waveform.circle.fill", style: .success)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            show(error.localizedDescription, symbol: "xmark.octagon.fill", style: .error)
        }
    }

    /// Recording a call can need everyone's consent; ask once and make the choice explicit.
    private static func confirmRecordingConsent() -> Bool {
        let key = "recordingConsentAcknowledged"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let alert = NSAlert()
        alert.messageText = "Record this call?"
        alert.informativeText = "Laws about recording calls differ by country and state, and many require everyone on the call to agree. PhonePigeon does not tell the other person. Only record when you are allowed to."
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    // MARK: - Feedback & persistence

    func show(_ message: String, symbol: String, style: Toast.Style = .info) {
        let t = Toast(message: message, symbol: symbol, style: style)
        withAnimation(.spring(duration: 0.4)) { toast = t }
        Task {
            try? await Task.sleep(for: .seconds(3.2))
            if toast?.id == t.id { withAnimation(.easeOut(duration: 0.3)) { toast = nil } }
        }
    }

    func persist() {
        store.save(AppSnapshot(phones: phones.map { $0.snapshot() }, selectedPhoneId: selectedPhoneId))
    }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    static func localIPAddress() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: iface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            addr = String(cString: host)
        }
        return addr
    }
}
