import AppKit
import SwiftUI

/// Everything that belongs to ONE paired phone: its synced data, its end-to-end encrypted channel, its media
/// client and screen-mirror state. `AppState` owns any number of these and shares one LAN listener and one
/// relay socket between them, routing frames by the sender's device id.
@Observable
final class PhoneSession: Identifiable {
    var id: String { pairing.androidDeviceId }
    var pairing: PairedDevice

    var notifications: [PhoneNotification] = []
    var appIcons: [String: NSImage] = [:]
    private(set) var sims: [SimCard] = []
    private(set) var contacts: [Contact] = []
    private(set) var threads: [ChatThread] = []
    private(set) var calls: [CallLogEntry] = []
    private(set) var battery: DeviceStatusEvent?
    var connection: ConnectionMode = .offline
    var activeCall: CallSession?
    var callSeenAt: Date = .now

    // Per-phone navigation state, so switching phones returns you to where you were.
    var selectedThreadId: String?
    var selectedContactId: String?
    var simFilter: Int?

    /// Sorted once per contact sync (a locale-aware sort per keystroke in the compose box was noticeable).
    private(set) var sortedContacts: [Contact] = []

    let media = MediaClient()
    let screen = ScreenMirrorSession()
    private(set) var sessionKeys: SessionKeys?

    @ObservationIgnored weak var host: AppState?
    @ObservationIgnored private(set) var channel: SecureChannel?
    @ObservationIgnored var demo: DemoPhone?
    @ObservationIgnored private var rekeyTask: Task<Void, Never>?
    @ObservationIgnored private var screenWindow: ScreenWindowController?
    @ObservationIgnored private var screenStream: ScreenStream?
    @ObservationIgnored private var contactIndex: [String: Contact] = [:]
    @ObservationIgnored private var seenDedup: Set<String> = []
    @ObservationIgnored private var rejectedCallIds: Set<String> = []
    @ObservationIgnored private var answeredCallIds: Set<String> = []

    init(pairing: PairedDevice, snapshot: PhoneSnapshot? = nil, host: AppState) {
        self.pairing = pairing
        self.host = host
        if let s = snapshot {
            sims = s.sims; contacts = s.contacts; threads = s.threads; calls = s.calls; battery = s.battery
            if let seen = s.callSeenAt { callSeenAt = seen }
        }
        rebuildIndexes()
    }

    func snapshot() -> PhoneSnapshot {
        var s = PhoneSnapshot(pairing: pairing)
        s.sims = sims; s.contacts = contacts; s.threads = threads; s.calls = calls; s.battery = battery
        s.outgoingSequence = channel?.outgoingSequence ?? 0
        s.incomingSequence = channel?.highestIncomingSequence ?? 0
        s.callSeenAt = callSeenAt
        return s
    }

    var isDemo: Bool { pairing.isDemo }
    var name: String { pairing.deviceName }
    var peerFingerprint: String { Crypto.fingerprint(pairing.androidPublicKey) }

    // MARK: - Derived

    var sortedThreads: [ChatThread] {
        threads.sorted { ($0.isPinned ? 1 : 0, $0.lastTimestamp) > ($1.isPinned ? 1 : 0, $1.lastTimestamp) }
    }
    var unreadTotal: Int { threads.reduce(0) { $0 + $1.unreadCount } }
    var missedSinceSeen: Int { calls.filter { $0.direction == .missed && $0.startedAt > callSeenAt }.count }
    var defaultSmsSim: SimCard? { sims.first(where: \.isDefaultSms) ?? sims.first }
    var defaultVoiceSim: SimCard? { sims.first(where: \.isDefaultVoice) ?? sims.first }

    func sim(_ id: Int?) -> SimCard? { sims.first { $0.subscriptionId == id } }
    func contact(for address: String) -> Contact? { contactIndex[PhoneNumber.normalize(address)] }
    func displayName(for address: String) -> String { contact(for: address)?.displayName ?? PhoneNumber.pretty(address) }
    func thread(_ id: String?) -> ChatThread? { threads.first { $0.threadId == id } }

