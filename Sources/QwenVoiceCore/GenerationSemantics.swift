import Foundation

public enum GenerationSemantics {
    public enum DesignWarmBucket: String, Sendable {
        case short
        case long
    }

    public enum Qwen3PromptMode: String, Codable, Hashable, Sendable {
        case customVoice = "custom_voice"
        case voiceDesign = "voice_design"
        case voiceClone = "voice_clone"
    }

    public struct Qwen3PromptAssembly: Hashable, Codable, Sendable {
        public let mode: Qwen3PromptMode
        public let text: String
        public let language: String
        public let instruct: String?
        public let refText: String?
        public let speakerID: String?
        public let usesInstructionControl: Bool
        public let cloneUsesTranscript: Bool
    }

    public static let appStreamingInterval = 0.32
    public static let canonicalCustomWarmText = "Hi."
    public static let canonicalCustomWarmSpeaker = "aiden"
    public static let canonicalCustomWarmLanguage = "english"
    public static let canonicalDesignWarmLanguage = "english"
    public static let englishDictionReinforcement =
        "Native English pronunciation with clear English diction and natural stress."
    public static let canonicalDesignWarmShortText = "Hello world."
    public static let canonicalDesignWarmLongText =
        """
        Artificial intelligence has rapidly transformed from a niche academic pursuit into one of the most consequential technologies of the modern era. Large language models, capable of generating coherent text across a wide range of domains, have captured the imagination of researchers and the general public alike. Meanwhile, text-to-speech systems have reached a point where synthesized voices are often indistinguishable from natural human speech, opening new possibilities for accessibility, creative media production, and personalized assistants.
        """

    public static func isNeutralDeliveryInstruction(_ emotion: String) -> Bool {
        let normalized = normalizedConditioningCacheKeyText(emotion)
        return normalized.isEmpty
            || normalized == "normal tone"
            || normalized == "neutral"
            || normalized == "neutral tone"
    }

    public static func hasMeaningfulDeliveryInstruction(_ emotion: String) -> Bool {
        !isNeutralDeliveryInstruction(emotion)
    }

    public static func supportsIdlePrewarm(mode: GenerationMode) -> Bool {
        mode == .custom
    }

    public static func designInstruction(voiceDescription: String, emotion: String) -> String {
        let trimmedDescription = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmotion = emotion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasMeaningfulDeliveryInstruction(trimmedEmotion) else {
            return trimmedDescription.trimmingTerminalSentencePunctuation()
        }

        guard !trimmedDescription.isEmpty else {
            return trimmedEmotion.trimmingTerminalSentencePunctuation()
        }
        return "Voice character: \(trimmedDescription.trimmingTerminalSentencePunctuation()). Delivery: \(trimmedEmotion.trimmingTerminalSentencePunctuation())."
    }

    public static func normalizedConditioningCacheKeyText(_ text: String) -> String {
        Qwen3TTSRuntimeProfile.normalizedCacheText(text)
    }

    public static func normalizedDesignConditioningIdentity(
        language: String,
        voiceDescription: String,
        emotion: String?
    ) -> String {
        let normalizedLanguage = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let resolvedInstruction = englishDictionReinforcedInstruction(
            baseInstruction: designInstruction(
                voiceDescription: voiceDescription,
                emotion: emotion ?? ""
            ),
            language: normalizedLanguage
        ) ?? ""
        let normalizedInstruction = normalizedConditioningCacheKeyText(resolvedInstruction)
        return "\(normalizedLanguage)|\(normalizedInstruction)"
    }

    public static func customInstruction(deliveryStyle: String?) -> String? {
        guard let deliveryStyle else { return nil }
        let trimmedDelivery = deliveryStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasMeaningfulDeliveryInstruction(trimmedDelivery) else {
            return nil
        }
        return trimmedDelivery
    }

    public static func customInstruction(
        for request: GenerationRequest,
        capabilities: Qwen3TTSModelCapabilities
    ) -> String? {
        qwen3PromptAssembly(for: request, capabilities: capabilities).instruct
    }

