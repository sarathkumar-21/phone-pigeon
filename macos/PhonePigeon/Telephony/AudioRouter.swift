import Foundation
import IOBluetooth

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
    private nonisolated static let queue = DispatchQueue(label: "dev.phonepigeon.bluetooth", qos: .userInitiated)

    /// Probe result computed off the main thread.
    private struct Probe: Sendable { let status: Status; let address: String? }

    private nonisolated static func probe(preferredName: String?, handsFreeConnected: Bool) -> Probe {
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            return Probe(status: .unavailable("Bluetooth is off"), address: nil)
        }
        let all = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let phones = all.filter { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone) }
        let match = phones.first { d in preferredName.map { (d.name ?? "").localizedCaseInsensitiveContains($0) } ?? false } ?? phones.first
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
            guard let self, let address, self.handsFree == nil,
                  let device = IOBluetoothDevice(addressString: address) else { return }
            let hf = IOBluetoothHandsFreeDevice(device: device, delegate: self)
            self.handsFree = hf
            hf?.connect()
            hf?.connectSCO()
        }
    }

    func detachAudio() {
        handsFree?.disconnectSCO()
        handsFree?.disconnect()
        handsFree = nil
        refresh(preferredName: nil)
    }
}

extension AudioRouter: IOBluetoothHandsFreeDeviceDelegate {
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        Task { @MainActor in self.refresh(preferredName: nil) }
    }
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        Task { @MainActor in self.refresh(preferredName: nil) }
    }
}
