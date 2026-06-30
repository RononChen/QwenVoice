import QwenVoiceCore
import XCTest

/// Shared XCUITest helpers for macOS bench driver (cold/warm relaunch, matrix navigation).
class VocelloMacUIBase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        installSystemAlertMonitor()
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func launchApp(extraEnvironment: [String: String] = [:]) {
        app = XCUIApplication()
        var env: [String: String] = [
            "QWENVOICE_DEBUG": "1",
            "QWENVOICE_UI_TEST_HOOKS": "1",
        ]
        if requiresTestModels {
            env["QVOICE_REQUIRE_TEST_MODELS"] = "1"
        }
        if MacGenerationWarmupCoordinator.isSuppressed {
            env["QWENVOICE_SUPPRESS_WARMUP"] = "1"
        }
        for (key, value) in extraEnvironment {
            env[key] = value
        }
        for (key, value) in env {
            app.launchEnvironment[key] = value
        }
        app.launch()
        XCTAssertTrue(VocelloMacUIQuery.waitForExistence(VocelloMacUIQuery.element(app, "mainWindow_ready"), timeout: 30))
    }

    func relaunchForWarmSession(extraEnvironment: [String: String] = [:]) {
        app?.terminate()
        terminateEngineService()
        var env = extraEnvironment
        env["QWENVOICE_SUPPRESS_WARMUP"] = "1"
        env["QWENVOICE_BENCH_FORCE_COLD"] = "0"
        launchApp(extraEnvironment: env)
    }

    func relaunchForColdTake(extraEnvironment: [String: String] = [:]) {
        app?.terminate()
        terminateEngineService()
        var env = extraEnvironment
        env["QWENVOICE_SUPPRESS_WARMUP"] = "1"
        env["QWENVOICE_BENCH_FORCE_COLD"] = "1"
        launchApp(extraEnvironment: env)
    }

    func terminateEngineService() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-x", "QwenVoiceEngineService"]
        try? task.run()
        task.waitUntilExit()
    }

    func element(_ identifier: String) -> XCUIElement {
        VocelloMacUIQuery.element(app, identifier)
    }

    @discardableResult
    func waitFor(_ identifier: String, timeout: TimeInterval = 15) -> Bool {
        VocelloMacUIQuery.waitForExistence(element(identifier), timeout: timeout)
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
            throw XCTSkip("\(item) is disabled in this environment (model not installed)")
        }
    }

    func tapGenerateAndWaitForPlayer(modeLabel: String) throws {
        let generate = element("textInput_generateButton")
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        guard generate.isEnabled else {
            if requiresTestModels {
                XCTFail("generate disabled for \(modeLabel) — run scripts/macos_test.sh models ensure")
            }
            throw XCTSkip("generate disabled (model not ready in this environment)")
        }
        VocelloMacUIQuery.clickWhenReady(generate, timeout: 45)
        XCTAssertTrue(
            element("sidebarPlayer_bar").waitForExistence(timeout: 180),
            "player bar should appear after \(modeLabel)"
        )
        XCTAssertFalse(element("sidebar_backendStatus_error").exists)
        XCTAssertFalse(element("sidebar_backendStatus_crashed").exists)
    }

    @discardableResult
    func fillVoiceBrief(_ brief: String = BenchMatrixSpec.defaultDesignBrief) -> Bool {
        if selectVoiceBriefStarter() { return true }
        return typeVoiceBrief(brief)
    }

    @discardableResult
    func selectVoiceBriefStarter() -> Bool {
        let menu = element("voiceDesign_briefStarters")
        guard menu.waitForExistence(timeout: 10) else { return false }
        VocelloMacUIQuery.clickWhenReady(menu)
        let starter = element("voiceDesign_briefStarter_0")
        if starter.waitForExistence(timeout: 5) {
            starter.click()
        } else {
            let fallback = app.menuItems.element(boundBy: 0)
            guard fallback.waitForExistence(timeout: 5) else { return false }
            fallback.click()
        }
        return VocelloMacUIQuery.waitForMarkerValue(
            app,
            identifier: "voiceDesign_voiceDescriptionValue",
            contains: " ",
            timeout: 5
        )
    }

    @discardableResult
    func typeVoiceBrief(_ text: String) -> Bool {
        let field = element("voiceDesign_voiceDescriptionField")
        guard field.waitForExistence(timeout: 10) else { return false }
        field.click()
        app.typeText(text)
        return VocelloMacUIQuery.waitForMarkerValue(
            app,
            identifier: "voiceDesign_voiceDescriptionValue",
            contains: " ",
            timeout: 5
        )
    }

    @discardableResult
    func openCloneVoiceFromSavedVoices(named voiceID: String) -> Bool {
        if disabledSidebarItems().contains("voices") { return false }
        XCTAssertTrue(VocelloMacUIQuery.navigateSidebar(app: app, item: "voices"))
        let useButton = element("voicesRow_use_\(voiceID)")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if useButton.waitForExistence(timeout: 1), useButton.isEnabled {
                if !useButton.isHittable {
                    app.scrollViews.firstMatch.swipeUp()
                }
                VocelloMacUIQuery.clickWhenReady(useButton, timeout: 5)
                if element("screen_voiceCloning").waitForExistence(timeout: 10),
                   element("voiceCloning_activeReference").waitForExistence(timeout: 10) {
                    return true
                }
            }
        }
        return false
    }

    var requiresTestModels: Bool {
        ProcessInfo.processInfo.environment["QVOICE_REQUIRE_TEST_MODELS"] == "1"
    }

    func clearEditor() {
        VocelloMacUIQuery.clearScriptEditor(app: app)
    }

    func navigateToMode(_ mode: String) throws {
        switch mode {
        case "custom":
            try skipIfDisabled("customVoice")
            XCTAssertTrue(VocelloMacUIQuery.navigateSidebar(app: app, item: "customVoice"))
        case "design":
            try skipIfDisabled("voiceDesign")
            XCTAssertTrue(VocelloMacUIQuery.navigateSidebar(app: app, item: "voiceDesign"))
            XCTAssertTrue(fillVoiceBrief(), "voice brief should be filled")
        case "clone":
            try skipIfDisabled("voiceCloning")
            XCTAssertTrue(
                openCloneVoiceFromSavedVoices(named: BenchMatrixSpec.defaultCloneVoice),
                "saved clone voice \(BenchMatrixSpec.defaultCloneVoice) should hand off"
            )
        default:
            XCTFail("unknown bench mode '\(mode)'")
        }
    }
}

private enum MacGenerationWarmupCoordinator {
    static var isSuppressed: Bool {
        let value = ProcessInfo.processInfo.environment["QWENVOICE_SUPPRESS_WARMUP"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value else { return false }
        return ["1", "true", "on", "yes"].contains(value)
    }
}