    public static func voiceDesignInstruction(
        for request: GenerationRequest,
        capabilities: Qwen3TTSModelCapabilities
    ) -> String? {
        qwen3PromptAssembly(for: request, capabilities: capabilities).instruct
    }

    public static func qwen3PromptAssembly(
        for request: GenerationRequest,
        capabilities: Qwen3TTSModelCapabilities,
        resolvedCloneTranscript: String? = nil
    ) -> Qwen3PromptAssembly {
        let language = qwenLanguageHint(
            for: request,
            resolvedCloneTranscript: resolvedCloneTranscript
        )
        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            let canUseInstruction = capabilities.supportsInstructionControl
            let baseInstruction = canUseInstruction
                ? customInstruction(deliveryStyle: deliveryStyle)
                : nil
            let instruction = canUseInstruction
                ? englishDictionReinforcedInstruction(
                    baseInstruction: baseInstruction,
                    language: language
                )
                : nil
            return Qwen3PromptAssembly(
                mode: .customVoice,
                text: request.text,
                language: language,
                instruct: instruction,
                refText: nil,
                speakerID: speakerID.trimmingCharacters(in: .whitespacesAndNewlines),
                usesInstructionControl: instruction != nil,
                cloneUsesTranscript: false
            )
        case .design(let voiceDescription, let deliveryStyle):
            let baseInstruction = capabilities.supportsInstructionControl
                ? designInstruction(
                    voiceDescription: voiceDescription,
                    emotion: deliveryStyle ?? ""
                )
                : voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let instruction = englishDictionReinforcedInstruction(
                baseInstruction: baseInstruction,
                language: language
            )
            return Qwen3PromptAssembly(
                mode: .voiceDesign,
                text: request.text,
                language: language,
                instruct: instruction,
                refText: nil,
                speakerID: nil,
                usesInstructionControl: instruction != nil,
                cloneUsesTranscript: false
            )
        case .clone(let reference):
            let rawRefText = (resolvedCloneTranscript ?? reference.transcript)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedRefText = (rawRefText?.isEmpty == false) ? rawRefText : nil
            return Qwen3PromptAssembly(
                mode: .voiceClone,
                text: request.text,
                language: language,
                instruct: nil,
                refText: trimmedRefText,
                speakerID: nil,
                usesInstructionControl: false,
                cloneUsesTranscript: trimmedRefText != nil
            )
        }
    }

    public static func englishDictionReinforcedInstruction(
        baseInstruction: String?,
        language: String
    ) -> String? {
        guard Qwen3TTSRuntimeProfile.normalizedLanguage(language) == "english" else {
            return baseInstruction
        }

        let reinforcement = englishDictionReinforcement
        guard let baseInstruction else {
            return reinforcement
        }

        let trimmedBase = baseInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            return reinforcement
        }
        if normalizedConditioningCacheKeyText(trimmedBase)
            .contains(normalizedConditioningCacheKeyText(reinforcement)) {
            return trimmedBase
        }
        // Skip the reinforcement append when the base instruction already
        // contains any diction/clarity tokens. Stops the model from receiving
        // "…with clear articulation… Native English pronunciation with clear
        // English diction and natural stress." which is redundant and can
        // crowd out the dominant emotion signal. See
        // docs/reference/emotion-delivery-improvements.md.
        let baseLowercased = trimmedBase.lowercased()
        let dictionTokens = [
            "clear", "clearly", "diction", "articulation",
            "pronunciation", "clarity", "intelligible", "understandable",
        ]
        if dictionTokens.contains(where: { baseLowercased.contains($0) }) {
            return trimmedBase
        }
        return "\(trimmedBase) \(reinforcement)"
    }

    public static func qwenLanguageHint(
        for request: GenerationRequest,
        resolvedCloneTranscript: String? = nil
    ) -> String {
        if let languageHint = request.languageHint {
            let normalized = Qwen3SupportedLanguage.normalized(languageHint)
            if normalized != .auto {
                return normalized.rawValue
            }
        }
        switch request.payload {
        case .custom:
            return detectedQwenLanguage(in: request.text)?.rawValue ?? canonicalCustomWarmLanguage
        case .design:
            return detectedQwenLanguage(in: request.text)?.rawValue ?? Qwen3SupportedLanguage.auto.rawValue
        case .clone:
            if let transcript = resolvedCloneTranscript,
               let detectedLanguage = detectedQwenLanguage(in: transcript) {
                return detectedLanguage.rawValue
            }
            return detectedQwenLanguage(in: request.text)?.rawValue ?? Qwen3SupportedLanguage.auto.rawValue
        }
    }

    public static func validateQwenPromptContract(for request: GenerationRequest) throws {
        switch request.payload {
        case .custom(_, let deliveryStyle):
            if let deliveryStyle,
               hasMeaningfulDeliveryInstruction(deliveryStyle),
               Qwen3TTSRuntimeProfile.containsDisallowedVoiceImitationInstruction(
                   normalizedConditioningCacheKeyText(deliveryStyle)
               ) {
                throw MLXTTSEngineError.unsupportedRequest(
                    "Custom Voice delivery instructions cannot request celebrity imitation or voice impersonation."
                )
            }
        case .design(let voiceDescription, let deliveryStyle):
            let instruction = designInstruction(
                voiceDescription: voiceDescription,
                emotion: deliveryStyle ?? ""
            )
            if Qwen3TTSRuntimeProfile.containsDisallowedVoiceImitationInstruction(
                normalizedConditioningCacheKeyText(instruction)
            ) {
                throw MLXTTSEngineError.unsupportedRequest(
                    "Voice Design descriptions cannot request celebrity imitation or voice impersonation."
                )
            }
        case .clone:
            break
        }
    }

    public static func canonicalCustomWarmInstruction() -> String? {
        nil
    }

    public static func canonicalDesignWarmInstruction() -> String {
        designInstruction(
            voiceDescription: "A clear, steady narrator with a natural conversational tone.",
            emotion: ""
        )
    }

    public static func canonicalDesignWarmText(for bucket: DesignWarmBucket) -> String {
        switch bucket {
        case .short:
            canonicalDesignWarmShortText
        case .long:
            canonicalDesignWarmLongText
        }
    }

    public static func designWarmBucket(for text: String) -> DesignWarmBucket {
        let normalizedText = normalizedConditioningCacheKeyText(text)
        guard !normalizedText.isEmpty else { return .short }

        let normalizedLongText = normalizedConditioningCacheKeyText(canonicalDesignWarmLongText)
        let longBucketThreshold = max(160, normalizedLongText.count / 2)
        return normalizedText.count >= longBucketThreshold ? .long : .short
    }

    public static func designConditioningWarmKey(
        modelID: String,
        language: String,
        voiceDescription: String,
        emotion: String?,
        text: String
    ) -> String {
        let normalizedConditioning = normalizedDesignConditioningIdentity(
            language: language,
            voiceDescription: voiceDescription,
            emotion: emotion
        )
        return [
            modelID,
            GenerationMode.design.rawValue,
            normalizedConditioning,
            designWarmBucket(for: text).rawValue,
        ].joined(separator: "|")
    }

    public static func designConditioningWarmKey(
        for request: GenerationRequest
    ) -> String? {
        guard case .design(let voiceDescription, let emotion) = request.payload else {
            return nil
        }
        let trimmedVoiceDescription = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoiceDescription.isEmpty else { return nil }
        let language = qwenLanguageHint(for: request)
        return designConditioningWarmKey(
            modelID: request.modelID,
            language: language,
            voiceDescription: voiceDescription,
            emotion: emotion,
            text: request.text
        )
    }

    public static func prewarmIdentityKey(
        modelID: String,
        mode: GenerationMode,
        voice: String? = nil,
        instruct: String? = nil,
        refAudio: String? = nil,
        refText: String? = nil
    ) -> String {
        let trimmedVoice = voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRefAudio = refAudio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRefText = refText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedInstruction = instruct?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedInstruction = hasMeaningfulDeliveryInstruction(trimmedInstruction) ? trimmedInstruction : ""
        let identityParts: [String]

        switch mode {
        case .custom:
            _ = trimmedVoice
            _ = normalizedInstruction
            // Keep custom interactive readiness stable at the model level so
            // UI draft churn does not invalidate the hot model state.
            identityParts = [modelID, mode.rawValue]
        case .design:
            identityParts = [modelID, mode.rawValue]
        case .clone:
            identityParts = [modelID, mode.rawValue, trimmedRefAudio, trimmedRefText]
        }

        return identityParts.joined(separator: "|")
    }

    public static func cloneReferenceIdentityKey(
        modelID: String,
        refAudio: String,
        refText: String?
    ) -> String {
        prewarmIdentityKey(
            modelID: modelID,
            mode: .clone,
            refAudio: refAudio,
            refText: refText
        )
    }

    /// Request-form prewarm identity key. For `.custom`, the key INCLUDES
    /// the speaker and (normalized) delivery instruction, so that voice/
    /// delivery changes invalidate the prewarm cache. The parameterized
    /// `prewarmIdentityKey(modelID:mode:...)` above intentionally omits
    /// those for the "stable model-level readiness" code paths — both
    /// forms coexist by design with intentionally different semantics.
    /// Live callers: NativeEngineRuntime, XPCNativeEngineClient,
    /// GenerationSemanticsTests.
    public static func prewarmIdentityKey(for request: GenerationRequest) -> String {
        switch request.payload {
        case .custom(let speakerID, let deliveryStyle):
            let normalizedInstruction = hasMeaningfulDeliveryInstruction(deliveryStyle ?? "")
                ? deliveryStyle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                : ""
            return [
                request.modelID,
                request.modeIdentifier,
                qwenLanguageHint(for: request),
                speakerID.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedInstruction,
            ].joined(separator: "|")
        case .design:
            return [
                request.modelID,
                request.modeIdentifier,
            ].joined(separator: "|")
        case .clone(let reference):
            return clonePreparationKey(modelID: request.modelID, reference: reference)
        }
    }

    /// Public clone-preparation cache key. Mirrors the engine-support
    /// signature so production callers can switch to this copy without
    /// changing arguments. Format: "<modelID>|clone|<audioPath>|<transcript>".
    public static func clonePreparationKey(modelID: String, reference: CloneReference) -> String {
        [
            modelID,
            "clone",
            reference.audioPath.trimmingCharacters(in: .whitespacesAndNewlines),
            reference.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ].joined(separator: "|")
    }

    private static func detectedQwenLanguage(in text: String) -> Qwen3SupportedLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.unicodeScalars.contains(where: \.isJapaneseScalar) {
            return .japanese
        }
        if trimmed.unicodeScalars.contains(where: \.isHangulScalar) {
            return .korean
        }
        if trimmed.unicodeScalars.contains(where: \.isCyrillicScalar) {
            return .russian
        }
        if trimmed.unicodeScalars.contains(where: \.isCJKScalar) {
            return .chinese
        }
        return nil
    }
}