    var latestOTP: (code: String, message: SmsMessage, sender: String)? {
        let cutoff = Date().addingTimeInterval(-15 * 60)
        for t in sortedThreads {
            for m in t.messages.reversed() where m.direction == .incoming && m.timestamp > cutoff {
                if let code = OTPDetector.detect(in: m.body) { return (code, m, t.title) }
            }
        }
        return nil
    }

    // MARK: - Session & transport glue

    /// Derives this phone's keys and channel and (for the demo phone) starts its in-process transport.
    /// LAN/relay sockets are shared and owned by `AppState`.
    func establish(outgoingSeq: UInt64, incomingSeq: UInt64) {
        guard let host else { return }
        guard let keys = try? SessionKeys.derive(privateKey: host.macIdentity, peerPublicKey: pairing.androidPublicKey,
                                                 sessionId: pairing.sessionId, role: .mac) else {
            host.show("Stored pairing keys for \(name) are invalid — please pair it again.", symbol: "key.slash", style: .error)
            return
        }
        channel = SecureChannel(keys: keys, role: .mac, sessionId: pairing.sessionId, localDeviceId: host.macDeviceId,
                                peerDeviceId: pairing.androidDeviceId, outgoingSequence: outgoingSeq, highestIncomingSequence: incomingSeq)
        sessionKeys = keys
        rekeyTask?.cancel()
        rekeyTask = Task { [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                elapsed += 20
                if elapsed >= 6 * 3600 { elapsed = 0; self?.channel?.scheduleRekey() }
                // A request can be lost (peer still starting up): retry while the link is up and no exchange has finished.
                if let self, self.host?.linkConnected(for: self) == true { self.maybeRekey() }
            }
        }
        media.send = { [weak self] body in self?.transmit(body) }
        media.demo = pairing.isDemo ? DemoMediaStore.shared : nil
        if pairing.isDemo {
            if demo == nil {
                demo = try? DemoPhone(macPublicKey: host.macIdentity.publicKey.rawRepresentation, macDeviceId: host.macDeviceId, sessionId: pairing.sessionId)
            }
            demo?.simulateActivity = host.settings.demoSimulateActivity
            demo?.onFrame = { [weak self] in self?.receive($0) }
            demo?.onStateChange = { [weak host] _ in host?.updateConnectionModes() }
            demo?.start()
        }
    }

    /// Stops everything this phone owns (not the shared sockets).
    func shutdown() {
        rekeyTask?.cancel(); rekeyTask = nil
        demo?.stop(); demo = nil
        tearDownScreen()
        channel = nil
        sessionKeys = nil
        media.reset()
        activeCall = nil
        connection = .offline
    }

    func transmit(_ body: PayloadBody) {
        guard let channel, let env = try? channel.seal(body) else { return }
        host?.sendFrame(.envelope(env), for: self)
        host?.persist()
    }

    /// Returns true when the frame decrypted and was applied (so the caller can trust the connection it came on).
    @discardableResult
    func receive(_ frame: WireFrame) -> Bool {
        guard case .envelope(let env) = frame, let channel else { return false }
        do {
            let payload = try channel.open(env)
            if case .rekey(let m) = payload.body {
                Trace.log("rekey message received reply=\(m.reply)")
                if let reply = channel.handleRekey(m) { transmit(reply) }
            } else {
                apply(payload.body)
            }
            maybeRekey()
            return true
        } catch {
            NSLog("PhonePigeon: dropped envelope %@ — %@", env.messageId, error.localizedDescription)
            return false
        }
    }

    /// A message sealed under the static keys that tells a phone "I lost our forward-secret keys (I restarted)":
    /// the phone drops its ephemeral keys and sends a fresh status, which this Mac can read.
    func resyncFrame() -> WireFrame? {
        guard let channel, let env = try? channel.seal(.ack(AckEvent(ackedMessageId: "resync"))) else { return nil }
        return .envelope(env)
    }

    /// Forward secrecy: (re)start the ephemeral exchange whenever one is due. Not for the in-process demo phone.
    func maybeRekey() {
        guard !pairing.isDemo, let channel, let req = channel.rekeyRequestIfDue() else { return }
        Trace.log("sending rekey request")
        transmit(req)
    }

