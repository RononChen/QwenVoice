import XCTest

final class AppDisplayLanguageTests: XCTestCase {
    func testSupportedLocalizationIdentifiersAreCompleteAndStable() {
        XCTAssertEqual(
            AppDisplayLanguage.localizationIdentifiers,
            ["zh-Hans", "zh-Hant", "en", "ja", "de", "fr", "ru", "pt", "es", "it"]
        )
    }

    func testInvalidStoredPreferenceFallsBackToSystem() {
        XCTAssertEqual(AppDisplayLanguage.selection(from: nil), .system)
        XCTAssertEqual(AppDisplayLanguage.selection(from: "unknown"), .system)
        XCTAssertEqual(AppDisplayLanguage.selection(from: "pt"), .portuguese)
    }

    func testExplicitSelectionDoesNotDependOnSystemPreferences() {
        XCTAssertEqual(
            AppDisplayLanguage.portuguese.resolvedLocalizationIdentifier(
                preferredLanguages: ["zh-Hans"]
            ),
            "pt"
        )
    }

    func testSystemSelectionUsesSupportedFallback() {
        let resolved = AppDisplayLanguage.system.resolvedLocalizationIdentifier(
            preferredLanguages: ["nl-NL", "en-US"]
        )
        XCTAssertEqual(resolved, "en")
    }

    func testSystemSelectionMapsLanguageVariants() {
        XCTAssertEqual(
            AppDisplayLanguage.system.resolvedLocalizationIdentifier(
                preferredLanguages: ["zh-TW"]
            ),
            "zh-Hant"
        )
        XCTAssertEqual(
            AppDisplayLanguage.system.resolvedLocalizationIdentifier(
                preferredLanguages: ["pt-BR"]
            ),
            "pt"
        )
    }
}
