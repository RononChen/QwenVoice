import Foundation
import QwenVoiceCore

/// Post-generation output verification for bench/autorun lanes — transcribes a WAV
/// in-process (Speech, on-device) and scores language match + word error rate vs the
/// source script. Avoids CLI Speech TCC issues documented in benchmarks/OPTIMIZATION.md.
enum GenerationOutputVerifier {
    struct Result: Codable, Sendable, Equatable {
        var transcript: String
        var detectedLanguage: String
        var expectedLanguage: String
        var languageMatchScore: Double
        var wordErrorRate: Double
        var languagePass: Bool
        var accuracyPass: Bool
        var skipReason: String?

        var pass: Bool {
            languagePass && accuracyPass && skipReason == nil
        }
    }

    static func verify(
        audioURL: URL,
        expectedScript: String,
        expectedLanguage: Qwen3SupportedLanguage,
        maxWordErrorRate: Double = VoiceClipTranscriber.outputVerificationDefaultMaxWordErrorRate
    ) async -> Result {
        let expectedToken = expectedLanguage.rawValue

        switch VoiceClipTranscriber.availability() {
        case .denied, .siriDisabled:
            return skipped(expectedLanguage: expectedToken, reason: "speech_recognition_unavailable")
        case .notDetermined, .available:
            break
        }

        guard let transcription = await VoiceClipTranscriber.transcribe(url: audioURL) else {
            return failed(
                expectedLanguage: expectedToken,
                reason: "transcription_failed",
                transcript: "",
                detectedLanguage: Qwen3SupportedLanguage.auto.rawValue
            )
        }

        let detected = transcription.language == .auto
            ? PromptLanguageDetector.detect(transcription.text)
            : transcription.language
        let detectedToken = detected.rawValue
        let languageScore = VoiceClipTranscriber.languageMatchScore(
            text: transcription.text,
            expected: expectedLanguage
        )
        let languagePass = languageScore >= VoiceClipTranscriber.outputVerificationLanguagePassScore
        let wer = VoiceClipTranscriber.wordErrorRate(
            reference: expectedScript,
            hypothesis: transcription.text
        )
        let accuracyPass = wer <= maxWordErrorRate

        return Result(
            transcript: transcription.text,
            detectedLanguage: detectedToken,
            expectedLanguage: expectedToken,
            languageMatchScore: languageScore,
            wordErrorRate: wer,
            languagePass: languagePass,
            accuracyPass: accuracyPass,
            skipReason: nil
        )
    }

    private static func skipped(expectedLanguage: String, reason: String) -> Result {
        Result(
            transcript: "",
            detectedLanguage: Qwen3SupportedLanguage.auto.rawValue,
            expectedLanguage: expectedLanguage,
            languageMatchScore: 0,
            wordErrorRate: 1,
            languagePass: false,
            accuracyPass: false,
            skipReason: reason
        )
    }

    private static func failed(
        expectedLanguage: String,
        reason: String,
        transcript: String,
        detectedLanguage: String
    ) -> Result {
        Result(
            transcript: transcript,
            detectedLanguage: detectedLanguage,
            expectedLanguage: expectedLanguage,
            languageMatchScore: 0,
            wordErrorRate: 1,
            languagePass: false,
            accuracyPass: false,
            skipReason: reason
        )
    }
}
