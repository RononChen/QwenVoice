import Foundation

/// Measures main-thread responsiveness during generation — the project's
/// "does the UI lag under engine load" KPI.
///
/// Mechanism: a utility-QoS `DispatchSourceTimer` ticks every 100 ms and
/// dispatches a no-op block to the main queue, measuring the block's arrival
/// latency. A saturated main thread delays the measurement block itself,
/// which is exactly the metric we want: how late a user event would be
/// serviced right now. Delayed heartbeats are bucketed at >50 ms (noticeable) and
/// >250 ms (a visible hang per Apple's hang-detection threshold).
///
/// Lifecycle: `begin()`/`end()` are refcounted so overlapping generations
/// (e.g. batch + single) share one timer. Callers only invoke it when
/// `TelemetryGate` is on (same convention as `AppGenerationTimeline`), so
/// shipped non-debug runs never start the timer. The whole thing costs one
/// no-op main-queue block per 100 ms while a generation is active.
final class MainThreadStallWatchdog: @unchecked Sendable {
    struct Report {
        let delayedHeartbeatCount50: Int
        let delayedHeartbeatCount250: Int
        let maximumDelayedHeartbeatMS: Int
        let scheduledHeartbeatCount: Int
        let completedHeartbeatCount: Int

        var asCounters: [String: Int] {
            let coveragePPM = scheduledHeartbeatCount > 0
                ? Int((Double(completedHeartbeatCount) / Double(scheduledHeartbeatCount) * 1_000_000).rounded())
                : 0
            return [
                "delayedHeartbeatCount50": delayedHeartbeatCount50,
                "delayedHeartbeatCount250": delayedHeartbeatCount250,
                "maximumDelayedHeartbeatMS": maximumDelayedHeartbeatMS,
                "heartbeatScheduledCount": scheduledHeartbeatCount,
                "heartbeatCompletedCount": completedHeartbeatCount,
                "heartbeatCoveragePPM": coveragePPM,
                // Compatibility keys for v1-v6 readers. These describe sampled
                // heartbeat delay, not an exhaustive count of main-thread stalls.
                "uiStallCount50": delayedHeartbeatCount50,
                "uiStallCount250": delayedHeartbeatCount250,
                "uiMaxStallMS": maximumDelayedHeartbeatMS,
                "uiHeartbeats": completedHeartbeatCount,
            ]
        }
    }

    static let shared = MainThreadStallWatchdog()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.qwenvoice.ui-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var activeSessions = 0
    private var sessionToken: UInt64 = 0

    private var delayedHeartbeatCount50 = 0
    private var delayedHeartbeatCount250 = 0
    private var maximumDelayedHeartbeatMS = 0
    private var scheduledHeartbeatCount = 0
    private var completedHeartbeatCount = 0

    init() {}

    /// Start (or join) a measurement session.
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        activeSessions += 1
        guard timer == nil else { return }

        sessionToken &+= 1
        let token = sessionToken
        delayedHeartbeatCount50 = 0
        delayedHeartbeatCount250 = 0
        maximumDelayedHeartbeatMS = 0
        scheduledHeartbeatCount = 0
        completedHeartbeatCount = 0

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let sentAt = ContinuousClock.now
            guard let completion = self.makeHeartbeatCompletion(token: token, sentAt: sentAt) else {
                return
            }
            DispatchQueue.main.async(execute: completion)
        }
        source.resume()
        timer = source
    }

    /// Leave the session; returns the accumulated report when the last
    /// participant leaves (nil while other generations are still active,
    /// or when `end()` is called without a matching `begin()`).
    @discardableResult
    func end() -> Report? {
        lock.lock()
        defer { lock.unlock() }
        guard activeSessions > 0 else { return nil }
        activeSessions -= 1
        guard activeSessions == 0 else { return nil }

        timer?.cancel()
        timer = nil
        sessionToken &+= 1
        return Report(
            delayedHeartbeatCount50: delayedHeartbeatCount50,
            delayedHeartbeatCount250: delayedHeartbeatCount250,
            maximumDelayedHeartbeatMS: maximumDelayedHeartbeatMS,
            scheduledHeartbeatCount: scheduledHeartbeatCount,
            completedHeartbeatCount: completedHeartbeatCount
        )
    }

    /// Test seam for deterministically delivering a callback after its owning
    /// session has retired. Production heartbeat accounting uses the same path.
    func heartbeatCompletionForTesting() -> (@Sendable () -> Void)? {
        lock.lock()
        let token = sessionToken
        lock.unlock()
        return makeHeartbeatCompletion(token: token, sentAt: ContinuousClock.now)
    }

    private func makeHeartbeatCompletion(
        token: UInt64,
        sentAt: ContinuousClock.Instant
    ) -> (@Sendable () -> Void)? {
        lock.lock()
        guard sessionToken == token, activeSessions > 0 else {
            lock.unlock()
            return nil
        }
        scheduledHeartbeatCount += 1
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            let latency = sentAt.duration(to: ContinuousClock.now)
            let ms = Int(Double(latency.components.seconds) * 1_000
                + Double(latency.components.attoseconds) / 1_000_000_000_000_000)
            self.lock.lock()
            guard self.sessionToken == token, self.activeSessions > 0 else {
                self.lock.unlock()
                return
            }
            self.completedHeartbeatCount += 1
            if ms > 50 { self.delayedHeartbeatCount50 += 1 }
            if ms > 250 { self.delayedHeartbeatCount250 += 1 }
            if ms > self.maximumDelayedHeartbeatMS { self.maximumDelayedHeartbeatMS = ms }
            self.lock.unlock()
        }
    }
}
