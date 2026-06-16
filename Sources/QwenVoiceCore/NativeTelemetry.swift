import Foundation
import OSLog

public struct NativeTelemetryStageMark: Hashable, Codable, Sendable {
    public let tMS: Int
    public let stage: String
    public let metadata: [String: String]

    public init(
        tMS: Int,
        stage: String,
        metadata: [String: String] = [:]
    ) {
        self.tMS = tMS
        self.stage = stage
        self.metadata = metadata
    }
}

public actor NativeTelemetryRecorder {
    /// Exposed (immutable, `Sendable`) so the per-generation `NativeTelemetrySampler`
    /// can be created with the SAME start instant — `NativeTelemetrySampler.decorate`
    /// joins memory samples to stage marks by `tMS`, so a mismatched start clock
    /// would break that join.
    public nonisolated let startUptimeSeconds: TimeInterval
    private var stageMarks: [NativeTelemetryStageMark] = []

    public init(startUptimeSeconds: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.startUptimeSeconds = startUptimeSeconds
    }

    public func mark(
        stage: String,
        metadata: [String: String] = [:]
    ) {
        stageMarks.append(
            NativeTelemetryStageMark(
                tMS: elapsedMilliseconds,
                stage: stage,
                metadata: metadata
            )
        )
    }

    public func snapshot() -> [NativeTelemetryStageMark] {
        stageMarks.sorted { lhs, rhs in
            if lhs.tMS == rhs.tMS {
                return lhs.stage < rhs.stage
            }
            return lhs.tMS < rhs.tMS
        }
    }

    public func reset() {
        stageMarks.removeAll(keepingCapacity: false)
    }

    private var elapsedMilliseconds: Int {
        Int(
            (
                ProcessInfo.processInfo.systemUptime
                - startUptimeSeconds
            ) * 1_000
        )
    }
}

extension NativeTelemetryRecorder {
    func mark(
        stage: NativeRuntimeStage,
        metadata: [String: String] = [:]
    ) {
        mark(stage: stage.rawValue, metadata: metadata)
    }
}

/// Maps the current Swift `Task` priority to a human-readable QoS label for
/// telemetry notes. Swift priorities are an approximation of Dispatch QoS:
/// `.userInitiated` ≈ user-initiated, `.background` ≈ background, etc.
public func currentTaskQOSNotes() -> [String: String] {
    let priority = Task.currentPriority
    let name: String
    switch priority {
    case .high: name = "high"
    case .userInitiated: name = "userInitiated"
    case .medium: name = "medium"
    case .utility: name = "utility"
    case .background: name = "background"
    case .low: name = "low"
    default: name = "priority-\(priority.rawValue)"
    }
    return ["qosClass": name]
}

/// Description of an `OSSignposter` interval whose wall-clock duration should
/// also be mirrored into the durable JSONL timings map.
public struct NativeTelemetrySignpostInterval: Sendable {
    public let name: StaticString
    public let timingKey: String

    public init(name: StaticString, timingKey: String) {
        self.name = name
        self.timingKey = timingKey
    }
}

extension NativeTelemetrySignpostInterval {
    public static let prepareGeneration = Self(
        name: "Native Prepare Generation",
        timingKey: "native_prepare_generation_ms"
    )
    public static let modelLoad = Self(
        name: "Native Model Load",
        timingKey: "native_model_load_ms"
    )
    public static let cloneConditioning = Self(
        name: "Native Clone Conditioning",
        timingKey: "native_clone_conditioning_ms"
    )
    public static let explicitPrewarm = Self(
        name: "Native Explicit Prewarm",
        timingKey: "native_explicit_prewarm_ms"
    )
    public static let qualityFirstGeneration = Self(
        name: "Native Quality-First Generation",
        timingKey: "native_quality_first_generation_ms"
    )
    public static let generationStream = Self(
        name: "Native Generation Stream",
        timingKey: "native_generation_stream_ms"
    )
    public static let finalWAVFinish = Self(
        name: "Native Final WAV Finish",
        timingKey: "native_final_wav_finish_ms"
    )
}

/// Wraps an `OSSignposter` interval and writes its duration (in milliseconds)
/// into `timings[timingKey]` so the same span seen in Instruments is also
/// present in the durable JSONL row.
public func withMirroredSignpost<T>(
    _ interval: NativeTelemetrySignpostInterval,
    signposter: OSSignposter,
    recorder: NativeTelemetryRecorder?,
    timings: inout [String: Int],
    operation: () async throws -> T
) async rethrows -> T {
    let signpostState = signposter.beginInterval(interval.name)
    let startedAt = ContinuousClock.now
    defer {
        timings[interval.timingKey] = startedAt.elapsedMilliseconds
        signposter.endInterval(interval.name, signpostState)
    }
    return try await operation()
}
