import XCTest

/// Thin UI-flow smoke for the Vocello iPhone app — the durable replacement (paired
/// with `scripts/ios_device.sh`) for the deprecated screen-mirror UI-driving method.
///
/// Intentionally shallow: it does NOT generate audio (that's the headless
/// `IOSAutorunHarness` / `vocello bench` path). It asserts the app launches and the
/// 4-tab information architecture + Studio composer/mode-control are reachable, keyed
/// off the stable `accessibilityIdentifier`s (kept through refactors per CLAUDE.md).
///
/// Run on a simulator (fast, no signing) or the device:
///   xcodebuild test -scheme VocelloiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///   xcodebuild test -scheme VocelloiOS -destination 'id=<device-udid>'
final class VocelloiOSSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        dismissOnboardingIfPresent()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Launches and confirms the Studio tab + its composer and Custom/Design/Clone
    /// mode control are present.
    func testStudioLaunchSurface() {
        XCTAssertTrue(
            waitFor("rootTab_studio"),
            "Studio tab should exist on launch"
        )
        XCTAssertTrue(
            waitFor("screen_generateStudio"),
            "Studio screen should be the default surface"
        )
        XCTAssertTrue(
            waitFor("generateSectionPicker"),
            "Custom/Design/Clone mode control should be present in Studio"
        )
        XCTAssertTrue(
            element("generateSection_custom").exists
                && element("generateSection_design").exists
                && element("generateSection_clone").exists,
            "all three mode segments should be present"
        )
        XCTAssertTrue(
            waitFor("textInput_textEditor"),
            "Studio composer text editor should be present"
        )
    }

    /// Confirms each of the 4 tabs navigates to its screen.
    func testTabNavigation() {
        let tabs: [(tab: String, screen: String)] = [
            ("rootTab_voices", "screen_voices"),
            ("rootTab_history", "historyModeFilter"),
            ("rootTab_settings", "iosSettingsOpenSystemSettings"),
            ("rootTab_studio", "screen_generateStudio"),
        ]
        for (tab, screen) in tabs {
            let tabElement = element(tab)
            XCTAssertTrue(tabElement.waitForExistence(timeout: 10), "tab \(tab) should exist")
            tabElement.tap()
            XCTAssertTrue(
                waitFor(screen, timeout: 10),
                "tapping \(tab) should reveal \(screen)"
            )
        }
    }

    // MARK: - Helpers

    /// Resolve an element by accessibility identifier across any element type
    /// (SwiftUI surfaces vary the underlying XCUIElementType).
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @discardableResult
    private func waitFor(_ identifier: String, timeout: TimeInterval = 15) -> Bool {
        element(identifier).waitForExistence(timeout: timeout)
    }

    /// First-run onboarding (if shown) sits in front of the tabs — skip past it so
    /// the smoke isn't first-launch-order dependent.
    private func dismissOnboardingIfPresent() {
        let skip = element("onboarding_skip")
        if skip.waitForExistence(timeout: 3) {
            skip.tap()
            return
        }
        let cta = element("onboarding_cta")
        if cta.exists { cta.tap() }
    }
}
