import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS
@preconcurrency import MLXLMCommon
@preconcurrency import QwenVoiceBackendCore

/// Talker sampling overrides, applied in the generation-parameter policies.
/// Two layers, env (dev A/B) winning over the per-request variation:
///
/// - **Per-request variation** (GitHub #47): `NativeEngineRuntime.
///   prepareGeneration` stamps the request's `Qwen3SamplingVariation` here
///   before the handlers resolve parameters. Single-mutator by construction —
///   the engine's model-operation gate admits one generation at a time — so
///   the `nonisolated(unsafe)` static is sound (same contract as the
///   single-owner notes on `UnsafeSpeechGenerationModel`).
/// - **Env knobs** (dev-only, resolved once): QWENVOICE_TALKER_TEMP / _TOPP,
///   for delivery-tuning A/Bs. The subtalker counterparts live in the
///   vendored backend (`Qwen3SamplingOverrides`: QWENVOICE_SUBTALKER_*).
///
/// With neither set, production sampling is the official checkpoint default.
enum Qwen3TalkerSamplingOverride {
    nonisolated(unsafe) static var requestVariation: Qwen3SamplingVariation?

    static let envTemperature: Float? = floatValue("QWENVOICE_TALKER_TEMP")
    static let envTopP: Float? = floatValue("QWENVOICE_TALKER_TOPP")

    private static func floatValue(_ key: String) -> Float? {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let value = Float(raw), value > 0 else { return nil }
        return value
    }

    static func apply(to parameters: inout GenerateParameters) {
        switch requestVariation {
        case .balanced:
            parameters.temperature = 0.8
            parameters.topP = 0.95
        case .consistent:
            parameters.temperature = 0.7
            parameters.topP = 0.9
        case .expressive, nil:
            break  // official checkpoint defaults
        }
        if let envTemperature { parameters.temperature = envTemperature }
        if let envTopP { parameters.topP = envTopP }
    }
}

enum Qwen3CustomVoiceGenerationParameterPolicy {
    static let temperature: Float = Qwen3GenerationConfiguration.officialQualityDefault.temperature
    static let topP: Float = Qwen3GenerationConfiguration.officialQualityDefault.topP

    static func productParameters(defaultParameters: GenerateParameters) -> GenerateParameters {
        var parameters = defaultParameters
        parameters.maxTokens = Qwen3GenerationConfiguration.officialQualityDefault.maxNewTokens
        parameters.temperature = temperature
        parameters.topP = topP
        parameters.repetitionPenalty = Qwen3GenerationConfiguration.officialQualityDefault.repetitionPenalty
        Qwen3TalkerSamplingOverride.apply(to: &parameters)
        return parameters
    }

    static func resolve(
        defaultParameters: GenerateParameters
    ) -> GenerateParameters {
        productParameters(defaultParameters: defaultParameters)
    }
}

enum Qwen3QualityGenerationParameterPolicy {
    static func productParameters(defaultParameters: GenerateParameters) -> GenerateParameters {
        var parameters = defaultParameters
        let official = Qwen3GenerationConfiguration.officialQualityDefault
        parameters.maxTokens = official.maxNewTokens
        parameters.temperature = official.temperature
        parameters.topP = official.topP
        parameters.repetitionPenalty = official.repetitionPenalty
        Qwen3TalkerSamplingOverride.apply(to: &parameters)
        return parameters
    }

    static func resolve(
        defaultParameters: GenerateParameters
    ) -> GenerateParameters {
        productParameters(defaultParameters: defaultParameters)
    }
}