    // MARK: - Applying inbound payloads

    private func apply(_ body: PayloadBody) {
        switch body {
        case .simInventory(let inv):
            sims = inv.sims.map {
                SimCard(subscriptionId: $0.subscriptionId, slotIndex: $0.slotIndex, carrierName: $0.carrierName,
                        displayName: $0.displayName, phoneNumber: $0.phoneNumber.isEmpty ? nil : $0.phoneNumber,
                        accentColorHex: $0.accentColorHex, isDefaultSms: $0.isDefaultSms, isDefaultVoice: $0.isDefaultVoice)
            }.sorted { $0.slotIndex < $1.slotIndex }
        case .contactSync(let batch):
            var position = Dictionary(uniqueKeysWithValues: contacts.enumerated().map { ($1.contactId, $0) })
            for c in batch.contacts {
                let contact = Contact(contactId: c.contactId, displayName: c.displayName,
                                      phoneNumbers: c.phoneNumbers.map(PhoneNumber.normalize), thumbnailJPEG: c.thumbnailJpeg)
                if let i = position[c.contactId] { contacts[i] = contact } else { position[c.contactId] = contacts.count; contacts.append(contact) }
            }
            // Indexes and name back-fill touch every thread and call: do it once per sync, not once per 100-contact batch.
            if batch.isFinalBatch {
                rebuildIndexes()
                for i in threads.indices { threads[i].contactName = contact(for: threads[i].recipient)?.displayName }
                for i in calls.indices { calls[i].contactName = contact(for: calls[i].remoteAddress)?.displayName }
            }
        case .smsThreadSync(let sync):
            for m in sync.messages { insert(m, notify: false) }
        case .smsMessage(let m):
            insert(m, notify: m.direction == .incoming)
        case .smsStatus(let update):
            updateStatus(update)
        case .callState(let event):
            applyCall(event)
        case .deviceStatus(let b):
            battery = b
            media.storage = b
        case .mediaEndpoint(let ep):
            media.updateEndpoint(ep, keys: sessionKeys)
        case .listDirRes(let r):
            media.resolve(r)
        case .searchRes(let r):
            media.resolve(r)
        case .listGalleryRes(let r):
            media.resolve(r)
        case .fileOpRes(let r):
            media.resolve(r)
        case .listDirReq, .searchReq, .listGalleryReq, .fileOpReq, .webrtcSignal:
            break
        case .notification(let ev):
            applyNotification(ev)
        case .notificationRemoved(let r):
            notifications.removeAll { $0.id == r.key }
        case .notificationDismiss, .remoteInput:
            break
        case .screenStatus(let s):
            applyScreenStatus(s)
        case .ack, .rekey, .screenReq, .sendSms, .placeCall, .callAction:
            break
        }
        host?.persist()
    }

    private func insert(_ e: SmsMessageEvent, notify: Bool) {
        let msg = SmsMessage(messageId: e.localId, threadId: PhoneNumber.threadId(for: e.address), subscriptionId: e.subscriptionId,
                             address: PhoneNumber.normalize(e.address), body: e.body, direction: e.direction, status: e.status,
                             timestamp: Date(timeIntervalSince1970: Double(e.timestampMs) / 1000), isRead: e.isRead)
        guard !seenDedup.contains(msg.dedupHash) else { return }
        seenDedup.insert(msg.dedupHash)

        var isViewing = false
        if let i = threads.firstIndex(where: { $0.threadId == msg.threadId }) {
            // Messages almost always arrive in order: append, or binary-search the slot (re-sorting a whole
            // thread per message made a 500-message sync quadratic).
            var at = threads[i].messages.count
            if let last = threads[i].messages.last, last.timestamp > msg.timestamp {
                var lo = 0, hi = at
                while lo < hi { let mid = (lo + hi) / 2; if threads[i].messages[mid].timestamp <= msg.timestamp { lo = mid + 1 } else { hi = mid } }
                at = lo
            }
            threads[i].messages.insert(msg, at: at)
            threads[i].preferredSubId = threads[i].messages.last?.subscriptionId
            isViewing = selectedThreadId == msg.threadId && host?.section == .messages && host?.current === self && NSApp.isActive
            if isViewing { threads[i].messages[at].isRead = true }
        } else {
            threads.append(ChatThread(threadId: msg.threadId, recipient: msg.address,
                                      contactName: contact(for: msg.address)?.displayName,
                                      messages: [msg], preferredSubId: msg.subscriptionId))
        }
        if notify && !isViewing {
            NotificationManager.shared.notifyMessage(msg, title: displayName(for: msg.address), sim: sim(msg.subscriptionId), phone: self)
        }
    }

