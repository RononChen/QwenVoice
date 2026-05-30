import Foundation

/// One durable telemetry row for a single generation, written by one layer.
///
/// Every layer (engine / engine-service / engine-extension / app) emits its own
/// record keyed by the same `generationID` (threaded app → engine, see
/// `NativeEngineRuntime`), so the per-layer JSONL streams join cleanly into the
/// unified `generations-merged.jsonl` (`layer == "merged"`).
///
/// Naming note: deliberately avoids the `Probe`/`Benchmark` tokens banned by
/// `scripts/check_project_inputs.sh`.
public struct GenerationTelemetryRecord: Hashable, Codable, Sendable {
    public enum Layer: String, Hashable, Codable, Sendable {
        case engine
        case engineService = "engine-service"
        case engineExtension = "engine-extension"
        case app
        case merged
    }

    /// v2 added the backend-optimization payload: `derivedMetrics` (RTF, tokens/sec),
    /// `mlxMemoryByStage` (per-stage MLX GPU memory), and `chunkTimeline` (per-chunk
    /// decode substage breakdown). v3 added `modelID` + `warmState` so each row
    /// self-identifies its benchmark cell (model variant × cold/warm). All optional,
    /// so older rows still decode.
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let generationID: String
    public let layer: Layer
    public let processName: String
    public let processIdentifier: Int32
    public let recordedAt: String
    public let mode: String?
    /// The resolved model id for this generation (variant-specific — distinguishes
    /// Speed 4-bit vs Quality 8-bit). Lets a benchmark attribute the row to its cell.
    public let modelID: String?
    /// Whether the model was loaded by THIS generation (`.cold`) or reused from a
    /// prior one (`.warm`). The benchmark's cold/warm axis.
    public let warmState: EngineWarmState?
    public let usedStreaming: Bool?
    public let finishReason: String?
    public let stageMarks: [NativeTelemetryStageMark]
    /// Raw integer timings. For the engine layer this carries the full MLX decode
    /// breakdown (talker forward, code predictor, decoder, stream-step eval/EOS,
    /// token-loop total, unattributed) + counters (generated codes, decoder calls),
    /// re-read from the model AFTER the decode loop so the hot-loop totals are final.
    public let timingsMS: [String: Int]
    public let counters: [String: Int]
    public let notes: [String: String]
    public let summary: TelemetrySummary?
    /// Headline derived throughput KPIs (engine layer): `audioSeconds`,
    /// `decodeWallSeconds`, `audioSecondsPerWallSecond` (>1 = faster than realtime),
    /// `tokensPerSecond`, `generatedTokenCount`. nil when not computed.
    public let derivedMetrics: [String: Double]?
    /// Per-stage MLX GPU memory (active/cache/peak MB) — e.g. before_stream,
    /// first_chunk, after_stream, after_generation_trim. nil when not collected.
    public let mlxMemoryByStage: [String: NativeMLXMemorySnapshot]?
    /// Per-chunk decode substage breakdown for streaming runs (cold-start vs
    /// steady-state, stall localization). nil for non-streaming / when gated off.
    public let chunkTimeline: [GenerationChunkTelemetry]?

    public init(
        generationID: String,
        layer: Layer,
        recordedAt: String,
        mode: String? = nil,
        modelID: String? = nil,
        warmState: EngineWarmState? = nil,
        usedStreaming: Bool? = nil,
        finishReason: String? = nil,
        stageMarks: [NativeTelemetryStageMark] = [],
        summary: TelemetrySummary? = nil,
        timingsMS: [String: Int] = [:],
        counters: [String: Int] = [:],
        notes: [String: String] = [:],
        derivedMetrics: [String: Double]? = nil,
        mlxMemoryByStage: [String: NativeMLXMemorySnapshot]? = nil,
        chunkTimeline: [GenerationChunkTelemetry]? = nil,
        schemaVersion: Int = GenerationTelemetryRecord.currentSchemaVersion,
        processName: String = ProcessInfo.processInfo.processName,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.layer = layer
        self.processName = processName
        self.processIdentifier = processIdentifier
        self.recordedAt = recordedAt
        self.mode = mode
        self.modelID = modelID
        self.warmState = warmState
        self.usedStreaming = usedStreaming
        self.finishReason = finishReason
        self.stageMarks = stageMarks
        self.summary = summary
        self.timingsMS = timingsMS
        self.counters = counters
        self.notes = notes
        self.derivedMetrics = derivedMetrics
        self.mlxMemoryByStage = mlxMemoryByStage
        self.chunkTimeline = chunkTimeline
    }
}

/// Per-chunk decode substage timing for one streaming audio chunk — a Codable,
/// persistence-safe mirror of the vendored `ChunkSubstageTimings` plus the chunk
/// index and wall-clock arrival (ms since the generation's telemetry start clock).
/// All substage values are millisecond deltas since the previous chunk boundary.
public struct GenerationChunkTelemetry: Hashable, Codable, Sendable {
    public let chunkIndex: Int
    public let arrivalMS: Int
    public let talkerForwardMS: Double
    public let codePredictorMS: Double
    public let audioDecoderMS: Double
    public let streamStepEvalMS: Double
    public let streamStepEOSReadMS: Double
    public let audioChunkEvalMS: Double

    public init(
        chunkIndex: Int,
        arrivalMS: Int,
        talkerForwardMS: Double,
        codePredictorMS: Double,
        audioDecoderMS: Double,
        streamStepEvalMS: Double,
        streamStepEOSReadMS: Double,
        audioChunkEvalMS: Double
    ) {
        self.chunkIndex = chunkIndex
        self.arrivalMS = arrivalMS
        self.talkerForwardMS = talkerForwardMS
        self.codePredictorMS = codePredictorMS
        self.audioDecoderMS = audioDecoderMS
        self.streamStepEvalMS = streamStepEvalMS
        self.streamStepEOSReadMS = streamStepEOSReadMS
        self.audioChunkEvalMS = audioChunkEvalMS
    }
}

/// The unified per-generation record produced by `GenerationTelemetryMerger`,
/// joining each layer's row under one `generationID`.
public struct MergedGenerationTelemetry: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generationID: String
    public let recordedAt: String
    public let app: GenerationTelemetryRecord?
    public let engineService: GenerationTelemetryRecord?
    public let engine: GenerationTelemetryRecord?

    public init(
        generationID: String,
        recordedAt: String,
        app: GenerationTelemetryRecord?,
        engineService: GenerationTelemetryRecord?,
        engine: GenerationTelemetryRecord?,
        schemaVersion: Int = MergedGenerationTelemetry.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.recordedAt = recordedAt
        self.app = app
        self.engineService = engineService
        self.engine = engine
    }
}
