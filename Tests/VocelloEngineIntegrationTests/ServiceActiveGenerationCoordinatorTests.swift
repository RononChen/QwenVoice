import Foundation
import QwenVoiceCore
import QwenVoiceEngineSupport
import XCTest

private enum ServiceAdmissionEffect: Equatable, Sendable {
    case timingRecorded(String)
    case forwarderStarted(String)
    case taskStarted(String)
    case event(String, Int)
    case terminal(String)
}

private actor ServiceAdmissionEffectLog {
    private struct Waiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var effects: [ServiceAdmissionEffect] = []
    private var waiters: [Waiter] = []

    func append(_ effect: ServiceAdmissionEffect) {
        effects.append(effect)
        let ready = waiters.filter { effects.count >= $0.minimumCount }
        waiters.removeAll { effects.count >= $0.minimumCount }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForCount(_ minimumCount: Int) async {
        guard effects.count < minimumCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(minimumCount: minimumCount, continuation: continuation))
        }
    }

    func snapshot() -> [ServiceAdmissionEffect] {
        effects
    }
}

private actor ServiceAdmissionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

private final class ServiceAdmissionCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock { count += 1 }
    }

    var recordedCount: Int {
        lock.withLock { count }
    }
}

final class ServiceActiveGenerationCoordinatorTests: XCTestCase {
    func testRejectedSecondRequestCannotMutateAcceptedRequestLifecycle() async throws {
        let coordinator = ServiceActiveGenerationCoordinator()
        let effects = ServiceAdmissionEffectLog()
        let terminalGate = ServiceAdmissionGate()
        let cancellationProbe = ServiceAdmissionCancellationProbe()

        let accepted = try await coordinator.reserve()
        let acceptedTask = Task {
            guard await coordinator.waitUntilOpen(accepted) else {
                throw CancellationError()
            }
            await effects.append(.taskStarted("accepted"))
            await effects.append(.event("accepted", 0))
            await terminalGate.wait()
            try Task.checkCancellation()
            await effects.append(.event("accepted", 1))
            await effects.append(.terminal("accepted"))
        }
        let mayOpen = try await coordinator.bind(
            accepted,
            cancel: {
                cancellationProbe.record()
                acceptedTask.cancel()
            },
            waitForTermination: { _ = await acceptedTask.result }
        )
        XCTAssertTrue(mayOpen)

        // These model the host's timing and forwarder side effects. They are
        // created only after reserve + bind and before the accepted gate opens.
        await effects.append(.timingRecorded("accepted"))
        await effects.append(.forwarderStarted("accepted"))
        try await coordinator.open(accepted)
        await effects.waitForCount(4)

        let beforeRejection = await effects.snapshot()
        do {
            // This is deliberately the first statement in the service's
            // second-request path. None of the following side effects may run.
            _ = try await coordinator.reserve()
            await effects.append(.timingRecorded("rejected"))
            await effects.append(.forwarderStarted("rejected"))
            XCTFail("A second service generation must be rejected")
        } catch let error as TTSEngineError {
            guard case .generationFailed = error else {
                return XCTFail("Unexpected admission error: \(error)")
            }
        }

        let afterRejection = await effects.snapshot()
        XCTAssertEqual(afterRejection, beforeRejection)
        XCTAssertEqual(cancellationProbe.recordedCount, 0)
        let isActiveAfterRejection = await coordinator.hasActive
        XCTAssertTrue(isActiveAfterRejection)

        await terminalGate.open()
        try await acceptedTask.value
        await coordinator.finish(accepted)

        let finalEffects = await effects.snapshot()
        XCTAssertEqual(
            finalEffects,
            [
                .timingRecorded("accepted"),
                .forwarderStarted("accepted"),
                .taskStarted("accepted"),
                .event("accepted", 0),
                .event("accepted", 1),
                .terminal("accepted"),
            ]
        )
        let isActiveAfterFinish = await coordinator.hasActive
        XCTAssertFalse(isActiveAfterFinish)
    }

    func testCancellationWaitsForBoundTaskAndOwnerRetainsAdmissionUntilFinish() async throws {
        let coordinator = ServiceActiveGenerationCoordinator()
        let terminalGate = ServiceAdmissionGate()
        let cancellationProbe = ServiceAdmissionCancellationProbe()
        let accepted = try await coordinator.reserve()
        let acceptedTask = Task {
            guard await coordinator.waitUntilOpen(accepted) else { return }
            await terminalGate.wait()
        }
        let mayOpen = try await coordinator.bind(
            accepted,
            cancel: {
                cancellationProbe.record()
                acceptedTask.cancel()
            },
            waitForTermination: { _ = await acceptedTask.result }
        )
        XCTAssertTrue(mayOpen)
        try await coordinator.open(accepted)

        let cancellation = Task {
            await coordinator.cancelCurrent()
        }
        for _ in 0..<100 {
            if await coordinator.isCancellationRequested { break }
            await Task.yield()
        }
        let cancellationWasRequested = await coordinator.isCancellationRequested
        XCTAssertTrue(cancellationWasRequested)
        XCTAssertEqual(cancellationProbe.recordedCount, 1)
        let isActiveDuringCancellation = await coordinator.hasActive
        XCTAssertTrue(isActiveDuringCancellation)

        await terminalGate.open()
        await cancellation.value

        // Task termination is not service-command retirement: the owner still
        // has an event drain/reply lifecycle to finish.
        let isActiveAfterTaskTermination = await coordinator.hasActive
        XCTAssertTrue(isActiveAfterTaskTermination)
        do {
            _ = try await coordinator.reserve()
            XCTFail("Admission must remain owned until the command owner finishes")
        } catch let error as TTSEngineError {
            guard case .generationFailed = error else {
                return XCTFail("Unexpected admission error: \(error)")
            }
        }

        await coordinator.finish(accepted)
        let isActiveAfterFinish = await coordinator.hasActive
        XCTAssertFalse(isActiveAfterFinish)
        let next = try await coordinator.reserve()
        await coordinator.abort(next)
    }

    func testCancellationDuringReserveToBindWindowDeniesTaskStart() async throws {
        let coordinator = ServiceActiveGenerationCoordinator()
        let cancellationProbe = ServiceAdmissionCancellationProbe()
        let reservation = try await coordinator.reserve()
        let task = Task {
            await coordinator.waitUntilOpen(reservation)
        }

        let cancellation = Task {
            await coordinator.cancelCurrent()
        }
        for _ in 0..<100 {
            if await coordinator.isCancellationRequested { break }
            await Task.yield()
        }
        let cancellationWasRequested = await coordinator.isCancellationRequested
        guard cancellationWasRequested else {
            cancellation.cancel()
            await coordinator.abort(reservation)
            return XCTFail("Cancellation did not reach the coordinator")
        }

        let mayOpen = try await coordinator.bind(
            reservation,
            cancel: {
                cancellationProbe.record()
                task.cancel()
            },
            waitForTermination: { _ = await task.result }
        )
        XCTAssertFalse(mayOpen)
        let didOpen = await task.value
        XCTAssertFalse(didOpen)
        await cancellation.value
        XCTAssertEqual(cancellationProbe.recordedCount, 1)
        let isActiveBeforeOwnerFinish = await coordinator.hasActive
        XCTAssertTrue(isActiveBeforeOwnerFinish)

        await coordinator.finish(reservation)
        let isActiveAfterOwnerFinish = await coordinator.hasActive
        XCTAssertFalse(isActiveAfterOwnerFinish)
    }
}
