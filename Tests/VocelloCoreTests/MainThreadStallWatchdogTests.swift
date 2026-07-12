import Foundation
import XCTest

final class MainThreadStallWatchdogTests: XCTestCase {
    func testOverlappingSessionsCloseOnlyAtFinalOwnerAndDoNotUnderflow() {
        let watchdog = MainThreadStallWatchdog()
        watchdog.begin()
        watchdog.begin()

        XCTAssertNil(watchdog.end())
        let report = watchdog.end()
        XCTAssertNotNil(report)
        XCTAssertNil(watchdog.end())
    }

    func testFreshSessionIsolatedFromRetiredSessionCallbacks() throws {
        let watchdog = MainThreadStallWatchdog()
        watchdog.begin()
        let staleCompletion = try XCTUnwrap(watchdog.heartbeatCompletionForTesting())
        _ = watchdog.end()

        watchdog.begin()
        let currentCompletion = try XCTUnwrap(watchdog.heartbeatCompletionForTesting())
        staleCompletion()
        currentCompletion()
        let report = try XCTUnwrap(watchdog.end())

        XCTAssertEqual(report.scheduledHeartbeatCount, 1)
        XCTAssertEqual(report.completedHeartbeatCount, 1)
        XCTAssertGreaterThanOrEqual(report.maximumDelayedHeartbeatMS, 0)
    }
}
