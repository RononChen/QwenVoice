import XCTest

/// On-device regression for the iOS model download manager (Tier B).
///
/// Runs on a real iPhone with the **real** backend (no `QVOICE_FAKE_ENGINE`) so it uses
/// the production URLSession download stack. It is skipped on the Simulator/CI (compile-time
/// gate) because the real engine can't initialize there. To avoid downloading the full ~2.3 GB
/// model, the test only verifies the **cancel** path: start a download, tap Cancel, choose
/// Cancel Download in the confirmation dialog, and confirm the Install button returns
/// (Cancel discards the partial; there is no Pause/Resume).
final class VocelloiOSOnDeviceDownloadUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        // Tier B: real download backend on a paired device only (compile-time gate).
        try XCTSkipUnless(
            UITestTier.canRunRealEngine,
            "Tier B (real on-device download) runs on a paired device only — MLX cannot run on the iOS Simulator."
        )

        installSystemAlertMonitor()

        // Self-launch a fresh, real-engine app (no fake flag) so the production URLSession
        // download stack is exercised. Skip onboarding so we land on Studio deterministically.
        VocelloUITestApp.shared.forceTerminate()
        Thread.sleep(forTimeInterval: 1.0)
        app = XCUIApplication()
        app.launchEnvironment["QVOICE_IOS_SKIP_ONBOARDING"] = "1"
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        VocelloUITestApp.dismissOnboardingIfPresent(in: app)

        navigateToSettings()
        uninstallProCustomIfNeeded()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    /// Start a real download and cancel it. The row must return to the Install state.
    func testRealDeviceDownloadCancel() {
        let installButton = element("iosModelDownload_pro_custom")
        XCTAssertTrue(installButton.waitForExistence(timeout: 10), "Install button should be visible")
        installButton.tap()

        let cancelButton = element("iosModelCancel_pro_custom")
        XCTAssertTrue(
            cancelButton.waitForExistence(timeout: 30),
            "Cancel button should appear after starting a real download"
        )
        captureScreenshot(named: "device-download-started-pro-custom")
        cancelButton.tap()

        XCTAssertTrue(
            element("iosModelCancelDownloadConfirmButton").waitForExistence(timeout: 10),
            "Cancel Download option should be offered"
        )
        element("iosModelCancelDownloadConfirmButton").tap()

        if !installButton.waitForExistence(timeout: 30) {
            print("=== Accessibility hierarchy after cancel ===")
            print(app.debugDescription)
            print("=== End hierarchy ===")
            XCTFail("Install button should reappear after cancelling on a real device")
        }
        captureScreenshot(named: "device-download-cancelled-pro-custom")
    }

    // Pause/Resume was removed from the download UX (Cancel now discards the partial),
    // so the former testRealDeviceDownloadPauseResumeAndCancel is gone — the cancel path
    // above is the complete coverage for the current behavior.

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

    private func navigateToSettings() {
        let settingsTab = element("rootTab_settings")
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "Settings tab should exist")
        settingsTab.tap()
        XCTAssertTrue(
            element("iosModelRow_pro_custom").waitForExistence(timeout: 10),
            "Model row should be visible in Settings"
        )
    }

    private func uninstallProCustomIfNeeded() {
        let deleteButton = element("iosModelDelete_pro_custom")
        guard deleteButton.waitForExistence(timeout: 5) else { return }
        deleteButton.tap()
        confirmDeleteModel()
        XCTAssertTrue(
            element("iosModelDownload_pro_custom").waitForExistence(timeout: 30),
            "Model should be not installed after cleanup"
        )
    }

    private func confirmDeleteModel() {
        let confirm = element("deleteModelSheet_confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Delete model confirmation should appear")
        confirm.tap()
    }
}
