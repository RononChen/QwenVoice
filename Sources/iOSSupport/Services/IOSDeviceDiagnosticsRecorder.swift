import Foundation
import QwenVoiceCore
import UIKit

@MainActor
final class IOSDeviceDiagnosticsRecorder {
    private struct Target {
        let name: String
        let directory: URL
        let manifestURL: URL
        let memoryContextsURL: URL
        let nativeEventsURL: URL
    }

    private let runID: String
    private let targets: [Target]
    private let encoder: JSONEncoder
    private let dateFormatter = ISO8601DateFormatter()
    private var preparedTargets: Set<String> = []

    private init(runID: String, diagnosticsDirectories: [(name: String, url: URL)]) {
        self.runID = runID
        self.targets = diagnosticsDirectories.map { entry in
            Target(
                name: entry.name,
                directory: entry.url,
                manifestURL: entry.url.appendingPathComponent("manifest.json", isDirectory: false),
                memoryContextsURL: entry.url.appendingPathComponent("memory-contexts.jsonl", isDirectory: false),
                nativeEventsURL: entry.url.appendingPathComponent("native-events.jsonl", isDirectory: false)
            )
        }
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    static func makeIfEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appSupportDirectory: URL = AppPaths.appSupportDir
    ) -> IOSDeviceDiagnosticsRecorder? {
#if DEBUG
        guard NativeTelemetryMode.current(environment: environment) == .lightweight else {
            return nil
        }
        guard let runID = environment["QVOICE_IOS_DEVICE_RUN_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !runID.isEmpty else {
            return nil
        }

        let safeRunID = runID.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "_"
        }
        .reduce(into: "") { $0.append($1) }

        let directory = appSupportDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent(safeRunID, isDirectory: true)
        var directories = [(name: "app-group", url: directory)]
        if let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first {
            let mirrorDirectory = cachesDirectory
                .appendingPathComponent("Vocello", isDirectory: true)
                .appendingPathComponent("diagnostics", isDirectory: true)
                .appendingPathComponent(safeRunID, isDirectory: true)
            directories.append((name: "app-container-cache", url: mirrorDirectory))
        }
        return IOSDeviceDiagnosticsRecorder(runID: safeRunID, diagnosticsDirectories: directories)
#else
        return nil
#endif
    }

    func recordMemoryContext(
        _ context: IOSMemoryContext,
        event: String,
        previousBand: IOSMemoryPressureBand? = nil
    ) {
        append(
            MemoryContextDiagnosticRecord(
                event: event,
                recordedAt: dateFormatter.string(from: Date()),
                processUptimeSeconds: ProcessInfo.processInfo.systemUptime,
                runID: runID,
                reason: context.reason,
                source: context.source,
                pressureBand: context.pressureBand,
                aggregatePressureBand: context.aggregatePressureBand,
                previousPressureBand: previousBand,
                worstProcessRole: context.worstProcessRole,
                combinedResidentBytes: context.combinedResidentBytes,
                combinedPhysFootprintBytes: context.combinedPhysFootprintBytes,
                combinedCompressedBytes: context.combinedCompressedBytes,
                combinedGPUAllocatedBytes: context.combinedGPUAllocatedBytes,
                trimLevel: nil,
                message: nil,
                context: context
            )
        )
    }

    func recordAction(
        event: String,
        reason: String,
        context: IOSMemoryContext?,
        trimLevel: NativeMemoryTrimLevel? = nil,
        message: String? = nil
    ) {
        append(
            MemoryContextDiagnosticRecord(
                event: event,
                recordedAt: dateFormatter.string(from: Date()),
                processUptimeSeconds: ProcessInfo.processInfo.systemUptime,
                runID: runID,
                reason: reason,
                source: context?.source,
                pressureBand: context?.pressureBand,
                aggregatePressureBand: context?.aggregatePressureBand,
                previousPressureBand: nil,
                worstProcessRole: context?.worstProcessRole,
                combinedResidentBytes: context?.combinedResidentBytes,
                combinedPhysFootprintBytes: context?.combinedPhysFootprintBytes,
                combinedCompressedBytes: context?.combinedCompressedBytes,
                combinedGPUAllocatedBytes: context?.combinedGPUAllocatedBytes,
                trimLevel: trimLevel,
                message: message,
                context: context
            )
        )
    }

    private func append(_ record: MemoryContextDiagnosticRecord) {
        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            var firstError: Error?
            for target in targets {
                do {
                    try prepareFilesIfNeeded(for: target)
                    try append(data, to: target.memoryContextsURL)
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                throw firstError
            }
            mirrorNativeEventsToAppContainerCacheIfNeeded()
        } catch {
#if DEBUG
            print("[IOSDeviceDiagnosticsRecorder] Could not write diagnostics: \(error.localizedDescription)")
#endif
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func prepareFilesIfNeeded(for target: Target) throws {
        guard !preparedTargets.contains(target.name) else { return }
        try FileManager.default.createDirectory(
            at: target.directory,
            withIntermediateDirectories: true
        )
        let manifest = DeviceDiagnosticsManifest(
            runID: runID,
            createdAt: dateFormatter.string(from: Date()),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String,
            deviceModel: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            appSupportDirectory: AppPaths.appSupportDir.path,
            memoryContextsPath: target.memoryContextsURL.lastPathComponent,
            nativeEventsPath: target.nativeEventsURL.lastPathComponent
        )
        let data = try encoder.encode(manifest)
        try data.write(to: target.manifestURL, options: .atomic)
        preparedTargets.insert(target.name)
    }

    private func mirrorNativeEventsToAppContainerCacheIfNeeded() {
        guard let appGroupTarget = targets.first(where: { $0.name == "app-group" }),
              FileManager.default.fileExists(atPath: appGroupTarget.nativeEventsURL.path) else {
            return
        }
        for target in targets where target.name != appGroupTarget.name {
            do {
                try FileManager.default.createDirectory(
                    at: target.directory,
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: target.nativeEventsURL.path) {
                    try FileManager.default.removeItem(at: target.nativeEventsURL)
                }
                try FileManager.default.copyItem(
                    at: appGroupTarget.nativeEventsURL,
                    to: target.nativeEventsURL
                )
            } catch {
#if DEBUG
                print("[IOSDeviceDiagnosticsRecorder] Could not mirror native events: \(error.localizedDescription)")
#endif
            }
        }
    }
}

private struct DeviceDiagnosticsManifest: Codable {
    let runID: String
    let createdAt: String
    let bundleIdentifier: String
    let marketingVersion: String?
    let buildVersion: String?
    let deviceModel: String
    let systemName: String
    let systemVersion: String
    let appSupportDirectory: String
    let memoryContextsPath: String
    let nativeEventsPath: String
}

private struct MemoryContextDiagnosticRecord: Codable {
    let event: String
    let recordedAt: String
    let processUptimeSeconds: Double
    let runID: String
    let reason: String
    let source: String?
    let pressureBand: IOSMemoryPressureBand?
    let aggregatePressureBand: IOSMemoryPressureBand?
    let previousPressureBand: IOSMemoryPressureBand?
    let worstProcessRole: IOSMemoryProcessRole?
    let combinedResidentBytes: UInt64?
    let combinedPhysFootprintBytes: UInt64?
    let combinedCompressedBytes: UInt64?
    let combinedGPUAllocatedBytes: UInt64?
    let trimLevel: NativeMemoryTrimLevel?
    let message: String?
    let context: IOSMemoryContext?
}
