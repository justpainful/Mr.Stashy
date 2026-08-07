import Foundation
import Testing
@testable import MrStashy

/// The interface's text is only as good as the lookup behind it. These pin the two behaviours
/// that fail silently and look like a broken app rather than a bug: a count that reads
/// "1 item(s)", and a screen that switches language but keeps formatting numbers, sizes, and
/// dates for the device's language instead.
struct LocalizationTests {
    /// Restores the picker to whatever it was, so one test cannot leave the process in Arabic.
    private func withLanguage<T>(_ language: UserSettings.AppLanguage, _ body: () throws -> T) rethrows -> T {
        L10n.setLanguage(language)
        defer { L10n.setLanguage(.system) }
        return try body()
    }

    @Test func englishCountsUseARealPluralRuleRatherThanItemParentheses() {
        withLanguage(.english) {
            #expect(L10n.format("queue.itemCount", Int64(1)) == "1 item")
            #expect(L10n.format("queue.itemCount", Int64(3)) == "3 items")
            #expect(L10n.format("library.mediaCount", Int64(1)) == "1 item")
            #expect(L10n.format("catch.ready.count", Int64(1)) == "Found 1 item.")
            #expect(L10n.format("catch.ready.count", Int64(7)) == "Found 7 items.")
            // No shipped string may still carry the placeholder plural.
            #expect(!L10n.format("queue.itemCount", Int64(2)).contains("(s)"))
        }
    }

    @Test func arabicCountsUseTheirOwnCategoriesRatherThanOneForm() {
        withLanguage(.arabic) {
            let one = L10n.format("queue.itemCount", Int64(1))
            let two = L10n.format("queue.itemCount", Int64(2))
            let few = L10n.format("queue.itemCount", Int64(3))
            let many = L10n.format("queue.itemCount", Int64(11))
            // Arabic distinguishes singular, dual, and two plural bands. If the stringsdict is
            // not being consulted these all collapse to the same sentence.
            #expect(one != two)
            #expect(two != few)
            #expect(few != many)
            #expect(one == "عنصر واحد")
            #expect(two == "عنصران")
        }
    }

    @Test func positionalPluralsPluraliseOffTheRightArgument() {
        withLanguage(.english) {
            #expect(L10n.format("resolver.warning.partialMedia", Int64(1), Int64(1)).hasPrefix("Saved 1 of 1 item."))
            #expect(L10n.format("resolver.warning.partialMedia", Int64(1), Int64(5)).hasPrefix("Saved 1 of 5 items."))
        }
    }

    @Test func everyPlatformAndSupportStatusHasATranslationInBothLanguages() {
        for language in [UserSettings.AppLanguage.english, .arabic] {
            withLanguage(language) {
                for platform in Platform.allCases {
                    let title = L10n.value(platform.titleKey)
                    #expect(title != platform.titleKey, "\(platform.rawValue) has no \(language.rawValue) name")
                }
                for status in SupportStatus.allCases {
                    #expect(L10n.value(status.titleKey) != status.titleKey)
                }
            }
        }
    }

    /// Every shipped capability paragraph is a key, not prose. This is the largest block of text
    /// in the app and the text that explains why a source cannot be captured.
    @Test func everyCapabilityExplanationIsTranslatedInBothLanguages() {
        for language in [UserSettings.AppLanguage.english, .arabic] {
            withLanguage(language) {
                for capability in PlatformCapabilityRegistry.baseline {
                    #expect(
                        L10n.localizedIfPresent(capability.evidenceSource) != nil,
                        "\(capability.platform.rawValue) has no \(language.rawValue) explanation"
                    )
                    #expect(!capability.evidence.hasPrefix("support.evidence."))
                }
            }
        }
    }

    @Test func formattedValuesFollowTheChosenLanguageRatherThanTheDevice() {
        let arabic = withLanguage(.arabic) { L10n.byteCount(1_500_000) }
        let english = withLanguage(.english) { L10n.byteCount(1_500_000) }
        // Arabic uses its own digits and unit names, so the two renderings must differ.
        #expect(arabic != english)
        #expect(english.contains("MB"))
    }

    /// A size or a duration dropped into a right-to-left sentence reorders unless it is isolated,
    /// which is how "1.2 MB of 5 MB" became "5 MB of 1.2 MB" on screen.
    @Test func formattedValuesCarryADirectionalIsolate() {
        let value = L10n.byteCount(2_048)
        #expect(value.hasPrefix("\u{2068}"))
        #expect(value.hasSuffix("\u{2069}"))
    }

    @Test func aMissingKeyIsReportedRatherThanReturnedAsItself() {
        #expect(L10n.localizedIfPresent("stashy.definitely.not.a.key") == nil)
        #expect(L10n.localizedIfPresent("action.done") != nil)
    }
}
