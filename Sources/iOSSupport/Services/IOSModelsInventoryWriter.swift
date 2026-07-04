import Foundation
import UIKit
import QwenVoiceCore

/// Headless on-device model inventory for `scripts/ios_device.sh models check`.
///
/// When `QVOICE_IOS_MODELS_CHECK=1` is set at launch, enumerates Speed-tier contract
/// models via `LocalModelAssetStore.integrity()` and writes pullable
/// `Library/Caches/Vocello/diagnostics/models-status.json` (app container — devicectl-readable).
@MainActor
enum IOSModelsInventoryWriter {
    static let requestEnvKey = "QVOICE_IOS_MODELS_CHECK"
    static let outputFileName = "models-status.json"

    /// Speed-tier models after iOS `resolvedForPlatform(.iOS)` (base ids, speed folders).
    static let requiredModelIDs = ["pro_custom", "pro_design", "pro_clone"]

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[requestEnvKey] == "1"
    }

    /// Lightweight inventory path — no MLX engine load. Terminates the process after write.
    static func runAndExit(storeVersionSeed: String) throws {
        guard AppPaths.isUsingSharedContainer else {
            try writePayload(
                storeVersionSeed: storeVersionSeed,
                models: [:],
                cloneVoicesEnrolled: 0,
                error: "App Group container unavailable — cannot read models store."
            )
            exit(1)
        }

        let registry = try TTSContract.loadRegistry()
        let store = LocalModelAssetStore(
            modelRegistry: registry,
            rootDirectory: AppPaths.modelsDir,
            storeVersionSeed: storeVersionSeed
        )

        var models: [String: ModelEntry] = [:]
        for modelID in requiredModelIDs {
            guard let descriptor = store.descriptor(id: modelID) else {
                models[modelID] = ModelEntry(
                    status: "missing",
                    sizeBytes: 0,
                    missingPaths: ["unknown contract id"]
                )
                continue
            }
            let integrity = store.integrity(for: descriptor)
            models[modelID] = ModelEntry(
                status: integrity.status.rawValue,
                sizeBytes: integrity.sizeBytes,
                missingPaths: integrity.missingRelativePaths.isEmpty
                    ? nil
                    : integrity.missingRelativePaths
            )
        }

        let cloneCount = enrolledCloneVoiceCount()
        try writePayload(
            storeVersionSeed: storeVersionSeed,
            models: models,
            cloneVoicesEnrolled: cloneCount,
            error: nil
        )
        exit(0)
    }

    static func writeFailure(_ error: Error, storeVersionSeed: String = "unknown") {
        do {
            try writePayload(
                storeVersionSeed: storeVersionSeed,
                models: [:],
                cloneVoicesEnrolled: 0,
                error: error.localizedDescription
            )
        } catch {
            print("[models-inventory] could not write failure payload: \(error.localizedDescription)")
        }
        exit(1)
    }

    private static func enrolledCloneVoiceCount() -> Int {
        let voicesDir = AppPaths.voicesDir
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: voicesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return entries.filter { $0.pathExtension == "txt" }.count
    }

    private static func writePayload(
        storeVersionSeed: String,
        models: [String: ModelEntry],
        cloneVoicesEnrolled: Int,
        error: String?
    ) throws {
        let record = ModelsStatusRecord(
            checkedAt: ISO8601DateFormatter().string(from: Date()),
            deviceModel: UIDevice.current.model,
            storeVersionSeed: storeVersionSeed,
            models: models,
            cloneVoicesEnrolled: cloneVoicesEnrolled,
            error: error
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)

        guard let pullableRoot = IOSPullableDiagnosticsMirror.pullableRoot else {
            throw InventoryError.pullableRootUnavailable
        }
        let url = pullableRoot.appendingPathComponent(outputFileName, isDirectory: false)
        try FileManager.default.createDirectory(at: pullableRoot, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        print("[models-inventory] wrote \(url.path)")
    }

    private enum InventoryError: LocalizedError {
        case pullableRootUnavailable

        var errorDescription: String? {
            switch self {
            case .pullableRootUnavailable:
                return "Could not resolve pullable diagnostics root in app container."
            }
        }
    }

    private struct ModelsStatusRecord: Codable {
        var schemaVersion = 1
        let checkedAt: String
        let deviceModel: String
        let storeVersionSeed: String
        let models: [String: ModelEntry]
        let cloneVoicesEnrolled: Int
        let error: String?
    }

    private struct ModelEntry: Codable {
        let status: String
        let sizeBytes: Int64
        let missingPaths: [String]?
    }
}
