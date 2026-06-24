import XCTest

/// On-device regression for the iOS model download manager.
///
/// Unlike `VocelloiOSDownloadManagerUITests`, this runs on a real iPhone and uses the
/// production URLSession download backend. To avoid downloading the full ~2.3 GB model,
/// the test only verifies the **cancel** path: start a download, immediately open the
/// Pause/Cancel dialog, choose Cancel Download, and confirm the Install button returns.
final class VocelloiOSOnDeviceDownloadUITests: XCTestCase {

    override class func setUp() {
        super.setUp()
        VocelloUITestApp.shared.retain()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        VocelloUITestApp.shared.resetToStudio()
        navigateToSettings()
        uninstallProCustomIfNeeded()
    }

    override class func tearDown() {
        VocelloUITestApp.shared.release()
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
        VocelloUITestApp.shared.captureScreenshot(named: "device-download-started-pro-custom")
        cancelButton.tap()

        let cancelDownloadButton = element("iosModelCancelDownloadConfirmButton")
        XCTAssertTrue(
            cancelDownloadButton.waitForExistence(timeout: 10),
            "Cancel Download option should be offered"
        )
        cancelDownloadButton.tap()

        if !installButton.waitForExistence(timeout: 30) {
            print("=== Accessibility hierarchy after cancel ===")
            print(VocelloUITestApp.shared.app.debugDescription)
            print("=== End hierarchy ===")
            XCTFail("Install button should reappear after cancelling on a real device")
        }
        VocelloUITestApp.shared.captureScreenshot(named: "device-download-cancelled-pro-custom")
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        VocelloUITestApp.shared.element(identifier)
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
