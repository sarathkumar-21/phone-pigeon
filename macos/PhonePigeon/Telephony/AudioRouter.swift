import Foundation
import IOBluetooth
import os

/// Bluetooth Hands-Free bridge (spec §9.3.2).
///
/// The Mac acts as an HFP unit for the paired phone so the cellular call's SCO audio
/// is played on the Mac's speakers / microphone. When the phone is out of range the
/// user can flip the route back to "Audio on Phone".
///
/// IOBluetooth's first use initialises CoreBluetooth and can block on a semaphore
/// (e.g. while the Bluetooth privacy prompt is pending). Every probe therefore runs on
/// a private queue; only results hop back to the main actor.
@Observable
final class AudioRouter: NSObject {
    enum Status: Equatable, Sendable {
        case unavailable(String)
        case ready(deviceName: String)
        case connected(deviceName: String)

        var label: String {
            switch self {
            case .unavailable(let why): why
            case .ready(let name): "Ready · \(name)"
            case .connected(let name): "Hands-Free · \(name)"
            }
        }
        var isUsable: Bool { if case .unavailable = self { false } else { true } }
    }

    private(set) var status: Status = .unavailable("Checking Bluetooth…")
    private var handsFree: IOBluetoothHandsFreeDevice?
    /// The hands-free service link to the phone is up (a call can now be put on the Mac).
    private(set) var linkUp = false
    /// The call's audio is actually flowing over Bluetooth to this Mac.
    private(set) var scoUp = false
    /// Why the Mac can't take the call audio, in words for the call card.
    private(set) var problem: String?
    /// Called when the link to the phone comes up, so the phone can be told to move the call here.
    var onLinkUp: (@MainActor () -> Void)?
    private var watchdog: Task<Void, Never>?
    private var phoneName = "Phone"
    private let log = Logger(subsystem: "dev.phonepigeon.mac", category: "audio")
    /// Keeps the in-flight service lookup alive (IOBluetooth holds its delegate weakly).
    private var sdp: SDPLookup?
    private var triedPairing = false
    /// Whether this Mac can take this phone's call audio: nil until known, false when the last check or attempt failed.
    private(set) var macAudioSupported: Bool?
    private var checking = false

    /// One line for the call card: what the Mac's hands-free link is doing right now.
    var statusLine: String {
        if scoUp { return "Hands-Free · \(phoneName)" }
        if let problem { return problem }
        if linkUp { return "Linked to \(phoneName) — waiting for call audio…" }
        if handsFree != nil { return "Connecting hands-free to \(phoneName)…" }
        return status.label
    }
    private nonisolated static let queue = DispatchQueue(label: "dev.phonepigeon.bluetooth", qos: .userInitiated)

    /// Probe result computed off the main thread.
    private struct Probe: Sendable { let status: Status; let address: String? }

    private nonisolated static let probeLog = Logger(subsystem: "dev.phonepigeon.mac", category: "audio")

