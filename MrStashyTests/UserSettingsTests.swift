import Foundation
import Testing
@testable import MrStashy

struct UserSettingsTests {
    @Test func decodesOlderSettingsWithoutLanguageOrLegacyQualityPrompt() throws {
        let data = Data(#"{"quality":"askEveryTime","saveMode":"askEveryTime","appearance":"dark"}"#.utf8)
        let settings = try JSONDecoder().decode(UserSettings.self, from: data)

        #expect(settings.quality == .askEveryTime)
        #expect(settings.language == .system)
        #expect(settings.appearance == .dark)
    }

    @Test func languageRoundTrips() throws {
        var settings = UserSettings()
        settings.language = .arabic

        let restored = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.language == .arabic)
    }
}
