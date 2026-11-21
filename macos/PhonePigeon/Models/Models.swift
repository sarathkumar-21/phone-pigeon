import Foundation
import SwiftUI

// MARK: - SIM

/// Mirrors `SimCard` from relay.proto and the `sim_cards` local table.
nonisolated struct SimCard: Codable, Hashable, Identifiable {
    var subscriptionId: Int
    var slotIndex: Int
    var carrierName: String
    var displayName: String
    var phoneNumber: String?
    var accentColorHex: String
    var isDefaultSms: Bool
    var isDefaultVoice: Bool
    var isActive: Bool = true

    var id: Int { subscriptionId }
    var slotLabel: String { "SIM \(slotIndex + 1)" }
    @MainActor var color: Color { Color(hex: accentColorHex) ?? .accentColor }
    /// Short pill label, e.g. "SIM 1 · Jio".
    var pillLabel: String { "\(slotLabel) · \(carrierName)" }
}

// MARK: - Contacts

nonisolated struct Contact: Codable, Hashable, Identifiable {
    var contactId: String
    var displayName: String
    var phoneNumbers: [String]
    var thumbnailJPEG: Data?
    var updatedAt: Date = .now

    var id: String { contactId }
    var primaryNumber: String { phoneNumbers.first ?? "" }
}

// MARK: - Messages

nonisolated enum MessageDirection: String, Codable { case incoming = "INCOMING", outgoing = "OUTGOING" }

