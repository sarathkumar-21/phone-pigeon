import CryptoKit
import Foundation

/// One paired phone's saved state. Mirrors the spec §7.2 tables, per device.
nonisolated struct PhoneSnapshot: Codable {
    var pairing: PairedDevice
    var sims: [SimCard] = []
    var contacts: [Contact] = []
    var threads: [ChatThread] = []
    var calls: [CallLogEntry] = []
    var battery: DeviceStatusEvent?
    var outgoingSequence: UInt64 = 0
    var incomingSequence: UInt64 = 0
    var callSeenAt: Date?
    var scheduled: [ScheduledItem] = []

    init(pairing: PairedDevice) { self.pairing = pairing }

    /// Field-by-field decode so a schema change in one table never wipes the pairing or message history.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairing = try c.decode(PairedDevice.self, forKey: .pairing)
        sims = (try? c.decode([SimCard].self, forKey: .sims)) ?? []
        contacts = (try? c.decode([Contact].self, forKey: .contacts)) ?? []
        threads = (try? c.decode([ChatThread].self, forKey: .threads)) ?? []
        calls = (try? c.decode([CallLogEntry].self, forKey: .calls)) ?? []
        battery = try? c.decodeIfPresent(DeviceStatusEvent.self, forKey: .battery)
        outgoingSequence = (try? c.decode(UInt64.self, forKey: .outgoingSequence)) ?? 0
        incomingSequence = (try? c.decode(UInt64.self, forKey: .incomingSequence)) ?? 0
        callSeenAt = try? c.decodeIfPresent(Date.self, forKey: .callSeenAt)
        scheduled = (try? c.decode([ScheduledItem].self, forKey: .scheduled)) ?? []
    }
}

/// Everything the Mac persists locally: any number of paired phones.
nonisolated struct AppSnapshot: Codable {
    var phones: [PhoneSnapshot] = []
    var selectedPhoneId: String?

    init(phones: [PhoneSnapshot] = [], selectedPhoneId: String? = nil) {
        self.phones = phones; self.selectedPhoneId = selectedPhoneId
    }

    private enum CodingKeys: String, CodingKey {
        case phones, selectedPhoneId
        // Version 1 stored exactly one phone at the top level; still read so an upgrade keeps its pairing and history.
        case pairing, sims, contacts, threads, calls, battery, outgoingSequence, incomingSequence
    }

    /// Decodes an array one element at a time so a single damaged phone never hides the others.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedPhoneId = try? c.decodeIfPresent(String.self, forKey: .selectedPhoneId)
        phones = ((try? c.decode([Lossy<PhoneSnapshot>].self, forKey: .phones)) ?? []).compactMap(\.value)
        if phones.isEmpty, let legacy = try? c.decodeIfPresent(PairedDevice.self, forKey: .pairing) {
            var p = PhoneSnapshot(pairing: legacy)
            p.sims = (try? c.decode([SimCard].self, forKey: .sims)) ?? []
            p.contacts = (try? c.decode([Contact].self, forKey: .contacts)) ?? []
            p.threads = (try? c.decode([ChatThread].self, forKey: .threads)) ?? []
            p.calls = (try? c.decode([CallLogEntry].self, forKey: .calls)) ?? []
            p.battery = try? c.decodeIfPresent(DeviceStatusEvent.self, forKey: .battery)
            p.outgoingSequence = (try? c.decode(UInt64.self, forKey: .outgoingSequence)) ?? 0
            p.incomingSequence = (try? c.decode(UInt64.self, forKey: .incomingSequence)) ?? 0
            phones = [p]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phones, forKey: .phones)
        try c.encodeIfPresent(selectedPhoneId, forKey: .selectedPhoneId)
    }
}

/// Local-first encrypted store.
///
/// Improvisation: the spec calls for GRDB + SQLCipher. To keep the project free of
/// third-party packages, the snapshot is sealed with ChaCha20-Poly1305 using a
/// 256-bit key held in the macOS Keychain. Writes are debounced and atomic.
final class EncryptedStore {
    private let url: URL
    private let key: SymmetricKey
    private var pendingWrite: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhonePigeon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("store.sealed")
        key = Keychain.storageKey()
    }

    func load() -> AppSnapshot {
        guard let data = try? Data(contentsOf: url) else { return AppSnapshot() }
        guard let box = try? ChaChaPoly.SealedBox(combined: data),
              let plain = try? ChaChaPoly.open(box, using: key),
              let snap = try? PayloadCodec.decode(AppSnapshot.self, from: plain)
        else {
            // Unreadable (key lost, corruption, schema change): keep the file so the next save cannot destroy it.
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            NSLog("PhonePigeon: local store could not be read; kept a copy at %@", backup.path)
            return AppSnapshot()
        }
        return snap
    }

    func save(_ snapshot: AppSnapshot, debounce: Duration = .milliseconds(400)) {
        pendingWrite?.cancel()
        // JSON-encoding every thread and contact photo is real work: keep it (and the disk write) off the main thread.
        pendingWrite = Task.detached(priority: .utility) { [url, key] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            guard let plain = try? PayloadCodec.encode(snapshot),
                  let sealed = try? ChaChaPoly.seal(plain, using: key).combined else { return }
            try? sealed.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    func wipe() {
        pendingWrite?.cancel()
        try? FileManager.default.removeItem(at: url)
    }
}