    private func updateStatus(_ u: SmsStatusUpdate) {
        for ti in threads.indices {
            if let mi = threads[ti].messages.firstIndex(where: { $0.clientRequestId == u.clientRequestId }) {
                withAnimation(.snappy) { threads[ti].messages[mi].status = u.status }
                if u.status == .failed {
                    host?.show("Message to \(threads[ti].title) failed\(u.errorReason.isEmpty ? "" : ": \(u.errorReason)")",
                               symbol: "exclamationmark.bubble.fill", style: .error)
                }
                return
            }
        }
    }

    private func applyCall(_ e: CallStateEvent) {
        guard let host else { return }
        let name = e.contactName.isEmpty ? contact(for: e.remoteAddress)?.displayName : e.contactName
        switch e.state {
        case .ringingIncoming, .dialingOutgoing, .active, .holding:
            let prev = activeCall
            var session = CallSession(id: e.callId, subscriptionId: e.subscriptionId, remoteAddress: e.remoteAddress,
                                      contactName: name, state: e.state,
                                      startedAt: e.startedAtMs > 0 ? Date(timeIntervalSince1970: Double(e.startedAtMs) / 1000) : nil,
                                      isMuted: e.isMuted, isOutgoing: e.state == .dialingOutgoing || (prev?.id == e.callId && prev?.isOutgoing == true))
            session.audioRoute = e.audioRoute != .unspecified ? e.audioRoute : (prev?.id == e.callId ? prev!.audioRoute : .mac)
            withAnimation(.spring(duration: 0.45)) { activeCall = session }
            if e.state == .ringingIncoming && prev?.id != e.callId {
                host.audio.refresh(preferredName: pairing.deviceName)
                NotificationManager.shared.notifyIncomingCall(session, sim: sim(e.subscriptionId), phone: self)
                NSApp.requestUserAttention(.criticalRequest)
                NSSound(named: "Submarine")?.play()
            }
            if e.state == .active {
                answeredCallIds.insert(e.callId)
                NotificationManager.shared.clearCall(e.callId)
                if session.audioOnMac, prev?.state != .active { host.audio.attachAudio(preferredName: pairing.deviceName) }
            }
        case .disconnected:
            let prev = activeCall?.id == e.callId ? activeCall : nil
            let outgoing = prev?.isOutgoing ?? false
            let answered = answeredCallIds.contains(e.callId)
            let direction: CallDirection = outgoing ? .outgoing : (answered ? .incoming : (rejectedCallIds.contains(e.callId) ? .rejected : .missed))
            let started = prev?.startedAt ?? .now
            calls.insert(CallLogEntry(id: e.callId, subscriptionId: e.subscriptionId, remoteAddress: e.remoteAddress, contactName: name,
                                      direction: direction, startedAt: started,
                                      duration: prev?.startedAt.map { Date().timeIntervalSince($0) } ?? 0), at: 0)
            NotificationManager.shared.clearCall(e.callId)
            host.audio.detachAudio()
            host.callEnded(phone: self, callId: e.callId) // saves an in-progress recording
            withAnimation(.spring(duration: 0.4)) { if activeCall?.id == e.callId { activeCall = nil } }
            if direction == .missed {
                host.show("Missed call from \(name ?? PhoneNumber.pretty(e.remoteAddress))\(host.phones.count > 1 ? " · \(self.name)" : "")",
                          symbol: "phone.down.fill", style: .warning)
            }
        }
    }

    func attachRecording(callId: String, path: String) {
        if let i = calls.firstIndex(where: { $0.id == callId }) { calls[i].recordingFile = path }
    }

    // MARK: - Commands (Mac → Android)

