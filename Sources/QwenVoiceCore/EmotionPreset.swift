import Foundation

// Single source of truth for the delivery (tone/emotion) presets, shared by the
// macOS app, the iOS app, and the `vocello` CLI (bench/review delivery cells).
// Previously duplicated as Sources/Models/EmotionPreset.swift and
// Sources/iOSSupport/Models/EmotionPreset.swift, which had to be edited in
// lockstep; consolidated here so preset copy changes land once.

public struct DeliveryProfile: Equatable, Sendable {
    public static let neutralInstruction = "Neutral"

    public let presetID: String?
    public let customText: String?
    public let finalInstruction: String

    public init(
        presetID: String?,
        customText: String?,
        finalInstruction: String
    ) {
        self.presetID = presetID
        self.customText = customText
        self.finalInstruction = finalInstruction
    }

    public static let neutral = DeliveryProfile(
        presetID: "neutral",
        customText: nil,
        finalInstruction: neutralInstruction
    )

    public static func isNeutralInstruction(_ instruction: String) -> Bool {
        let normalized = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty
            || normalized == "normal tone"
            || normalized == "neutral"
            || normalized == "neutral tone"
    }

    public var trimmedInstruction: String {
        finalInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedCustomText: String? {
        customText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isNeutral: Bool {
        DeliveryProfile.isNeutralInstruction(trimmedInstruction)
    }

    public var isMeaningful: Bool {
        !isNeutral
    }

    public static func preset(_ preset: EmotionPreset) -> DeliveryProfile {
        DeliveryProfile(
            presetID: preset.id,
            customText: nil,
            finalInstruction: preset.instruction
        )
    }

    public static func custom(_ text: String) -> DeliveryProfile {
        DeliveryProfile(
            presetID: nil,
            customText: text,
            finalInstruction: text
        )
    }
}

public struct EmotionPreset: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let sfSymbol: String
    public let instruction: String

    public init(
        id: String,
        label: String,
        sfSymbol: String,
        instruction: String
    ) {
        self.id = id
        self.label = label
        self.sfSymbol = sfSymbol
        self.instruction = instruction
    }

    public static func preset(id: String?) -> EmotionPreset? {
        guard let id else { return nil }
        return all.first(where: { $0.id == id })
    }

    public static let all: [EmotionPreset] = [
        EmotionPreset(
            id: "neutral",
            label: "Neutral",
            sfSymbol: "face.dashed",
            instruction: DeliveryProfile.neutralInstruction
        ),
        EmotionPreset(
            id: "happy",
            label: "Happy",
            sfSymbol: "face.smiling",
            instruction: "Speaks happily and upbeat, with a bright, beaming tone, slightly lifted pitch, and a lively, bouncy pace; no laughing."
        ),
        EmotionPreset(
            id: "sad",
            label: "Sad",
            sfSymbol: "cloud.rain",
            instruction: "Speaks sadly and somberly, with a lowered pitch, slow weighted pace, and a fragile, restrained tone; keeps every word clear."
        ),
        EmotionPreset(
            id: "angry",
            label: "Angry",
            sfSymbol: "flame",
            instruction: "Speaks angrily and firmly, with sharp consonants, tight stress, and forceful tension; never breaks into a scream."
        ),
        EmotionPreset(
            id: "fearful",
            label: "Fearful",
            sfSymbol: "exclamationmark.triangle",
            instruction: "Speaks fearfully and anxiously, with a breathy, shaky voice, uncertain pacing, and a smaller, urgent tone; stays audible."
        ),
        EmotionPreset(
            id: "surprised",
            label: "Surprised",
            sfSymbol: "exclamationmark.2",
            instruction: "Speaks with unmistakable surprise, pitch jumping higher, pace quick and animated, stressing unexpected words; no gasping or extra sounds."
        ),
        EmotionPreset(
            id: "whisper",
            label: "Whisper",
            sfSymbol: "ear",
            instruction: "Whispers throughout, hushed and breathy, every word voiced just above breath, close and confidential; never lifted into normal speech."
        ),
        EmotionPreset(
            id: "dramatic",
            label: "Dramatic",
            sfSymbol: "theatermasks",
            instruction: "Speaks dramatically with heightened inflection, deliberate pacing, and bold stress on key words; generous, well-timed pauses command attention."
        ),
        EmotionPreset(
            id: "calm",
            label: "Calm",
            sfSymbol: "leaf",
            instruction: "Speaks calmly and soothingly, with smooth unhurried pacing, low settled pitch, and reassuring warmth."
        ),
        EmotionPreset(
            id: "excited",
            label: "Excited",
            sfSymbol: "sparkles",
            instruction: "Noticeably higher pitch and louder than normal, with a fast, driving, animated pace and a bright, ringing tone; no laughing or shouting."
        ),
        EmotionPreset(
            id: "narrator",
            label: "Narrator",
            sfSymbol: "text.book.closed",
            instruction: "Narrates like a composed documentary voice, with a low warm timbre, deliberate pacing, crisp diction, and gentle emphasis on key phrases."
        ),
        EmotionPreset(
            id: "news",
            label: "News",
            sfSymbol: "newspaper",
            instruction: "Speaks in a clear news broadcast style, with steady professional delivery, even pacing, precise articulation, and no dramatics."
        ),
    ]
}
