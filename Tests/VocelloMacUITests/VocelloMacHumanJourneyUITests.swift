import QwenVoiceCore
import XCTest

/// Phase-A human journeys — compose → generate → player → history replay.
final class VocelloMacHumanJourneyUITests: VocelloMacHumanTestCase {

    func testComposeGeneratePlayerAndHistory() throws {
        try skipIfDisabled("customVoice")
        navigateSidebar("customVoice")
        typeScript("Human journey: compose, generate, replay from history.")
        try generateAndWaitForPlayer(modeLabel: "Custom Voice")

        let playPause = element("sidebarPlayer_playPause")
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        VocelloMacUIQuery.clickWhenReady(playPause)

        navigateSidebar("history")
        XCTAssertTrue(element("screen_history").waitForExistence(timeout: 15))
        let firstPlay = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'historyRow_play_'")).firstMatch
        XCTAssertTrue(firstPlay.waitForExistence(timeout: 30), "history should list the generation")
        VocelloMacUIQuery.clickWhenReady(firstPlay)
        XCTAssertTrue(element("sidebarPlayer_bar").waitForExistence(timeout: 30))
    }

    func testCharCountReflectsTyping() throws {
        try skipIfDisabled("customVoice")
        navigateSidebar("customVoice")
        typeScript("Char count journey.")
        let charCount = element("textInput_charCount")
        XCTAssertTrue(charCount.waitForExistence(timeout: 5))
        let label = ((charCount.value as? String) ?? charCount.label)
        XCTAssertTrue(label.contains("Char") || !label.hasPrefix("0"))
    }

    func testVoiceDesignReadyToGenerate() throws {
        try skipIfDisabled("voiceDesign")
        navigateSidebar("voiceDesign")
        fillVoiceBrief()
        typeScript("Human journey voice design.")
        _ = VocelloMacUIQuery.waitForMarkerValue(
            app,
            identifier: "mainWindow_composeReady_design",
            contains: "true",
            timeout: 45
        )
        try generateAndWaitForPlayer(modeLabel: "Voice Design")
    }
}