    private nonisolated static func probe(preferredName: String?, handsFreeConnected: Bool) -> Probe {
        let power = IOBluetoothHostController.default()?.powerState
        // Only a definite "off" counts: right after launch the controller can briefly report nothing useful.
        if power == kBluetoothHCIPowerStateOFF {
            probeLog.notice("probe: Bluetooth is off")
            return Probe(status: .unavailable("Bluetooth is off"), address: nil)
        }
        let all = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let phones = all.filter { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone) }
        let named = all.first { d in preferredName.map { !$0.isEmpty && (d.name ?? "").localizedCaseInsensitiveContains($0) } ?? false }
        let match = phones.first { d in preferredName.map { (d.name ?? "").localizedCaseInsensitiveContains($0) } ?? false } ?? phones.first ?? named
        probeLog.notice("probe: power=\(String(describing: power), privacy: .public) paired=\(all.count, privacy: .public) phones=\(phones.count, privacy: .public) match=\(match?.name ?? "none", privacy: .public)")
        guard let match else { return Probe(status: .unavailable("No phone paired over Bluetooth"), address: nil) }
        let name = match.name ?? "Phone"
        return Probe(status: handsFreeConnected ? .connected(deviceName: name) : .ready(deviceName: name), address: match.addressString)
    }

    func refresh(preferredName: String?, then: (@MainActor (String?) -> Void)? = nil) {
        let connected = handsFree?.isConnected == true
        Self.queue.async {
            let result = Self.probe(preferredName: preferredName, handsFreeConnected: connected)
            Task { @MainActor [weak self] in
                self?.status = result.status
                then?(result.address)
            }
        }
    }

    /// Opens the HFP service level connection and SCO audio link for an active call.
    func attachAudio(preferredName: String?) {
        refresh(preferredName: preferredName) { [weak self] address in
            guard let self else { return }
            guard let address, let device = IOBluetoothDevice(addressString: address) else {
                self.problem = "No phone paired over Bluetooth. Pair it in System Settings › Bluetooth."
                return
            }
            self.phoneName = device.name ?? "phone"
            if let hf = self.handsFree {            // already linked for this call: just ask for the audio again
                if self.linkUp { hf.connectSCO() }
                return
            }
            self.problem = nil; self.linkUp = false; self.scoUp = false
            self.watchdog?.cancel()
            self.watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, !self.linkUp else { return }
                self.problem = self.problem ?? "The phone didn't accept a hands-free link. On the phone open Bluetooth settings, tap this Mac, and switch on Phone calls (call audio)."
            }
            // IOBluetooth opens the hands-free channel from the phone's cached service list. A phone that has only
            // been used for other things has none cached, and the link then fails with "No channel". Look the services
            // up first (this also refreshes a stale record), then connect.
            let lookup = SDPLookup { [weak self] services, status in
                guard let self else { return }
                self.sdp = nil
                self.log.notice("SDP lookup finished status=\(status, privacy: .public) services=\(services, privacy: .public)")
                if services.isEmpty || !services.contains(where: { $0.hasPrefix("Hands") || $0.localizedCaseInsensitiveContains("handsfree") || $0.localizedCaseInsensitiveContains("audio gateway") || $0.localizedCaseInsensitiveContains("hfp") }) {
                    self.problem = "The phone doesn't offer call audio to this Mac. On the phone open Bluetooth settings, tap this Mac, and switch on Phone calls. If this Mac isn't listed, forget it on both devices and pair again."
                }
                let hf = IOBluetoothHandsFreeDevice(device: device, delegate: self)
                self.handsFree = hf
                // The SCO audio link can only be opened once the service-level connection is up (see the delegate below).
                hf?.connect()
                self.log.notice("hands-free connect started, paired=\(device.isPaired(), privacy: .public) connected=\(device.isConnected(), privacy: .public)")
                // The phone refuses the hands-free channel when it has no classic (call-audio) bond with this Mac, and
                // shows nothing. Pairing again from here makes the phone ask the user to confirm.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, !Task.isCancelled, !self.linkUp, self.handsFree != nil, !self.triedPairing else { return }
                    self.startPairing(device)
                }
            }
            self.sdp = lookup
            lookup.start(device)
        }
    }

    /// The phone refuses the hands-free channel until the Mac and phone share a classic (call-audio) bond. The Mac may
    /// only hold a low-energy bond with it, so ask for authentication on the classic link itself: that makes the phone
    /// show its pairing request. Then retry the hands-free link a few times.
    private func startPairing(_ device: IOBluetoothDevice) {
        triedPairing = true
        problem = "Confirm the Bluetooth pairing request on your phone to allow call audio on this Mac."
        let open = device.isConnected() ? kIOReturnSuccess : device.openConnection()
        let auth = device.requestAuthentication()
        log.notice("classic authentication requested open=\(open, privacy: .public) auth=\(auth, privacy: .public)")
        Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled, !self.linkUp, self.handsFree != nil else { return }
                self.log.notice("retrying hands-free link")
                self.handsFree?.disconnect()
                let hf = IOBluetoothHandsFreeDevice(device: device, delegate: self)
                self.handsFree = hf
                hf?.connect()
            }
            guard let self, !self.linkUp else { return }
            self.macAudioSupported = false
            self.problem = "The phone still refuses call audio. On the phone, forget this Mac in Bluetooth settings, then pair it again from the phone (keep System Settings › Bluetooth open on the Mac so it is visible) and switch on Phone calls."
        }
    }

    // MARK: Setup check

    struct CheckStep: Identifiable, Equatable {
        enum State { case pending, ok, failed }
        let id: Int
        let title: String
        var state: State = .pending
        var detail = ""
    }

    /// Step by step test of everything call audio needs, with a plain reason for the first thing that fails.
    /// Used by the "Set up call audio" guide. Does not touch a call in progress.
    func runCheck(preferredName: String?, update: @MainActor @escaping ([CheckStep]) -> Void) async {
        var steps = [CheckStep(id: 0, title: "Bluetooth is on"), CheckStep(id: 1, title: "Phone is paired with this Mac"),
                     CheckStep(id: 2, title: "Phone offers call audio"), CheckStep(id: 3, title: "Phone accepts a hands-free link")]
        func set(_ i: Int, _ state: CheckStep.State, _ detail: String = "") { steps[i].state = state; steps[i].detail = detail; update(steps) }
        update(steps)
        defer { macAudioSupported = steps.allSatisfy { $0.state == .ok }; checking = false }
        checking = true

        let probe: Probe = await withCheckedContinuation { cont in
            Self.queue.async { cont.resume(returning: Self.probe(preferredName: preferredName, handsFreeConnected: false)) }
        }
        if case .unavailable(let why) = probe.status, probe.address == nil {
            if why == "Bluetooth is off" { set(0, .failed, "Turn Bluetooth on in Control Centre or System Settings.") }
            else { set(0, .ok); set(1, .failed, "Pair your phone in System Settings › Bluetooth first.") }
            return
        }
        set(0, .ok)
        guard let address = probe.address, let device = IOBluetoothDevice(addressString: address) else {
            set(1, .failed, "Pair your phone in System Settings › Bluetooth first."); return
        }
        set(1, .ok, device.name ?? "")

        let services: [String] = await withCheckedContinuation { cont in
            let lookup = SDPLookup { names, _ in self.sdp = nil; cont.resume(returning: names) }
            self.sdp = lookup
            lookup.start(device)
        }
        let channels = services.compactMap { n -> UInt8? in
            guard n.localizedCaseInsensitiveContains("handsfree") || n.localizedCaseInsensitiveContains("headset") else { return nil }
            return n.split(separator: "#").last.flatMap { UInt8($0) }
        }
        guard let channel = channels.first else {
            set(2, .failed, "The phone didn't list a hands-free service. On the phone open Bluetooth settings, tap this Mac, and switch on Phone calls.")
            return
        }
        set(2, .ok, "Hands-free service on channel \(channel)")

        let code: IOReturn = await withCheckedContinuation { cont in
            Self.queue.async {
                var chan: IOBluetoothRFCOMMChannel?
                let r = device.openRFCOMMChannelSync(&chan, withChannelID: channel, delegate: nil)
                chan?.close()
                cont.resume(returning: r)
            }
        }
        log.notice("setup check: RFCOMM channel \(channel, privacy: .public) open result \(code, privacy: .public)")
        if code == kIOReturnSuccess { set(3, .ok, "Ready: call audio can move to this Mac.") }
        else {
            set(3, .failed, "The phone refused the connection (code \(code)). It has no call-audio bond with this Mac, so it ignores the request.")
        }
    }

    /// Quietly tests whether call audio can work, so the call screen only offers "On Mac" when it can.
    func checkSupport(preferredName: String?) {
        guard !checking, handsFree == nil else { return }
        Task { await runCheck(preferredName: preferredName) { _ in } }
    }

    func detachAudio() {
        watchdog?.cancel(); watchdog = nil
        handsFree?.disconnectSCO()
        handsFree?.disconnect()
        handsFree = nil
        linkUp = false; scoUp = false; problem = nil
        refresh(preferredName: nil)
    }
}

