import AVFoundation
import CryptoKit
import Foundation
import QwenVoiceCore
import UIKit

/// Headless, non-UI on-device diagnostics runner — the iOS analog of `vocello bench`.
///
/// Fires **only** when `QVOICE_IOS_DEVICE_DIAGNOSTICS_SPEC` is present and non-empty in the launch
/// environment, so it ships completely inert (a normal user launch never sets it).
/// `scripts/ios_device.sh bench` sets it — together with `QWENVOICE_DEBUG=1` (lights
/// up `TelemetryGate`, so the engine appends its decode/RTF/audioQC row to
/// `diagnostics/engine/generations.jsonl`) and `QVOICE_IOS_DEVICE_RUN_ID=<runID>`
/// (tags the run) — launches the app over `devicectl`, polls for the completion
/// sentinel, then pulls the App-Group `diagnostics/` tree and runs the summarizer.
///
/// Spec format (the env value): `<mode>:<variant>:<text>`, e.g.
/// `custom:speed:Hello from Vocello on device`. `mode ∈ custom|design|clone`,
/// `variant ∈ speed|quality` (iPhone resolves speed-only regardless), and the text is
/// everything after the second `:` (so it may itself contain colons). Forgiving:
/// a bare `1`/`on`/`true`/`yes`, a bare mode, or a partial spec all fall back to
/// sensible defaults.
///
/// Optional companion env `QVOICE_IOS_DEVICE_DIAGNOSTICS_LANGUAGE` sets the UI language picker
/// equivalent (`english`, `french`, `auto`, …) on the generation request. Omitted
/// behaves like Auto. `scripts/ios_device.sh lang-bench` sets it per matrix cell.
/// `QVOICE_IOS_DEVICE_DIAGNOSTICS_SEED=<UInt64>` pins the MLX sampling stream for
/// predeclared diagnostic cohorts; an invalid value fails before generation.
/// `QVOICE_IOS_DEVICE_DIAGNOSTICS_VARIATION=expressive|balanced|consistent`
/// explicitly pins the sampling policy; otherwise the current iOS preference applies.
///
/// Clone diagnostics additionally require `QVOICE_IOS_DEVICE_DIAGNOSTICS_CLONE_VOICE_ID`
/// to identify the exact prepared voice. They never select an arbitrary saved voice or
/// substitute a bundled speaker preview.
///
/// When `QVOICE_IOS_DEVICE_DIAGNOSTICS_VERIFY_OUTPUT=1`, after a successful generation the runner
/// transcribes the output WAV in-process (Speech) and stamps `outputVerification`
/// on the diagnostics sentinel for `scripts/check_language_output.py`. The completed
/// run also mirrors only its exact WAV as `output.wav`, with bounded sample metadata
/// and a SHA-256 digest in the sentinel; raw prompts and absolute paths are omitted.
///
/// The runner drives the same in-process `TTSEngineStore.generate(_:)` the UI uses —
/// no UI interaction — then writes `diagnostics/<runID>/device-diagnostics-done.json`. It never
/// calls `exit()`; the app stays up so the script can pull the diagnostics container.
@MainActor
enum IOSDeviceDiagnosticsRunner {
    private static let environmentKey = "QVOICE_IOS_DEVICE_DIAGNOSTICS_SPEC"
    private static let runIDKey = "QVOICE_IOS_DEVICE_RUN_ID"
    private static let languageEnvKey = "QVOICE_IOS_DEVICE_DIAGNOSTICS_LANGUAGE"
    private static let verifyOutputEnvKey = "QVOICE_IOS_DEVICE_DIAGNOSTICS_VERIFY_OUTPUT"
    private static let cloneVoiceIDEnvKey = "QVOICE_IOS_DEVICE_DIAGNOSTICS_CLONE_VOICE_ID"
    private static let seedEnvKey = "QVOICE_IOS_DEVICE_DIAGNOSTICS_SEED"
    private static let variationEnvKey = "QVOICE_IOS_DEVICE_DIAGNOSTICS_VARIATION"

    /// Default benchmark sentence — long enough to exercise streaming chunking,
    /// free of any personal/sensitive content.
    private static let defaultText =
        "Vocello on-device diagnostics check. The quick brown fox jumps over the lazy dog, "
        + "then pauses, takes a breath, and reads one more sentence aloud."
    /// Default Voice Design brief when a `design` run supplies only text.
    private static let defaultVoiceBrief =
        "A warm, friendly narrator with a calm, measured pace."

    struct Spec {
        var mode: GenerationMode
        var variant: ModelVariantKind
        var text: String
    }

