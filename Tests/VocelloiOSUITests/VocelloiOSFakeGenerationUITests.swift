import XCTest

/// Tier-A fake-backend generation flow.
///
/// With `QVOICE_FAKE_ENGINE=1` the model reports as installed and `FakeTTSEngine.generate`
/// writes a tiny silent clip in ~250 ms, so the full Studio backend-dependent path —
/// idle → Generate → Generating → inline player — is exercised deterministically with no
/// real model, no Metal, and no 120 s timeouts. Runs on Simulator/CI and device.
final class VocelloiOSFakeGenerationUITests: XCTestCase {

    override class func setUp() {
        super.setUp()
        VocelloUITestBootstrap.registerObserverIfNeeded()
        VocelloUITestApp.shared.retainIfNeeded()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        installSystemAlertMonitor()
        VocelloUITestApp.shared.resetToStudio()
    }

    /// Type a short script in Custom mode, tap Generate, and confirm the inline player
    /// appears — proving the fake backend drives the Studio's generate → ready states.
    func testFakeGenerationProducesPlayer() {
        let app = VocelloUITestApp.shared

        // The fake reports the model installed, so the Generate CTA (not the Install CTA)
        // is shown once we are in Custom mode with text entered.
        let customMode = app.element("generateSection_custom")
        XCTAssertTrue(customMode.waitForExistence(timeout: 15), "Custom mode segment should exist")
        if !customMode.isSelected { customMode.tap() }

        let editor = app.element("textInput_textEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Composer text editor should be queryable")
        editor.tap()
        editor.typeText("Hello from the fake engine.")
        // The editor's Return is configured as Done and dismisses the keyboard.
        editor.typeText("\n")
        _ = app.app.keyboards.element.waitForNonExistence(timeout: 10)
        app.captureScreenshot(named: "fake-generate-typed")

        let generate = app.element("textInput_generateButton")
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "Generate button should be present")
        XCTAssertTrue(generate.isEnabled, "Generate should be enabled after typing")
        generate.tap()
        app.captureScreenshot(named: "fake-generate-tapped")

        let player = app.element("studio_inlinePlayer")
        if !player.waitForExistence(timeout: 20) {
            // Surface why: if generation was blocked/failed, the Studio shows an error bar.
            let errorBar = app.element("textInput_generationError")
            let detail = errorBar.exists ? (errorBar.label.isEmpty ? errorBar.value as? String ?? "" : errorBar.label) : "<no error bar>"
            app.captureScreenshot(named: "fake-generate-no-player")
            XCTFail("Inline player should appear after the fake generation completes. Error surface: \(detail)")
        }
        app.captureScreenshot(named: "fake-generate-player")
    }
}