/// Thin wrapper around an `MLXAudioTTS.SpeechGenerationModel` that lets us
/// hand the model across actor boundaries inside the engine.
///
/// "Unsafe" here means the `@unchecked Sendable` suppression below — not raw
/// memory manipulation. The wrapped closures and the backing model instance
/// are single-owner by construction (the engine never shares them between
/// concurrent generations), so bypassing the strict-concurrency checker is
/// safe for the use sites inside this module. Do not extend this surface
/// without preserving the single-owner contract (Tier 6).
final class UnsafeSpeechGenerationModel: @unchecked Sendable {
    private let sampleRateProvider: @Sendable () -> Int
    private let prewarmHandler: @Sendable (String, String?, MLXArray?, String?) async throws -> Void
    private let streamHandler: @Sendable (String, String?, MLXArray?, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>
    private let loadDiagnosticsProvider: @Sendable () -> [String: Int]
    private let loadDiagnosticBooleanFlagsProvider: @Sendable () -> [String: Bool]
    private let latestPreparationDiagnosticsProvider: @Sendable () -> [String: Int]
    private let latestPreparationBooleanFlagsProvider: @Sendable () -> [String: Bool]
    private let latestPreparationStringFlagsProvider: @Sendable () -> [String: String]
    private let resetPreparationDiagnosticsHandler: @Sendable () -> Void
    private let customPrewarmHandler: (@Sendable (String, String, String, String?, String?) async throws -> Void)?
    private let customStreamHandler: (@Sendable (String, String, String, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>)?
    private let customGenerateHandler: (@Sendable (String, String, String, String?) async throws -> AudioGenerationCompletion)?
    private let designPrewarmHandler: (@Sendable (String, String, String) async throws -> Void)?
    private let designStreamHandler: (@Sendable (String, String, String, Double) -> AsyncThrowingStream<AudioGeneration, Error>)?
    private let designGenerateHandler: (@Sendable (String, String, String) async throws -> AudioGenerationCompletion)?
    private let clonePromptCreator: (@Sendable (MLXArray, String?, Bool) throws -> Qwen3TTSVoiceClonePrompt)?
    private let clonePrewarmHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> Void)?
    private let cloneStreamHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt, Double) -> AsyncThrowingStream<AudioGeneration, Error>)?
    private let cloneGenerateHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> AudioGenerationCompletion)?

    private final class BaseModelBox: @unchecked Sendable {
        let base: any SpeechGenerationModel

        init(base: any SpeechGenerationModel) {
            self.base = base
        }
    }

    private final class OptimizedModelBox: @unchecked Sendable {
        let base: any Qwen3OptimizedSpeechGenerationModel

        init(base: any Qwen3OptimizedSpeechGenerationModel) {
            self.base = base
        }
    }

    init(base: any SpeechGenerationModel) {
        let box = BaseModelBox(base: base)
        self.sampleRateProvider = { box.base.sampleRate }
        self.prewarmHandler = { text, voice, refAudio, refText in
            try await box.base.prepareForGeneration(
                text: text,
                voice: voice,
                refAudio: refAudio,
                refText: refText,
                language: nil,
                generationParameters: box.base.defaultGenerationParameters
            )
        }
        self.streamHandler = { text, voice, refAudio, refText, streamingInterval in
            return box.base.generateStream(
                text: text,
                voice: voice,
                refAudio: refAudio,
                refText: refText,
                language: nil,
                generationParameters: box.base.defaultGenerationParameters,
                streamingInterval: streamingInterval
            )
        }
        self.loadDiagnosticsProvider = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.loadTimingsMS ?? [:]
        }
        self.loadDiagnosticBooleanFlagsProvider = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.loadBooleanFlags ?? [:]
        }
        self.latestPreparationDiagnosticsProvider = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.latestPreparationTimingsMS ?? [:]
        }
        self.latestPreparationBooleanFlagsProvider = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.latestPreparationBooleanFlags ?? [:]
        }
        self.latestPreparationStringFlagsProvider = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.latestPreparationStringFlags ?? [:]
        }
        self.resetPreparationDiagnosticsHandler = {
            (box.base as? any SpeechGenerationModelDiagnosticsProvider)?.resetPreparationDiagnostics()
        }
        if let optimizedBase = base as? any Qwen3OptimizedSpeechGenerationModel {
            let optimizedBox = OptimizedModelBox(base: optimizedBase)
            self.customPrewarmHandler = { text, language, speaker, instruct, customPrewarmDepth in
                let parameters = Qwen3CustomVoiceGenerationParameterPolicy.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                if let configurable = optimizedBox.base as? any Qwen3CustomVoicePrewarmDepthControlling {
                    try await configurable.prepareCustomVoice(
                        text: text,
                        language: language,
                        speaker: speaker,
                        instruct: instruct,
                        generationParameters: parameters,
                        customPrewarmDepth: customPrewarmDepth
                    )
                } else {
                    try await optimizedBox.base.prepareCustomVoice(
                        text: text,
                        language: language,
                        speaker: speaker,
                        instruct: instruct,
                        generationParameters: parameters
                    )
                }
            }
            self.customStreamHandler = { text, language, speaker, instruct, streamingInterval in
                let parameters = Qwen3CustomVoiceGenerationParameterPolicy.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                return optimizedBox.base.generateCustomVoiceStream(
                    text: text,
                    language: language,
                    speaker: speaker,
                    instruct: instruct,
                    generationParameters: parameters,
                    streamingInterval: streamingInterval,
                    customVoiceProfile: nil,
                    streamStepEvalPolicy: nil,
                    generationSpeedProfile: nil,
                    memoryClearCadence: nil
                )
            }
            self.customGenerateHandler = { text, language, speaker, instruct in
                let parameters = Qwen3CustomVoiceGenerationParameterPolicy.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                return try await optimizedBox.base.generateCustomVoice(
                    text: text,
                    language: language,
                    speaker: speaker,
                    instruct: instruct,
                    generationParameters: parameters
                )
            }
            self.designPrewarmHandler = { text, language, voiceDescription in
                try await optimizedBox.base.prepareVoiceDesign(
                    text: text,
                    language: language,
                    voiceDescription: voiceDescription,
                    generationParameters: box.base.defaultGenerationParameters
                )
            }
            self.designStreamHandler = { text, language, voiceDescription, streamingInterval in
                return optimizedBox.base.generateVoiceDesignStream(
                    text: text,
                    language: language,
                    voiceDescription: voiceDescription,
                    generationParameters: box.base.defaultGenerationParameters,
                    streamingInterval: streamingInterval,
                    streamStepEvalPolicy: nil,
                    generationSpeedProfile: nil,
                    memoryClearCadence: nil
                )
            }
            self.designGenerateHandler = { text, language, voiceDescription in
                let parameters = Qwen3QualityGenerationParameterPolicy.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                return try await optimizedBox.base.generateVoiceDesign(
                    text: text,
                    language: language,
                    voiceDescription: voiceDescription,
                    generationParameters: parameters
                )
            }
            self.clonePromptCreator = { refAudio, refText, xVectorOnlyMode in
                try optimizedBox.base.createVoiceClonePrompt(
                    refAudio: refAudio,
                    refText: refText,
                    xVectorOnlyMode: xVectorOnlyMode
                )
            }
            self.clonePrewarmHandler = { text, language, voiceClonePrompt in
                try await optimizedBox.base.prepareVoiceClone(
                    text: text,
                    language: language,
                    voiceClonePrompt: voiceClonePrompt,
                    generationParameters: box.base.defaultGenerationParameters
                )
            }
            self.cloneStreamHandler = { text, language, voiceClonePrompt, streamingInterval in
                return optimizedBox.base.generateVoiceCloneStream(
                    text: text,
                    language: language,
                    voiceClonePrompt: voiceClonePrompt,
                    generationParameters: box.base.defaultGenerationParameters,
                    streamingInterval: streamingInterval,
                    streamStepEvalPolicy: nil,
                    generationSpeedProfile: nil,
                    memoryClearCadence: nil
                )
            }
            self.cloneGenerateHandler = { text, language, voiceClonePrompt in
                let parameters = Qwen3QualityGenerationParameterPolicy.resolve(
                    defaultParameters: box.base.defaultGenerationParameters
                )
                return try await optimizedBox.base.generateVoiceClone(
                    text: text,
                    language: language,
                    voiceClonePrompt: voiceClonePrompt,
                    generationParameters: parameters
                )
            }
        } else {
            self.customPrewarmHandler = nil
            self.customStreamHandler = nil
            self.customGenerateHandler = nil
            self.designPrewarmHandler = nil
            self.designStreamHandler = nil
            self.designGenerateHandler = nil
            self.clonePromptCreator = nil
            self.clonePrewarmHandler = nil
            self.cloneStreamHandler = nil
            self.cloneGenerateHandler = nil
        }
    }

    static func qwen3Optimized(base: any SpeechGenerationModel) throws -> UnsafeSpeechGenerationModel {
        guard base is any Qwen3OptimizedSpeechGenerationModel else {
            throw MLXTTSEngineError.unsupportedRequest(
                "QwenVoice's native backend supports only optimized Qwen3-TTS models."
            )
        }
        return UnsafeSpeechGenerationModel(base: base)
    }

    init(
        sampleRate: Int = 24_000,
        prewarmHandler: @escaping @Sendable (String, String?) async throws -> Void = { _, _ in },
        streamHandler: @escaping @Sendable (String, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error> = { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: MLXTTSEngineError.generationFailed(
                        "No stream configured for UnsafeSpeechGenerationModel."
                    )
                )
            }
        },
        latestPreparationDiagnosticsProvider: @escaping @Sendable () -> [String: Int] = { [:] },
        latestPreparationBooleanFlagsProvider: @escaping @Sendable () -> [String: Bool] = { [:] },
        latestPreparationStringFlagsProvider: @escaping @Sendable () -> [String: String] = { [:] },
        customPrewarmHandler: (@Sendable (String, String, String, String?) async throws -> Void)? = nil,
        customStreamHandler: (@Sendable (String, String, String, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        customGenerateHandler: (@Sendable (String, String, String, String?) async throws -> AudioGenerationCompletion)? = nil,
        designPrewarmHandler: (@Sendable (String, String, String) async throws -> Void)? = nil,
        designStreamHandler: (@Sendable (String, String, String, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        designGenerateHandler: (@Sendable (String, String, String) async throws -> AudioGenerationCompletion)? = nil,
        clonePromptCreator: (@Sendable (MLXArray, String?, Bool) throws -> Qwen3TTSVoiceClonePrompt)? = nil,
        clonePrewarmHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> Void)? = nil,
        cloneStreamHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        cloneGenerateHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> AudioGenerationCompletion)? = nil
    ) {
        self.sampleRateProvider = { sampleRate }
        self.prewarmHandler = { (text: String, voice: String?, _: MLXArray?, _: String?) async throws in
            try await prewarmHandler(text, voice)
        }
        self.streamHandler = { (text: String, voice: String?, _: MLXArray?, _: String?, streamingInterval: Double) in
            streamHandler(text, voice, streamingInterval)
        }
        self.loadDiagnosticsProvider = { [:] }
        self.loadDiagnosticBooleanFlagsProvider = { [:] }
        self.latestPreparationDiagnosticsProvider = latestPreparationDiagnosticsProvider
        self.latestPreparationBooleanFlagsProvider = latestPreparationBooleanFlagsProvider
        self.latestPreparationStringFlagsProvider = latestPreparationStringFlagsProvider
        self.resetPreparationDiagnosticsHandler = {}
        if let customPrewarmHandler {
            self.customPrewarmHandler = { text, language, speaker, instruct, _ in
                try await customPrewarmHandler(text, language, speaker, instruct)
            }
        } else {
            self.customPrewarmHandler = nil
        }
        if let customStreamHandler {
            self.customStreamHandler = { text, language, speaker, instruct, streamingInterval in
                customStreamHandler(text, language, speaker, instruct, streamingInterval)
            }
        } else {
            self.customStreamHandler = nil
        }
        if let customGenerateHandler {
            self.customGenerateHandler = { text, language, speaker, instruct in
                try await customGenerateHandler(text, language, speaker, instruct)
            }
        } else {
            self.customGenerateHandler = nil
        }
        self.designPrewarmHandler = designPrewarmHandler
        if let designStreamHandler {
            self.designStreamHandler = { text, language, voiceDescription, streamingInterval in
                designStreamHandler(text, language, voiceDescription, streamingInterval)
            }
        } else {
            self.designStreamHandler = nil
        }
        if let designGenerateHandler {
            self.designGenerateHandler = { text, language, voiceDescription in
                try await designGenerateHandler(text, language, voiceDescription)
            }
        } else {
            self.designGenerateHandler = nil
        }
        self.clonePromptCreator = clonePromptCreator
        self.clonePrewarmHandler = clonePrewarmHandler
        if let cloneStreamHandler {
            self.cloneStreamHandler = { text, language, voiceClonePrompt, streamingInterval in
                cloneStreamHandler(text, language, voiceClonePrompt, streamingInterval)
            }
        } else {
            self.cloneStreamHandler = nil
        }
        if let cloneGenerateHandler {
            self.cloneGenerateHandler = { text, language, voiceClonePrompt in
                try await cloneGenerateHandler(text, language, voiceClonePrompt)
            }
        } else {
            self.cloneGenerateHandler = nil
        }
    }

    init(
        sampleRate: Int = 24_000,
        fullPrewarmHandler: @escaping @Sendable (String, String?, MLXArray?, String?) async throws -> Void,
        fullStreamHandler: @escaping @Sendable (String, String?, MLXArray?, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>,
        latestPreparationDiagnosticsProvider: @escaping @Sendable () -> [String: Int] = { [:] },
        latestPreparationBooleanFlagsProvider: @escaping @Sendable () -> [String: Bool] = { [:] },
        latestPreparationStringFlagsProvider: @escaping @Sendable () -> [String: String] = { [:] },
        customPrewarmHandler: (@Sendable (String, String, String, String?) async throws -> Void)? = nil,
        customStreamHandler: (@Sendable (String, String, String, String?, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        customGenerateHandler: (@Sendable (String, String, String, String?) async throws -> AudioGenerationCompletion)? = nil,
        designPrewarmHandler: (@Sendable (String, String, String) async throws -> Void)? = nil,
        designStreamHandler: (@Sendable (String, String, String, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        designGenerateHandler: (@Sendable (String, String, String) async throws -> AudioGenerationCompletion)? = nil,
        clonePromptCreator: (@Sendable (MLXArray, String?, Bool) throws -> Qwen3TTSVoiceClonePrompt)? = nil,
        clonePrewarmHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> Void)? = nil,
        cloneStreamHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt, Double) -> AsyncThrowingStream<AudioGeneration, Error>)? = nil,
        cloneGenerateHandler: (@Sendable (String, String, Qwen3TTSVoiceClonePrompt) async throws -> AudioGenerationCompletion)? = nil
    ) {
        self.sampleRateProvider = { sampleRate }
        self.prewarmHandler = fullPrewarmHandler
        self.streamHandler = fullStreamHandler
        self.loadDiagnosticsProvider = { [:] }
        self.loadDiagnosticBooleanFlagsProvider = { [:] }
        self.latestPreparationDiagnosticsProvider = latestPreparationDiagnosticsProvider
        self.latestPreparationBooleanFlagsProvider = latestPreparationBooleanFlagsProvider
        self.latestPreparationStringFlagsProvider = latestPreparationStringFlagsProvider
        self.resetPreparationDiagnosticsHandler = {}
        if let customPrewarmHandler {
            self.customPrewarmHandler = { text, language, speaker, instruct, _ in
                try await customPrewarmHandler(text, language, speaker, instruct)
            }
        } else {
            self.customPrewarmHandler = nil
        }
        if let customStreamHandler {
            self.customStreamHandler = { text, language, speaker, instruct, streamingInterval in
                customStreamHandler(text, language, speaker, instruct, streamingInterval)
            }
        } else {
            self.customStreamHandler = nil
        }
        if let customGenerateHandler {
            self.customGenerateHandler = { text, language, speaker, instruct in
                try await customGenerateHandler(text, language, speaker, instruct)
            }
        } else {
            self.customGenerateHandler = nil
        }
        self.designPrewarmHandler = designPrewarmHandler
        if let designStreamHandler {
            self.designStreamHandler = { text, language, voiceDescription, streamingInterval in
                designStreamHandler(text, language, voiceDescription, streamingInterval)
            }
        } else {
            self.designStreamHandler = nil
        }
        if let designGenerateHandler {
            self.designGenerateHandler = { text, language, voiceDescription in
                try await designGenerateHandler(text, language, voiceDescription)
            }
        } else {
            self.designGenerateHandler = nil
        }
        self.clonePromptCreator = clonePromptCreator
        self.clonePrewarmHandler = clonePrewarmHandler
        if let cloneStreamHandler {
            self.cloneStreamHandler = { text, language, voiceClonePrompt, streamingInterval in
                cloneStreamHandler(text, language, voiceClonePrompt, streamingInterval)
            }
        } else {
            self.cloneStreamHandler = nil
        }
        if let cloneGenerateHandler {
            self.cloneGenerateHandler = { text, language, voiceClonePrompt in
                try await cloneGenerateHandler(text, language, voiceClonePrompt)
            }
        } else {
            self.cloneGenerateHandler = nil
        }
    }

    var sampleRate: Int {
        sampleRateProvider()
    }

    var loadDiagnosticsTimingsMS: [String: Int] {
        loadDiagnosticsProvider()
    }

    var loadDiagnosticBooleanFlags: [String: Bool] {
        loadDiagnosticBooleanFlagsProvider()
    }

    var latestPreparationTimingsMS: [String: Int] {
        latestPreparationDiagnosticsProvider()
    }

    var latestPreparationBooleanFlags: [String: Bool] {
        latestPreparationBooleanFlagsProvider()
    }

    var latestPreparationStringFlags: [String: String] {
        latestPreparationStringFlagsProvider()
    }

    func resetPreparationDiagnostics() {
        resetPreparationDiagnosticsHandler()
    }

    var supportsDedicatedCustomVoice: Bool {
        customPrewarmHandler != nil && customStreamHandler != nil && customGenerateHandler != nil
    }

    var supportsOptimizedCustomVoice: Bool {
        supportsDedicatedCustomVoice
    }

    var supportsOptimizedVoiceDesign: Bool {
        designPrewarmHandler != nil && designStreamHandler != nil && designGenerateHandler != nil
    }

    var supportsOptimizedVoiceClone: Bool {
        clonePromptCreator != nil && clonePrewarmHandler != nil && cloneStreamHandler != nil && cloneGenerateHandler != nil
    }

    func prewarm(text: String, voice: String?) async throws {
        try await prewarmHandler(text, voice, nil, nil)
    }

    func prewarm(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?
    ) async throws {
        try await prewarmHandler(text, voice, refAudio, refText)
    }

    func generateStream(
        text: String,
        voice: String?,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        streamHandler(text, voice, nil, nil, streamingInterval)
    }

    func generateStream(
        text: String,
        voice: String?,
        refAudio: MLXArray?,
        refText: String?,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        streamHandler(text, voice, refAudio, refText, streamingInterval)
    }

    func prewarmCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        customPrewarmDepth: String? = nil
    ) async throws {
        guard let customPrewarmHandler else {
            throw MLXTTSEngineError.unsupportedRequest(
                "The active native model does not support optimized Qwen3 Custom Voice generation."
            )
        }
        try await customPrewarmHandler(text, language, speaker, instruct, customPrewarmDepth)
    }

    func generateCustomVoiceStream(
        text: String,
        language: String,
        speaker: String,
        instruct: String?,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        if let customStreamHandler {
            return customStreamHandler(text, language, speaker, instruct, streamingInterval)
        }
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: MLXTTSEngineError.unsupportedRequest(
                    "The active native model does not support optimized Qwen3 Custom Voice generation."
                )
            )
        }
    }

    func generateCustomVoice(
        text: String,
        language: String,
        speaker: String,
        instruct: String?
    ) async throws -> AudioGenerationCompletion {
        guard let customGenerateHandler else {
            throw MLXTTSEngineError.unsupportedRequest(
                "The active native model does not support quality-first Qwen3 Custom Voice generation."
            )
        }
        return try await customGenerateHandler(text, language, speaker, instruct)
    }

    func prewarmVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String
    ) async throws {
        guard let designPrewarmHandler else {
            throw MLXTTSEngineError.unsupportedRequest(
                "The active native model does not support optimized Qwen3 Voice Design generation."
            )
        }
        try await designPrewarmHandler(text, language, voiceDescription)
    }

    func generateVoiceDesignStream(
        text: String,
        language: String,
        voiceDescription: String,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        if let designStreamHandler {
            return designStreamHandler(text, language, voiceDescription, streamingInterval)
        }
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: MLXTTSEngineError.unsupportedRequest(
                    "The active native model does not support optimized Qwen3 Voice Design generation."
                )
            )
        }
    }

    func generateVoiceDesign(
        text: String,
        language: String,
        voiceDescription: String
    ) async throws -> AudioGenerationCompletion {
        guard let designGenerateHandler else {
            throw MLXTTSEngineError.unsupportedRequest(
                "The active native model does not support quality-first Qwen3 Voice Design generation."
            )
        }
        return try await designGenerateHandler(text, language, voiceDescription)
    }

    func createVoiceClonePrompt(
        refAudio: MLXArray,
        refText: String?,
        xVectorOnlyMode: Bool
    ) throws -> Qwen3TTSVoiceClonePrompt? {
        try clonePromptCreator?(refAudio, refText, xVectorOnlyMode)
    }

    func prewarmVoiceClone(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt
    ) async throws {
        guard let clonePrewarmHandler else {
            throw MLXTTSEngineError.unsupportedRequest(
                "The active native model does not support optimized Qwen voice-clone prompts."
            )
        }
        try await clonePrewarmHandler(text, language, voiceClonePrompt)
    }

    func generateVoiceCloneStream(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt,
        streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> {
        if let cloneStreamHandler {
            return cloneStreamHandler(text, language, voiceClonePrompt, streamingInterval)
        }
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: MLXTTSEngineError.unsupportedRequest(
                    "The active native model does not support optimized Qwen voice-clone prompts."
                )
            )
        }
    }

    func generateVoiceClone(
        text: String,
        language: String,
        voiceClonePrompt: Qwen3TTSVoiceClonePrompt
    ) async throws -> AudioGenerationCompletion {
        guard let cloneGenerateHandler else {
            throw MLXTTSEngineError.unsupportedRequest(
                "The active native model does not support quality-first Qwen voice-clone generation."
            )
        }
        return try await cloneGenerateHandler(text, language, voiceClonePrompt)
    }

}
