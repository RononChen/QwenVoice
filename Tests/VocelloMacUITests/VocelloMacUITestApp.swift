import XCTest

/// Shared macOS app session for human-like UI tests (smoke, journey, review).
final class VocelloMacUITestApp: @unchecked Sendable {
    static let shared = VocelloMacUITestApp()
    private init() {}

    private let lock = NSRecursiveLock()
    private var retainCount = 0
    private(set) var app: XCUIApplication!

    func retainIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if app != nil {
            ensureForeground()
            return
        }
        retainCount = max(retainCount, 1)
        launch()
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        retainCount -= 1
        if retainCount <= 0 {
            terminate()
            retainCount = 0
        }
    }

    func forceTerminate() {
        lock.lock()
        defer { lock.unlock() }
        terminate()
        retainCount = 0
    }

    func launch(extraEnvironment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchEnvironment["QWENVOICE_DEBUG"] = "1"
        app.launchEnvironment["QWENVOICE_UI_TEST_HOOKS"] = "1"
        if ProcessInfo.processInfo.environment["QVOICE_REQUIRE_TEST_MODELS"] == "1" {
            app.launchEnvironment["QVOICE_REQUIRE_TEST_MODELS"] = "1"
        }
        for (key, value) in extraEnvironment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        _ = VocelloMacUIQuery.waitForExistence(VocelloMacUIQuery.element(app, "mainWindow_ready"), timeout: 30)
    }

    func resetToGenerateSurface() {
        retainIfNeeded()
        ensureForeground()
        dismissSheetsIfPresent()
        _ = VocelloMacUIQuery.navigateSidebar(app: app, item: "customVoice")
        VocelloMacUIQuery.clearScriptEditor(app: app)
    }

    private func dismissSheetsIfPresent() {
        for id in ["batch_cancelButton", "voicesEnroll_cancelButton", "recordClip_cancel"] {
            let cancel = VocelloMacUIQuery.element(app, id)
            if cancel.exists {
                cancel.click()
                _ = cancel.waitForNonExistence(timeout: 5)
            }
        }
    }

    private func ensureForeground() {
        guard app != nil else { return }
        if !app.windows.firstMatch.exists {
            app.activate()
        }
    }

    private func terminate() {
        app?.terminate()
        app = nil
    }
}

/// Base for human-like macOS UI tests using a shared app session.
class VocelloMacHumanTestCase: XCTestCase {
    var app: XCUIApplication { VocelloMacUITestApp.shared.app }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        installSystemAlertMonitor()
        VocelloMacUITestApp.shared.retainIfNeeded()
    }

    override func tearDown() {
        VocelloMacUITestApp.shared.resetToGenerateSurface()
        VocelloMacUITestApp.shared.release()
        super.tearDown()
    }

    func element(_ identifier: String) -> XCUIElement {
        VocelloMacUIQuery.element(app, identifier)
    }

    func disabledSidebarItems() -> Set<String> {
        let marker = element("mainWindow_disabledSidebarItems")
        guard marker.exists else { return [] }
        let raw = (marker.value as? String) ?? marker.label
        guard raw != "none" else { return [] }
        return Set(raw.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "sidebar_", with: "")
        })
    }

    func skipIfDisabled(_ item: String) throws {
        if disabledSidebarItems().contains(item) {
            if requiresTestModels {
                XCTFail("\(item) is disabled — run scripts/macos_test.sh models ensure")
            }
            throw XCTSkip("\(item) is disabled (model not installed)")
        }
    }

    var requiresTestModels: Bool {
        ProcessInfo.processInfo.environment["QVOICE_REQUIRE_TEST_MODELS"] == "1"
    }

    func navigateSidebar(_ item: String) {
        XCTAssertTrue(VocelloMacUIQuery.navigateSidebar(app: app, item: item))
    }

    func typeScript(_ text: String) {
        XCTAssertTrue(VocelloMacUIQuery.focusAndTypeScript(app: app, text: text))
    }

    func clearEditor() {
        VocelloMacUIQuery.clearScriptEditor(app: app)
    }

    func fillVoiceBrief() {
        let menu = element("voiceDesign_briefStarters")
        if menu.waitForExistence(timeout: 10) {
            VocelloMacUIQuery.clickWhenReady(menu)
            let starter = element("voiceDesign_briefStarter_0")
            if starter.waitForExistence(timeout: 5) {
                starter.click()
            } else if app.menuItems.element(boundBy: 0).waitForExistence(timeout: 3) {
                app.menuItems.element(boundBy: 0).click()
            }
        } else {
            let field = element("voiceDesign_voiceDescriptionField")
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.click()
            app.typeText("A warm, calm middle-aged male narrator with a clear, measured pace.")
        }
        XCTAssertTrue(
            VocelloMacUIQuery.waitForMarkerValue(
                app,
                identifier: "voiceDesign_voiceDescriptionValue",
                contains: "warm",
                timeout: 5
            ) || element("voiceDesign_voiceDescriptionValue").exists
        )
    }

    func openCloneVoiceFromSavedVoices(named voiceID: String) {
        if disabledSidebarItems().contains("voices") {
            XCTFail("voices screen disabled")
            return
        }
        navigateSidebar("voices")
        XCTAssertTrue(element("screen_voices").waitForExistence(timeout: 15))
        let useButton = element("voicesRow_use_\(voiceID)")
        let deadline = Date().addingTimeInterval(30)
        var opened = false
        while Date() < deadline {
            if useButton.waitForExistence(timeout: 1), useButton.isEnabled {
                if !useButton.isHittable {
                    app.scrollViews.firstMatch.swipeUp()
                }
                VocelloMacUIQuery.clickWhenReady(useButton, timeout: 5)
                if element("screen_voiceCloning").waitForExistence(timeout: 10),
                   element("voiceCloning_activeReference").waitForExistence(timeout: 10) {
                    opened = true
                    break
                }
            }
        }
        XCTAssertTrue(opened, "clone handoff for \(voiceID) should succeed")
    }

    func generateAndWaitForPlayer(modeLabel: String, failOnSkip: Bool = false) throws {
        let generate = element("textInput_generateButton")
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        if !generate.isEnabled {
            if requiresTestModels || failOnSkip {
                XCTFail("generate disabled for \(modeLabel)")
            }
            throw XCTSkip("generate disabled (model not ready)")
        }
        VocelloMacUIQuery.clickWhenReady(generate, timeout: 45)
        XCTAssertTrue(
            element("sidebarPlayer_bar").waitForExistence(timeout: 180),
            "player bar should appear after \(modeLabel)"
        )
        XCTAssertFalse(element("sidebar_backendStatus_error").exists)
        XCTAssertFalse(element("sidebar_backendStatus_crashed").exists)
        if MacUITestSurfaceMarkers.isEnabled {
            _ = VocelloMacUIQuery.waitForMarkerValue(
                app,
                identifier: "mainWindow_lastGenerationComplete",
                contains: "-",
                timeout: 30
            )
        }
    }
}

// Test bundle reads marker enablement the same way as the app target.
private enum MacUITestSurfaceMarkers {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["QWENVOICE_UI_TEST_HOOKS"] == "1"
            || ProcessInfo.processInfo.environment["QWENVOICE_DEBUG"] == "1"
    }
}
