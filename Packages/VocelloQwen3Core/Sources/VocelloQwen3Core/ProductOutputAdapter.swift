import Foundation

public enum VocelloQwen3ProductOutputAdapterError: Error, Equatable, Sendable {
    case modelDidNotComplete(VocelloQwen3TerminalOutcome)
    case outputWasNotPublished
}

/// Limiter-approved PCM16 preview payload. Product sinks return this only
/// after the same frames have been durably appended to staged output. Keeping
/// preview in its transport representation avoids rebuilding a second float
/// array for every chunk.
public struct VocelloQwen3PreviewAudioChunk: Hashable, Sendable {
    public let generationID: UUID
    public let sequence: Int
    public let pcm16LittleEndian: Data
    public let frameCount: Int
    public let sampleRate: Int
    public let channelCount: Int

    public init(
        generationID: UUID,
        sequence: Int,
        pcm16LittleEndian: Data,
        frameCount: Int,
        sampleRate: Int,
        channelCount: Int = 1
    ) {
        self.generationID = generationID
        self.sequence = sequence
        self.pcm16LittleEndian = pcm16LittleEndian
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Product-owned incremental output work used by the runtime adapter.
///
/// Implementations write every frame before exposing it to a frontend, then
/// finalize/reopen the output, run mandatory Fast QC, and atomically publish.
/// No MLX value is accepted by this boundary.
public protocol VocelloQwen3ProductOutputSink: Sendable {
    func consume(
        _ chunk: VocelloQwen3AudioChunkEvent
    ) async throws -> VocelloQwen3PreviewAudioChunk
    func finalize(
        modelTerminal: VocelloQwen3TerminalEvent
    ) async throws -> VocelloQwen3ProductFinalizationDisposition
    func abort() async
}

public struct VocelloQwen3ProductTerminal: Hashable, Sendable {
    public let modelTerminal: VocelloQwen3TerminalEvent
    public let disposition: VocelloQwen3ProductFinalizationDisposition

    public init(
        modelTerminal: VocelloQwen3TerminalEvent,
        disposition: VocelloQwen3ProductFinalizationDisposition
    ) {
        self.modelTerminal = modelTerminal
        self.disposition = disposition
    }
}

private actor VocelloQwen3ProductTerminalClaim {
    private var terminal: VocelloQwen3ProductTerminal?

    func claim(_ proposed: VocelloQwen3ProductTerminal) -> Bool {
        guard terminal == nil else { return false }
        terminal = proposed
        return true
    }
}

/// Owns the mandatory core-audio drain and the product-finalization handshake.
///
/// `run` claims audio before opening the inert reservation. A sink failure
/// requests cancellation immediately so a producer suspended on backpressure
/// can wake. The engine operation lease is released only after the sink has
/// completed cleanup and this adapter has published exactly one product
/// terminal.
public struct VocelloQwen3ProductOutputAdapter: Sendable {
    public typealias PreviewPublisher = @Sendable (VocelloQwen3PreviewAudioChunk) async -> Void
    public typealias TerminalPublisher = @Sendable (VocelloQwen3ProductTerminal) async -> Void

    private let previewPublisher: PreviewPublisher
    private let terminalPublisher: TerminalPublisher

    public init(
        previewPublisher: @escaping PreviewPublisher = { _ in },
        terminalPublisher: @escaping TerminalPublisher = { _ in }
    ) {
        self.previewPublisher = previewPublisher
        self.terminalPublisher = terminalPublisher
    }

    @discardableResult
    public func run(
        engine: VocelloQwen3Engine,
        reservation: VocelloQwen3GenerationReservation,
        sink: any VocelloQwen3ProductOutputSink
    ) async throws -> VocelloQwen3ProductTerminal {
        let claim = VocelloQwen3ProductTerminalClaim()
        let audio = try await reservation.session.claimAudioConsumer()
        let drain = Task {
            do {
                for try await chunk in audio {
                    try Task.checkCancellation()
                    // Persisted output is authoritative. Preview is emitted
                    // only after the sink accepted this exact ordered chunk.
                    let previewChunk = try await sink.consume(chunk)
                    await previewPublisher(previewChunk)
                }
            } catch {
                // Cancellation ingress is deliberately independent of the
                // engine actor. Wake a producer blocked on the lossless channel
                // before performing any actor-isolated cleanup.
                reservation.session.cancellation.request(.shutdown)
                await audio.fail(ProductOutputAdapterDrainFailure())
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            do {
                // Cancellation can arrive after the consumer is claimed but
                // before the engine opens the inert reservation. Check again
                // inside the installed handler so that window aborts without
                // starting MLX work.
                try Task.checkCancellation()
                try await engine.open(reservation.id)
            } catch {
                drain.cancel()
                reservation.session.cancellation.request(.shutdown)
                let reason = reservation.session.cancellation.reason ?? .shutdown
                await audio.cancel(reason: reason)
                try? await engine.abortReservation(reservation.id, reason: reason)
                await sink.abort()
                throw error
            }

            let modelTerminal = await reservation.session.waitForModelTermination()
            do {
                try await drain.value
                guard case .completed(.endOfSequence) = modelTerminal.outcome else {
                    throw VocelloQwen3ProductOutputAdapterError.modelDidNotComplete(
                        modelTerminal.outcome
                    )
                }
                let disposition = try await sink.finalize(modelTerminal: modelTerminal)
                guard disposition == .published else {
                    throw VocelloQwen3ProductOutputAdapterError.outputWasNotPublished
                }
                let terminal = VocelloQwen3ProductTerminal(
                    modelTerminal: modelTerminal,
                    disposition: disposition
                )
                if await claim.claim(terminal) {
                    await terminalPublisher(terminal)
                }
                _ = try await engine.acknowledgeProductFinalization(
                    generationID: reservation.session.generationID,
                    leaseID: reservation.lease.id,
                    token: reservation.session.finalizationToken,
                    disposition: disposition
                )
                return terminal
            } catch {
                reservation.session.cancellation.request(.shutdown)
                _ = await reservation.session.waitForModelTermination()
                await sink.abort()
                let disposition = VocelloQwen3ProductFinalizationDisposition.aborted(.runtime)
                let terminal = VocelloQwen3ProductTerminal(
                    modelTerminal: modelTerminal,
                    disposition: disposition
                )
                if await claim.claim(terminal) {
                    await terminalPublisher(terminal)
                }
                _ = try? await engine.acknowledgeProductFinalization(
                    generationID: reservation.session.generationID,
                    leaseID: reservation.lease.id,
                    token: reservation.session.finalizationToken,
                    disposition: disposition
                )
                throw error
            }
        } onCancel: {
            drain.cancel()
            // `onCancel` cannot suspend. The lock-backed controller records the
            // first reason and invokes the installed task-cancellation action
            // synchronously, without an unstructured actor-hop Task.
            reservation.session.cancellation.request(.shutdown)
        }
    }
}

private struct ProductOutputAdapterDrainFailure: Error, Sendable {}
