import Foundation

struct Settings: Codable, Equatable, Sendable {
    enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
    enum Language: String, Codable, CaseIterable, Sendable {
        case system, english, arabic

        var localeIdentifier: String? {
            switch self {
            case .system: nil
            case .english: "en"
            case .arabic: "ar"
            }
        }
    }

    var quality: QualityPreference = .best
    var saveToPhotos = true
    var askBeforeSaving = true
    var allowCellular = true
    var parallelDownloads = 2
    var appearance: Appearance = .system
    var language: Language = .system
    var onboardingDone = false

    private enum CodingKeys: String, CodingKey {
        case quality, saveToPhotos, askBeforeSaving, allowCellular, parallelDownloads, appearance, language, onboardingDone
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        quality = try values.decodeIfPresent(QualityPreference.self, forKey: .quality) ?? .best
        saveToPhotos = try values.decodeIfPresent(Bool.self, forKey: .saveToPhotos) ?? true
        askBeforeSaving = try values.decodeIfPresent(Bool.self, forKey: .askBeforeSaving) ?? true
        allowCellular = try values.decodeIfPresent(Bool.self, forKey: .allowCellular) ?? true
        parallelDownloads = try values.decodeIfPresent(Int.self, forKey: .parallelDownloads) ?? 2
        appearance = try values.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        language = try values.decodeIfPresent(Language.self, forKey: .language) ?? .system
        onboardingDone = try values.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
    }

    static let storageKey = "stashy.settings.v2"

    static func load(from defaults: UserDefaults = .standard) -> Settings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
