import Foundation

enum L10n {
    static func value(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: value(key), locale: .current, arguments: arguments)
    }
}
