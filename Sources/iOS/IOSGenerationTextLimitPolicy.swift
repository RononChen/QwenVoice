import Foundation
import QwenVoiceCore

struct IOSGenerationTextLimitPolicy {
    private static let sharedScriptLimit = 150

    /// Voice Design BRIEF (the voice DESCRIPTION) limit — deliberately decoupled from the
    /// spoken-script limit above. Research on the official Qwen3-TTS VoiceDesign docs found no
    /// model-imposed description cap for the open-weights model; the hosted API caps voice_prompt
    /// at 2048 chars, and official example descriptions are short (one dense sentence, ~21–160
    /// chars). 500 fits 2–3 dense sentences with headroom while discouraging paragraph-length
    /// rambling the examples suggest is unnecessary. (The spoken-script limit stays 150.)
    static let descriptionLimit = 500

    struct State: Equatable {
        let count: Int
        let limit: Int
        let trimmedIsEmpty: Bool

        var remainingCount: Int {
            max(limit - count, 0)
        }

        var isOverLimit: Bool {
            count > limit
        }

        var counterText: String {
            "\(count)/\(limit)"
        }

        var helperMessage: String {
            if isOverLimit {
                return warningMessage
            }
            if remainingCount == 0 {
                return "At the on-device limit for this mode."
            }
            return "\(remainingCount) characters remaining for on-device generation."
        }

        var warningMessage: String {
            "Shorten the script to \(limit) characters or less for on-device generation."
        }

        var readinessTitle: String {
            "Shorten script to \(limit) chars"
        }
    }

    static func state(for text: String, mode: GenerationMode) -> State {
        State(
            count: text.count,
            limit: limit(for: mode),
            trimmedIsEmpty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    static func clamped(_ text: String, mode: GenerationMode) -> String {
        let limit = limit(for: mode)
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    static func limit(for mode: GenerationMode) -> Int {
        sharedScriptLimit
    }
}