nonisolated enum MessageStatus: String, Codable {
    case pending = "PENDING", sent = "SENT", delivered = "DELIVERED", failed = "FAILED"

    var symbol: String {
        switch self {
        case .pending: "clock"
        case .sent: "checkmark"
        case .delivered: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }
    var label: String { rawValue.capitalized }
}

nonisolated struct SmsMessage: Codable, Hashable, Identifiable {
    var messageId: String
    var threadId: String
    var subscriptionId: Int
    var address: String
    var body: String
    var direction: MessageDirection
    var status: MessageStatus
    var timestamp: Date
    var isRead: Bool
    /// Client request id for outgoing messages (links `SmsStatusUpdate` back to the bubble).
    var clientRequestId: String?

    var id: String { messageId }

    /// Spec §8.2 dedup hash: (normalizedAddress, trimmedBody, timestampMs / 5000).
    var dedupHash: String {
        let bucket = Int64(timestamp.timeIntervalSince1970 * 1000) / 5000
        return "\(PhoneNumber.normalize(address))|\(body.trimmingCharacters(in: .whitespacesAndNewlines))|\(bucket)"
    }
}

nonisolated struct ChatThread: Codable, Hashable, Identifiable {
    var threadId: String
    var recipient: String
    var contactName: String?
    var messages: [SmsMessage]
    /// Sticky SIM memory per thread (spec §9.2).
    var preferredSubId: Int?
    var isPinned: Bool = false
    var draft: String = ""

    var id: String { threadId }
    var title: String { contactName ?? PhoneNumber.pretty(recipient) }
    var lastMessage: SmsMessage? { messages.last }
    var lastTimestamp: Date { lastMessage?.timestamp ?? .distantPast }
    var unreadCount: Int { messages.lazy.filter { $0.direction == .incoming && !$0.isRead }.count }
    var snippet: String { lastMessage?.body ?? "" }
}

// MARK: - Calls

nonisolated enum CallState: String, Codable {
    case ringingIncoming = "RINGING_INCOMING"
    case dialingOutgoing = "DIALING_OUTGOING"
    case active = "ACTIVE"
    case holding = "HOLDING"
    case disconnected = "DISCONNECTED"
}

nonisolated enum CallAction: String, Codable {
    case answer = "ANSWER", reject = "REJECT", endCall = "END_CALL", toggleMute = "TOGGLE_MUTE"
    case sendDtmf = "SEND_DTMF", switchAudioRoute = "SWITCH_AUDIO_ROUTE"
}

/// Where the call's voice audio is playing (spec v2 `AudioRoute`).
nonisolated enum AudioRoute: String, Codable, CaseIterable {
    case unspecified = "AUDIO_ROUTE_UNSPECIFIED"
    case mac = "MAC_BLUETOOTH_HFP"
    case earpiece = "PHONE_EARPIECE"
    case speaker = "PHONE_SPEAKER"
    case wired = "WIRED_HEADSET"

    var label: String {
        switch self {
        case .unspecified: "Auto"
        case .mac: "Mac"
        case .earpiece: "Phone"
        case .speaker: "Speaker"
        case .wired: "Headset"
        }
    }
    var symbol: String {
        switch self {
        case .unspecified: "speaker.wave.2"
        case .mac: "laptopcomputer"
        case .earpiece: "iphone"
        case .speaker: "speaker.wave.3.fill"
        case .wired: "headphones"
        }
    }
    /// Routes the user can pick from the Mac call bar (spec §5.3.7).
    static let selectable: [AudioRoute] = [.mac, .speaker, .earpiece]
}

nonisolated enum CallDirection: String, Codable { case incoming, outgoing, missed, rejected

    var symbol: String {
        switch self {
        case .incoming: "phone.arrow.down.left.fill"
        case .outgoing: "phone.arrow.up.right.fill"
        case .missed: "phone.down.fill"
        case .rejected: "phone.down.circle.fill"
        }
    }
    var label: String {
        switch self {
        case .incoming: "Incoming"
        case .outgoing: "Outgoing"
        case .missed: "Missed"
        case .rejected: "Declined"
        }
    }
}

nonisolated struct CallLogEntry: Codable, Hashable, Identifiable {
    var id: String
    var subscriptionId: Int
    var remoteAddress: String
    var contactName: String?
    var direction: CallDirection
    var startedAt: Date
    var duration: TimeInterval
    /// Path of a recording made on this Mac, if any.
    var recordingFile: String?

    var title: String { contactName ?? PhoneNumber.pretty(remoteAddress) }
}

/// A live call mirrored from Android via `CallStateEvent`.
struct CallSession: Identifiable, Equatable {
    var id: String
    var subscriptionId: Int
    var remoteAddress: String
    var contactName: String?
    var state: CallState
    var startedAt: Date?
    var isMuted: Bool
    var isOutgoing: Bool
    var audioRoute: AudioRoute = .mac
    var audioOnMac: Bool { audioRoute == .mac }

    var title: String { contactName ?? PhoneNumber.pretty(remoteAddress) }
}

// MARK: - Device

/// Mirrors `DeviceStatusEvent` (spec v2): battery, Bluetooth HFP link and storage.
nonisolated struct DeviceStatusEvent: Codable, Hashable {
    var batteryPercent: Int
    var isCharging: Bool
    var bluetoothHfpConnected: Bool
    var storageFreeBytes: Int64
    var storageTotalBytes: Int64

    var storageUsedFraction: Double {
        storageTotalBytes > 0 ? 1 - Double(storageFreeBytes) / Double(storageTotalBytes) : 0
    }
    var storageLabel: String {
        guard storageTotalBytes > 0 else { return "—" }
        let f = ByteCountFormatter.string(fromByteCount: storageFreeBytes, countStyle: .file)
        return "\(f) free"
    }
}

nonisolated struct PairedDevice: Codable, Hashable {
    var androidDeviceId: String
    var macDeviceId: String
    var deviceName: String
    var manufacturer: String
    var osVersion: String
    var androidPublicKey: Data
    var sessionId: String
    var pairedAt: Date
    var isDemo: Bool
}

enum ConnectionMode: Equatable {
    case offline
    case connecting
    case lan(host: String)
    case cloud
    case demo

    var label: String {
        switch self {
        case .offline: "Offline"
        case .connecting: "Connecting…"
        case .lan: "Local Network"
        case .cloud: "Cloud Relay"
        case .demo: "Demo Phone"
        }
    }
    var symbol: String {
        switch self {
        case .offline: "bolt.horizontal.circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .lan: "wifi"
        case .cloud: "icloud.fill"
        case .demo: "sparkles"
        }
    }
    var isConnected: Bool {
        switch self {
        case .offline, .connecting: false
        default: true
        }
    }
    var tint: Color {
        switch self {
        case .offline: .red
        case .connecting: .orange
        case .lan: .green
        case .cloud: .blue
        case .demo: .purple
        }
    }
}

// MARK: - Helpers

nonisolated enum PhoneNumber {
    /// Light-weight E.164 normaliser (keeps leading +, strips formatting).
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return trimmed }
        return trimmed.hasPrefix("+") ? "+" + digits : digits
    }

    /// Human-friendly grouping for display. Short codes and alphanumeric senders pass through.
    static func pretty(_ raw: String) -> String {
        let n = normalize(raw)
        guard n.hasPrefix("+"), n.count > 8 else { return raw }
        let digits = Array(n.dropFirst())
        let ccLen: Int = digits.first == "1" || digits.first == "7" ? 1 : 2
        let cc = String(digits.prefix(ccLen))
        let rest = Array(digits.dropFirst(ccLen))
        let groups: [Int] = rest.count == 10 ? [5, 5] : (rest.count == 9 ? [3, 3, 3] : [rest.count])
        var parts: [String] = []
        var idx = 0
        for g in groups where idx < rest.count {
            let end = min(idx + g, rest.count)
            parts.append(String(rest[idx..<end]))
            idx = end
        }
        if cc == "1", rest.count == 10 {
            return "+1 (\(String(rest[0..<3]))) \(String(rest[3..<6]))-\(String(rest[6..<10]))"
        }
        return "+\(cc) " + parts.joined(separator: " ")
    }

    /// Thread id = SHA256 of sorted participants (spec §7.2).
    static func threadId(for address: String) -> String {
        Crypto.sha256Hex(normalize(address))
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// A notification mirrored from the phone.
struct PhoneNotification: Identifiable, Hashable {
    let id: String            // Android's notification key
    let packageName: String
    let appName: String
    let title: String
    let text: String
    let subText: String
    let postedAt: Date
    let canDismiss: Bool
}
