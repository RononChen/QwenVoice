import Foundation

public enum VocelloQwen3RuntimeOperationKind: String, Codable, Hashable, Sendable {
    case load
    case prewarm
    case generation
    case memoryRelief = "memory_relief"
    case unload
}

public enum VocelloQwen3OperationPhase: String, Codable, Hashable, Sendable {
    case unloaded
    case loading
    case ready
    case prewarming
    case reservedGeneration = "reserved_generation"
    case generating
    case awaitingProductFinalization = "awaiting_product_finalization"
    case relievingMemory = "relieving_memory"
    case unloading
    case failed
}

public struct VocelloQwen3RuntimeOperationLease: Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: VocelloQwen3RuntimeOperationKind
    public let generationID: UUID?
    public let modelEpoch: UInt64

    fileprivate init(
        id: UUID = UUID(),
        kind: VocelloQwen3RuntimeOperationKind,
        generationID: UUID?,
        modelEpoch: UInt64
    ) {
        self.id = id
        self.kind = kind
        self.generationID = generationID
        self.modelEpoch = modelEpoch
    }
}

public enum VocelloQwen3MemoryPressureLevel: String, Codable, Hashable, Sendable {
    case normal
    case warning
    case critical
}

public struct VocelloQwen3MemoryPressureSnapshot: Codable, Hashable, Sendable {
    public let level: VocelloQwen3MemoryPressureLevel
    public let sequence: UInt64
    public let admissionClosed: Bool

    public init(
        level: VocelloQwen3MemoryPressureLevel = .normal,
        sequence: UInt64 = 0,
        admissionClosed: Bool = false
    ) {
        self.level = level
        self.sequence = sequence
        self.admissionClosed = admissionClosed
    }
}

public struct VocelloQwen3EngineSnapshot: Codable, Hashable, Sendable {
    public let loadedModel: VocelloQwen3ModelIdentity?
    public let modelEpoch: UInt64
    public let phase: VocelloQwen3OperationPhase
    public let activeOperation: VocelloQwen3RuntimeOperationLease?
    public let pressure: VocelloQwen3MemoryPressureSnapshot

    public init(
        loadedModel: VocelloQwen3ModelIdentity?,
        modelEpoch: UInt64,
        phase: VocelloQwen3OperationPhase,
        activeOperation: VocelloQwen3RuntimeOperationLease?,
        pressure: VocelloQwen3MemoryPressureSnapshot
    ) {
        self.loadedModel = loadedModel
        self.modelEpoch = modelEpoch
        self.phase = phase
        self.activeOperation = activeOperation
        self.pressure = pressure
    }
}

public enum VocelloQwen3EngineError: Error, Equatable, Sendable {
    case operationInProgress(VocelloQwen3RuntimeOperationKind)
    case noLoadedModel
    case staleOperation
    case invalidReservation
    case reservationAlreadyOpen
    case audioConsumerNotClaimed
    case modelHasNotTerminated
    case admissionClosedForMemoryRelief
    case invalidCloneHandle
    case invalidConditioningDigest
}

public enum VocelloQwen3CloneHandleCapability: String, Codable, Hashable, Sendable {
    case decoderOnly = "decoder_only"
    case encoderAndDecoder = "encoder_and_decoder"
}

/// Epoch-bound identity for actor-owned clone conditioning.
///
/// The handle intentionally exposes no tensor storage and is never a portable
/// artifact identifier. Loading another model or unloading this engine
/// invalidates it even when a caller retains the value.
public struct VocelloQwen3CloneHandle: Codable, Hashable, Sendable {
    fileprivate let id: UUID
    public let model: VocelloQwen3ModelIdentity
    public let modelEpoch: UInt64
    public let capability: VocelloQwen3CloneHandleCapability
    public let conditioningDigest: String

    fileprivate init(
        id: UUID = UUID(),
        model: VocelloQwen3ModelIdentity,
        modelEpoch: UInt64,
        capability: VocelloQwen3CloneHandleCapability,
        conditioningDigest: String
    ) {
        self.id = id
        self.model = model
        self.modelEpoch = modelEpoch
        self.capability = capability
        self.conditioningDigest = conditioningDigest
    }
}

