import XCTest

final class InitialSidebarItemOverrideTests: XCTestCase {
    func testResolvesEverySupportedValueWhenDebugModeIsEnabled() {
        let values: [(String, InitialSidebarItemOverride)] = [
            ("settings", .settings),
            ("history", .history),
            ("custom", .custom),
        ]

        for (rawValue, expected) in values {
            XCTAssertEqual(
                InitialSidebarItemOverride.resolve(
                    environment: [InitialSidebarItemOverride.environmentKey: rawValue],
                    debugModeEnabled: true
                ),
                expected
            )
        }
    }

    func testNormalizesWhitespaceAndCase() {
        XCTAssertEqual(
            InitialSidebarItemOverride.resolve(
                environment: [InitialSidebarItemOverride.environmentKey: "  HiStOrY  "],
                debugModeEnabled: true
            ),
            .history
        )
    }

    func testRejectsOverrideWhenDebugModeIsDisabled() {
        for rawValue in ["settings", "history", "custom"] {
            XCTAssertNil(
                InitialSidebarItemOverride.resolve(
                    environment: [InitialSidebarItemOverride.environmentKey: rawValue],
                    debugModeEnabled: false
                )
            )
        }
    }

    func testRejectsMissingEmptyUnknownAndLegacyValues() {
        let invalidEnvironments: [[String: String]] = [
            [:],
            [InitialSidebarItemOverride.environmentKey: ""],
            [InitialSidebarItemOverride.environmentKey: "unknown"],
            [InitialSidebarItemOverride.environmentKey: "customVoice"],
            [InitialSidebarItemOverride.environmentKey: "Custom Voice"],
        ]

        for environment in invalidEnvironments {
            XCTAssertNil(
                InitialSidebarItemOverride.resolve(
                    environment: environment,
                    debugModeEnabled: true
                )
            )
        }
    }
}
