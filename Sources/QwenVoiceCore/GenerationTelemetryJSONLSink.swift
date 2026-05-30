import Foundation

/// Shared, runtime-gated, append-only writer for per-generation telemetry rows.
///
/// Replaces the dead `#if DEBUG` `NativeDiagnosticEventJSONLWriter` path: this sink
/// is gated on `TelemetryGate.resolvedEnabled` (resolved at runtime, never compiled
/// out) so dev and shipped binaries run identical code. Each layer appends one JSON
/// line to `<appSupport>/diagnostics/<layer>/generations.jsonl`.
public actor GenerationTelemetryJSONLSink {
    public static let shared = GenerationTelemetryJSONLSink()

    private let encoder: JSONEncoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    /// Append one record under `diagnostics/<subdirectory>/<fileName>`.
    /// No-op when the telemetry gate is off or the directory is unknown.
    public func write(
        record: GenerationTelemetryRecord,
        appSupportDirectory: URL?,
        subdirectory: String,
        fileName: String = "generations.jsonl"
    ) {
        guard TelemetryGate.resolvedEnabled else { return }
        guard let appSupportDirectory else { return }

        let directory = appSupportDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
        let url = directory.appendingPathComponent(fileName, isDirectory: false)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var data = try encoder.encode(record)
            data.append(0x0A)
            try Self.append(data, to: url)
        } catch {
            print("[GenerationTelemetryJSONLSink] Could not write telemetry for '\(record.generationID)': \(error.localizedDescription)")
        }
    }

    /// Opt-in verbose path: persist the raw per-sample memory/timing series to a
    /// per-generation sidecar `samples-<generationID>.jsonl` (one `TelemetrySample`
    /// per line). Separate file so the main `generations.jsonl` stays compact and
    /// the high-volume series is only paid for when explicitly requested.
    public func writeRawSamples(
        _ samples: [TelemetrySample],
        generationID: String,
        appSupportDirectory: URL?,
        subdirectory: String
    ) {
        guard TelemetryGate.resolvedEnabled else { return }
        guard let appSupportDirectory, !samples.isEmpty else { return }

        let directory = appSupportDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
        let safeID = generationID.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent("samples-\(safeID).jsonl", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var blob = Data()
            for sample in samples {
                var line = try encoder.encode(sample)
                line.append(0x0A)
                blob.append(line)
            }
            try blob.write(to: url, options: .atomic)
        } catch {
            print("[GenerationTelemetryJSONLSink] Could not write raw samples for '\(generationID)': \(error.localizedDescription)")
        }
    }

    private static func append(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