    /// True when the launch environment requested a diagnostic generation.
    static var isRequested: Bool {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !raw.isEmpty
    }

    /// Kick off the diagnostic generation if requested. Safe to call once after engine init;
    /// no-op when `QVOICE_IOS_DEVICE_DIAGNOSTICS_SPEC` is unset. Runs detached on the MainActor so it
    /// doesn't block app startup.
    static func runIfRequested(engine: TTSEngineStore) {
        guard isRequested else { return }
        #if QVOICE_DEVICE_DIAGNOSTICS
        // Crash-capture lane verification: deliberately fault so MetricKit captures the
        // crash and the `scripts/ios_device.sh crashes --test` flow can symbolicate it
        // against the preserved build dSYM. This code is absent from ordinary builds.
        if ProcessInfo.processInfo.environment["QVOICE_IOS_DEVICE_DIAGNOSTICS_CRASH_TEST"] == "1" {
            print("[device-diagnostics] deliberate crash requested for the capture/symbolication lane")
            fatalError("QVOICE_IOS_DEVICE_DIAGNOSTICS_CRASH_TEST: deliberate diagnostics crash")
        }
        #endif
        let spec = parseSpec(ProcessInfo.processInfo.environment[environmentKey] ?? "")
        let uiLanguageHint = trimmedEnvironmentValue(languageEnvKey)
        // Record calls + lifecycle transitions for the sentinel so a doomed run
        // self-reports its cause ("call arrived at t=42s"). Diagnostics-only → inert
        // on user launches.
        IOSInterruptionRecorder.shared.start()
        Task { @MainActor in
            await run(spec: spec, uiLanguageHint: uiLanguageHint, engine: engine)
        }
    }

    // MARK: - Spec parsing

