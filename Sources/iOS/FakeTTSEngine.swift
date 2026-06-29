import Combine
import Foundation
import QwenVoiceCore

/// Test/UI-only fake backend selection. Reads the launch environment once.
///
/// `QVOICE_FAKE_ENGINE=1` swaps the real in-process MLX engine (and the real
/// model-status provider) for deterministic fakes, so Tier-A UI tests can walk the
/// backend-dependent Studio flow — ready → generate → player (or error) — with **no
/// 2.3 GB model, no Metal, no 120 s timeouts**. Production never sets these vars.
enum FakeEngineConfig {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Master switch. When true, `IOSAppBootstrap.makeBackend` builds the fake backend and
    /// the device-support gate is bypassed so the UI mounts on the iOS Simulator too.
    static var isEnabled: Bool {
        flag("QVOICE_FAKE_ENGINE")
    }

    /// Whether the fake model-status provider reports the model as installed (the default,
    /// which lets the Studio generate flow run) or not-installed (to exercise the install CTA).
    /// `QVOICE_FAKE_MODEL_STATE=notInstalled` flips it.
    static var modelInstalled: Bool {
        environment["QVOICE_FAKE_MODEL_STATE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() != "notinstalled"
    }

    /// `QVOICE_FAKE_ENGINE_SCENARIO=generateError` makes `generate` throw, so the error
    /// surface (`textInput_generationError`) is testable. Any other value generates normally.
    static var generateShouldFail: Bool {
        environment["QVOICE_FAKE_ENGINE_SCENARIO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "generateerror"
    }

    private static func flag(_ key: String) -> Bool {
        switch environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

enum FakeTTSEngineError: LocalizedError {
    case scenario(String)
    case unsupportedInFakeMode(String)

    var errorDescription: String? {
        switch self {
        case .scenario(let message):
            return message
        case .unsupportedInFakeMode(let op):
            return "\(op) is not available with the fake engine (QVOICE_FAKE_ENGINE)."
        }
    }
}

/// A scriptable, in-memory `TTSEngine` for Tier-A UI tests. It conforms to the full engine
/// protocol surface but does no real inference: `generate` writes a tiny silent WAV to the
/// requested output path and returns a `GenerationResult` pointing at it, so the Studio
/// player card appears exactly as it does for a real take — without loading a model.
@MainActor
final class FakeTTSEngine: ObservableObject, TTSEngine, TTSEngineRuntimeControlling, ActiveGenerationCancellable {
    let modelRegistry: any ModelRegistry

    @Published private(set) var loadState: EngineLoadState = .idle
    @Published private(set) var clonePreparationState: ClonePreparationState = .idle
    @Published private(set) var latestEvent: GenerationEvent?
    @Published private(set) var isReady: Bool = true
    @Published private(set) var visibleErrorMessage: String?

    init(modelRegistry: any ModelRegistry) {
        self.modelRegistry = modelRegistry
    }

    func supportDecision(for request: GenerationRequest) -> GenerationSupportDecision {
        .supported(.nativeMLX)
    }

    func start() {
        isReady = true
        loadState = .idle
    }

    func stop() {
        isReady = false
        loadState = .idle
    }

    func initialize(appSupportDirectory: URL) async throws {
        isReady = true
    }

    func ping() async throws -> Bool { true }

    func loadModel(id: String) async throws {
        loadState = .loaded(modelID: id)
        isReady = true
    }

    func unloadModel() async throws {
        loadState = .idle
    }

    func prepareAudio(_ request: AudioPreparationRequest) async throws -> AudioNormalizationResult {
        throw FakeTTSEngineError.unsupportedInFakeMode("Audio preparation")
    }

    func ensureModelLoadedIfNeeded(id: String) async {
        if loadState.currentModelID != id {
            loadState = .loaded(modelID: id)
        }
        isReady = true
    }

    func prewarmModelIfNeeded(for request: GenerationRequest) async {
        isReady = true
    }

    func ensureCloneReferencePrimed(modelID: String, reference: CloneReference) async throws {
        clonePreparationState = .primed(key: reference.preparedVoiceID)
    }

    func cancelClonePreparationIfNeeded() async {
        clonePreparationState = .idle
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        if FakeEngineConfig.generateShouldFail {
            throw FakeTTSEngineError.scenario("The fake engine simulated a generation failure.")
        }

        loadState = .running(modelID: request.modelID, label: request.engineActivityLabel, fraction: nil)
        // A short, deterministic delay so the "Generating" UI is observable, and so a
        // cooperative cancel (Task cancellation from the view) surfaces as CancellationError.
        try await Task.sleep(nanoseconds: 250_000_000)

        let outputURL = URL(fileURLWithPath: request.outputPath)
        let duration = 0.6
        try FakeAudioClip.writeSilentWAV(to: outputURL, seconds: duration)

        loadState = .loaded(modelID: request.modelID)
        return GenerationResult(
            audioPath: request.outputPath,
            durationSeconds: duration,
            streamSessionDirectory: nil,
            usedStreaming: false,
            finishReason: .eos
        )
    }

    func listPreparedVoices() async throws -> [PreparedVoice] { [] }

    func enrollPreparedVoice(name: String, audioPath: String, transcript: String?) async throws -> PreparedVoice {
        throw FakeTTSEngineError.unsupportedInFakeMode("Voice enrollment")
    }

    func deletePreparedVoice(id: String) async throws {}

    func importReferenceAudio(from sourceURL: URL) throws -> ImportedReferenceAudio {
        throw FakeTTSEngineError.unsupportedInFakeMode("Reference audio import")
    }

    func exportGeneratedAudio(from sourceURL: URL, to destinationURL: URL) throws -> ExportedDocument {
        throw FakeTTSEngineError.unsupportedInFakeMode("Audio export")
    }

    func clearGenerationActivity() {
        latestEvent = nil
        if case .running = loadState {
            loadState = .idle
        }
    }

    func clearVisibleError() {
        visibleErrorMessage = nil
    }

    // MARK: - TTSEngineRuntimeControlling

    func prefetchInteractiveReadinessIfNeeded(
        for request: GenerationRequest
    ) async -> InteractivePrefetchDiagnostics? {
        nil
    }

    func setVisibleError(_ message: String?) {
        visibleErrorMessage = message
    }

    func setAllowsProactiveWarmOperations(_ allow: Bool) {}

    func trimMemory(level: NativeMemoryTrimLevel, reason: String) async {}

    // MARK: - ActiveGenerationCancellable

    func cancelActiveGeneration() async throws {
        if case .running(let modelID, _, _) = loadState {
            loadState = modelID.map { .loaded(modelID: $0) } ?? .idle
        }
    }
}

/// Reports a fixed inventory status for every model so the Studio generate gate
/// (`ModelManagerViewModel.isAvailable`) is deterministic under the fake engine.
@MainActor
final class FakeModelStatusProvider: ModelStatusProviding {
    private let installed: Bool

    init(installed: Bool) {
        self.installed = installed
    }

    private func status(for models: [TTSModel]) -> [String: ModelInventoryStatus] {
        let status: ModelInventoryStatus = installed
            ? .installed(sizeBytes: 2_492_000_000)
            : .notInstalled
        return Dictionary(uniqueKeysWithValues: models.map { ($0.id, status) })
    }

    func initialStatuses(for models: [TTSModel]) -> [String: ModelInventoryStatus] {
        status(for: models)
    }

    func refreshStatuses(for models: [TTSModel]) async -> [String: ModelInventoryStatus] {
        status(for: models)
    }

    func isLikelyInstalled(_ model: TTSModel) -> Bool {
        installed
    }
}

/// Minimal valid PCM16 mono WAV writer for the fake engine's generated takes.
enum FakeAudioClip {
    static func writeSilentWAV(to url: URL, seconds: Double, sampleRate: Int = 24_000) throws {
        let frameCount = max(1, Int(Double(sampleRate) * seconds))
        let bytesPerSample = 2
        let dataSize = frameCount * bytesPerSample
        let blockAlign = bytesPerSample
        let byteRate = sampleRate * blockAlign

        var data = Data(capacity: 44 + dataSize)
        func appendUInt32LE(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendUInt16LE(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32LE(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32LE(16)                 // PCM fmt chunk size
        appendUInt16LE(1)                  // audio format = PCM
        appendUInt16LE(1)                  // channels = mono
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(byteRate))
        appendUInt16LE(UInt16(blockAlign))
        appendUInt16LE(16)                 // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendUInt32LE(UInt32(dataSize))
        data.append(Data(count: dataSize)) // silence

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
