import Foundation

enum Qwen3TTSRuntimeProfileError: LocalizedError, Sendable {
    case missingFile(String)
    case invalidMetadata(String)
    case unsupportedCapability(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let message),
             .invalidMetadata(let message),
             .unsupportedCapability(let message):
            return message
        }
    }
}

enum Qwen3TTSModelFamily: String, Codable, Hashable, Sendable {
    case customVoice = "custom_voice"
    case voiceDesign = "voice_design"
    case baseClone = "base_clone"

    init?(descriptor: ModelDescriptor, configModelType: String?) {
        let joined = [
            descriptor.folder,
            descriptor.huggingFaceRepo,
            configModelType ?? "",
        ]
        .joined(separator: "|")
        .lowercased()

        if joined.contains("customvoice") || joined.contains("custom_voice") {
            self = .customVoice
        } else if joined.contains("voicedesign") || joined.contains("voice_design") {
            self = .voiceDesign
        } else if joined.contains("base") {
            self = .baseClone
        } else {
            return nil
        }
    }

    var requiredMode: GenerationMode {
        switch self {
        case .customVoice:
            return .custom
        case .voiceDesign:
            return .design
        case .baseClone:
            return .clone
        }
    }
}

enum Qwen3TTSQuantizationTier: String, Codable, Hashable, Sendable {
    case fourBit = "4bit"
    case eightBit = "8bit"
    case unknown
}

struct Qwen3TTSGenerationDefaults: Hashable, Codable, Sendable {
    let maxTokens: Int?
    let topP: Double?
    let temperature: Double?
    let repetitionPenalty: Double?
}

struct Qwen3TTSRuntimeProfile: Hashable, Codable, Sendable {
    static let canonicalSampleRate = 24_000
    static let canonicalTokenizerType = "qwen3_tts_tokenizer_12hz"

    static let criticalRequiredComponents: [String] = [
        "config.json",
        "generation_config.json",
        "merges.txt",
        "model.safetensors",
        "model.safetensors.index.json",
        "preprocessor_config.json",
        "speech_tokenizer/config.json",
        "speech_tokenizer/configuration.json",
        "speech_tokenizer/model.safetensors",
        "speech_tokenizer/preprocessor_config.json",
        "tokenizer_config.json",
        "vocab.json",
    ]

    let modelType: String
    let modelFamily: Qwen3TTSModelFamily
    let quantizationTier: Qwen3TTSQuantizationTier
    let sampleRate: Int
    let tokenizerType: String
    let languageSupport: [String]
    let modeCapability: GenerationMode
    let supportsStreaming: Bool
    let requiredComponents: [String]
    let supportedSpeakers: [String]
    let generationDefaults: Qwen3TTSGenerationDefaults
    let validationSignature: String

    static func load(
        from modelDirectory: URL,
        descriptor: ModelAssetDescriptor,
        fileManager: FileManager = .default
    ) throws -> Qwen3TTSRuntimeProfile {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        let generationConfigURL = modelDirectory.appendingPathComponent("generation_config.json")

        guard fileManager.fileExists(atPath: configURL.path) else {
            throw Qwen3TTSRuntimeProfileError.missingFile("Missing Qwen3-TTS config.json at '\(configURL.path)'.")
        }
        guard fileManager.fileExists(atPath: generationConfigURL.path) else {
            throw Qwen3TTSRuntimeProfileError.missingFile("Missing Qwen3-TTS generation_config.json at '\(generationConfigURL.path)'.")
        }

        let config = try readJSONObject(configURL)
        let generationConfig = try readJSONObject(generationConfigURL)
        let profile = try fromConfig(
            config,
            generationConfig: generationConfig,
            descriptor: descriptor
        )
        try profile.validate(
            descriptor: descriptor.model,
            modelDirectory: modelDirectory,
            fileManager: fileManager
        )
        return profile
    }

