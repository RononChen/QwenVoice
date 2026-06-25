import XCTest

#if targetEnvironment(simulator)

/// Simulator-only Studio generation UI tests using `IOSSimulatorTTSEngine`.
///
/// Exercises generate/complete and error affordances without MLX. Real generation
/// quality and cold-launch MLX paths stay on device (`ios_device.sh ui-test --cold`).
final class VocelloiOSSimulatorGenerationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        VocelloUITestApp.shared.forceTerminate()
        Thread.sleep(forTimeInterval: 0.5)

        app = XCUIApplication()
        app.launchEnvironment["QVOICE_SIM_FAKE_MODELS"] = "all"
        app.launchEnvironment["QVOICE_SIM_SEED_DATA"] = "voices,history"
        app.launchEnvironment["QVOICE_SIM_BACKEND_SCENARIO"] = "success"
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        VocelloUITestApp.dismissOnboardingIfPresent(in: app)
        selectCustomMode()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testSimulatedGenerationCompletes() throws {
        typeSampleScript()
        tapGenerate()

        let completePlayer = app.descendants(matching: .any)["studio_inlinePlayer"]
        let completeByPlay = app.buttons.matching(NSPredicate(format: "label == %@", "Play")).firstMatch
        XCTAssertTrue(
            completePlayer.waitForExistence(timeout: 30) || completeByPlay.waitForExistence(timeout: 5),
            "Simulated generation should surface completion UI"
        )
        captureScreenshot(named: "sim-generation-complete")
    }

    func testSimulatedGenerationFailureUI() throws {
        VocelloUITestApp.shared.forceTerminate()
        app = XCUIApplication()
        app.launchEnvironment["QVOICE_SIM_FAKE_MODELS"] = "all"
        app.launchEnvironment["QVOICE_SIM_BACKEND_SCENARIO"] = "fail"
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        VocelloUITestApp.dismissOnboardingIfPresent(in: app)
        selectCustomMode()

        typeSampleScript()
        tapGenerate()

        let errorByID = app.descendants(matching: .any)["textInput_generationError"]
        let errorByLabel = app.buttons.matching(NSPredicate(format: "label == %@", "Generation failed")).firstMatch
        XCTAssertTrue(
            errorByID.waitForExistence(timeout: 20) || errorByLabel.waitForExistence(timeout: 5),
            "Simulated failure scenario should surface generation error UI"
        )
        captureScreenshot(named: "sim-generation-error")
    }

    func testSimulatedGenerationCancelMidFlight() throws {
        VocelloUITestApp.shared.forceTerminate()
        app = XCUIApplication()
        app.launchEnvironment["QVOICE_SIM_FAKE_MODELS"] = "all"
        app.launchEnvironment["QVOICE_SIM_BACKEND_SCENARIO"] = "cancel_mid"
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        VocelloUITestApp.dismissOnboardingIfPresent(in: app)
        selectCustomMode()

        typeSampleScript()
        tapGenerate()

        let cancel = app.buttons.matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "Cancel control should appear during slow generation")
        cancel.tap()

        let generate = app.buttons.matching(NSPredicate(format: "label == %@", "Generate")).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 15), "Generate should return after cancel")
        captureScreenshot(named: "sim-generation-cancelled")
    }

    // MARK: - Helpers

    private func selectCustomMode() {
        let byID = app.descendants(matching: .any)["generateSection_custom"]
        let byLabel = app.buttons.matching(NSPredicate(format: "label == %@", "Custom")).firstMatch
        if byID.waitForExistence(timeout: 10) {
            if !byID.isSelected { byID.tap() }
        } else if byLabel.waitForExistence(timeout: 5), !byLabel.isSelected {
            byLabel.tap()
        }
    }

    private func typeSampleScript() {
        let editorByID = app.descendants(matching: .any)["textInput_textEditor"]
        let editor = editorByID.waitForExistence(timeout: 5) ? editorByID : app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Studio text editor should exist")
        editor.tap()
        editor.typeText("Hello from the simulator fake backend.")
        editor.typeText("\n")
        _ = app.keyboards.element.waitForNonExistence(timeout: 10)
    }

    private func tapGenerate() {
        let generate = app.buttons.matching(NSPredicate(format: "label == %@", "Generate")).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "Generate button should exist")
        XCTAssertTrue(generate.isEnabled, "Generate button should be enabled after typing")
        generate.tap()
    }

    private func captureScreenshot(named name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#endif
