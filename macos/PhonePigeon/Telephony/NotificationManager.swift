import AppKit
import UserNotifications

/// Native notifications: messages (with inline reply), OTP ("Copy 123456") and incoming calls.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    weak var appState: AppState?
    private let center = UNUserNotificationCenter.current()
    private var registeredCategories: Set<UNNotificationCategory> = []

    enum Category { static let message = "MESSAGE", call = "CALL" }
    enum Action { static let reply = "REPLY", copy = "COPY", markRead = "MARK_READ", answer = "ANSWER", decline = "DECLINE" }

    func bootstrap() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Action.reply, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let markRead = UNNotificationAction(identifier: Action.markRead, title: "Mark as Read")
        let answer = UNNotificationAction(identifier: Action.answer, title: "Answer", options: [.foreground])
        let decline = UNNotificationAction(identifier: Action.decline, title: "Decline", options: [.destructive])
        registeredCategories = [
            UNNotificationCategory(identifier: Category.message, actions: [reply, markRead], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.call, actions: [answer, decline], intentIdentifiers: []),
        ]
        center.setNotificationCategories(registeredCategories)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// "Pixel 9 · SIM 1" when several phones are paired, so it is clear which phone a notification came from.
    private func subtitle(sim: SimCard?, phone: PhoneSession) -> String {
        let simPart = sim?.pillLabel ?? ""
        guard (appState?.phones.count ?? 1) > 1 else { return simPart }
        return simPart.isEmpty ? phone.name : "\(phone.name) · \(simPart)"
    }

    func notifyMessage(_ message: SmsMessage, title: String, sim: SimCard?, phone: PhoneSession) {
        guard appState?.settings.notificationsEnabled ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle(sim: sim, phone: phone)
        content.body = message.body
        content.sound = .default
        content.threadIdentifier = "\(phone.id)|\(message.threadId)"
        content.userInfo = ["threadId": message.threadId, "phoneId": phone.id]

        if let code = OTPDetector.detect(in: message.body) {
            // Action titles are static per category, so register a one-off category for this code.
            let catId = "OTP-\(code)"
            let copy = UNNotificationAction(identifier: Action.copy, title: "Copy \(code)")
            registeredCategories.insert(UNNotificationCategory(identifier: catId, actions: [copy], intentIdentifiers: []))
            center.setNotificationCategories(registeredCategories)
            content.categoryIdentifier = catId
            content.userInfo["otp"] = code
            content.title = "\(title) · Verification code"
            content.interruptionLevel = .timeSensitive
        } else {
            content.categoryIdentifier = Category.message
        }
        center.add(UNNotificationRequest(identifier: message.messageId, content: content, trigger: nil))
    }

    /// A notification that appeared on the phone (WhatsApp, banking apps, …), shown as a Mac banner.
    func notifyPhoneNotification(_ n: PhoneNotification, phone: String?, icon: Data? = nil) {
        guard appState?.settings.notificationsEnabled ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = n.title.isEmpty ? n.appName : n.title
        content.subtitle = [n.appName, phone].compactMap { $0 }.joined(separator: " · ")
        content.body = n.text
        content.sound = .default
        content.threadIdentifier = "phone-\(n.packageName)"
        content.userInfo = ["phoneNotification": n.id]
        // The app's own icon next to the banner (macOS shows PhonePigeon's icon on the left, so the phone app goes on the right).
        if let icon, let url = Self.writeIcon(icon, package: n.packageName),
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: url, options: nil) {
            content.attachments = [attachment]
        }
        center.add(UNNotificationRequest(identifier: "phone-\(n.id)", content: content, trigger: nil))
    }

    func notifyIncomingCall(_ call: CallSession, sim: SimCard?, phone: PhoneSession) {
        let content = UNMutableNotificationContent()
        content.title = call.title
        let via = (appState?.phones.count ?? 1) > 1 ? " · \(phone.name)" : ""
        content.subtitle = "Incoming call" + via + (sim.map { " · \($0.pillLabel)" } ?? "")
        content.body = PhoneNumber.pretty(call.remoteAddress)
        content.sound = .defaultCritical
        content.categoryIdentifier = Category.call
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["callId": call.id, "phoneId": phone.id]
        center.add(UNNotificationRequest(identifier: "call-\(call.id)", content: content, trigger: nil))
    }

    /// A scheduled text or call just ran (or was missed).
    func notifyScheduled(title: String, body: String) {
        guard appState?.settings.notificationsEnabled ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "scheduled-\(UUID().uuidString)", content: content, trigger: nil))
    }

    private static func writeIcon(_ data: Data, package: String) -> URL? {
        let safe = package.filter { $0.isLetter || $0.isNumber || $0 == "." }
        guard !safe.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(safe)-\(UUID().uuidString.prefix(6)).png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    func clearCall(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["call-\(id)"])
    }

    func clearThread(_ threadId: String) {
        center.getDeliveredNotifications { notes in
            let ids = notes.filter { $0.request.content.threadIdentifier.hasSuffix(threadId) }.map(\.request.identifier)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let threadId = info["threadId"] as? String
        let phoneId = info["phoneId"] as? String
        let otp = info["otp"] as? String
        let callId = info["callId"] as? String
        await MainActor.run {
            guard let app = self.appState else { return }
            switch action {
            case Action.copy: if let otp { Clipboard.copySensitive(otp, clearAfter: app.settings.otpClearSeconds) }
            case Action.reply: if let threadId, let text, !text.isEmpty { app.reply(phoneId: phoneId, threadId: threadId, body: text) }
            case Action.markRead: if let threadId { app.markRead(phoneId: phoneId, threadId: threadId) }
            case Action.answer: if callId != nil { app.performCallAction(phoneId: phoneId, .answer) }
            case Action.decline: if callId != nil { app.performCallAction(phoneId: phoneId, .reject) }
            default:
                NSApp.activate(ignoringOtherApps: true)
                if let threadId { app.open(phoneId: phoneId, threadId: threadId) }
            }
        }
    }
}

enum Clipboard {
    /// Copies a secret and wipes it after `clearAfter` seconds if the user hasn't copied anything else.
    static func copySensitive(_ value: String, clearAfter seconds: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        let change = pb.changeCount
        guard seconds > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        }
    }

    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
