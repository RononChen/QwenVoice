import XCTest

/// Tier-A fake-backend error surface.
///
/// Launches its own app with `QVOICE_FAKE_ENGINE_SCENARIO=generateError` so
/// `FakeTTSEngine.generate` throws, exercising the Studio's failure UI
/// (`textInput_generationError`) deterministically. Self-launches (rather than using the
/// shared coordinator) because the error scenario is set per-launch. Runs anywhere the
/// fake backend runs (Simulator/CI/device).
final class VocelloiOSFakeGenerationErrorUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        installSystemAlertMonitor()

        VocelloUITestApp.shared.forceTerminate()
        Thread.sleep(forTimeInterval: 1.0)
        app = XCUIApplication()
        app.launchEnvironment["QVOICE_FAKE_ENGINE"] = "1"
        app.launchEnvironment["QVOICE_FAKE_ENGINE_SCENARIO"] = "generateError"
        app.launchEnvironment["QVOICE_IOS_SKIP_ONBOARDING"] = "1"
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        VocelloUITestApp.dismissOnboardingIfPresent(in: app)
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testFakeGenerationSurfacesError() {
        XCTAssertTrue(
            element("rootTab_studio").waitForExistence(timeout: 30),
            "Studio tab should be visible after launch"
        )

        let customMode = element("generateSection_custom")
        XCTAssertTrue(customMode.waitForExistence(timeout: 15), "Custom mode segment should exist")
        if !customMode.isSelected { customMode.tap() }

        let editor = element("textInput_textEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Composer text editor should be queryable")
        editor.tap()
        editor.typeText("This generation is going to fail.")
        editor.typeText("\n")
        _ = app.keyboards.element.waitForNonExistence(timeout: 10)

        let generate = element("textInput_generateButton")
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "Generate button should be present")
        generate.tap()

        let errorBar = element("textInput_generationError")
        XCTAssertTrue(
            errorBar.waitForExistence(timeout: 20),
            "The generation error surface should appear when the fake engine fails"
        )
        captureScreenshot(named: "fake-generate-error")
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func captureScreenshot(named name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            activity.add(attachment)
        }
    }
}
