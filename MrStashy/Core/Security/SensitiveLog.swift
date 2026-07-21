import Foundation

enum SensitiveLog {
    static func redact(_ message: String) -> String {
        message.replacingOccurrences(of: #"(?i)(bot|bearer|token)[=: ]+[^\\s&]+"#, with: "$1=[REDACTED]", options: .regularExpression)
    }
}