public struct VocelloQwen3GenerationReservation: Sendable {
    public let id: UUID
    public let lease: VocelloQwen3RuntimeOperationLease
    public let session: VocelloQwen3ClassifiedGenerationSession

    fileprivate init(
        id: UUID,
        lease: VocelloQwen3RuntimeOperationLease,
        session: VocelloQwen3ClassifiedGenerationSession
    ) {
        self.id = id
        self.lease = lease
        self.session = session
    }
}

/// The converged owner for all public MLX-mutating runtime operations.
///
/// This actor begins as a compatibility authority beside the shipping product
/// coordinator. Mode cutover removes those callers one at a time; it never
/// runs a shadow generation. The inner Qwen generation gate remains active as
/// defense-in-depth while compatibility streams are still used.
public actor VocelloQwen3Engine {
    private struct CloneRecord {
        let handle: VocelloQwen3CloneHandle
        let prompt: VocelloQwen3ClonePrompt
    }

    private struct PendingGeneration {
        let reservationID: UUID
        let lease: VocelloQwen3RuntimeOperationLease
        let request: VocelloQwen3SynthesisRequest
        let clonePrompt: VocelloQwen3ClonePrompt?
        let session: VocelloQwen3ClassifiedGenerationSession
        var opened = false
        var task: Task<Void, Never>?
        var generatedTokenCount = 0
        var emittedAudioFrameCount = 0
        var nextAudioSequence = 0
    }

    private struct LastFinalization {
        let generationID: UUID
        let leaseID: UUID
        let token: VocelloQwen3ProductFinalizationToken
        let disposition: VocelloQwen3ProductFinalizationDisposition
    }

    private var loadedModel: VocelloQwen3LoadedModel?
    private var modelEpoch: UInt64 = 0
    private var phase: VocelloQwen3OperationPhase = .unloaded
    private var activeOperation: VocelloQwen3RuntimeOperationLease?
    private var pendingGeneration: PendingGeneration?
    private var lastFinalization: LastFinalization?
    private var pressure = VocelloQwen3MemoryPressureSnapshot()
    private var cloneRecords: [UUID: CloneRecord] = [:]

    public init() {}

    /// Deterministic package-test seam. Production always starts unloaded and
    /// reaches this state through `load(_:behavior:cachePolicy:)`.
    init(loadedModel: VocelloQwen3LoadedModel, modelEpoch: UInt64 = 1) {
        self.loadedModel = loadedModel
        self.modelEpoch = modelEpoch
        phase = .ready
    }

    public func snapshot() -> VocelloQwen3EngineSnapshot {
        VocelloQwen3EngineSnapshot(
            loadedModel: loadedModel?.identity,
            modelEpoch: modelEpoch,
            phase: phase,
            activeOperation: activeOperation,
            pressure: pressure
        )
    }

    /// Records pressure ingress without exposing an admission-reopen switch.
    /// Critical pressure is monotonic until this actor completes the matching
    /// relief operation; warning/normal observations cannot reopen it.
    public func observeMemoryPressure(_ level: VocelloQwen3MemoryPressureLevel) {
        if pressure.admissionClosed, level != .critical {
            return
        }
        let closesAdmission = pressure.admissionClosed || level == .critical
        pressure = VocelloQwen3MemoryPressureSnapshot(
            level: level,
            sequence: pressure.sequence &+ 1,
            admissionClosed: closesAdmission
        )
        if level == .critical, let pendingGeneration {
            pendingGeneration.session.cancellation.request(.memoryPressure)
        }
    }

    @discardableResult
    public func load(
        _ bundle: VocelloQwen3PreparedModelBundle,
        behavior: VocelloQwen3LoadBehavior? = nil,
        cachePolicy: VocelloQwen3CachePolicy = .systemDefault,
        diagnosticSink: VocelloQwen3DiagnosticSink? = nil
    ) async throws -> VocelloQwen3ModelIdentity {
        let lease = try beginOperation(kind: .load, generationID: nil, phase: .loading)
        do {
            let model = try await VocelloQwen3Runtime.loadPreparedModel(
                bundle,
                loadBehavior: behavior,
                cachePolicy: cachePolicy,
                diagnosticSink: diagnosticSink,
                isolation: self
            )
            try revalidate(lease)
            try Task.checkCancellation()
            loadedModel = model
            modelEpoch &+= 1
            cloneRecords.removeAll(keepingCapacity: false)
            activeOperation = nil
            phase = .ready
            return model.identity
        } catch {
            failOperationIfCurrent(lease)
            throw error
        }
    }

    /// Builds clone conditioning inside the actor and returns only an
    /// epoch-bound opaque handle to product code.
    public func makeCloneHandle(
        referenceSamples: [Float],
        referenceText: String?,
        xVectorOnlyMode: Bool,
        conditioningDigest: String
    ) throws -> VocelloQwen3CloneHandle {
        guard let model = loadedModel else {
            throw VocelloQwen3EngineError.noLoadedModel
        }
        guard model.capabilities.contains(.voiceClone) else {
            throw VocelloQwen3ContractError.unsupportedMode(.voiceClone)
        }
        guard !conditioningDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VocelloQwen3EngineError.invalidConditioningDigest
        }
        let lease = try beginOperation(
            kind: .prewarm,
            generationID: nil,
            phase: .prewarming
        )
        do {
            try Task.checkCancellation()
            let prompt = try model.makeClonePrompt(
                referenceSamples: referenceSamples,
                referenceText: referenceText,
                xVectorOnlyMode: xVectorOnlyMode
            )
            try revalidate(lease)
            try Task.checkCancellation()
            let handle = VocelloQwen3CloneHandle(
                model: model.identity,
                modelEpoch: modelEpoch,
                capability: xVectorOnlyMode ? .decoderOnly : .encoderAndDecoder,
                conditioningDigest: conditioningDigest
            )
            cloneRecords[handle.id] = CloneRecord(handle: handle, prompt: prompt)
            activeOperation = nil
            phase = .ready
            return handle
        } catch {
            failOperationIfCurrent(lease)
            throw error
        }
    }

    /// Prepares the currently loaded model without exposing its mutable facade.
    public func prewarm(
        request: VocelloQwen3SynthesisRequest,
        cloneHandle: VocelloQwen3CloneHandle? = nil,
        customDepth: String? = nil
    ) async throws {
        guard let model = loadedModel else {
            throw VocelloQwen3EngineError.noLoadedModel
        }
        _ = try request.validated(for: model.capabilities)
        let lease = try beginOperation(kind: .prewarm, generationID: nil, phase: .prewarming)
        do {
            switch request.input {
            case .customVoice(let speakerID, let instruction):
                try await model.prewarmCustomVoice(
                    text: request.text,
                    language: request.language,
                    speaker: speakerID,
                    instruction: instruction,
                    sampling: request.sampling,
                    memory: request.memory,
                    depth: customDepth,
                    isolation: self
                )
            case .voiceDesign(let description):
                try await model.prewarmVoiceDesign(
                    text: request.text,
                    language: request.language,
                    description: description,
                    sampling: request.sampling,
                    memory: request.memory,
                    isolation: self
                )
            case .voiceClone:
                guard let cloneHandle,
                      let record = validCloneRecord(for: cloneHandle) else {
                    throw VocelloQwen3EngineError.invalidCloneHandle
                }
                try await model.prewarmVoiceClone(
                    text: request.text,
                    language: request.language,
                    prompt: record.prompt,
                    sampling: request.sampling,
                    memory: request.memory,
                    isolation: self
                )
            }
            try revalidate(lease)
            try Task.checkCancellation()
            activeOperation = nil
            phase = .ready
        } catch {
            failOperationIfCurrent(lease)
            throw error
        }
    }

    public func reserveGeneration(
        request: VocelloQwen3SynthesisRequest,
        cloneHandle: VocelloQwen3CloneHandle? = nil,
        audioCapacityFrames: Int,
        diagnosticCapacity: Int = 128
    ) async throws -> VocelloQwen3GenerationReservation {
        let prompt: VocelloQwen3ClonePrompt?
        if case .voiceClone = request.input {
            guard let cloneHandle,
                  let record = validCloneRecord(for: cloneHandle) else {
                throw VocelloQwen3EngineError.invalidCloneHandle
            }
            prompt = record.prompt
        } else {
            prompt = nil
        }
        return try await reserveGeneration(
            request: request,
            clonePrompt: prompt,
            audioCapacityFrames: audioCapacityFrames,
            diagnosticCapacity: diagnosticCapacity
        )
    }

    private func reserveGeneration(
        request: VocelloQwen3SynthesisRequest,
        clonePrompt: VocelloQwen3ClonePrompt? = nil,
        audioCapacityFrames: Int,
        diagnosticCapacity: Int = 128
    ) async throws -> VocelloQwen3GenerationReservation {
        guard !pressure.admissionClosed else {
            throw VocelloQwen3EngineError.admissionClosedForMemoryRelief
        }
        guard let model = loadedModel else {
            throw VocelloQwen3EngineError.noLoadedModel
        }
        _ = try request.validated(for: model.capabilities)
        if case .voiceClone = request.input, clonePrompt == nil {
            throw VocelloQwen3ContractError.missingClonePrompt
        }

        let lease = try beginOperation(
            kind: .generation,
            generationID: request.generationID,
            phase: .reservedGeneration
        )
        let reservationID = UUID()
        let session = VocelloQwen3ClassifiedGenerationSession(
            generationID: request.generationID,
            leaseID: lease.id,
            audioCapacityFrames: audioCapacityFrames,
            diagnosticCapacity: diagnosticCapacity
        )
        pendingGeneration = PendingGeneration(
            reservationID: reservationID,
            lease: lease,
            request: request,
            clonePrompt: clonePrompt,
            session: session
        )
        return VocelloQwen3GenerationReservation(
            id: reservationID,
            lease: lease,
            session: session
        )
    }

    /// Opens generation only after the product output adapter has claimed the
    /// session's mandatory audio consumer.
    public func open(_ reservationID: UUID) async throws {
        guard var pending = pendingGeneration,
              pending.reservationID == reservationID else {
            throw VocelloQwen3EngineError.invalidReservation
        }
        guard !pending.opened else {
            throw VocelloQwen3EngineError.reservationAlreadyOpen
        }
        guard await pending.session.hasClaimedAudioConsumer() else {
            throw VocelloQwen3EngineError.audioConsumerNotClaimed
        }
        try revalidate(pending.lease)
        guard !pressure.admissionClosed else {
            throw VocelloQwen3EngineError.admissionClosedForMemoryRelief
        }

        pending.opened = true
        phase = .generating
        let task = Task { [self] in
            await runGeneration(reservationID: reservationID)
        }
        pending.task = task
        pending.session.cancellation.installCancelAction { task.cancel() }
        pendingGeneration = pending
    }

    /// Aborts an inert reservation. No model task or preparation can have
    /// started because opened reservations use the normal cancellation path.
    /// A reason already recorded by critical-pressure ingress wins over a
    /// later host cleanup reason.
    public func abortReservation(
        _ reservationID: UUID,
        reason: VocelloQwen3CancellationReason = .shutdown
    ) async throws {
        guard let pending = pendingGeneration,
              pending.reservationID == reservationID,
              !pending.opened else {
            throw VocelloQwen3EngineError.invalidReservation
        }
        let effectiveReason: VocelloQwen3CancellationReason
        if let recordedReason = pending.session.cancellation.reason {
            effectiveReason = recordedReason
        } else {
            pending.session.cancellation.request(reason)
            effectiveReason = pending.session.cancellation.reason ?? reason
        }
        let terminal = VocelloQwen3TerminalEvent(
            generationID: pending.request.generationID,
            outcome: .cancelled(effectiveReason),
            generatedTokenCount: 0,
            emittedAudioFrameCount: 0,
            elapsedMilliseconds: 0
        )
        await pending.session.cancelModelTerminal(terminal, reason: effectiveReason)
        _ = try await pending.session.acknowledgeProductFinalization(
            generationID: pending.request.generationID,
            leaseID: pending.lease.id,
            token: pending.session.finalizationToken,
            disposition: .aborted(.runtime)
        )
        releaseGeneration(
            pending,
            disposition: .aborted(.runtime)
        )
    }

    /// Cancels either lifecycle state. An inert reservation is finalized and
    /// released synchronously; an opened producer receives the first reason
    /// through the lock-backed controller and completes its normal barrier.
    public func cancelGeneration(
        _ reservationID: UUID,
        reason: VocelloQwen3CancellationReason
    ) async throws {
        guard let pending = pendingGeneration,
              pending.reservationID == reservationID else {
            throw VocelloQwen3EngineError.invalidReservation
        }
        if !pending.opened {
            try await abortReservation(reservationID, reason: reason)
            return
        }
        pending.session.cancellation.request(reason)
    }

    public func acknowledgeProductFinalization(
        generationID: UUID,
        leaseID: UUID,
        token: VocelloQwen3ProductFinalizationToken,
        disposition: VocelloQwen3ProductFinalizationDisposition
    ) async throws -> VocelloQwen3FinalizationAcknowledgeResult {
        guard let pending = pendingGeneration else {
            return try acknowledgeAgainstLastFinalization(
                generationID: generationID,
                leaseID: leaseID,
                token: token,
                disposition: disposition
            )
        }
        guard phase == .awaitingProductFinalization else {
            throw VocelloQwen3EngineError.modelHasNotTerminated
        }
        try revalidate(pending.lease)
        let result = try await pending.session.acknowledgeProductFinalization(
            generationID: generationID,
            leaseID: leaseID,
            token: token,
            disposition: disposition
        )

        guard let current = pendingGeneration,
              current.reservationID == pending.reservationID,
              activeOperation == pending.lease else {
            return try acknowledgeAgainstLastFinalization(
                generationID: generationID,
                leaseID: leaseID,
                token: token,
                disposition: disposition
            )
        }
        releaseGeneration(current, disposition: disposition)
        return result
    }

    /// Atomically converts the completed generation lease into the critical
    /// relief lease. Admission remains closed throughout; no newer operation
    /// can appear between product cleanup and cache release.
    public func acknowledgeProductFinalizationAndRelieveMemory(
        generationID: UUID,
        leaseID: UUID,
        token: VocelloQwen3ProductFinalizationToken,
        disposition: VocelloQwen3ProductFinalizationDisposition
    ) async throws -> VocelloQwen3FinalizationAcknowledgeResult {
        guard let pending = pendingGeneration else {
            return try acknowledgeAgainstLastFinalization(
                generationID: generationID,
                leaseID: leaseID,
                token: token,
                disposition: disposition
            )
        }
        guard phase == .awaitingProductFinalization else {
            throw VocelloQwen3EngineError.modelHasNotTerminated
        }
        try revalidate(pending.lease)
        let result = try await pending.session.acknowledgeProductFinalization(
            generationID: generationID,
            leaseID: leaseID,
            token: token,
            disposition: disposition
        )
        try revalidate(pending.lease)

        lastFinalization = LastFinalization(
            generationID: generationID,
            leaseID: leaseID,
            token: token,
            disposition: disposition
        )
        let reliefLease = VocelloQwen3RuntimeOperationLease(
            id: pending.lease.id,
            kind: .memoryRelief,
            generationID: nil,
            modelEpoch: pending.lease.modelEpoch
        )
        pendingGeneration = nil
        activeOperation = reliefLease
        phase = .relievingMemory
        do {
            await VocelloQwen3Runtime.clearRuntimeCaches(isolation: self)
            try revalidate(reliefLease)
            activeOperation = nil
            phase = loadedModel == nil ? .unloaded : .ready
            completePressureReliefIfNeeded()
            return result
        } catch {
            failOperationIfCurrent(reliefLease)
            throw error
        }
    }

    /// Clears prepared and decoder caches only when no product operation owns
    /// the runtime. Critical-pressure continuity is coordinated by the product
    /// gate until its cutover to this actor.
    public func relieveMemory() async throws {
        let lease = try beginOperation(
            kind: .memoryRelief,
            generationID: nil,
            phase: .relievingMemory,
            permitsClosedAdmission: true
        )
        do {
            await VocelloQwen3Runtime.clearRuntimeCaches(isolation: self)
            try revalidate(lease)
            activeOperation = nil
            phase = loadedModel == nil ? .unloaded : .ready
            completePressureReliefIfNeeded()
        } catch {
            failOperationIfCurrent(lease)
            throw error
        }
    }

    public func unload() async throws {
        let lease = try beginOperation(kind: .unload, generationID: nil, phase: .unloading)
        do {
            await VocelloQwen3Runtime.clearRuntimeCaches(isolation: self)
            try revalidate(lease)
            loadedModel = nil
            modelEpoch &+= 1
            cloneRecords.removeAll(keepingCapacity: false)
            activeOperation = nil
            phase = .unloaded
        } catch {
            failOperationIfCurrent(lease)
            throw error
        }
    }

    private func runGeneration(reservationID: UUID) async {
        guard let pending = pendingGeneration,
              pending.reservationID == reservationID,
              pending.opened,
              let model = loadedModel else {
            return
        }

        let startedAt = ContinuousClock.now
        do {
            try revalidate(pending.lease)
            try pending.session.cancellation.checkCancellation()

            let finishReason = try await model.produce(
                request: pending.request,
                clonePrompt: pending.clonePrompt,
                sink: { [self] signal in
                    try await consumeGenerationSignal(
                        signal,
                        reservationID: reservationID,
                        modelIdentity: model.identity,
                        sampleRate: model.sampleRate,
                        startedAt: startedAt
                    )
                }
            )
            try revalidate(pending.lease)
            guard let completed = pendingGeneration,
                  completed.reservationID == reservationID else {
                throw VocelloQwen3EngineError.staleOperation
            }
            let outcome: VocelloQwen3TerminalOutcome
            if let cancellationReason = pending.session.cancellation.reason {
                outcome = .cancelled(cancellationReason)
            } else {
                switch finishReason {
                case .endOfSequence:
                    guard completed.emittedAudioFrameCount > 0 else {
                        throw VocelloQwen3EngineRuntimeFailure()
                    }
                    outcome = .completed(.endOfSequence)
                case .maximumTokens:
                    guard completed.emittedAudioFrameCount > 0 else {
                        throw VocelloQwen3EngineRuntimeFailure()
                    }
                    outcome = .completed(.maximumTokens)
                case .cancelled:
                    pending.session.cancellation.request(.user)
                    outcome = .cancelled(pending.session.cancellation.reason ?? .user)
                case .failed:
                    outcome = .failed(.runtime)
                }
            }
            let terminal = VocelloQwen3TerminalEvent(
                generationID: pending.request.generationID,
                outcome: outcome,
                generatedTokenCount: completed.generatedTokenCount,
                emittedAudioFrameCount: completed.emittedAudioFrameCount,
                elapsedMilliseconds: startedAt.elapsedMilliseconds
            )
            try revalidate(pending.lease)
            phase = .awaitingProductFinalization
            switch outcome {
            case .completed:
                await pending.session.resolveModelTerminal(terminal)
            case .cancelled(let reason):
                await pending.session.cancelModelTerminal(terminal, reason: reason)
            case .failed:
                await pending.session.failModelTerminal(
                    terminal,
                    error: VocelloQwen3EngineRuntimeFailure()
                )
            }
        } catch {
            guard activeOperation == pending.lease else { return }
            let current = pendingGeneration?.reservationID == reservationID
                ? pendingGeneration
                : nil
            let tokenCount = current?.generatedTokenCount ?? 0
            let frameCount = current?.emittedAudioFrameCount ?? 0
            // Publish the phase before resolving the model terminal. Terminal
            // resolution resumes the product adapter and therefore creates an
            // actor-reentrancy point where finalization may be acknowledged.
            // A fast adapter must never observe a completed model while the
            // engine still claims to be generating.
            phase = .awaitingProductFinalization
            if pending.session.cancellation.isCancelled || error is CancellationError {
                let reason = pending.session.cancellation.reason ?? .user
                let terminal = VocelloQwen3TerminalEvent(
                    generationID: pending.request.generationID,
                    outcome: .cancelled(reason),
                    generatedTokenCount: tokenCount,
                    emittedAudioFrameCount: frameCount,
                    elapsedMilliseconds: startedAt.elapsedMilliseconds
                )
                await pending.session.cancelModelTerminal(terminal, reason: reason)
            } else {
                let terminal = VocelloQwen3TerminalEvent(
                    generationID: pending.request.generationID,
                    outcome: .failed(.runtime),
                    generatedTokenCount: tokenCount,
                    emittedAudioFrameCount: frameCount,
                    elapsedMilliseconds: startedAt.elapsedMilliseconds
                )
                await pending.session.failModelTerminal(
                    terminal,
                    error: VocelloQwen3EngineRuntimeFailure()
                )
            }
        }
    }

    /// Handles one materialized event while preserving the generation lease
    /// across every suspension. The producer awaits this method, so a full
    /// audio channel directly backpressures the Qwen token/decode loop.
    private func consumeGenerationSignal(
        _ signal: VocelloQwen3GenerationSignal,
        reservationID: UUID,
        modelIdentity: VocelloQwen3ModelIdentity,
        sampleRate: Int,
        startedAt: ContinuousClock.Instant
    ) async throws {
        guard var pending = pendingGeneration,
              pending.reservationID == reservationID,
              pending.opened else {
            throw VocelloQwen3EngineError.staleOperation
        }
        try revalidate(pending.lease)
        try pending.session.cancellation.checkCancellation()

        switch signal {
        case .prepared:
            await pending.session.publishPrepared(VocelloQwen3PreparedEvent(
                generationID: pending.request.generationID,
                model: modelIdentity,
                mode: pending.request.mode,
                elapsedMilliseconds: startedAt.elapsedMilliseconds
            ))
            try revalidate(pending.lease)
            try pending.session.cancellation.checkCancellation()
        case .token:
            pending.generatedTokenCount += 1
            pendingGeneration = pending
        case .info(let info):
            pending.generatedTokenCount = max(
                pending.generatedTokenCount,
                info.generationTokenCount
            )
            pendingGeneration = pending
        case .chunkTimings:
            await pending.session.recordDiagnostic(VocelloQwen3DiagnosticEvent(
                generationID: pending.request.generationID,
                phase: .decode,
                disposition: .observed,
                generatedTokenCount: pending.generatedTokenCount,
                audioFrameCount: pending.emittedAudioFrameCount
            ))
            try revalidate(pending.lease)
            try pending.session.cancellation.checkCancellation()
        case .audio(let samples):
            let chunk = VocelloQwen3AudioChunkEvent(
                generationID: pending.request.generationID,
                sequence: pending.nextAudioSequence,
                samples: samples,
                sampleRate: sampleRate
            )
            try await pending.session.publishAudio(chunk)
            guard var current = pendingGeneration,
                  current.reservationID == reservationID else {
                throw VocelloQwen3EngineError.staleOperation
            }
            try revalidate(current.lease)
            try current.session.cancellation.checkCancellation()
            current.emittedAudioFrameCount += chunk.frameCount
            current.nextAudioSequence += 1
            pendingGeneration = current
        }

        guard let current = pendingGeneration,
              current.reservationID == reservationID else {
            throw VocelloQwen3EngineError.staleOperation
        }
        try revalidate(current.lease)
        await current.session.publishProgress(VocelloQwen3ProgressEvent(
            generationID: current.request.generationID,
            generatedTokenCount: current.generatedTokenCount,
            emittedAudioFrameCount: current.emittedAudioFrameCount,
            elapsedMilliseconds: startedAt.elapsedMilliseconds
        ))
        try revalidate(current.lease)
        try current.session.cancellation.checkCancellation()
    }

    private func beginOperation(
        kind: VocelloQwen3RuntimeOperationKind,
        generationID: UUID?,
        phase nextPhase: VocelloQwen3OperationPhase,
        permitsClosedAdmission: Bool = false
    ) throws -> VocelloQwen3RuntimeOperationLease {
        if pressure.admissionClosed, !permitsClosedAdmission {
            throw VocelloQwen3EngineError.admissionClosedForMemoryRelief
        }
        if let activeOperation {
            throw VocelloQwen3EngineError.operationInProgress(activeOperation.kind)
        }
        let lease = VocelloQwen3RuntimeOperationLease(
            kind: kind,
            generationID: generationID,
            modelEpoch: modelEpoch
        )
        activeOperation = lease
        phase = nextPhase
        return lease
    }

    private func validCloneRecord(
        for handle: VocelloQwen3CloneHandle
    ) -> CloneRecord? {
        guard handle.modelEpoch == modelEpoch,
              handle.model == loadedModel?.identity,
              let record = cloneRecords[handle.id],
              record.handle == handle else {
            return nil
        }
        return record
    }

    private func revalidate(_ lease: VocelloQwen3RuntimeOperationLease) throws {
        guard activeOperation == lease,
              lease.modelEpoch == modelEpoch else {
            throw VocelloQwen3EngineError.staleOperation
        }
        if let generationID = lease.generationID,
           pendingGeneration?.request.generationID != generationID {
            throw VocelloQwen3EngineError.staleOperation
        }
    }

    private func failOperationIfCurrent(_ lease: VocelloQwen3RuntimeOperationLease) {
        guard activeOperation == lease else { return }
        activeOperation = nil
        phase = .failed
    }

    private func releaseGeneration(
        _ pending: PendingGeneration,
        disposition: VocelloQwen3ProductFinalizationDisposition
    ) {
        lastFinalization = LastFinalization(
            generationID: pending.request.generationID,
            leaseID: pending.lease.id,
            token: pending.session.finalizationToken,
            disposition: disposition
        )
        pendingGeneration = nil
        activeOperation = nil
        phase = loadedModel == nil ? .unloaded : .ready
    }

    /// The sole admission-reopen transition. It is called only after a
    /// successfully revalidated memory-relief lease has completed.
    private func completePressureReliefIfNeeded() {
        guard pressure.admissionClosed else { return }
        pressure = VocelloQwen3MemoryPressureSnapshot(
            level: .normal,
            sequence: pressure.sequence &+ 1,
            admissionClosed: false
        )
    }

    private func acknowledgeAgainstLastFinalization(
        generationID: UUID,
        leaseID: UUID,
        token: VocelloQwen3ProductFinalizationToken,
        disposition: VocelloQwen3ProductFinalizationDisposition
    ) throws -> VocelloQwen3FinalizationAcknowledgeResult {
        guard let lastFinalization,
              lastFinalization.generationID == generationID,
              lastFinalization.leaseID == leaseID,
              lastFinalization.token == token else {
            throw VocelloQwen3SessionError.invalidFinalizationIdentity
        }
        guard lastFinalization.disposition == disposition else {
            throw VocelloQwen3SessionError.conflictingFinalizationAcknowledgement
        }
        return .alreadyAcknowledged
    }
}

private struct VocelloQwen3EngineRuntimeFailure: Error, Sendable {}

private extension ContinuousClock.Instant {
    var elapsedMilliseconds: Int {
        let duration = duration(to: .now)
        return max(0, Int((Double(duration.components.seconds) * 1_000)
            + (Double(duration.components.attoseconds) / 1e15)))
    }
}
