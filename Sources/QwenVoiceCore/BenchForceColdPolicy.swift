import Foundation

/// Debug-only benchmark hook: force an explicit model unload immediately before the next
/// generation so telemetry records `warmState=cold`. Honored only when durable telemetry
/// is enabled (`TelemetryGate`), matching the trust model for other bench env vars.
public enum BenchForceColdPolicy {
    private static let environmentKey = "QWENVOICE_BENCH_FORCE_COLD"

    public static var shouldUnloadBeforeGeneration: Bool {
        guard TelemetryGate.resolvedEnabled else { return false }
        let value = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value else { return false }
        return ["1", "true", "on", "yes"].contains(value)
    }
}
