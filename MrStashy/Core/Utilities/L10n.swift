import Foundation

/// Resolves interface text against the language the person chose in Settings.
///
/// `NSLocalizedString` and `String(localized:)` both read the app bundle's own preferred
/// localization and ignore the SwiftUI locale environment, so a language picker that only set
/// that environment changed date formatting and nothing else. Pointing every lookup at the
/// bundle for the selected language is what actually switches the interface.
enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrideBundle: Bundle?
    nonisolated(unsafe) private static var overrideIdentifier: String?

    static func setLanguage(_ language: UserSettings.AppLanguage) {
        lock.lock()
        defer { lock.unlock() }
        switch language {
        case .system:
            overrideBundle = nil
            overrideIdentifier = nil
        case .english:
            overrideBundle = localizationBundle(for: "en")
            overrideIdentifier = overrideBundle == nil ? nil : "en"
        case .arabic:
            overrideBundle = localizationBundle(for: "ar")
            overrideIdentifier = overrideBundle == nil ? nil : "ar"
        }
    }

    static func value(_ key: String) -> String {
        lock.lock()
        let bundle = overrideBundle
        lock.unlock()
        guard let bundle else { return Bundle.main.localizedString(forKey: key, value: nil, table: nil) }
        let translated = bundle.localizedString(forKey: key, value: key, table: nil)
        // A bundle without an entry returns the key. Falling back to the main bundle keeps a
        // newly added string readable instead of showing a raw identifier.
        return translated == key ? Bundle.main.localizedString(forKey: key, value: nil, table: nil) : translated
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: value(key), locale: activeLocale, arguments: arguments)
    }

    static var activeLocale: Locale {
        lock.lock()
        let identifier = overrideIdentifier
        lock.unlock()
        guard let identifier else { return .autoupdatingCurrent }
        return Locale(identifier: identifier)
    }

    private static func localizationBundle(for identifier: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
