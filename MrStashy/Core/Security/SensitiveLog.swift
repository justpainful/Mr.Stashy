import Foundation

enum SensitiveLog {
    static func redact(_ message: String) -> String {
        var redacted = message
        let patterns = [
            #"(?i)\b(authorization|cookie|set-cookie|bot|bearer|token|session|api[_-]?key)\b\s*[=:]\s*[^\s&,;]+"#,
            #"(?i)([?&](?:access_token|token|signature|sig|key|session)=)[^&#\s]+"#
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(of: pattern, with: "$1=[REDACTED]", options: .regularExpression)
        }
        return redacted
    }
}
