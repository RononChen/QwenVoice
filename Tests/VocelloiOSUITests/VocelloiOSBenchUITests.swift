import XCTest

/// iOS on-device UI-driven benchmark — the iPhone counterpart of macOS
/// `VocelloMacBenchUITests`, run via `scripts/ios_device.sh bench-ui`.
///
/// Drives the REAL Studio UI (mode segments, composer, Generate) for a full
/// matrix of takes; the engine writes durable telemetry rows (QWENVOICE_DEBUG=1)
/// that the driver pulls and gates after the run. Take metadata (benchRunID)
/// rides the launch environment via `BenchRunContext`; cells are reconstructed
/// Mac-side from each row's mode + prompt length + recorded warm state.
///
/// Matrix (mirrors `BenchMatrixSpec.matrix` — keep the corpus IDENTICAL):
///   per mode: [cold medium (custom/design only)] + warm reps × each length.
/// Cold takes relaunch with `QWENVOICE_BENCH_FORCE_COLD=1`; warm takes run
/// in-session (the first warm take after a relaunch records `cold` — the same
/// semantics as the macOS bench).
///
/// Clone takes need a SAVED VOICE on the device (record one once via Voices →
/// Save a new voice — the mic is NOT available through iPhone Mirroring, so
/// that step is attended). When none exists the clone cells are skipped and the
/// manifest line reflects the reduced take count.
final class VocelloiOSBenchUITests: XCTestCase {
    private var app: XCUIApplication!

    // Keep IDENTICAL to BenchMatrixSpec.corpus (QwenVoiceCore is deliberately
    // not linked into the UI-test bundle).
    private static let corpus: [(len: String, text: String)] = [
        ("short", "The train left the station at dawn."),
        ("medium", "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast."),
        ("long", "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast. Outside the fogged windows, pale fields gave way to grey water, and the rhythm of the rails settled into a steady, hypnotic hum. By the time the sun finally broke through, most of the passengers had drifted into an unhurried silence."),
    ]

    private struct Take {
        let mode: String
        let length: String
        let warmState: String
        let rep: Int
        let text: String
    }

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

    func testFullMatrix() throws {
        let env = ProcessInfo.processInfo.environment
        let runID = env["QVOICE_IOS_BENCH_RUN_ID"] ?? "ios-bench-ui-local"
        let modes = list(env["QVOICE_IOS_BENCH_MODES"], default: ["custom", "design", "clone"])
        let lengths = list(env["QVOICE_IOS_BENCH_LENGTHS"], default: ["short", "medium", "long"])
        let warm = max(1, Int(env["QVOICE_IOS_BENCH_WARM"] ?? "") ?? 3)

        var ran = 0
        var skippedClone = false

        for mode in modes {
            let takes = takesFor(mode: mode, lengths: lengths, warm: warm)

            // Cold take first (custom/design): fresh launch that force-unloads
            // before generation.
            if let cold = takes.first(where: { $0.warmState == "cold" }) {
                relaunch(runID: runID, forceCold: true)
                guard try prepareMode(mode) else {
                    if mode == "clone" { skippedClone = true }
                    continue
                }
                try runTake(cold, timeout: 300)
                ran += 1
            }

            // Warm takes share one session (model stays loaded in-process).
            relaunch(runID: runID, forceCold: false)
            guard try prepareMode(mode) else {
                if mode == "clone" { skippedClone = true }
                continue
            }
            for take in takes.filter({ $0.warmState == "warm" }) {
                try runTake(take, timeout: 240)
                ran += 1
            }
        }

        // The driver greps this exact line to know how many rows to expect.
        print("VOCELLO-BENCH-UI-MANIFEST ran=\(ran) runID=\(runID) skippedClone=\(skippedClone)")
        XCTAssertGreaterThan(ran, 0, "bench matrix ran no takes")
    }

    // MARK: - Matrix

    private func takesFor(mode: String, lengths: [String], warm: Int) -> [Take] {
        var takes: [Take] = []
        let coldLen = lengths.contains("medium") ? "medium" : lengths.first
        if mode != "clone", let coldLen, let text = text(for: coldLen) {
            takes.append(Take(mode: mode, length: coldLen, warmState: "cold", rep: 0, text: text))
        }
        for len in lengths {
            guard let body = text(for: len) else { continue }
            for rep in 0..<warm {
                takes.append(Take(mode: mode, length: len, warmState: "warm", rep: rep, text: body))
            }
        }
        return takes
    }

    private func text(for len: String) -> String? {
        Self.corpus.first { $0.len == len }?.text
    }

