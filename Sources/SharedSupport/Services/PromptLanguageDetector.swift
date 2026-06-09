import Foundation
import NaturalLanguage
import QwenVoiceCore

/// Cheap, on-device language detection of **typed text** (no audio, no models) used to recommend
/// voices for the script the user is writing.
///
/// Uses NaturalLanguage's `NLLanguageRecognizer` — text-only, allocation-light, microseconds — so
/// called debounced on prompt edits it adds no noticeable CPU/RAM cost. Returns a Qwen3-TTS language
/// or `.auto` when the text is too short / ambiguous / not a supported language (→ nothing highlighted).
enum PromptLanguageDetector {
    /// Minimum trimmed length before attempting detection. CJK scripts clear the confidence floor on
    /// a few characters; short/ambiguous Latin text stays `.auto` (no false highlight).
    private static let minimumCharacters = 4
    /// Minimum top-hypothesis probability to accept a detection.
    private static let confidenceFloor = 0.65

    static func detect(_ text: String) -> Qwen3SupportedLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return .auto }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              top.value >= confidenceFloor else { return .auto }

        // Collapse to the base language code (handles zh-Hans/zh-Hant, pt-BR/pt-PT, etc.).
        let code = Locale(identifier: top.key.rawValue).language.languageCode?.identifier ?? top.key.rawValue
        return Qwen3SupportedLanguage.normalized(code)
    }
}