    @discardableResult
    func send(_ body: String, to address: String, simId: Int?) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let simId = simId ?? defaultSmsSim?.subscriptionId else { return false }
        let normalized = PhoneNumber.normalize(address)
        let requestId = UUID().uuidString.lowercased()

        // Backpressure warning (spec §12 carrier rate limit).
        let recent = threads.flatMap(\.messages).filter { $0.direction == .outgoing && $0.timestamp > .now.addingTimeInterval(-60) }.count
        if recent >= 30 { host?.show("Sending quickly — messages are queued on the phone to respect carrier limits.", symbol: "tortoise.fill", style: .warning) }

        let msg = SmsMessage(messageId: requestId, threadId: PhoneNumber.threadId(for: normalized), subscriptionId: simId,
                             address: normalized, body: text, direction: .outgoing, status: .pending, timestamp: .now,
                             isRead: true, clientRequestId: requestId)
        seenDedup.insert(msg.dedupHash)
        withAnimation(.snappy) {
            if let i = threads.firstIndex(where: { $0.threadId == msg.threadId }) {
                threads[i].messages.append(msg)
                threads[i].preferredSubId = simId
                threads[i].draft = ""
            } else {
                threads.append(ChatThread(threadId: msg.threadId, recipient: normalized,
                                          contactName: contact(for: normalized)?.displayName, messages: [msg], preferredSubId: simId))
            }
        }
        transmit(.sendSms(SendSmsCommand(clientRequestId: requestId, subscriptionId: simId, recipientAddress: normalized, body: text)))
        return true
    }

    func reply(threadId: String, body: String) {
        guard let t = thread(threadId) else { return }
        send(body, to: t.recipient, simId: t.preferredSubId)
    }

    func placeCall(_ number: String, simId: Int?) {
        let n = PhoneNumber.normalize(number)
        guard !n.isEmpty, activeCall == nil, let simId = simId ?? defaultVoiceSim?.subscriptionId else { return }
        let id = UUID().uuidString.lowercased()
        host?.audio.refresh(preferredName: pairing.deviceName)
        withAnimation(.spring(duration: 0.45)) {
            activeCall = CallSession(id: id, subscriptionId: simId, remoteAddress: n, contactName: contact(for: n)?.displayName,
                                     state: .dialingOutgoing, startedAt: nil, isMuted: false, isOutgoing: true)
        }
        transmit(.placeCall(PlaceCallCommand(requestId: id, subscriptionId: simId, phoneNumber: n, routeAudioToMac: true)))
    }

    func performCallAction(_ action: CallAction, digit: String = "") {
        guard let call = activeCall else { return }
        if action == .reject { rejectedCallIds.insert(call.id) }
        if action == .toggleMute { activeCall?.isMuted.toggle() }
        transmit(.callAction(CallActionCommand(callId: call.id, action: action, dtmfDigit: digit)))
    }

    /// Mid-call audio handoff (spec §5.3.7, §13 "Mid-Call Audio Handoff").
    func setAudioRoute(_ route: AudioRoute) {
        guard var call = activeCall, call.audioRoute != route, let host else { return }
        call.audioRoute = route
        withAnimation(.snappy) { activeCall = call }
        transmit(.callAction(CallActionCommand(callId: call.id, action: .switchAudioRoute, targetAudioRoute: route)))
        if route == .mac {
            host.audio.attachAudio(preferredName: pairing.deviceName)
            if !host.audio.status.isUsable {
                host.show("Bluetooth audio unavailable — call active on phone.", symbol: "headphones.slash", style: .warning)
            }
        } else {
            host.audio.detachAudio()
        }
    }

    // MARK: - Screen mirroring (view only)

    /// Asks the phone to start mirroring. The phone's owner must tap the request notification and accept Android's dialog.
    func startScreenMirror() {
        guard let host else { return }
        guard !pairing.isDemo else {
            host.show("Screen mirroring needs a real phone — the demo phone has no screen to share.", symbol: "rectangle.on.rectangle.slash", style: .warning)
            return
        }
        guard !screen.isBusy else { screenWindow?.show(); return }
        guard media.isAvailable else {
            host.show("The phone's local media server isn't reachable. Both devices need to be on the same Wi-Fi.", symbol: "wifi.exclamationmark", style: .warning)
            return
        }
        screen.begin()
        transmit(.screenReq(ScreenMirrorRequest(action: .start, maxDimension: 1280)))
        host.show("Approve screen sharing on \(name)", symbol: "rectangle.on.rectangle", style: .info)
    }

    func stopScreenMirror() {
        if screen.isBusy {
            Trace.log("sending screen stop")
            transmit(.screenReq(ScreenMirrorRequest(action: .stop, maxDimension: 0)))
        }
        tearDownScreen()
    }

    // MARK: Phone notifications

    private func applyNotification(_ ev: NotificationEvent) {
        if !ev.appIconPng.isEmpty, let data = Data(base64Encoded: ev.appIconPng), let img = NSImage(data: data) { appIcons[ev.packageName] = img }
        let note = PhoneNotification(id: ev.key, packageName: ev.packageName, appName: ev.appName, title: ev.title, text: ev.text,
                                     subText: ev.subText, postedAt: Date(timeIntervalSince1970: Double(ev.postedAtMs) / 1000),
                                     canDismiss: ev.canDismiss)
        let isNew = !notifications.contains { $0.id == note.id }
        notifications.removeAll { $0.id == note.id }
        notifications.insert(note, at: 0)
        notifications.sort { $0.postedAt > $1.postedAt }
        if notifications.count > 300 { notifications.removeLast(notifications.count - 300) }
        // The phone replays what is already in its shade when it connects: only fresh ones become Mac banners.
        if isNew, host?.settings.showPhoneNotifications ?? true, abs(note.postedAt.timeIntervalSinceNow) < 120 {
            NotificationManager.shared.notifyPhoneNotification(note, phone: host?.phones.count ?? 1 > 1 ? name : nil)
        }
    }

    func dismissNotification(_ key: String) {
        notifications.removeAll { $0.id == key }
        transmit(.notificationDismiss(NotificationDismiss(key: key)))
    }

    func clearNotifications() {
        let keys = notifications.filter(\.canDismiss).map(\.id)
        notifications.removeAll { keys.contains($0.id) }
        keys.forEach { transmit(.notificationDismiss(NotificationDismiss(key: $0))) }
    }

    func sendRemoteInput(_ input: RemoteInput) {
        guard screen.control else { return }
        transmit(.remoteInput(input))
    }

    private func applyScreenStatus(_ s: ScreenMirrorStatus) {
        screen.apply(s)
        switch s.state {
        case .streaming:
            if let w = screenWindow { w.resize(width: s.width, height: s.height); w.controlEnabled = s.control } else { openScreenWindow(s) }
        case .denied, .error:
            tearDownScreen()
            host?.show(s.message.isEmpty ? "Screen mirroring was not started." : s.message, symbol: "rectangle.on.rectangle.slash", style: .warning)
        case .stopped:
            tearDownScreen()
            host?.show("Screen mirroring ended" + (s.message.isEmpty ? "" : " — \(s.message)"), symbol: "rectangle.on.rectangle", style: .info)
        case .idle, .waiting:
            break
        }
    }

    private func openScreenWindow(_ s: ScreenMirrorStatus) {
        guard let (request, hash) = media.screenStreamRequest() else {
            tearDownScreen()
            host?.show("Couldn't reach the phone's media server for screen mirroring.", symbol: "wifi.exclamationmark", style: .error)
            return
        }
        let controller = ScreenWindowController(title: pairing.deviceName, width: s.width, height: s.height)
        controller.onUserClose = { [weak self] in self?.stopScreenMirror() }
        controller.onInput = { [weak self] in self?.sendRemoteInput($0) }
        controller.controlEnabled = s.control
        screenWindow = controller
        controller.show()
        screenStream = ScreenStream(request: request, pinnedHash: hash,
            onFrame: { frame in Task { @MainActor [weak controller] in controller?.handle(frame) } },
            onEnd: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.screenStream != nil else { return }
                    self.tearDownScreen()
                    self.host?.show("Screen mirroring ended\(error.map { ": \($0.localizedDescription)" } ?? "")", symbol: "rectangle.on.rectangle.slash", style: .warning)
                }
            })
    }

    private func tearDownScreen() {
        let stream = screenStream
        screenStream = nil
        stream?.cancel()
        if let w = screenWindow { screenWindow = nil; w.onUserClose = nil; w.close() }
        screen.reset(.idle)
    }

    // MARK: - Local thread management

    func open(threadId: String) {
        host?.section = .messages
        selectedThreadId = threadId
        markRead(threadId: threadId)
    }

    func startConversation(with address: String) {
        let n = PhoneNumber.normalize(address)
        let id = PhoneNumber.threadId(for: n)
        if thread(id) == nil {
            threads.append(ChatThread(threadId: id, recipient: n, contactName: contact(for: n)?.displayName, messages: [],
                                      preferredSubId: defaultSmsSim?.subscriptionId))
        }
        open(threadId: id)
    }

    func markRead(threadId: String) {
        guard let i = threads.firstIndex(where: { $0.threadId == threadId }), threads[i].unreadCount > 0 else { return }
        for j in threads[i].messages.indices { threads[i].messages[j].isRead = true }
        NotificationManager.shared.clearThread(threadId)
        host?.persist()
    }

    func markAllRead() {
        for i in threads.indices { for j in threads[i].messages.indices { threads[i].messages[j].isRead = true } }
        host?.persist()
    }

    func togglePin(_ threadId: String) {
        guard let i = threads.firstIndex(where: { $0.threadId == threadId }) else { return }
        withAnimation(.snappy) { threads[i].isPinned.toggle() }
        host?.persist()
    }

    func deleteThread(_ threadId: String) {
        withAnimation(.snappy) { threads.removeAll { $0.threadId == threadId } }
        if selectedThreadId == threadId { selectedThreadId = nil }
        host?.persist()
    }

    func setPreferredSim(_ simId: Int, for threadId: String) {
        guard let i = threads.firstIndex(where: { $0.threadId == threadId }) else { return }
        threads[i].preferredSubId = simId
    }

    func setDraft(_ text: String, for threadId: String) {
        guard let i = threads.firstIndex(where: { $0.threadId == threadId }), threads[i].draft != text else { return }
        threads[i].draft = text
    }

    func clearCallLog() { calls.removeAll(); host?.persist() }

    // MARK: - Demo controls

    func demoIncomingCall() { demo?.simulateIncomingCall() }
    func demoIncomingMessage() { demo?.simulateIncomingMessage() }
    func demoIncomingOTP() { demo?.simulateIncomingOTP() }

    func seedDemoCallLog() {
        func entry(_ addr: String, _ dir: CallDirection, hoursAgo: Double, dur: TimeInterval, sim: Int) -> CallLogEntry {
            CallLogEntry(id: UUID().uuidString, subscriptionId: sim, remoteAddress: addr, contactName: contact(for: addr)?.displayName,
                         direction: dir, startedAt: .now.addingTimeInterval(-hoursAgo * 3600), duration: dur)
        }
        calls = [
            entry("+919447001122", .incoming, hoursAgo: 1.2, dur: 734, sim: 1),
            entry("+919900112233", .missed, hoursAgo: 3.5, dur: 0, sim: 2),
            entry("+919845012345", .outgoing, hoursAgo: 20, dur: 312, sim: 1),
            entry("+918041234567", .outgoing, hoursAgo: 27, dur: 95, sim: 2),
            entry("+919811223344", .incoming, hoursAgo: 49, dur: 1260, sim: 2),
            entry("+917012345678", .rejected, hoursAgo: 53, dur: 0, sim: 1),
            entry("+919746556677", .outgoing, hoursAgo: 75, dur: 48, sim: 1),
        ]
        callSeenAt = .now.addingTimeInterval(-4 * 3600)
    }

    private func rebuildIndexes() {
        contactIndex = [:]
        for c in contacts { for n in c.phoneNumbers { contactIndex[PhoneNumber.normalize(n)] = c } }
        seenDedup = Set(threads.flatMap(\.messages).map(\.dedupHash))
        sortedContacts = contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
