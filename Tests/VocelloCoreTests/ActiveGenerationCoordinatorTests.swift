import XCTest
@testable import QwenVoiceCore

private actor TestGenerationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum TestMemoryPressureAction: Equatable, Sendable {
    case admissionClosed
    case observed(NativeMemoryTrimLevel)
    case cancellationRequested(GenerationCancellationReason)
    case workerTerminated
    case terminalBarrierPassed
    case modelOperationBarrierStarted
    case modelOperationsQuiesced
    case trimmed(NativeMemoryTrimLevel, String)
    case reliefPublished
    case operationAttempted(String)
    case operationEntered(String)
}

private actor TestMemoryPressureActionLog {
    private struct Waiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var actions: [TestMemoryPressureAction] = []
    private var waiters: [Waiter] = []

    func append(_ action: TestMemoryPressureAction) {
        actions.append(action)
        let ready = waiters.filter { actions.count >= $0.minimumCount }
        waiters.removeAll { actions.count >= $0.minimumCount }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForCount(_ minimumCount: Int) async {
        guard actions.count < minimumCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(minimumCount: minimumCount, continuation: continuation))
        }
    }

    func snapshot() -> [TestMemoryPressureAction] {
        actions
    }
}

final class ActiveGenerationCoordinatorTests: XCTestCase {
    func testCancellationRetainsOwnershipUntilTaskTerminates() async throws {
        let coordinator = ActiveGenerationCoordinator()
        let terminalGate = TestGenerationGate()
        let worker = Task {
            await terminalGate.wait()
        }
        let registration = try await coordinator.register(
            cancel: { worker.cancel() },
            waitForTermination: { _ = await worker.result }
        )

        let cancellation = Task {
            await coordinator.cancelCurrent(reason: .memoryPressure)
        }

        for _ in 0..<100 {
            if await coordinator.currentCancellationReason != nil { break }
            await Task.yield()
        }
        let cancellationReason = await coordinator.currentCancellationReason
        let isActiveWhileCancelling = await coordinator.hasActiveGeneration
        XCTAssertEqual(cancellationReason, .memoryPressure)
        XCTAssertTrue(isActiveWhileCancelling)

        await terminalGate.open()
        await cancellation.value

        let isActiveAfterCancellation = await coordinator.hasActiveGeneration
        let reasonAfterCancellation = await coordinator.currentCancellationReason
        XCTAssertFalse(isActiveAfterCancellation)
        XCTAssertNil(reasonAfterCancellation)

        let terminalReason = await coordinator.finish(registration)
        XCTAssertEqual(terminalReason, .memoryPressure)
        let isActiveAfterFinish = await coordinator.hasActiveGeneration
        let reasonAfterFinish = await coordinator.currentCancellationReason
        XCTAssertFalse(isActiveAfterFinish)
        XCTAssertNil(reasonAfterFinish)
    }

    func testFinishPreservesEveryTypedReasonAcrossEarlyCancellation() async throws {
        let reasons: [GenerationCancellationReason] = [
            .memoryPressure,
            .superseded,
            .shutdown,
        ]

        for expectedReason in reasons {
            let coordinator = ActiveGenerationCoordinator()
            let terminalGate = TestGenerationGate()
            let worker = Task {
                await terminalGate.wait()
                try Task.checkCancellation()
            }
            let registration = try await coordinator.register(
                cancel: { worker.cancel() },
                waitForTermination: { _ = await worker.result }
            )

            let cancellation = Task {
                await coordinator.cancelCurrent(reason: expectedReason)
            }
            for _ in 0..<100 {
                if await coordinator.currentCancellationReason != nil { break }
                await Task.yield()
            }

            await terminalGate.open()
            await cancellation.value

            let preservedReason = await coordinator.finish(registration)
            XCTAssertEqual(preservedReason, expectedReason)
            let reasonAfterFinish = await coordinator.currentCancellationReason
            XCTAssertNil(reasonAfterFinish)
        }
    }

