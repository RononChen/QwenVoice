import XCTest

/// macOS UI review capture tour — walks the sidebar screens and captures a screenshot of
/// each (`VocelloMacTestSupport.captureScreenshot` → `MAC_TEST_SCREENSHOT_DIR` + the
/// `.xcresult`), for visual review + baseline diffing against
/// `docs/macos-review-baselines/`. Run via `scripts/macos_test.sh review`. macOS is the
/// host (direct XCUITest capture; no iPhone Mirroring / no burn-in concern).
final class VocelloMacReviewTourUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Capture the canonical review screens in one tour. One method on purpose: a single
    /// `-only-testing` run captures every baseline together (one app session). Stable
    /// capture names are the baseline keys.
    func testCaptureReviewScreens() {
        let app = XCUIApplication()
        app.launchEnvironment["QWENVOICE_DEBUG"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["sidebar_customVoice"].waitForExistence(timeout: 60),
                      "app should mount (sidebar_customVoice appears)")

        visit(app, sidebar: "sidebar_customVoice",  named: "review-custom")
        visit(app, sidebar: "sidebar_voiceDesign",  named: "review-design")
        visit(app, sidebar: "sidebar_voiceCloning", named: "review-clone")
        visit(app, sidebar: "sidebar_history",      named: "review-history")
        visit(app, sidebar: "sidebar_voices",       named: "review-voices")
        visit(app, sidebar: "sidebar_settings",     named: "review-settings")
    }

    private func visit(_ app: XCUIApplication, sidebar: String, named name: String) {
        let btn = app.buttons[sidebar]
        guard btn.waitForExistence(timeout: 15) else {
            XCTFail("sidebar \(sidebar) should exist")
            return
        }
        if btn.isHittable { btn.click() }
        usleep(400_000)   // let the detail pane settle before the screenshot
        VocelloMacTestSupport.captureScreenshot(app, named: name)
    }
}
