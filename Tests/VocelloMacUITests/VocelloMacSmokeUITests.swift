import QwenVoiceCore
import XCTest

/// macOS UI smoke suite — fast pre-merge gate via human-like driver.
final class VocelloMacSmokeUITests: VocelloMacHumanTestCase {

    func testMainWindowReady() {
        XCTAssertTrue(element("sidebar_customVoice").exists)
        XCTAssertTrue(element("sidebar_settings").exists)
    }

    func testSidebarNavigation() {
        let disabled = disabledSidebarItems()
        for item in ["customVoice", "voiceDesign", "voiceCloning", "history", "voices", "settings"] {
            guard !disabled.contains(item) else { continue }
            navigateSidebar(item)
            XCTAssertTrue(
                VocelloMacUIQuery.waitForMarkerValue(
                    app,
                    identifier: "mainWindow_activeScreen",
                    contains: item
                )
            )
        }
    }

    func testKeyboardNavigation() {
        let disabled = disabledSidebarItems()
        let shortcuts: [(String, String)] = [
            ("1", "customVoice"), ("2", "voiceDesign"), ("3", "voiceCloning"),
            ("4", "history"), ("5", "voices"), ("6", "settings"),
        ]
        for (key, item) in shortcuts {
            guard !disabled.contains(item) else { continue }
            app.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(
                VocelloMacUIQuery.waitForMarkerValue(
                    app,
                    identifier: "mainWindow_activeScreen",
                    contains: item,
                    timeout: 10
                )
            )
        }
    }

    func testComposerTypingUpdatesCharCount() throws {
        try skipIfDisabled("customVoice")
        navigateSidebar("customVoice")
        XCTAssertTrue(element("screen_customVoice").waitForExistence(timeout: 10))
        typeScript("Smoke test sentence.")
        let charCount = element("textInput_charCount")
        XCTAssertTrue(charCount.waitForExistence(timeout: 5))
        let label = ((charCount.value as? String) ?? charCount.label)
        XCTAssertFalse(label.hasPrefix("0"))
        clearEditor()
    }

    func testGenerateCustomVoiceSmoke() throws {
        try skipIfDisabled("customVoice")
        navigateSidebar("customVoice")
        typeScript("Automated smoke generation.")
        try generateAndWaitForPlayer(modeLabel: "Custom Voice")
        clearEditor()
    }

    func testGenerateVoiceDesignSmoke() throws {
        try skipIfDisabled("voiceDesign")
        navigateSidebar("voiceDesign")
        fillVoiceBrief()
        typeScript("Automated Voice Design generation.")
        try generateAndWaitForPlayer(modeLabel: "Voice Design")
        clearEditor()
    }

    func testGenerateVoiceCloningSmoke() throws {
        try skipIfDisabled("voiceCloning")
        openCloneVoiceFromSavedVoices(named: "A_warm_elderly_woman")
        typeScript("Automated Voice Cloning generation.")
        try generateAndWaitForPlayer(modeLabel: "Voice Cloning")
        clearEditor()
    }

    func testCancelDuringGeneration() throws {
        try skipIfDisabled("customVoice")
        navigateSidebar("customVoice")
        typeScript(
            "A deliberately longer script so the generation runs long enough for the"
            + " cancel control to appear and be exercised by the automated smoke suite."
        )
        let generate = element("textInput_generateButton")
        guard generate.waitForExistence(timeout: 5), generate.isEnabled else {
            if requiresTestModels {
                XCTFail("generate unavailable — run scripts/macos_test.sh models ensure")
            }
            throw XCTSkip("generate unavailable (model not ready)")
        }
        VocelloMacUIQuery.clickWhenReady(generate)
        let cancel = element("textInput_cancelButton")
        guard cancel.waitForExistence(timeout: 30) else {
            throw XCTSkip("generation finished before cancel appeared")
        }
        cancel.click()
        XCTAssertTrue(VocelloMacUIQuery.waitForNonExistence(cancel, timeout: 120))
        XCTAssertFalse(element("sidebar_backendStatus_error").exists)
        clearEditor()
    }

    func testHistoryScreen() throws {
        try skipIfDisabled("history")
        navigateSidebar("history")
        XCTAssertTrue(element("screen_history").waitForExistence(timeout: 10))
        XCTAssertTrue(element("history_searchField").exists)
        XCTAssertTrue(element("history_sortPicker").exists)
    }

    func testVoicesScreenAndEnrollSheet() throws {
        try skipIfDisabled("voices")
        navigateSidebar("voices")
        let enroll = element("voices_enrollButton")
        XCTAssertTrue(enroll.waitForExistence(timeout: 10))
        VocelloMacUIQuery.clickWhenReady(enroll)
        XCTAssertTrue(element("voicesEnroll_nameField").waitForExistence(timeout: 10))
        element("voicesEnroll_cancelButton").click()
        XCTAssertTrue(VocelloMacUIQuery.waitForNonExistence(element("voicesEnroll_nameField"), timeout: 10))
    }

    func testSettingsScreen() {
        navigateSidebar("settings")
        XCTAssertTrue(element("screen_settings").waitForExistence(timeout: 10))
        XCTAssertTrue(element("settings_modelDownloadsSummary").waitForExistence(timeout: 10))
        XCTAssertTrue(element("preferences_autoPlayToggle").exists)
        XCTAssertTrue(element("preferences_outputDirectory").exists)
    }

    func testBatchSheetOpens() throws {
        try skipIfDisabled("customVoice")
        navigateSidebar("customVoice")
        let batch = element("textInput_batchButton")
        guard batch.waitForExistence(timeout: 10), batch.isEnabled else {
            if requiresTestModels {
                XCTFail("batch unavailable — run scripts/macos_test.sh models ensure")
            }
            throw XCTSkip("batch unavailable (model not ready)")
        }
        VocelloMacUIQuery.clickWhenReady(batch)
        XCTAssertTrue(element("batch_textEditor").waitForExistence(timeout: 10))
        element("batch_cancelButton").click()
        XCTAssertTrue(VocelloMacUIQuery.waitForNonExistence(element("batch_textEditor"), timeout: 10))
    }
}
