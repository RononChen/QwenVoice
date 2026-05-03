import Foundation
import os
@testable import QwenVoiceCore

/// Test double that conforms to `NativeStreamingSessionRunning` so unit
/// tests can drive `MLXTTSEngine.generate(...)` through the streaming
/// seam without spinning up a real `NativeStreamingSynthesisSession`.
///
/// Tests configure `events` (delivered to the event sink in order before
/// returning) and `result` (the value that `run` returns), or supply
/// `error` to make `run` throw after emitting any pre-error events.
///
/// Built for Session 5b of the QwenVoiceNativeRuntime retirement.
final class MockNativeStreamingSession: NativeStreamingSessionRunning, @unchecked Sendable {
    private struct State {
        var events: [GenerationEvent]
        var result: GenerationResult?
        var error: Error?
        var initialDelay: Duration?
        var eventDelay: Duration?
        var runCallCount: Int = 0
        var deliveredEventCount: Int = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        events: [GenerationEvent] = [],
        result: GenerationResult? = nil,
        error: Error? = nil,
        initialDelay: Duration? = nil,
        eventDelay: Duration? = nil
    ) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(
                events: events,
                result: result,
                error: error,
                initialDelay: initialDelay,
                eventDelay: eventDelay
            )
        )
    }

    var events: [GenerationEvent] {
        get { state.withLock { $0.events } }
        set { state.withLock { $0.events = newValue } }
    }

    var result: GenerationResult? {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }

    var error: Error? {
        get { state.withLock { $0.error } }
        set { state.withLock { $0.error = newValue } }
    }

    var runCallCount: Int {
        state.withLock { $0.runCallCount }
    }

    /// The number of events successfully delivered to `eventSink` across
    /// all `run(...)` invocations. Useful for cancellation tests that
    /// need to assert later events did NOT fire (the engine writes the
    /// final cancellation error into `latestEvent`, masking the last
    /// successful chunk).
    var deliveredEventCount: Int {
        state.withLock { $0.deliveredEventCount }
    }

    func run(
        eventSink: @escaping @MainActor @Sendable (GenerationEvent) -> Void
    ) async throws -> GenerationResult {
        let snapshot = state.withLock {
            current -> (
                events: [GenerationEvent],
                result: GenerationResult?,
                error: Error?,
                initialDelay: Duration?,
                eventDelay: Duration?
            ) in
            current.runCallCount += 1
            return (
                current.events,
                current.result,
                current.error,
                current.initialDelay,
                current.eventDelay
            )
        }

        if let initialDelay = snapshot.initialDelay {
            try await Task.sleep(for: initialDelay)
        }

        for event in snapshot.events {
            try Task.checkCancellation()
            await MainActor.run { eventSink(event) }
            state.withLock { $0.deliveredEventCount += 1 }
            if let eventDelay = snapshot.eventDelay {
                try await Task.sleep(for: eventDelay)
            }
        }
        if let error = snapshot.error {
            throw error
        }
        guard let result = snapshot.result else {
            throw NSError(
                domain: "MockNativeStreamingSession",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MockNativeStreamingSession received a run() call with no result and no error configured."]
            )
        }
        return result
    }
}
