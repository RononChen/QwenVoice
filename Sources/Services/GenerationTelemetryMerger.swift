import Foundation
import QwenVoiceCore

/// Joins the per-layer telemetry rows for one generation into a single readable
/// `generations-merged.jsonl` row, keyed by the shared `generationID`.
///
/// macOS-only (app target): the engine-service runs in a process that shares the
/// app's app-support directory, so the app can read the engine/engine-service rows
/// directly. (iOS leans on `GenerationResult.telemetrySummary` carried back in the
/// result instead — see the plan; that wiring is deferred with the rest of iOS.)
///
/// Runtime-gated and fully off the main actor. The engine and engine-service rows
/// flush slightly after the app's `completed` (both write asynchronously), so the
/// merge polls briefly before giving up.
enum GenerationTelemetryMerger {
    private static let mergedFileName = "generations-merged.jsonl"
    private static let pollAttempts = 5
    private static let pollIntervalNanos: UInt64 = 100_000_000 // 100 ms × 5 = ~500 ms

    /// Schedule a merge for the given generation. No-op when telemetry is off.
    static func scheduleMerge(generationID: UUID?) {
        guard TelemetryGate.appProcessIntendedEnabled else { return }
        guard let generationID else { return }
        let key = generationID.uuidString
        let appSupportDirectory = AppPaths.appSupportDir
        Task.detached(priority: .background) {
            await merge(generationID: key, appSupportDirectory: appSupportDirectory)
        }
    }

    private static func merge(generationID: String, appSupportDirectory: URL) async {
        let diagnostics = appSupportDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        let appURL = diagnostics.appendingPathComponent("app/generations.jsonl", isDirectory: false)
        let engineServiceURL = diagnostics.appendingPathComponent("engine-service/generations.jsonl", isDirectory: false)
        let engineURL = diagnostics.appendingPathComponent("engine/generations.jsonl", isDirectory: false)

        var app: GenerationTelemetryRecord?
        var engineService: GenerationTelemetryRecord?
        var engine: GenerationTelemetryRecord?

        for attempt in 0..<pollAttempts {
            app = app ?? latestRecord(for: generationID, in: appURL)
            engineService = engineService ?? latestRecord(for: generationID, in: engineServiceURL)
            engine = engine ?? latestRecord(for: generationID, in: engineURL)
            if app != nil, engineService != nil, engine != nil { break }
            if attempt < pollAttempts - 1 {
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
            }
        }

        guard app != nil || engineService != nil || engine != nil else { return }

        let merged = MergedGenerationTelemetry(
            generationID: generationID,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            app: app,
            engineService: engineService,
            engine: engine
        )
        write(merged, into: diagnostics)
    }

    /// Returns the last row matching `generationID` in a per-layer JSONL file.
    private static func latestRecord(
        for generationID: String,
        in url: URL
    ) -> GenerationTelemetryRecord? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        var match: GenerationTelemetryRecord?
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(GenerationTelemetryRecord.self, from: lineData),
                  record.generationID == generationID else {
                continue
            }
            match = record
        }
        return match
    }

    private static func write(_ merged: MergedGenerationTelemetry, into diagnostics: URL) {
        let url = diagnostics.appendingPathComponent(mergedFileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
            var data = try encoder.encode(merged)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            // Cap the merged log the same way the per-layer logs are capped
            // (oldest-first front trim) so benchmark logs can't blow out disk.
            GenerationTelemetryJSONLSink.pruneJSONLFromFront(
                at: url,
                maxBytes: GenerationTelemetryJSONLSink.maxLogBytes
            )
        } catch {
            print("[GenerationTelemetryMerger] Could not write merged telemetry for '\(merged.generationID)': \(error.localizedDescription)")
        }
    }
}
