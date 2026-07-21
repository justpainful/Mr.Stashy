import Foundation

struct UserSettings: Codable, Equatable, Sendable {
    enum Quality: String, Codable, CaseIterable { case original, askEveryTime, dataSaver }
    enum SaveMode: String, Codable, CaseIterable { case fullPost, mediaOnly, askEveryTime }
    enum Appearance: String, Codable, CaseIterable { case system, light, dark }

    var quality: Quality = .original
    var saveMode: SaveMode = .askEveryTime
    var saveToPhotos = false
    var allowCellular = true
    var maxParallelDownloads = 3
    var appearance: Appearance = .system
    var reduceMotion = false

    private enum CodingKeys: String, CodingKey {
        case quality, saveMode, saveToPhotos, allowCellular, maxParallelDownloads, appearance, reduceMotion, reduceCharacterMotion
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        quality = try values.decodeIfPresent(Quality.self, forKey: .quality) ?? .original
        saveMode = try values.decodeIfPresent(SaveMode.self, forKey: .saveMode) ?? .askEveryTime
        saveToPhotos = try values.decodeIfPresent(Bool.self, forKey: .saveToPhotos) ?? false
        allowCellular = try values.decodeIfPresent(Bool.self, forKey: .allowCellular) ?? true
        maxParallelDownloads = try values.decodeIfPresent(Int.self, forKey: .maxParallelDownloads) ?? 3
        appearance = try values.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        let legacyReduceMotion = try values.decodeIfPresent(Bool.self, forKey: .reduceCharacterMotion)
        reduceMotion = try values.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? legacyReduceMotion ?? false
    }

    static func load() -> UserSettings {
        guard let data = UserDefaults.standard.data(forKey: "user-settings"), let settings = try? JSONDecoder().decode(UserSettings.self, from: data) else { return .init() }
        return settings
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "user-settings") }
}