    static func parseSpec(_ raw: String) -> Spec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var spec = Spec(mode: .custom, variant: .speed, text: defaultText)
        guard !["", "1", "on", "true", "yes"].contains(trimmed.lowercased()) else {
            return spec
        }
        let parts = trimmed
            .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
        if let first = parts.first, let mode = GenerationMode(rawValue: first.lowercased()) {
            spec.mode = mode
        }
        if parts.count >= 2 {
            switch parts[1].lowercased() {
            case "quality", "hq": spec.variant = .quality
            case "speed", "fast", "": spec.variant = .speed
            default: break
            }
        }
        if parts.count >= 3, !parts[2].isEmpty {
            spec.text = parts[2]
        }
        return spec
    }

    // MARK: - Run

    private static func run(spec: Spec, uiLanguageHint: String?, engine: TTSEngineStore) async {
        let runID = safeRunID(from: ProcessInfo.processInfo.environment[runIDKey]) ?? "device-diagnostics"
        let generationID = UUID()
        let startedAt = Date()
        print(
            "[device-diagnostics] start mode=\(spec.mode.rawValue) variant=\(spec.variant.rawValue) "
            + "runID=\(runID) lang=\(uiLanguageHint ?? "auto") chars=\(spec.text.count)"
        )

        // Device/bundle fields read here (MainActor) — UIDevice is MainActor-isolated,
        // so they cannot be struct property defaults under Swift 6 strict concurrency.
        let device = UIDevice.current
        var record = SentinelRecord(
            runID: runID,
            generationID: generationID.uuidString,
            mode: spec.mode.rawValue,
            variant: spec.variant.rawValue,
            promptCharacters: spec.text.count,
            startedAt: ISO8601DateFormatter().string(from: startedAt),
            uiLanguageHint: uiLanguageHint,
            requestedLanguageHint: uiLanguageHint ?? Qwen3SupportedLanguage.auto.rawValue,
            languageHintSource: languageHintSource(for: uiLanguageHint),
            deviceModel: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
        )
        var appTimelineSubmitted = false

        do {
            guard let model = ModelDescriptor.model(for: spec.mode) else {
                throw DiagnosticsError("no model in the contract for mode '\(spec.mode.rawValue)'")
            }
            record.modelID = model.id
            record.modelName = model.name

            let payload = try await buildPayload(spec: spec, engine: engine)
            record.fixtureDigest = try fixtureDigest(for: payload)
            let seed = try diagnosticsSeed()
            let variation = try diagnosticsVariation()
            record.seed = seed
            record.samplingVariation = (variation ?? .expressive).rawValue
            let loadedModelID = engine.loadState.currentModelID
            record.preGenerationModelID = loadedModelID
            record.preGenerationWarmState = loadedModelID == model.id ? "warm" : "cold"

            // Do not explicitly load or prime here. `engine.generate` enters the native
            // per-generation telemetry session before model load, prewarm, and clone
            // conditioning. Preloading from this runner would hide the cold model-loading
            // peak and clone preparation from the benchmark's clock and sampler.

            let outputPath = makeOutputPath(runID: runID, model: model)
            let request = GenerationRequest(
                mode: spec.mode,
                modelID: model.id,
                text: spec.text,
                outputPath: outputPath,
                shouldStream: true,
                streamingInterval: GenerationSemantics.appStreamingInterval,
                languageHint: uiLanguageHint,
                payload: payload,
                generationID: generationID,
                seed: seed,
                variation: variation
            )
            guard let capabilities = model.qwen3Capabilities else {
                throw DiagnosticsError("model '\(model.id)' has no declared Qwen3 prompt capabilities")
            }
            let prompt = GenerationSemantics.qwen3PromptAssembly(
                for: request,
                capabilities: capabilities
            )
            record.resolvedLanguageHint = prompt.language
            record.resolvedPromptAssemblyDigest = try digest(prompt)
            record.promptDigestScope = spec.mode == .clone
                ? "request_without_resolved_clone_transcript"
                : "resolved"

            print("[device-diagnostics] generating… resolvedLanguage=\(record.resolvedLanguageHint ?? "?")")
            // Headless diagnostics still execute in the production app process. Record the real
            // submit/completion lifecycle so iOS benchmark evidence proves both app and engine
            // ownership. Do not synthesize player milestones: this lane never schedules playback.
            AppGenerationTimeline.shared.recordSubmitted(
                id: generationID,
                mode: spec.mode.rawValue
            )
            appTimelineSubmitted = true
            let t0 = Date()
            let result = try await engine.generate(request)
            await AppGenerationTimeline.shared.recordCompleted(
                id: generationID,
                mode: spec.mode.rawValue,
                usedStreaming: true,
                finishReason: result.finishReason?.rawValue,
                summary: result.telemetrySummary
            )
            appTimelineSubmitted = false
            let wall = Date().timeIntervalSince(t0)
            let rtf = wall > 0 ? result.durationSeconds / wall : 0

            record.status = "ok"
            record.durationSeconds = result.durationSeconds
            record.wallSeconds = wall
            record.realtimeFactor = rtf
            record.finishReason = result.finishReason?.rawValue
            print(String(
                format: "[device-diagnostics] ✓ %.2fs audio · rtf=%.2f · finish=%@",
                result.durationSeconds, rtf, result.finishReason?.rawValue ?? "?"
            ))

            if shouldVerifyOutput,
               let resolvedHint = record.resolvedLanguageHint,
               let expectedLanguage = resolvedLanguageHint(for: resolvedHint) {
                let verification = await GenerationOutputVerifier.verify(
                    audioURL: URL(fileURLWithPath: result.audioPath),
                    expectedScript: spec.text,
                    expectedLanguage: expectedLanguage
                )
                record.outputVerification = verification
                print(
                    "[device-diagnostics] output verify pass=\(verification.pass) "
                    + "lang=\(verification.languagePass) wer=\(verification.wordErrorRate.map { String(format: "%.2f", $0) } ?? "unavailable") "
                    + "score=\(String(format: "%.2f", verification.languageMatchScore))"
                )
            }

            let audioURL = URL(fileURLWithPath: result.audioPath)
            let outputEvidence = try makeOutputEvidence(for: audioURL)
            try mirrorOutputToPullableDiagnostics(audioURL, runID: runID)
            record.outputEvidence = outputEvidence
        } catch is CancellationError {
            if appTimelineSubmitted {
                await AppGenerationTimeline.shared.recordFailed(
                    id: generationID,
                    finishReason: .cancelled
                )
            }
            record.status = "error"
            record.error = "cancelled"
            print("[device-diagnostics] ✗ cancelled")
        } catch {
            if appTimelineSubmitted {
                await AppGenerationTimeline.shared.recordFailed(id: generationID)
            }
            record.status = "error"
            record.error = error.localizedDescription
            print("[device-diagnostics] ✗ \(error.localizedDescription)")
        }

        record.finishedAt = ISO8601DateFormatter().string(from: Date())
        let interruptions = IOSInterruptionRecorder.shared.snapshot()
        if !interruptions.isEmpty {
            record.interruptions = interruptions
            if record.status == "ok" {
                record.status = "error"
                record.error = "diagnostic run was interrupted (\(interruptions.count) event(s))"
            }
        }
        writeSentinel(record, runID: runID)
    }

    @MainActor
    private static func buildPayload(
        spec: Spec,
        engine: TTSEngineStore
    ) async throws -> GenerationRequest.Payload {
        switch spec.mode {
        case .custom:
            return .custom(
                speakerID: ModelDescriptor.defaultSpeaker,
                deliveryStyle: nil
            )
        case .design:
            return .design(
                voiceDescription: defaultVoiceBrief,
                deliveryStyle: nil
            )
        case .clone:
            guard let requestedVoiceID = trimmedEnvironmentValue(cloneVoiceIDEnvKey) else {
                throw DiagnosticsError(
                    "clone diagnostics require \(cloneVoiceIDEnvKey) to identify an exact saved voice"
                )
            }
            let voices = try await engine.listPreparedVoices()
            guard let voice = voices.first(where: { $0.id == requestedVoiceID }) else {
                let availableIDs = voices.map(\.id).sorted().joined(separator: ", ")
                throw DiagnosticsError(
                    "saved clone voice '\(requestedVoiceID)' was not found"
                    + (availableIDs.isEmpty ? "; no saved voices are installed" : "; available IDs: \(availableIDs)")
                )
            }
            return .clone(
                reference: CloneReference(
                    audioPath: voice.audioPath,
                    transcript: nil,
                    preparedVoiceID: voice.id
                )
            )
        }
    }

    private static func trimmedEnvironmentValue(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func diagnosticsSeed() throws -> UInt64? {
        guard let raw = trimmedEnvironmentValue(seedEnvKey) else { return nil }
        guard let seed = UInt64(raw) else {
            throw DiagnosticsError("\(seedEnvKey) must be an unsigned 64-bit integer")
        }
        return seed
    }

    private static func diagnosticsVariation() throws -> Qwen3SamplingVariation? {
        guard let raw = trimmedEnvironmentValue(variationEnvKey) else {
            return IOSGenerationVariationPreference.requestValue()
        }
        guard let variation = Qwen3SamplingVariation(rawValue: raw.lowercased()) else {
            throw DiagnosticsError(
                "\(variationEnvKey) must be expressive, balanced, or consistent"
            )
        }
        return variation == .expressive ? nil : variation
    }

    private static func languageHintSource(for requestedHint: String?) -> String {
        guard let requestedHint,
              Qwen3SupportedLanguage.normalized(requestedHint) != .auto else {
            return "auto"
        }
        return "explicit"
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Privacy-safe identity for the exact non-text fixture used by a diagnostic
    /// generation. The sentinel exposes only the digest—never the App Group path,
    /// saved-voice name, transcript, or design description.
    private static func fixtureDigest(for payload: GenerationRequest.Payload) throws -> String? {
        switch payload {
        case .custom:
            return nil
        case .design(let voiceDescription, _):
            return SHA256.hash(data: Data(voiceDescription.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        case .clone(let reference):
            let url = URL(fileURLWithPath: reference.audioPath)
            guard let stream = InputStream(url: url) else {
                throw DiagnosticsError("could not open the resolved clone reference for identity hashing")
            }
            stream.open()
            defer { stream.close() }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 {
                    throw stream.streamError
                        ?? DiagnosticsError("could not read the resolved clone reference for identity hashing")
                }
                if count == 0 { break }
                hasher.update(data: Data(buffer[..<count]))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static var shouldVerifyOutput: Bool {
        ProcessInfo.processInfo.environment[verifyOutputEnvKey] == "1"
    }

    private static func resolvedLanguageHint(for rawHint: String) -> Qwen3SupportedLanguage? {
        let normalized = Qwen3SupportedLanguage.normalized(rawHint)
        return normalized == .auto ? nil : normalized
    }

    // MARK: - Paths & sentinel

    private static func makeOutputEvidence(for url: URL) throws -> OutputEvidence {
        let file = try AVAudioFile(forReading: url)
        let frameCount = Int64(file.length)
        let sampleRate = file.fileFormat.sampleRate
        let channelCount = Int(file.fileFormat.channelCount)
        guard frameCount > 0, sampleRate > 0, channelCount > 0 else {
            throw DiagnosticsError("generated WAV has invalid sample metadata")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw DiagnosticsError("generated WAV has no readable file size")
        }
        return OutputEvidence(
            artifactRelativePath: "output.wav",
            sha256: try sha256Hex(for: url),
            byteCount: Int64(fileSize),
            durationSeconds: Double(frameCount) / sampleRate,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount
        )
    }

    private static func sha256Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func mirrorOutputToPullableDiagnostics(_ source: URL, runID: String) throws {
        guard let pullableRoot = IOSPullableDiagnosticsMirror.pullableRoot else {
            throw DiagnosticsError("pullable diagnostics directory is unavailable")
        }
        try copyAtomically(
            source,
            to: pullableRoot.appendingPathComponent(runID, isDirectory: true)
                .appendingPathComponent("output.wav", isDirectory: false)
        )
    }

    private static func copyAtomically(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".output-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private static func makeOutputPath(runID: String, model: ModelDescriptor) -> String {
        let dir = AppPaths.outputsDir
            .appendingPathComponent(model.outputSubfolder, isDirectory: true)
            .appendingPathComponent("device-diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(runID).wav", isDirectory: false).path
    }

    private static func writeSentinel(_ record: SentinelRecord, runID: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(record)) ?? Data()

        // 1) Canonical: the App-Group diagnostics dir, where the engine also writes its
        //    telemetry (`diagnostics/engine/generations.jsonl`).
        let groupRunDir = AppPaths.appSupportDir
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        writeData(data, to: groupRunDir.appendingPathComponent("device-diagnostics-done.json", isDirectory: false),
                  label: "sentinel (app-group)")

        // 2) Pullable mirror in the app's OWN container. devicectl `copy from
        //    --domain-type appDataContainer` CAN pull this, but it CANNOT pull the
        //    App-Group container (confirmed: any source there fails with a bogus
        //    "File paths cannot contain '..'"). scripts/ios_device.sh pulls
        //    `Library/Caches/Vocello/diagnostics` from appDataContainer, so the bench
        //    needs the sentinel + the engine telemetry here too.
        guard let pullableRoot = IOSPullableDiagnosticsMirror.pullableRoot else { return }
        // Publish the exact generation telemetry before the pullable sentinel: the
        // sentinel is the completion barrier observed by the shell poller.
        IOSPullableDiagnosticsMirror.syncGenerationTelemetry(
            generationID: record.generationID,
            from: AppPaths.appSupportDir.appendingPathComponent("diagnostics", isDirectory: true),
            into: pullableRoot
        )
        writeData(data, to: pullableRoot.appendingPathComponent(runID, isDirectory: true)
                    .appendingPathComponent("device-diagnostics-done.json", isDirectory: false),
                  label: "sentinel (pullable)")
    }

    private static func writeData(_ data: Data, to url: URL, label: String) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            print("[device-diagnostics] \(label) → \(url.path)")
        } catch {
            print("[device-diagnostics] could not write \(label): \(error.localizedDescription)")
        }
    }

    /// Mirror `IOSDeviceDiagnosticsRecorder` / `MLXTTSEngine` run-ID sanitization so
    /// the sentinel lands in the same `diagnostics/<runID>/` directory.
    private static func safeRunID(from rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let safe = trimmed.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "_"
        }
        return String(safe)
    }

    private struct DiagnosticsError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct SentinelRecord: Codable {
        // `var` (not `let`) for the defaulted fields: a `let` with an initial value is
        // skipped by Codable decode (warning) and, for the device fields, a default
        // expression touching MainActor `UIDevice` would be evaluated in the nonisolated
        // synthesized init (Swift 6 error). So defaults stay literal/`var`, and device/
        // bundle fields are passed in from the @MainActor call site.
        var schemaVersion = 2
        let runID: String
        let generationID: String
        let mode: String
        let variant: String
        let promptCharacters: Int
        let startedAt: String
        var finishedAt: String?
        var status = "error"
        var uiLanguageHint: String?
        var requestedLanguageHint: String
        var languageHintSource: String
        var resolvedLanguageHint: String?
        var resolvedPromptAssemblyDigest: String?
        var promptDigestScope: String?
        var seed: UInt64?
        var samplingVariation: String?
        var preGenerationModelID: String?
        var preGenerationWarmState: String?
        var modelID: String?
        var modelName: String?
        var fixtureDigest: String?
        var outputEvidence: OutputEvidence?
        var durationSeconds: Double?
        var wallSeconds: Double?
        var realtimeFactor: Double?
        var finishReason: String?
        var error: String?
        var outputVerification: GenerationOutputVerifier.Result?
        /// Calls + lifecycle transitions observed during the run (see
        /// `IOSInterruptionRecorder`) — explains doomed runs. Omitted when clean.
        var interruptions: [IOSInterruptionRecorder.Event]?
        let deviceModel: String
        let systemName: String
        let systemVersion: String
        let bundleVersion: String?
        let buildVersion: String?
    }

    private struct OutputEvidence: Codable {
        let artifactRelativePath: String
        let sha256: String
        let byteCount: Int64
        let durationSeconds: Double
        let sampleRate: Double
        let channelCount: Int
        let frameCount: Int64
    }
}
