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
            try tapGenerateAndWaitForPlayer(modeLabel: label)
            waitForTelemetryFlush(timeout: take.warmState == "cold" ? 20 : 12)
            clearEditor()
        }
    }

    private func waitForTelemetryFlush(timeout: TimeInterval) {
        let marker = element("mainWindow_lastTelemetryFlushed")
        let predicate = NSPredicate { _, _ in
            guard marker.exists else { return false }
            let value = ((marker.value as? String) ?? marker.label)
            return value != "none" && !value.isEmpty
        }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: marker)
        _ = XCTWaiter.wait(for: [exp], timeout: timeout)
    }
}
