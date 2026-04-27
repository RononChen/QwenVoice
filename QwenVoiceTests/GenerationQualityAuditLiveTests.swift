import Foundation
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

    private struct AuditManifest: Codable {
        let generatedAt: String
        let appSupportDirectory: String
        let modelsRoot: String
        let artifacts: [AuditArtifact]
    }

    private struct AuditArtifact: Codable {
        let mode: String
        let modelID: String
        let text: String
        let outputPath: String
        let streamSessionDirectory: String?
        let durationSeconds: Double
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
        let expiresAt: String?
    }

    private struct LiveAuditConfiguration {
        let outputRoot: URL
        let modelsRoot: URL
        let modes: [AuditMode]
        let cloneReference: String?
        let cloneTranscript: String?
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
        for mode in modes {
            let request = try makeRequest(
                mode: mode,
                outputRoot: generatedRoot,
                configuration: configuration
            )
            let result = try await client.generate(request)
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

            artifacts.append(
                AuditArtifact(
                    mode: mode.rawValue,
                    modelID: request.modelID,
                    text: request.text,
                    outputPath: result.audioPath,
                    streamSessionDirectory: result.streamSessionDirectory,
                    durationSeconds: result.durationSeconds,
                    streamingUsed: result.benchmarkSample?.streamingUsed ?? request.shouldStream,
                    timingsMS: result.benchmarkSample?.timingsMS ?? [:]
                )
            )
        }

        let manifest = AuditManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appSupportDirectory: appSupportRoot.path,
            modelsRoot: modelsRoot.path,
            artifacts: artifacts
        )
        let data = try JSONEncoder.audioQCEncoder.encode(manifest)
        try data.write(to: outputRoot.appendingPathComponent("generation-manifest.json"))
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
                cloneTranscript: environment["QWENVOICE_AUDIO_QC_CLONE_TRANSCRIPT"]?.nonEmpty
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
            cloneTranscript: request.cloneTranscript?.nonEmpty
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
        outputRoot: URL,
        configuration: LiveAuditConfiguration
    ) throws -> GenerationRequest {
        let modeOutputRoot = outputRoot.appendingPathComponent(mode.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: modeOutputRoot, withIntermediateDirectories: true)
        let outputURL = modeOutputRoot.appendingPathComponent("\(mode.fileStem).wav")

        switch mode {
        case .customVoice:
            return GenerationRequest(
                modelID: mode.modelID,
                text: "Hello from the Vocello audio quality audit. This short clip should be clear and complete.",
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
                text: "Welcome to the Vocello generation quality audit. This clip should sound smooth and uninterrupted.",
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
