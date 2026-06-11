import Foundation
import QwenVoiceCore

/// Shared presentation rules for the language selector across generation modes
/// (macOS `QwenLanguagePicker`, iOS Studio chips + `IOSQwenLanguagePickerSheet`).
///
/// Model: a stored selection of `.auto` means "follow detection" — the UI shows
/// the *effective* language (the detected one while following, else the pinned
/// pick). Picking a concrete language pins it; picking the Auto row resumes
/// following. Generation behavior is inherently consistent with this display:
/// `GenerationSemantics.qwenLanguageHint` resolves `.auto` through the same
/// `PromptLanguageDetector` at request time.
enum LanguageSelectionPresentation {
    /// The language the generation will effectively use, for display purposes.
    static func effective(
        selected: Qwen3SupportedLanguage,
        detected: Qwen3SupportedLanguage
    ) -> Qwen3SupportedLanguage {
        selected == .auto && detected != .auto ? detected : selected
    }

    /// What the closed selector (menu button / Studio chip) reads:
    /// "French (Auto)" while following a detection, "Auto" while following
    /// with nothing detected, the pinned language's name otherwise.
    static func buttonLabel(
        selected: Qwen3SupportedLanguage,
        detected: Qwen3SupportedLanguage
    ) -> String {
        guard selected == .auto else { return selected.displayName }
        guard detected != .auto else { return Qwen3SupportedLanguage.auto.displayName }
        return "\(detected.displayName) (Auto)"
    }
}