    static func fromConfig(
        _ config: [String: Any],
        generationConfig: [String: Any],
        descriptor: ModelAssetDescriptor
    ) throws -> Qwen3TTSRuntimeProfile {
        let modelType = normalizedModelType(string(config["model_type"]) ?? "qwen3_tts")
        guard modelType == "qwen3_tts" else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "QwenVoice supports only Qwen3-TTS model metadata (expected model_type qwen3_tts, found \(modelType))."
            )
        }

        guard let modelFamily = Qwen3TTSModelFamily(
            descriptor: descriptor.model,
            configModelType: string(config["tts_model_type"])
        ) else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "Could not infer Qwen3-TTS family from model '\(descriptor.model.id)' folder/repo/config."
            )
        }

        let tokenizerType = normalizedModelType(
            string(config["tokenizer_type"]) ?? Self.canonicalTokenizerType
        )
        let sampleRate = int(config["sample_rate"])
            ?? int(nested(config, "tokenizer_config")?["output_sample_rate"])
            ?? Self.canonicalSampleRate
        let languages = normalizedLanguageSupport(from: nested(config, "talker_config")?["codec_language_id"])
        let speakers = normalizedSpeakerIDs(from: nested(config, "talker_config")?["spk_id"])
        let quantization = quantizationTier(
            descriptor: descriptor.model,
            config: config
        )
        let generationDefaults = Qwen3TTSGenerationDefaults(
            maxTokens: int(generationConfig["max_new_tokens"])
                ?? int(generationConfig["max_tokens"]),
            topP: double(generationConfig["top_p"]),
            temperature: double(generationConfig["temperature"]),
            repetitionPenalty: double(generationConfig["repetition_penalty"])
        )
        let requiredComponents = Self.criticalRequiredComponents
        let signatureParts = [
            modelType,
            modelFamily.rawValue,
            quantization.rawValue,
            String(sampleRate),
            tokenizerType,
            languages.joined(separator: ","),
            speakers.joined(separator: ","),
        ]

        return Qwen3TTSRuntimeProfile(
            modelType: modelType,
            modelFamily: modelFamily,
            quantizationTier: quantization,
            sampleRate: sampleRate,
            tokenizerType: tokenizerType,
            languageSupport: languages,
            modeCapability: modelFamily.requiredMode,
            supportsStreaming: true,
            requiredComponents: requiredComponents,
            supportedSpeakers: speakers,
            generationDefaults: generationDefaults,
            validationSignature: signatureParts.joined(separator: "|")
        )
    }

    func validateCapability(_ requestedCapability: NativeLoadCapabilityProfile) throws {
        let expectedMode = switch requestedCapability {
        case .customOnly:
            GenerationMode.custom
        case .designOnly:
            GenerationMode.design
        case .cloneOnly:
            GenerationMode.clone
        case .fullCapabilities:
            modeCapability
        }

        guard expectedMode == modeCapability else {
            throw Qwen3TTSRuntimeProfileError.unsupportedCapability(
                "Qwen3-TTS \(modelFamily.rawValue) model cannot serve \(requestedCapability.rawValue)."
            )
        }
    }

    func validateSpeaker(_ speaker: String) throws {
        let normalized = Self.normalizedCacheText(speaker)
        guard !normalized.isEmpty else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata("Custom Voice requires a non-empty Qwen3 speaker.")
        }
        guard supportedSpeakers.isEmpty || supportedSpeakers.contains(normalized) else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "Unsupported Qwen3 speaker '\(speaker)'. Supported speakers: \(supportedSpeakers.joined(separator: ", "))."
            )
        }
    }

    func validatePromptText(_ value: String, label: String) throws {
        let normalized = Self.normalizedCacheText(value)
        guard !normalized.isEmpty else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata("\(label) must not be empty.")
        }
        guard !Self.containsDisallowedVoiceImitationInstruction(normalized) else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "\(label) cannot request celebrity imitation or voice impersonation."
            )
        }
    }

    func diagnosticStringFlags() -> [String: String] {
        [
            "qwen3_model_family": modelFamily.rawValue,
            "qwen3_quantization_tier": quantizationTier.rawValue,
            "qwen3_tokenizer_type": tokenizerType,
            "qwen3_mode_capability": modeCapability.rawValue,
            "qwen3_sample_rate": String(sampleRate),
            "qwen3_supported_speaker_count": String(supportedSpeakers.count),
        ]
    }

    private func validate(
        descriptor: ModelDescriptor,
        modelDirectory: URL,
        fileManager: FileManager
    ) throws {
        guard descriptor.folder.localizedCaseInsensitiveContains("Qwen3-TTS"),
              descriptor.huggingFaceRepo.localizedCaseInsensitiveContains("Qwen3-TTS") else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "Model '\(descriptor.id)' must use Qwen3-TTS folder and repository metadata."
            )
        }
        guard descriptor.mode == modeCapability else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "Model '\(descriptor.id)' is declared for \(descriptor.mode.rawValue) but its Qwen3-TTS family supports \(modeCapability.rawValue)."
            )
        }
        guard sampleRate == Self.canonicalSampleRate else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "QwenVoice expects Qwen3-TTS 24 kHz output; model '\(descriptor.id)' declares \(sampleRate) Hz."
            )
        }
        guard tokenizerType == Self.canonicalTokenizerType else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "QwenVoice expects \(Self.canonicalTokenizerType); model '\(descriptor.id)' declares \(tokenizerType)."
            )
        }

        let descriptorRequiredPaths = Set(descriptor.requiredRelativePaths)
        let missingDescriptorRequirements = requiredComponents.filter {
            !descriptorRequiredPaths.contains($0)
        }
        guard missingDescriptorRequirements.isEmpty else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "Model '\(descriptor.id)' is missing Qwen3-TTS required contract paths: \(missingDescriptorRequirements.joined(separator: ", "))."
            )
        }

        let missingFiles = requiredComponents.filter {
            !fileManager.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
        guard missingFiles.isEmpty else {
            throw Qwen3TTSRuntimeProfileError.missingFile(
                "Installed Qwen3-TTS model '\(descriptor.id)' is missing files: \(missingFiles.joined(separator: ", "))."
            )
        }
    }

    static func normalizedLanguage(_ raw: String?) -> String {
        let normalized = normalizedCacheText(raw ?? "")
        switch normalized {
        case "", "auto", "automatic":
            return "auto"
        case "en", "en-us", "en_us", "en-gb", "en_gb", "english":
            return "english"
        case "zh", "zh-cn", "zh_cn", "cn", "mandarin", "chinese":
            return "chinese"
        case "ja", "jp", "japanese":
            return "japanese"
        case "ko", "kr", "korean":
            return "korean"
        default:
            return normalized
        }
    }

    static func normalizedCacheText(_ raw: String) -> String {
        raw
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func containsDisallowedVoiceImitationInstruction(_ normalizedText: String) -> Bool {
        let markers = [
            "celebrity",
            "impersonate",
            "imitate the voice",
            "clone the voice",
            "sound exactly like",
            "sound just like",
            "in the voice of",
        ]
        return markers.contains { normalizedText.contains($0) }
    }

    private static func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Qwen3TTSRuntimeProfileError.invalidMetadata(
                "Expected JSON object at '\(url.path)'."
            )
        }
        return object
    }

    private static func normalizedModelType(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func normalizedLanguageSupport(from raw: Any?) -> [String] {
        guard let map = raw as? [String: Any] else {
            return ["auto", "english", "chinese"]
        }
        let languages = Set(map.keys.map(normalizedLanguage))
        return languages.sorted()
    }

    private static func normalizedSpeakerIDs(from raw: Any?) -> [String] {
        guard let map = raw as? [String: Any] else {
            return []
        }
        return map.keys.map(normalizedCacheText).filter { !$0.isEmpty }.sorted()
    }

    private static func quantizationTier(
        descriptor: ModelDescriptor,
        config: [String: Any]
    ) -> Qwen3TTSQuantizationTier {
        let identity = "\(descriptor.folder)|\(descriptor.huggingFaceRepo)".lowercased()
        if identity.contains("4bit") {
            return .fourBit
        }
        if identity.contains("8bit") {
            return .eightBit
        }
        if let bits = int(nested(config, "quantization")?["bits"])
            ?? int(nested(config, "quantization_config")?["bits"]) {
            if bits == 4 {
                return .fourBit
            }
            if bits == 8 {
                return .eightBit
            }
        }
        return .unknown
    }

    private static func nested(_ object: [String: Any], _ key: String) -> [String: Any]? {
        object[key] as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func int(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }
}

