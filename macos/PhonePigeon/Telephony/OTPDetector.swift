import Foundation

/// Local OTP / 2FA detector (spec §9.2). Runs entirely on-device.
enum OTPDetector {
    private static let keywords = ["otp", "code", "verification", "verify", "login", "log in", "passcode",
                                   "one-time", "one time", "2fa", "pin", "authentication", "security code"]
    private static let codeRegex = try! NSRegularExpression(pattern: #"(?<!\d)(?<!\d[.,])(?:[A-Z]-)?(\d{4,8})(?!\d)(?![.,]\d)"#)

    static func detect(in body: String) -> String? {
        let lower = body.lowercased()
        guard keywords.contains(where: lower.contains) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        // Prefer the first match that is not obviously a year or an amount.
        for m in codeRegex.matches(in: body, range: range) {
            guard let r = Range(m.range(at: 1), in: body) else { continue }
            let code = String(body[r])
            if code.count == 4, let y = Int(code), (1990...2099).contains(y) { continue }
            return code
        }
        return nil
    }
}