    func testSecondGenerationIsRejectedWhileFirstOwnsEngine() async throws {
        let coordinator = ActiveGenerationCoordinator()
        let terminalGate = TestGenerationGate()
        let worker = Task {
            await terminalGate.wait()
        }
        let registration = try await coordinator.register(
            cancel: { worker.cancel() },
            waitForTermination: { _ = await worker.result }
        )

        do {
            _ = try await coordinator.register(cancel: {}, waitForTermination: {})
            XCTFail("A second generation must not acquire the engine")
        } catch let error as TTSEngineError {
            guard case .generationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await terminalGate.open()
        _ = await worker.result
        await coordinator.finish(registration)
        let isActiveAfterFinish = await coordinator.hasActiveGeneration
        XCTAssertFalse(isActiveAfterFinish)
    }

    func testCriticalKernelPressureWaitsForTypedCancellationBarrierBeforeHardTrim() async throws {
        let coordinator = ActiveGenerationCoordinator()
        let terminalGate = TestGenerationGate()
        let actions = TestMemoryPressureActionLog()
        let worker = Task {
            await terminalGate.wait()
            await actions.append(.workerTerminated)
        }
        let registration = try await coordinator.register(
            cancel: { worker.cancel() },
            waitForTermination: { _ = await worker.result }
        )
        let executor = NativeMemoryPressureResponseExecutor(
            recordObservation: { level in
                await actions.append(.observed(level))
            },
            cancelActiveGeneration: { reason in
                await actions.append(.cancellationRequested(reason))
                await coordinator.cancelCurrent(reason: reason)
                await actions.append(.terminalBarrierPassed)
            },
            trim: { level, reason in
                await actions.append(.trimmed(level, reason))
            },
            closeAdmissionForCriticalRelief: {
                await actions.append(.admissionClosed)
            },
            awaitModelOperationsQuiesced: {
                await actions.append(.modelOperationsQuiesced)
            },
            publishCriticalReliefCompletion: {
                await actions.append(.reliefPublished)
            }
        )

        let response = Task {
            await executor.execute(
                level: .hardTrim,
                reason: "test_kernel_pressure_hardTrim"
            )
        }

        await actions.waitForCount(3)
        let beforeTerminal = await actions.snapshot()
        XCTAssertEqual(
            beforeTerminal,
            [
                .admissionClosed,
                .observed(.hardTrim),
                .cancellationRequested(.memoryPressure),
            ]
        )
        XCTAssertFalse(
            beforeTerminal.contains {
                if case .trimmed(_, _) = $0 { return true }
                return false
            },
            "Hard trim must not run before the generation terminal barrier"
        )
        let activeBeforeTerminal = await coordinator.hasActiveGeneration
        XCTAssertTrue(activeBeforeTerminal)

        await terminalGate.open()
        await response.value

        let afterTerminal = await actions.snapshot()
        XCTAssertEqual(
            afterTerminal,
            [
                .admissionClosed,
                .observed(.hardTrim),
                .cancellationRequested(.memoryPressure),
                .workerTerminated,
                .terminalBarrierPassed,
                .modelOperationsQuiesced,
                .trimmed(.hardTrim, "test_kernel_pressure_hardTrim"),
                .reliefPublished,
            ]
        )
        let terminalReason = await coordinator.finish(registration)
        XCTAssertEqual(terminalReason, .memoryPressure)
    }

    func testFirstCancellationReasonWinsAcrossConcurrentRequests() async throws {
        let coordinator = ActiveGenerationCoordinator()
        let terminalGate = TestGenerationGate()
        let worker = Task {
            await terminalGate.wait()
            try Task.checkCancellation()
        }
        let registration = try await coordinator.register(
            cancel: { worker.cancel() },
            waitForTermination: { _ = await worker.result }
        )

        let criticalCancellation = Task {
            await coordinator.cancelCurrent(reason: .memoryPressure)
        }
        for _ in 0..<100 {
            if await coordinator.currentCancellationReason == .memoryPressure { break }
            await Task.yield()
        }
        let firstReason = await coordinator.currentCancellationReason
        XCTAssertEqual(firstReason, .memoryPressure)

        let laterCancellation = Task {
            await coordinator.cancelCurrent(reason: .shutdown)
        }
        await Task.yield()
        let reasonAfterLaterRequest = await coordinator.currentCancellationReason
        XCTAssertEqual(
            reasonAfterLaterRequest,
            .memoryPressure,
            "A later cancellation request must not replace the first typed reason"
        )

        await terminalGate.open()
        await criticalCancellation.value
        await laterCancellation.value
        let terminalReason = await coordinator.finish(registration)
        XCTAssertEqual(terminalReason, .memoryPressure)
    }

    @MainActor
    func testCriticalReliefBlocksLoadPrewarmAndGenerationUntilPublication() async throws {
        let admission = CriticalMemoryReliefAdmission()
        let quiescenceGate = TestGenerationGate()
        let actions = TestMemoryPressureActionLog()
        let executor = NativeMemoryPressureResponseExecutor(
            recordObservation: { level in
                await actions.append(.observed(level))
            },
            cancelActiveGeneration: { reason in
                await actions.append(.cancellationRequested(reason))
            },
            trim: { level, reason in
                await actions.append(.trimmed(level, reason))
            },
            closeAdmissionForCriticalRelief: {
                await admission.close()
                await actions.append(.admissionClosed)
            },
            awaitModelOperationsQuiesced: {
                await actions.append(.modelOperationBarrierStarted)
                await quiescenceGate.wait()
                await actions.append(.modelOperationsQuiesced)
            },
            publishCriticalReliefCompletion: {
                await actions.append(.reliefPublished)
                await admission.reopen()
            }
        )

        let response = Task {
            await executor.execute(
                level: .hardTrim,
                reason: "test_continuous_critical_relief"
            )
        }
        await actions.waitForCount(4)

        let load = Task { @MainActor in
            await actions.append(.operationAttempted("load"))
            try await admission.waitUntilOpen()
            await actions.append(.operationEntered("load"))
        }
        let generation = Task { @MainActor in
            await actions.append(.operationAttempted("generation"))
            try await admission.waitUntilOpen()
            await actions.append(.operationEntered("generation"))
        }
        await actions.append(.operationAttempted("prewarm"))
        if admission.allowsProactiveOperation {
            await actions.append(.operationEntered("prewarm"))
        }

        await actions.waitForCount(7)
        let whileSuspended = await actions.snapshot()
        XCTAssertFalse(whileSuspended.contains(.operationEntered("load")))
        XCTAssertFalse(whileSuspended.contains(.operationEntered("generation")))
        XCTAssertFalse(whileSuspended.contains(.operationEntered("prewarm")))
        XCTAssertFalse(
            whileSuspended.contains {
                if case .trimmed = $0 { return true }
                return false
            }
        )

        await quiescenceGate.open()
        await response.value
        try await load.value
        try await generation.value

        let completed = await actions.snapshot()
        let publicationIndex = try XCTUnwrap(
            completed.firstIndex(of: .reliefPublished)
        )
        let loadIndex = try XCTUnwrap(
            completed.firstIndex(of: .operationEntered("load"))
        )
        let generationIndex = try XCTUnwrap(
            completed.firstIndex(of: .operationEntered("generation"))
        )
        XCTAssertLessThan(publicationIndex, loadIndex)
        XCTAssertLessThan(publicationIndex, generationIndex)
        XCTAssertFalse(completed.contains(.operationEntered("prewarm")))
    }

    func testPressureSnapshotSupportsConcurrentReadsAndTransitions() async {
        let state = NativeMemoryPressureSnapshotState()

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for iteration in 0..<2_000 {
                        let value: NativeMemoryTrimLevel? = switch (writer + iteration) % 3 {
                        case 0: .softTrim
                        case 1: .hardTrim
                        default: nil
                        }
                        state.transition(to: value)
                    }
                }
            }
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<4_000 {
                        _ = state.currentLevel
                    }
                }
            }
        }

        state.transition(to: .hardTrim)
        XCTAssertEqual(state.currentLevel, .hardTrim)
        XCTAssertEqual(state.transition(to: nil), .hardTrim)
        XCTAssertNil(state.currentLevel)
    }

    func testWarningKernelPressureSoftTrimsWithoutCancellingGeneration() async {
        let actions = TestMemoryPressureActionLog()
        let executor = NativeMemoryPressureResponseExecutor(
            recordObservation: { level in
                await actions.append(.observed(level))
            },
            cancelActiveGeneration: { reason in
                await actions.append(.cancellationRequested(reason))
            },
            trim: { level, reason in
                await actions.append(.trimmed(level, reason))
            },
            closeAdmissionForCriticalRelief: {
                await actions.append(.admissionClosed)
            },
            awaitModelOperationsQuiesced: {
                await actions.append(.modelOperationsQuiesced)
            },
            publishCriticalReliefCompletion: {
                await actions.append(.reliefPublished)
            }
        )

        await executor.execute(
            level: .softTrim,
            reason: "test_kernel_pressure_softTrim"
        )

        let recorded = await actions.snapshot()
        XCTAssertEqual(
            recorded,
            [
                .observed(.softTrim),
                .trimmed(.softTrim, "test_kernel_pressure_softTrim"),
            ]
        )
    }
}
