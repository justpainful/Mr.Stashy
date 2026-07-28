import Foundation

enum SensitiveLog {
    /// Ordered so the broadest header form is neutralised first. Matching only `name = value`
    /// left `Authorization: Bearer <token>` — the most common shape of all — fully in the clear,
    /// because the secret there follows whitespace rather than a separator.
    private static let headerPatterns = [
        #"(?i)\b(authorization|proxy-authorization)\b\s*[:=]\s*\S+(\s+\S+)?"#,
        #"(?i)\b(bearer|bot|basic)\b\s+[A-Za-z0-9._~+/-]{4,}={0,2}"#,
        #"(?i)\b(cookie|set-cookie|token|session|api[_-]?key|secret|password)\b\s*[=:]\s*[^\s&,;]+"#
    ]
    private static let queryPattern =
        #"(?i)([?&](?:access_token|token|signature|sig|key|session|x-signature|password|passwd)=)[^&#\s]+"#

    static func redact(_ message: String) -> String {
        var redacted = message
        for pattern in headerPatterns {
            redacted = redacted.replacingOccurrences(of: pattern, with: "$1=[REDACTED]", options: .regularExpression)
        }
        // A redacted address keeps its parameter names so the log stays diagnosable.
        redacted = redacted.replacingOccurrences(of: queryPattern, with: "$1[REDACTED]", options: .regularExpression)
        return redacted
    }
}
