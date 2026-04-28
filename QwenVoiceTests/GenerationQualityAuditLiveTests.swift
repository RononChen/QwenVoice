import Foundation
import Dispatch
import XCTest
@testable import QwenVoiceNative
import QwenVoiceEngineSupport

final class GenerationQualityAuditLiveTests: XCTestCase {
    private enum AuditMode: String, CaseIterable {
        case customVoice = "CustomVoice"
        case voiceDesign = "VoiceDesign"
        case clones = "Clones"

        var modelID: String {
            switch self {
            case .customVoice:
                "pro_custom"
            case .voiceDesign:
                "pro_design"
            case .clones:
                "pro_clone"
            }
        }

        var fileStem: String {
            switch self {
            case .customVoice:
                "custom-voice"
            case .voiceDesign:
                "voice-design"
            case .clones:
                "voice-clone"
            }
        }
    }

    private enum BenchmarkProfile: String {
        case standard = "repeat"
        case coldWarm = "cold-warm"
    }

    private enum AuditPhase: String {
        case standard = "repeat"
        case cold
        case warm
        case primer
    }

    private struct AuditManifest: Codable {
        let generatedAt: String
        let benchmarkProfile: String
        let coldRuns: Int?
        let warmRuns: Int?
        let appSupportDirectory: String
        let modelsRoot: String
        let artifacts: [AuditArtifact]
    }

    private struct AuditArtifact: Codable {
        let iteration: Int
        let phase: String
        let runIndex: Int
        let measured: Bool
        let qcEligible: Bool
        let mode: String
        let modelID: String
        let text: String
        let appSupportDirectory: String
        let outputPath: String
        let streamSessionDirectory: String?
        let durationSeconds: Double
        let wallClockMS: Int
        let realTimeFactor: Double?
        let streamingUsed: Bool
        let timingsMS: [String: Int]
    }

    private struct LiveAuditRequest: Codable {
        let live: Bool
        let allowModelLoad: Bool
        let outputDirectory: String
        let modes: [String]
        let modelsRoot: String
        let cloneReference: String?
        let cloneTranscript: String?
        let repeatCount: Int?
        let benchmarkProfile: String?
        let coldRuns: Int?
        let warmRuns: Int?
        let expiresAt: String?
    }

    private struct LiveAuditConfiguration {
        let outputRoot: URL
        let modelsRoot: URL
        let modes: [AuditMode]
        let cloneReference: String?
        let cloneTranscript: String?
        let repeatCount: Int
        let benchmarkProfile: BenchmarkProfile
        let coldRuns: Int
        let warmRuns: Int
    }

