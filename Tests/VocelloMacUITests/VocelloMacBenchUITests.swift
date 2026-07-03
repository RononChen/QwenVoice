import QwenVoiceCore
import XCTest

/// macOS XPC UI benchmark — matrix driver (no shared human session reset).
final class VocelloMacBenchUITests: VocelloMacUIBase {
    func testFullMatrix() throws {
        let config = VocelloMacBenchMatrixConfig.load()
        let runID = ProcessInfo.processInfo.environment["QVOICE_MAC_BENCH_RUN_ID"] ?? "bench-local"
        let takes = BenchMatrixSpec.matrix(
            modes: config.modes,
            lengths: config.lengths,
            warm: config.warm
        )

        for (index, take) in takes.enumerated() {
            let label = "\(take.mode)/\(take.length)/\(take.warmState)#\(take.rep)"

            let benchEnv = BenchRunContext.applyLaunchEnvironment(
                runID: runID,
                takeIndex: index + 1,
                cell: label,
                intendedWarmState: take.warmState
            )
            BenchRunContext.writeCurrentTakeFile(
                takeIndex: index + 1,
                cell: label,
                intendedWarmState: take.warmState
            )

            if take.warmState == "cold" {
                relaunchForColdTake(extraEnvironment: benchEnv)
            } else if index > 0 && takes[index - 1].warmState == "cold" {
                relaunchForWarmSession(extraEnvironment: benchEnv)
            } else if app == nil {
                relaunchForWarmSession(extraEnvironment: benchEnv)
            } else {
                for (key, value) in benchEnv {
                    app.launchEnvironment[key] = value
                }
            }

            try navigateToMode(take.mode)
            clearEditor()
            XCTAssertTrue(
                VocelloMacUIQuery.focusAndTypeScript(app: app, text: take.text),
                "typed corpus for \(label)"
            )
            let completedBeforeTake = markerValue(element("mainWindow_lastGenerationComplete"))
            try tapGenerateAndWaitForPlayer(modeLabel: label)
            waitForTelemetryFlush(
                previousCompletedID: completedBeforeTake,
                timeout: telemetryFlushTimeout(for: take),
                label: label
            )
            clearEditor()
        }
    }

    func markerValue(_ marker: XCUIElement) -> String {
        guard marker.exists else { return "" }
        return (marker.value as? String) ?? marker.label
    }

    /// Player bar appears at first chunk; long scripts can run for minutes after that.
    /// Audit J1: a 12 s warm timeout let takes #10/#29 (warm/long at relaunch
    /// boundaries) soft-fail and terminate the app before `recordCompleted` landed.
    private func telemetryFlushTimeout(for take: BenchMatrixSpec.Take) -> TimeInterval {
        switch take.length {
        case "long": return take.warmState == "cold" ? 360 : 300
        case "medium": return take.warmState == "cold" ? 180 : 120
        default: return take.warmState == "cold" ? 90 : 60
        }
    }

    /// Wait until the merge/flush marker catches up to THIS take's generation.
    ///
    /// Audit J1 (two rounds):
    /// 1. The original predicate only checked the flush marker was non-empty, so
    ///    from take #2 on it matched the PREVIOUS take instantly and the next
    ///    relaunch terminated the app mid-write (engine 29 rows vs app 27).
    /// 2. Matching `flushed == completed` alone still raced: both markers update
    ///    via async MainActor tasks, so at wait start they can BOTH still hold
    ///    the previous take's ID — a stale pair that also matches instantly.
    ///    The takes lost were exactly the ones followed by a terminate (last
    ///    take before the design cold relaunch, and the final take).
    /// The wait therefore requires the completed ID to CHANGE from its
    /// pre-generate value before comparing it to the flushed ID.
    private func waitForTelemetryFlush(
        previousCompletedID: String,
        timeout: TimeInterval,
        label: String
    ) {
        let completeMarker = element("mainWindow_lastGenerationComplete")
        let flushedMarker = element("mainWindow_lastTelemetryFlushed")
        let predicate = NSPredicate { [self] _, _ in
            let completed = markerValue(completeMarker)
            guard completed != "none", !completed.isEmpty, completed != previousCompletedID else {
                return false
            }
            return markerValue(flushedMarker) == completed
        }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: flushedMarker)
        let result = XCTWaiter.wait(for: [exp], timeout: timeout)
        if result != .completed {
            XCTFail(
                "telemetry flush marker did not advance past \(previousCompletedID) for \(label) within \(Int(timeout))s — app row may be lost on relaunch"
            )
        } else {
            // Let detached merger / JSONL fsync settle before the next terminate.
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