extension AudioRouter: IOBluetoothHandsFreeDeviceDelegate {
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        let code = status?.intValue ?? -1
        NSLog("PhonePigeon: hands-free connect finished, status %d", code)
        Task { @MainActor in
            if code == 0 {
                self.linkUp = true; self.problem = nil; self.macAudioSupported = true
                self.handsFree?.connectSCO()
                self.onLinkUp?()
            } else {
                self.linkUp = false
                self.problem = "The hands-free link to the phone failed (code \(code)). Check that Phone calls is on for this Mac in the phone's Bluetooth settings."
            }
            self.refresh(preferredName: nil)
        }
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        NSLog("PhonePigeon: hands-free link closed")
        Task { @MainActor in self.linkUp = false; self.scoUp = false; self.refresh(preferredName: nil) }
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        NSLog("PhonePigeon: call audio link opened")
        Task { @MainActor in self.scoUp = true; self.problem = nil }
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        NSLog("PhonePigeon: call audio link closed")
        Task { @MainActor in self.scoUp = false }
    }
}

/// One-shot SDP query: asks the phone which services it offers and reports their names.
private final class SDPLookup: NSObject {
    private let done: @MainActor ([String], Int32) -> Void
    init(done: @escaping @MainActor ([String], Int32) -> Void) { self.done = done }

    func start(_ device: IOBluetoothDevice) {
        let r = device.performSDPQuery(self)
        if r != kIOReturnSuccess { Task { @MainActor in self.done([], r) } }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let names = ((device?.services as? [IOBluetoothSDPServiceRecord]) ?? []).map { rec -> String in
            var ch: BluetoothRFCOMMChannelID = 0
            let hasChannel = rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess
            return (rec.getServiceName() ?? "?") + (hasChannel ? "#\(ch)" : "")
        }
        Task { @MainActor in self.done(names, status) }
    }
}
