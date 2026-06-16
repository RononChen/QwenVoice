import Foundation

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
