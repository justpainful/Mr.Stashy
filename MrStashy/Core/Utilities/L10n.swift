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

    static func setLanguage(_ language: Settings.Language) {
        lock.lock()
        defer { lock.unlock() }
        guard let identifier = language.localeIdentifier else {
            overrideBundle = nil
            overrideIdentifier = nil
            return
        }
        overrideBundle = localizationBundle(for: identifier)
        overrideIdentifier = overrideBundle == nil ? nil : identifier
    }

    /// Whether the interface is currently right-to-left, following the in-app choice first.
    static var isRightToLeft: Bool {
        lock.lock()
        let identifier = overrideIdentifier
        lock.unlock()
        if let identifier { return identifier == "ar" }
        return Locale.current.language.characterDirection == .rightToLeft
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

    /// The translation for `key`, or `nil` when neither bundle has one. Used where a value may
    /// be either a key Stashy authored or prose generated elsewhere, so the first is translated
    /// and the second passes through instead of being replaced by its own identifier.
    static func localizedIfPresent(_ key: String) -> String? {
        let sentinel = "\u{0}stashy.missing"
        lock.lock()
        let bundle = overrideBundle
        lock.unlock()
        if let bundle {
            let translated = bundle.localizedString(forKey: key, value: sentinel, table: nil)
            if translated != sentinel { return translated }
        }
        let fallback = Bundle.main.localizedString(forKey: key, value: sentinel, table: nil)
        return fallback == sentinel ? nil : fallback
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: value(key), locale: activeLocale, arguments: arguments)
    }

    /// Looks up `key.one`, `key.two`, `key.few`… by the active language's plural rules and
    /// formats the count into it. Arabic has six forms; `String(format:)` alone would show
    /// "3 items" grammar to an Arabic reader.
    static func plural(_ key: String, _ count: Int) -> String {
        let category = pluralCategory(count)
        let candidates = ["\(key).\(category)", "\(key).other", key]
        for candidate in candidates {
            if let found = localizedIfPresent(candidate) {
                return String(format: found, locale: activeLocale, Int64(count))
            }
        }
        return "\(count)"
    }

    static func pluralCategory(_ count: Int) -> String {
        let language = activeLocale.language.languageCode?.identifier ?? "en"
        if language == "ar" {
            switch count {
            case 0: return "zero"
            case 1: return "one"
            case 2: return "two"
            default:
                let remainder = count % 100
                if (3 ... 10).contains(remainder) { return "few" }
                if (11 ... 99).contains(remainder) { return "many" }
                return "other"
            }
        }
        return count == 1 ? "one" : "other"
    }

    static var activeLocale: Locale {
        lock.lock()
        let identifier = overrideIdentifier
        lock.unlock()
        guard let identifier else { return .autoupdatingCurrent }
        return Locale(identifier: identifier)
    }

    // MARK: - Formatted values
    //
    // `ByteCountFormatter` and the bare `Date.formatted()`/`Duration.formatted()` overloads all
    // resolve against `Locale.current`, which is the *device's* language — so an Arabic interface
    // on an English phone showed English sizes, dates, and durations. Every value that reaches the
    // interface goes through one of these, so there is a single place to get it right.

    static func byteCount(_ bytes: Int64) -> String {
        isolated(bytes.formatted(.byteCount(style: .file).locale(activeLocale)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return isolated("0") }
        return isolated(
            Duration.seconds(Int(seconds.rounded()))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated).locale(activeLocale))
        )
    }

    static func date(_ value: Date, time: Date.FormatStyle.TimeStyle = .shortened) -> String {
        isolated(value.formatted(Date.FormatStyle(date: .abbreviated, time: time).locale(activeLocale)))
    }

    /// Wraps a value in a Unicode first-strong isolate so it keeps its own direction inside a
    /// sentence of the opposite one. Without it, "1.2 MB / 5 MB" inside an Arabic paragraph
    /// visually reorders to "5 MB / 1.2 MB" — which tells a person the download is bigger than
    /// the file it is downloading.
    static func isolated(_ value: String) -> String {
        "\u{2068}\(value)\u{2069}"
    }

    private static func localizationBundle(for identifier: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