private extension String {
    func trimmingTerminalSentencePunctuation() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?。！？"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension UnicodeScalar {
    var isCJKScalar: Bool {
        switch value {
        case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF:
            return true
        default:
            return false
        }
    }

    var isJapaneseScalar: Bool {
        switch value {
        case 0x3040 ... 0x309F, 0x30A0 ... 0x30FF:
            return true
        default:
            return false
        }
    }

    var isHangulScalar: Bool {
        switch value {
        case 0x1100 ... 0x11FF, 0x3130 ... 0x318F, 0xAC00 ... 0xD7AF:
            return true
        default:
            return false
        }
    }

    var isArabicScalar: Bool {
        switch value {
        case 0x0600 ... 0x06FF, 0x0750 ... 0x077F, 0x08A0 ... 0x08FF:
            return true
        default:
            return false
        }
    }

    var isDevanagariScalar: Bool {
        switch value {
        case 0x0900 ... 0x097F:
            return true
        default:
            return false
        }
    }

    var isCyrillicScalar: Bool {
        switch value {
        case 0x0400 ... 0x04FF, 0x0500 ... 0x052F:
            return true
        default:
            return false
        }
    }

    var isLatinLetterScalar: Bool {
        switch value {
        case 0x0041 ... 0x005A, 0x0061 ... 0x007A:
            return true
        default:
            return false
        }
    }
}