    private func list(_ raw: String?, default def: [String]) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return def }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - App lifecycle

    private func relaunch(runID: String, forceCold: Bool) {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["QWENVOICE_DEBUG"] = "1"
        app.launchEnvironment["QWENVOICE_UI_TEST_HOOKS"] = "1"
        app.launchEnvironment["QVOICE_IOS_SKIP_ONBOARDING"] = "1"
        app.launchEnvironment["QVOICE_MAC_BENCH_RUN_ID"] = runID // BenchRunContext key (platform-neutral)
        app.launchEnvironment["QWENVOICE_BENCH_FORCE_COLD"] = forceCold ? "1" : "0"
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        VocelloUITestApp.dismissOnboardingIfPresent(in: app)
        XCTAssertTrue(
            app.buttons["rootTab_studio"].firstMatch.waitForExistence(timeout: 30),
            "Studio tab should exist after launch"
        )
    }

    // MARK: - Mode setup

    /// Returns false when the mode cannot run (no saved voice for clone).
    private func prepareMode(_ mode: String) throws -> Bool {
        let studioTab = app.buttons["rootTab_studio"].firstMatch
        if studioTab.exists, !studioTab.isSelected { studioTab.tap() }

        switch mode {
        case "custom":
            selectSegment("generateSection_custom", label: "Custom")
        case "design":
            selectSegment("generateSection_design", label: "Design")
            try fillVoiceBriefIfNeeded()
        case "clone":
            // Handoff path: Voices tab → first saved voice card → Studio clone.
            let voicesTab = app.buttons["rootTab_voices"].firstMatch
            XCTAssertTrue(voicesTab.waitForExistence(timeout: 10))
            voicesTab.tap()
            let saved = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "voicesRow_saved_"))
                .firstMatch
            guard saved.waitForExistence(timeout: 10) else {
                print("[bench-ui] no saved voice on device — skipping clone cells")
                studioTab.tap()
                return false
            }
            saved.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["generateSection_clone"].firstMatch
                    .waitForExistence(timeout: 15),
                "saved-voice tap should hand off to Studio clone mode"
            )
        default:
            XCTFail("unknown bench mode '\(mode)'")
        }

        // Model must be installed for this mode.
        if app.descendants(matching: .any)["textInput_installModelButton"].firstMatch
            .waitForExistence(timeout: 3) {
            XCTFail("model for mode '\(mode)' is not installed on the device")
        }
        return true
    }

    private func selectSegment(_ identifier: String, label: String) {
        let byID = app.descendants(matching: .any)[identifier].firstMatch
        var target = byID
        if !byID.waitForExistence(timeout: 20) {
            target = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 10), "mode segment \(identifier) should exist")
        }
        if !target.isSelected { target.tap() }
    }

    private func fillVoiceBriefIfNeeded() throws {
        // A brief persists in the draft for the session; set it once.
        let chip = app.descendants(matching: .any)["studioChip_voiceBrief"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "voice-brief chip should exist in Design mode")
        if !chip.label.contains("Describe the voice") {
            return
        }
        chip.tap()
        let starter = app.descendants(matching: .any)["voiceBrief_starter_0"].firstMatch
        if starter.waitForExistence(timeout: 8) {
            // Starter rows fill + dismiss the sheet — no Confirm step.
            starter.tap()
            _ = starter.waitForNonExistence(timeout: 8)
            return
        }
        let editor = app.descendants(matching: .any)["voiceBrief_editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), "voice-brief editor should exist")
        editor.tap()
        app.typeText("A warm, calm middle-aged male narrator with a clear, measured pace.")
        let confirm = app.descendants(matching: .any)["voiceBrief_confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), "voice-brief confirm should exist")
        confirm.tap()
        _ = confirm.waitForNonExistence(timeout: 8)
    }

    // MARK: - One take

    private func runTake(_ take: Take, timeout: TimeInterval) throws {
        let label = "\(take.mode)/\(take.length)/\(take.warmState)#\(take.rep)"

        clearScript()
        typeScript(take.text)

        let completeMarker = app.descendants(matching: .any)["iosStudio_lastGenerationComplete"].firstMatch
        let errorMarker = app.descendants(matching: .any)["iosStudio_generationError"].firstMatch
        let before = markerValue(completeMarker)

        let generate = app.descendants(matching: .any)["textInput_generateButton"].firstMatch
        var cta = generate
        if !generate.waitForExistence(timeout: 8) {
            cta = app.buttons.matching(NSPredicate(format: "label == %@", "Generate")).firstMatch
            XCTAssertTrue(cta.waitForExistence(timeout: 8), "Generate button should exist for \(label)")
        }
        XCTAssertTrue(cta.isEnabled, "Generate should be enabled for \(label)")
        cta.tap()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = markerValue(completeMarker)
            if now != before, now != "none", !now.isEmpty {
                // Brief settle so the engine's awaited JSONL write + any
                // trailing persistence lands before a relaunch/terminate.
                Thread.sleep(forTimeInterval: 1.5)
                return
            }
            let error = markerValue(errorMarker)
            if error != "none", !error.isEmpty {
                XCTFail("take \(label) failed: \(error)")
                return
            }
            usleep(500_000)
        }
        XCTFail("take \(label) did not complete within \(Int(timeout))s")
    }

    private func clearScript() {
        let clear = app.descendants(matching: .any)["iosStudio_benchClearScript"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "bench clear hook should exist (QWENVOICE_UI_TEST_HOOKS=1)")
        // 1×1 hidden control: coordinate-tap its center for reliability.
        clear.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func typeScript(_ text: String) {
        let editor: XCUIElement
        let byID = app.descendants(matching: .any)["textInput_textEditor"].firstMatch
        if byID.waitForExistence(timeout: 8) {
            editor = byID
        } else {
            editor = app.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10), "Studio text editor should exist")
        }
        editor.tap()
        app.typeText(text)
        // Return is configured as Done → dismisses the keyboard so the CTA is tappable.
        app.typeText("\n")
        _ = app.keyboards.element.waitForNonExistence(timeout: 10)
    }

    private func markerValue(_ marker: XCUIElement) -> String {
        guard marker.exists else { return "" }
        return (marker.value as? String) ?? marker.label
    }
}
