import Foundation

// MARK: - Scheduled calls and messages

nonisolated enum ScheduledKind: String, Codable { case sms, call }

nonisolated enum ScheduledStatus: String, Codable {
    case pending, sent, failed, missed, cancelled

    var label: String {
        switch self {
        case .pending: "Scheduled"
        case .sent: "Done"
        case .failed: "Failed"
        case .missed: "Missed"
        case .cancelled: "Cancelled"
        }
    }
}

/// A text or call the Mac performs later. The Mac app has to be running, and the phone connected, at the chosen time:
/// the phone itself knows nothing about the schedule.
nonisolated struct ScheduledItem: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var kind: ScheduledKind
    var address: String
    /// Message text; empty for a call.
    var body: String = ""
    var subscriptionId: Int?
    var fireAt: Date
    var status: ScheduledStatus = .pending
    var createdAt: Date = .now
    /// Calls only: keep redialling with the defaults from Settings when nobody answers.
    var autoRedial: Bool = false
    var finishedAt: Date?
    var note: String?

    /// A scheduled text that was not sent this long after its time is dropped, never sent late
    /// (a "good morning" must not go out at 3 pm because the Mac was asleep). Calls are stricter.
    var lateTolerance: TimeInterval { kind == .sms ? 300 : 120 }
}

// MARK: - Auto-redial

/// Progress of "call again until someone answers" for one number.
struct RedialState: Equatable {
    var callId: String
    var number: String
    var simId: Int
    var attempt: Int
    var maxAttempts: Int
    var delay: Int
    /// Set while waiting for the next attempt.
    var nextAt: Date?
}

/// Limits that keep auto-redial from turning into harassment or a runaway loop.
nonisolated enum RedialLimits {
    static let minDelay = 5
    static let maxAttempts = 20
    static let delays = [5, 10, 15, 30, 60, 120, 300]
    static let attempts = [3, 5, 10, 20]
}

nonisolated enum ScheduleLimits {
    static let maxPending = 100
    static let minLead: TimeInterval = 10
    static let maxLead: TimeInterval = 366 * 24 * 3600
    static let maxBodyLength = 1600
}

extension PhoneNumber {
    /// Digits with an optional leading "+" only: what the phone will accept for a call or text.
    nonisolated static func isDialable(_ raw: String) -> Bool {
        let n = normalize(raw)
        let digits = n.hasPrefix("+") ? n.dropFirst() : Substring(n)
        return digits.count >= 3 && digits.count <= 15 && digits.allSatisfy(\.isNumber)
    }
}
