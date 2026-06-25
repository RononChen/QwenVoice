import XCTest

#if targetEnvironment(simulator)

/// Simulator-only Studio generation UI tests using `IOSSimulatorTTSEngine`.
/// Runs against the shared warm app; each scenario gets a hermetic relaunch.
final class VocelloiOSSimulatorGenerationUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        VocelloUITestApp.shared.resetToStudio()
    }

    func testSimulatedGenerationCompletes() throws {
        VocelloUITestApp.shared.relaunchWith(backendScenario: "success")
        selectCustomMode()
        typeSampleScript()
        tapGenerate()

        let completePlayer = VocelloUITestApp.shared.element("studio_inlinePlayer")
        let completeByPlay = VocelloUITestApp.shared.button(labelPrefix: "Play")
        XCTAssertTrue(
            completePlayer.waitForExistence(timeout: 30) || completeByPlay.waitForExistence(timeout: 5),
            "Simulated generation should surface completion UI"
        )
        VocelloUITestApp.shared.captureScreenshot(named: "sim-generation-complete")
    }

    func testSimulatedGenerationFailureUI() throws {
        VocelloUITestApp.shared.relaunchWith(backendScenario: "fail")
        selectCustomMode()
        typeSampleScript()
        tapGenerate()

        let errorByID = VocelloUITestApp.shared.element("textInput_generationError")
        let errorByLabel = VocelloUITestApp.shared.button(labelPrefix: "Generation failed")
        XCTAssertTrue(
            errorByID.waitForExistence(timeout: 20) || errorByLabel.waitForExistence(timeout: 5),
            "Simulated failure scenario should surface generation error UI"
        )
        VocelloUITestApp.shared.captureScreenshot(named: "sim-generation-error")
    }

    func testSimulatedGenerationCancelMidFlight() throws {
        VocelloUITestApp.shared.relaunchWith(
            backendScenario: "cancel_mid",
            delayMilliseconds: 12_000
        )
        selectCustomMode()
        typeSampleScript()
        tapGenerate()

        guard let cancel = waitForCancelControl(timeout: 15) else {
            XCTFail("Cancel control should appear during slow generation")
            return
        }
        cancel.tap()

        let generate = VocelloUITestApp.shared.button("textInput_generateButton")
        XCTAssertTrue(generate.waitForExistence(timeout: 15), "Generate should return after cancel")
        VocelloUITestApp.shared.captureScreenshot(named: "sim-generation-cancelled")
    }

    // MARK: - Helpers

    private func selectCustomMode() {
        let byID = VocelloUITestApp.shared.element("generateSection_custom")
        let byLabel = VocelloUITestApp.shared.button(labelPrefix: "Custom")
        if byID.waitForExistence(timeout: 10) {
            if !byID.isSelected { byID.tap() }
        } else if byLabel.waitForExistence(timeout: 5), !byLabel.isSelected {
            byLabel.tap()
        }
    }

    private func typeSampleScript() {
        guard let app = VocelloUITestApp.shared.app else {
            XCTFail("Shared app not available")
            return
        }
        let editorByID = app.textViews["textInput_textEditor"].firstMatch
        let editor = editorByID.waitForExistence(timeout: 3)
            ? editorByID
            : app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Studio text editor should exist")
        editor.tap()
        editor.typeText("Hello from the simulator fake backend.")
        // Dismiss the software keyboard explicitly instead of relying on \n.
        let doneButton = app.keyboards.buttons["Done"]
        if doneButton.waitForExistence(timeout: 3) {
            doneButton.tap()
        } else {
            editor.typeText("\n")
        }
        _ = app.keyboards.element.waitForNonExistence(timeout: 10)
    }

    private func tapGenerate() {
        let generate = VocelloUITestApp.shared.button("textInput_generateButton")
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "Generate button should exist")
        XCTAssertTrue(generate.isEnabled, "Generate button should be enabled after typing")
        generate.tap()
    }

    private func waitForCancelControl(timeout: TimeInterval = 15) -> XCUIElement? {
        let byID = VocelloUITestApp.shared.button("textInput_cancelButton")
        let byPlayer = VocelloUITestApp.shared.button("studio_livePreview_cancel")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if byID.exists { return byID }
            if byPlayer.exists { return byPlayer }
            usleep(200_000)
        }
        return nil
    }
}

#endif