    func testLiveXPCGenerationQualityAuditArtifacts() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = try loadLiveAuditConfiguration(environment: environment)
        let outputRoot = configuration.outputRoot
        let modelsRoot = configuration.modelsRoot
        let modes = configuration.modes
        let appSupportRoot = outputRoot.appendingPathComponent("app-support", isDirectory: true)
        let generatedRoot = outputRoot.appendingPathComponent("generated", isDirectory: true)

        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generatedRoot, withIntermediateDirectories: true)

        let artifacts: [AuditArtifact]
        switch configuration.benchmarkProfile {
        case .standard:
            let repeatAppSupportRoot = appSupportRoot.appendingPathComponent("repeat", isDirectory: true)
            artifacts = try await runRepeatAudit(
                configuration: configuration,
                modes: modes,
                modelsRoot: modelsRoot,
                appSupportRoot: repeatAppSupportRoot,
                generatedRoot: generatedRoot
            )
        case .coldWarm:
            artifacts = try await runColdWarmBenchmark(
                configuration: configuration,
                modes: modes,
                modelsRoot: modelsRoot,
                appSupportBase: appSupportRoot,
                generatedRoot: generatedRoot
            )
        }

        let manifest = AuditManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            benchmarkProfile: configuration.benchmarkProfile.rawValue,
            coldRuns: configuration.benchmarkProfile == .coldWarm ? configuration.coldRuns : nil,
            warmRuns: configuration.benchmarkProfile == .coldWarm ? configuration.warmRuns : nil,
            appSupportDirectory: appSupportRoot.path,
            modelsRoot: modelsRoot.path,
            artifacts: artifacts
        )
        let data = try JSONEncoder.audioQCEncoder.encode(manifest)
        try data.write(to: outputRoot.appendingPathComponent("generation-manifest.json"))
    }

    private func runRepeatAudit(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportRoot: URL,
        generatedRoot: URL
    ) async throws -> [AuditArtifact] {
        try mirrorRequiredModels(for: modes, from: modelsRoot, into: appSupportRoot)

        let chunkRecorder = LiveChunkArtifactRecorder()
        let client = XPCNativeEngineClient(onChunk: { event in
            chunkRecorder.record(event)
        })
        try await client.initialize(appSupportDirectory: appSupportRoot)
        defer {
            Task {
                await client.debugInvalidateConnectionForTesting()
            }
        }

        var artifacts: [AuditArtifact] = []
        for iteration in 1...configuration.repeatCount {
            for mode in modes {
                artifacts.append(
                    try await generateArtifact(
                        client: client,
                        mode: mode,
                        iteration: iteration,
                        phase: .standard,
                        runIndex: iteration,
                        measured: true,
                        qcEligible: true,
                        appSupportRoot: appSupportRoot,
                        generatedRoot: generatedRoot,
                        configuration: configuration
                    )
                )
            }
        }
        return artifacts
    }

    private func runColdWarmBenchmark(
        configuration: LiveAuditConfiguration,
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportBase: URL,
        generatedRoot: URL
    ) async throws -> [AuditArtifact] {
        var artifacts: [AuditArtifact] = []

        for mode in modes {
            for runIndex in 1...configuration.coldRuns {
                let appSupportRoot = appSupportBase
                    .appendingPathComponent("cold", isDirectory: true)
                    .appendingPathComponent(mode.rawValue, isDirectory: true)
                    .appendingPathComponent(String(format: "run_%03d", runIndex), isDirectory: true)
                let client = try await makeInitializedClient(
                    modes: [mode],
                    modelsRoot: modelsRoot,
                    appSupportRoot: appSupportRoot
                )
                do {
                    artifacts.append(
                        try await generateArtifact(
                            client: client,
                            mode: mode,
                            iteration: runIndex,
                            phase: .cold,
                            runIndex: runIndex,
                            measured: true,
                            qcEligible: true,
                            appSupportRoot: appSupportRoot,
                            generatedRoot: generatedRoot,
                            configuration: configuration
                        )
                    )
                    await shutdownBenchmarkClient(client)
                } catch {
                    await shutdownBenchmarkClient(client)
                    throw error
                }
            }

            let warmAppSupportRoot = appSupportBase
                .appendingPathComponent("warm", isDirectory: true)
                .appendingPathComponent(mode.rawValue, isDirectory: true)
            let warmClient = try await makeInitializedClient(
                modes: [mode],
                modelsRoot: modelsRoot,
                appSupportRoot: warmAppSupportRoot
            )
            do {
                artifacts.append(
                    try await generateArtifact(
                        client: warmClient,
                        mode: mode,
                        iteration: 0,
                        phase: .primer,
                        runIndex: 0,
                        measured: false,
                        qcEligible: false,
                        appSupportRoot: warmAppSupportRoot,
                        generatedRoot: generatedRoot,
                        configuration: configuration
                    )
                )
                for runIndex in 1...configuration.warmRuns {
                    artifacts.append(
                        try await generateArtifact(
                            client: warmClient,
                            mode: mode,
                            iteration: runIndex,
                            phase: .warm,
                            runIndex: runIndex,
                            measured: true,
                            qcEligible: true,
                            appSupportRoot: warmAppSupportRoot,
                            generatedRoot: generatedRoot,
                            configuration: configuration
                        )
                    )
                }
                await shutdownBenchmarkClient(warmClient)
            } catch {
                await shutdownBenchmarkClient(warmClient)
                throw error
            }
        }

        return artifacts
    }

    private func makeInitializedClient(
        modes: [AuditMode],
        modelsRoot: URL,
        appSupportRoot: URL
    ) async throws -> XPCNativeEngineClient {
        try mirrorRequiredModels(for: modes, from: modelsRoot, into: appSupportRoot)
        let chunkRecorder = LiveChunkArtifactRecorder()
        let client = XPCNativeEngineClient(onChunk: { event in
            chunkRecorder.record(event)
        })
        try await client.initialize(appSupportDirectory: appSupportRoot)
        return client
    }

    private func shutdownBenchmarkClient(_ client: XPCNativeEngineClient) async {
        do {
            try await client.unloadModel()
        } catch {
            // Best-effort cleanup between benchmark samples.
        }
        await client.debugInvalidateConnectionForTesting()
        terminateEngineServiceIfRunning()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func terminateEngineServiceIfRunning() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["QwenVoiceEngineService"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // No helper process was running, or killall was unavailable.
        }
    }

    private func generateArtifact(
        client: XPCNativeEngineClient,
        mode: AuditMode,
        iteration: Int,
        phase: AuditPhase,
        runIndex: Int,
        measured: Bool,
        qcEligible: Bool,
        appSupportRoot: URL,
        generatedRoot: URL,
        configuration: LiveAuditConfiguration
    ) async throws -> AuditArtifact {
        let request = try makeRequest(
            mode: mode,
            iteration: iteration,
            phase: phase,
            runIndex: runIndex,
            outputRoot: generatedRoot,
            configuration: configuration
        )
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try await client.generate(request)
        let finished = DispatchTime.now().uptimeNanoseconds
        let wallClockMS = Int((finished - started) / 1_000_000)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.audioPath),
            "Expected generated audio at \(result.audioPath)."
        )
        XCTAssertGreaterThan(result.durationSeconds, 0)
        if let sessionDirectory = result.streamSessionDirectory {
            try ensureSessionHasFinalWAV(
                sessionDirectory: URL(fileURLWithPath: sessionDirectory, isDirectory: true),
                finalAudioPath: result.audioPath
            )
        }

        let realTimeFactor = result.durationSeconds > 0
            ? (Double(wallClockMS) / 1_000.0) / result.durationSeconds
            : nil

        return AuditArtifact(
            iteration: iteration,
            phase: phase.rawValue,
            runIndex: runIndex,
            measured: measured,
            qcEligible: qcEligible,
            mode: mode.rawValue,
            modelID: request.modelID,
            text: request.text,
            appSupportDirectory: appSupportRoot.path,
            outputPath: result.audioPath,
            streamSessionDirectory: result.streamSessionDirectory,
            durationSeconds: result.durationSeconds,
            wallClockMS: wallClockMS,
            realTimeFactor: realTimeFactor,
            streamingUsed: result.benchmarkSample?.streamingUsed ?? request.shouldStream,
            timingsMS: result.benchmarkSample?.timingsMS ?? [:]
        )
    }

    private func loadLiveAuditConfiguration(environment: [String: String]) throws -> LiveAuditConfiguration {
        if environment["QWENVOICE_AUDIO_QC_LIVE"] == "1" {
            try XCTSkipUnless(
                environment["QWENVOICE_AUDIO_QC_ALLOW_MODEL_LOAD"] == "1",
                "Live audio QC generation requires QWENVOICE_AUDIO_QC_ALLOW_MODEL_LOAD=1."
            )
            let outputRoot = try requireURL(
                environment["QWENVOICE_AUDIO_QC_OUTPUT_DIR"],
                name: "QWENVOICE_AUDIO_QC_OUTPUT_DIR"
            )
            let modelsRoot = URL(
                fileURLWithPath: environment["QWENVOICE_AUDIO_QC_MODELS_ROOT"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty ?? defaultModelsRoot().path,
                isDirectory: true
            )
            return LiveAuditConfiguration(
                outputRoot: outputRoot,
                modelsRoot: modelsRoot,
                modes: try parseModes(environment["QWENVOICE_AUDIO_QC_MODES"]),
                cloneReference: environment["QWENVOICE_AUDIO_QC_CLONE_REFERENCE"]?.nonEmpty,
                cloneTranscript: environment["QWENVOICE_AUDIO_QC_CLONE_TRANSCRIPT"]?.nonEmpty,
                repeatCount: try parseRepeatCount(environment["QWENVOICE_AUDIO_QC_REPEAT_COUNT"]),
                benchmarkProfile: try parseBenchmarkProfile(environment["QWENVOICE_AUDIO_QC_BENCHMARK_PROFILE"]),
                coldRuns: try parseBenchmarkRunCount(
                    environment["QWENVOICE_AUDIO_QC_COLD_RUNS"],
                    name: "cold"
                ),
                warmRuns: try parseBenchmarkRunCount(
                    environment["QWENVOICE_AUDIO_QC_WARM_RUNS"],
                    name: "warm"
                )
            )
        }

        let requestURL = repositoryRoot()
            .appendingPathComponent("build/audio-qc/live-request.json")
        guard FileManager.default.fileExists(atPath: requestURL.path) else {
            throw XCTSkip("Set QWENVOICE_AUDIO_QC_LIVE=1 through scripts/run_generation_quality_audit.py to run live audio QC generation.")
        }
        let request = try JSONDecoder().decode(LiveAuditRequest.self, from: Data(contentsOf: requestURL))
        guard request.live else {
            throw XCTSkip("Live audio QC request file is not marked live.")
        }
        guard request.allowModelLoad else {
            throw XCTSkip("Live audio QC request file does not allow model loading.")
        }
        if let expiresAt = request.expiresAt,
           let expiry = ISO8601DateFormatter().date(from: expiresAt),
           expiry < Date() {
            throw XCTSkip("Live audio QC request file expired.")
        }
        return LiveAuditConfiguration(
            outputRoot: URL(fileURLWithPath: request.outputDirectory, isDirectory: true),
            modelsRoot: URL(fileURLWithPath: request.modelsRoot, isDirectory: true),
            modes: try parseModes(request.modes.joined(separator: ",")),
            cloneReference: request.cloneReference?.nonEmpty,
            cloneTranscript: request.cloneTranscript?.nonEmpty,
            repeatCount: try parseRepeatCount(request.repeatCount.map { String($0) }),
            benchmarkProfile: try parseBenchmarkProfile(request.benchmarkProfile),
            coldRuns: try parseBenchmarkRunCount(request.coldRuns.map { String($0) }, name: "cold"),
            warmRuns: try parseBenchmarkRunCount(request.warmRuns.map { String($0) }, name: "warm")
        )
    }

    private func requireURL(_ rawValue: String?, name: String) throws -> URL {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(name)."]
            )
        }
        return URL(fileURLWithPath: rawValue, isDirectory: true)
    }

    private func parseModes(_ rawValue: String?) throws -> [AuditMode] {
        let requested = rawValue?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let modeNames = requested.isEmpty ? ["CustomVoice", "VoiceDesign"] : requested
        let modes = try modeNames.map { name in
            guard let mode = AuditMode(rawValue: name) else {
                throw NSError(
                    domain: "GenerationQualityAuditLiveTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported audio QC mode '\(name)'."]
                )
            }
            return mode
        }
        var seen = Set<AuditMode>()
        return modes.filter { seen.insert($0).inserted }
    }

    private func parseRepeatCount(_ rawValue: String?) throws -> Int {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? 1 : Int(trimmed)
        guard let repeatCount = value, (1...10).contains(repeatCount) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Audio QC repeat count must be between 1 and 10."]
            )
        }
        return repeatCount
    }

    private func parseBenchmarkProfile(_ rawValue: String?) throws -> BenchmarkProfile {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .standard }
        guard let profile = BenchmarkProfile(rawValue: trimmed) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported benchmark profile '\(trimmed)'."]
            )
        }
        return profile
    }

    private func parseBenchmarkRunCount(_ rawValue: String?, name: String) throws -> Int {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultValue = name == "cold" ? 2 : 3
        let value = trimmed.isEmpty ? defaultValue : Int(trimmed)
        guard let runCount = value, (1...10).contains(runCount) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Audio QC \(name) run count must be between 1 and 10."]
            )
        }
        return runCount
    }

    private func mirrorRequiredModels(
        for modes: [AuditMode],
        from modelsRoot: URL,
        into appSupportRoot: URL
    ) throws {
        let destinationRoot = appSupportRoot.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for mode in modes {
            let model = try NativeRuntimeTestSupport.bundledModelEntry(id: mode.modelID)
            let source = modelsRoot.appendingPathComponent(model.folder, isDirectory: true)
            try validateInstalledModel(model, at: source)

            let destination = destinationRoot.appendingPathComponent(model.folder, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        }
    }

    private func validateInstalledModel(
        _ model: NativeRuntimeTestSupport.ModelEntry,
        at source: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Installed model '\(model.id)' is missing at \(source.path)."]
            )
        }
        for relativePath in model.requiredRelativePaths {
            let requiredURL = source.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: requiredURL.path) else {
                throw NSError(
                    domain: "GenerationQualityAuditLiveTests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Installed model '\(model.id)' is incomplete; missing \(requiredURL.path)."]
                )
            }
        }
    }

    private func makeRequest(
        mode: AuditMode,
        iteration: Int,
        phase: AuditPhase,
        runIndex: Int,
        outputRoot: URL,
        configuration: LiveAuditConfiguration
    ) throws -> GenerationRequest {
        let runRoot = outputRootForRun(
            mode: mode,
            iteration: iteration,
            phase: phase,
            runIndex: runIndex,
            outputRoot: outputRoot,
            configuration: configuration
        )
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let outputURL = runRoot.appendingPathComponent("\(mode.fileStem).wav")

        switch mode {
        case .customVoice:
            return GenerationRequest(
                modelID: mode.modelID,
                text: "Hello from the Vocello audio quality audit with a clear complete short phrase for smooth playback",
                outputPath: outputURL.path,
                shouldStream: true,
                streamingInterval: GenerationSemantics.appStreamingInterval,
                streamingTitle: "Audio QC Custom Voice",
                payload: .custom(
                    speakerID: "vivian",
                    deliveryStyle: "Conversational"
                )
            )
        case .voiceDesign:
            return GenerationRequest(
                modelID: mode.modelID,
                text: "Welcome to the Vocello generation quality audit with steady continuous speech and smooth playback throughout",
                outputPath: outputURL.path,
                shouldStream: true,
                streamingInterval: GenerationSemantics.appStreamingInterval,
                streamingTitle: "Audio QC Voice Design",
                payload: .design(
                    voiceDescription: "A warm, steady narrator with clear pronunciation and calm pacing.",
                    deliveryStyle: "Normal tone"
                )
            )
        case .clones:
            let referencePath = try requireCloneReference(configuration)
            return GenerationRequest(
                modelID: mode.modelID,
                text: "This is a short cloned voice quality audit for smooth playback and complete final audio.",
                outputPath: outputURL.path,
                shouldStream: true,
                streamingInterval: GenerationSemantics.appStreamingInterval,
                streamingTitle: "Audio QC Voice Clone",
                payload: .clone(
                    reference: CloneReference(
                        audioPath: referencePath,
                        transcript: configuration.cloneTranscript,
                        preparedVoiceID: nil
                    )
                )
            )
        }
    }

    private func outputRootForRun(
        mode: AuditMode,
        iteration: Int,
        phase: AuditPhase,
        runIndex: Int,
        outputRoot: URL,
        configuration: LiveAuditConfiguration
    ) -> URL {
        switch configuration.benchmarkProfile {
        case .standard:
            let runRoot = configuration.repeatCount > 1
                ? outputRoot.appendingPathComponent(String(format: "run_%03d", iteration), isDirectory: true)
                : outputRoot
            return runRoot.appendingPathComponent(mode.rawValue, isDirectory: true)
        case .coldWarm:
            return outputRoot
                .appendingPathComponent(phase.rawValue, isDirectory: true)
                .appendingPathComponent(mode.rawValue, isDirectory: true)
                .appendingPathComponent(String(format: "run_%03d", runIndex), isDirectory: true)
        }
    }

    private func requireCloneReference(_ configuration: LiveAuditConfiguration) throws -> String {
        guard let referencePath = configuration.cloneReference?.nonEmpty else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Clones mode requires QWENVOICE_AUDIO_QC_CLONE_REFERENCE."]
            )
        }
        guard FileManager.default.fileExists(atPath: referencePath) else {
            throw NSError(
                domain: "GenerationQualityAuditLiveTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Clone reference does not exist at \(referencePath)."]
            )
        }
        return referencePath
    }

    private func ensureSessionHasFinalWAV(sessionDirectory: URL, finalAudioPath: String) throws {
        let finalURL = sessionDirectory.appendingPathComponent("final.wav")
        guard !FileManager.default.fileExists(atPath: finalURL.path) else { return }
        guard FileManager.default.fileExists(atPath: finalAudioPath) else { return }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: finalAudioPath), to: finalURL)
    }

    private func defaultModelsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenVoice/models", isDirectory: true)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class LiveChunkArtifactRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var nextChunkIndexBySession: [String: Int] = [:]

    func record(_ event: GenerationEvent) {
        guard case .chunk(let chunk) = event,
              let sessionDirectory = chunk.streamSessionDirectory?.nonEmpty,
              let previewAudio = chunk.previewAudio,
              !previewAudio.isFinal,
              !previewAudio.pcm16LE.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        do {
            let sessionURL = URL(fileURLWithPath: sessionDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
            let index = nextChunkIndexBySession[sessionDirectory, default: 0]
            nextChunkIndexBySession[sessionDirectory] = index + 1
            let chunkURL = sessionURL.appendingPathComponent(String(format: "chunk_%04d.wav", index))
            try Self.writePCM16MonoWAV(
                pcm16LE: previewAudio.pcm16LE,
                sampleRate: previewAudio.sampleRate,
                to: chunkURL
            )
        } catch {
            XCTFail("Failed to retain live preview chunk artifact: \(error)")
        }
    }

    private static func writePCM16MonoWAV(pcm16LE: Data, sampleRate: Int, to url: URL) throws {
        var data = Data()
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let dataSize = UInt32(pcm16LE.count)
        let fileSize = UInt32(36 + pcm16LE.count)

        data.appendASCII("RIFF")
        data.appendLittleEndian(fileSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        data.append(pcm16LE)

        try data.write(to: url, options: .atomic)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private extension JSONEncoder {
    static var audioQCEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
