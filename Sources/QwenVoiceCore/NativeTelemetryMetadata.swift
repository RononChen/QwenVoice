import Foundation

/// Strongly-typed metadata for a `NativeTelemetryStageMark`.
///
/// Concrete types convert to/from the wire-format `[String: String]` dictionary
/// so the JSONL output stays human-readable and backward-compatible, while
/// Swift call sites get compile-time safety and avoid string-key drift.
public protocol NativeTelemetryMetadata: Sendable {
    /// The `stage` value this metadata is associated with.
    static var stage: String { get }

    /// Decode from the wire-format dictionary stored on a stage mark.
    init?(dictionary: [String: String])

    /// Encode to the wire-format dictionary stored on a stage mark.
    var dictionaryRepresentation: [String: String] { get }
}

extension NativeTelemetryStageMark {
    /// Attempt to interpret the wire-format metadata as a typed value.
    public func typedMetadata<T: NativeTelemetryMetadata>(as type: T.Type) -> T? {
        T(dictionary: metadata)
    }
}

extension NativeTelemetryRecorder {
    /// Record a stage mark with strongly-typed metadata.
    public func mark<T: NativeTelemetryMetadata>(metadata: T) {
        mark(stage: T.stage, metadata: metadata.dictionaryRepresentation)
    }
}

// MARK: - Memory lifecycle

public struct MemoryTrimMetadata: NativeTelemetryMetadata {
    public static let stage = "memory_trim"

    public let level: NativeMemoryTrimLevel
    public let reason: String

    public init(level: NativeMemoryTrimLevel, reason: String) {
        self.level = level
        self.reason = reason
    }

    public init?(dictionary: [String: String]) {
        guard let levelRaw = dictionary["level"],
              let level = NativeMemoryTrimLevel(rawValue: levelRaw) else {
            return nil
        }
        self.level = level
        self.reason = dictionary["reason"] ?? ""
    }

    public var dictionaryRepresentation: [String: String] {
        [
            "level": level.rawValue,
            "reason": reason,
        ]
    }
}

public struct MemoryPressureMetadata: NativeTelemetryMetadata {
    public static let stage = "memory_pressure"

    public let level: NativeMemoryTrimLevel

    public init(level: NativeMemoryTrimLevel) {
        self.level = level
    }

    public init?(dictionary: [String: String]) {
        guard let levelRaw = dictionary["level"],
              let level = NativeMemoryTrimLevel(rawValue: levelRaw) else {
            return nil
        }
        self.level = level
    }

    public var dictionaryRepresentation: [String: String] {
        ["level": level.rawValue]
    }
}

// MARK: - Model loading

public struct ModelSwitchCacheClearMetadata: NativeTelemetryMetadata {
    public static let stage = "model_switch_cache_clear"

    public let fromModelID: String
    public let toModelID: String
    public let capabilityProfile: NativeLoadCapabilityProfile

    public init(
        fromModelID: String,
        toModelID: String,
        capabilityProfile: NativeLoadCapabilityProfile
    ) {
        self.fromModelID = fromModelID
        self.toModelID = toModelID
        self.capabilityProfile = capabilityProfile
    }

    public init?(dictionary: [String: String]) {
        guard let fromModelID = dictionary["fromModelID"],
              let toModelID = dictionary["toModelID"],
              let profileRaw = dictionary["nativeLoadCapabilityProfile"],
              let capabilityProfile = NativeLoadCapabilityProfile(rawValue: profileRaw) else {
            return nil
        }
        self.fromModelID = fromModelID
        self.toModelID = toModelID
        self.capabilityProfile = capabilityProfile
    }

    public var dictionaryRepresentation: [String: String] {
        [
            "fromModelID": fromModelID,
            "toModelID": toModelID,
            "nativeLoadCapabilityProfile": capabilityProfile.rawValue,
        ]
    }
}

// MARK: - Streaming generation

public struct FirstChunkMetadata: NativeTelemetryMetadata {
    public static let stage = NativeRuntimeStage.firstChunk.rawValue

    public let chunkIndex: Int

    public init(chunkIndex: Int) {
        self.chunkIndex = chunkIndex
    }

    public init?(dictionary: [String: String]) {
        guard let indexString = dictionary["chunk_index"],
              let chunkIndex = Int(indexString) else {
            return nil
        }
        self.chunkIndex = chunkIndex
    }

    public var dictionaryRepresentation: [String: String] {
        ["chunk_index": String(chunkIndex)]
    }
}

public struct StreamFailureMessageMetadata: NativeTelemetryMetadata {
    public static let stage = NativeRuntimeStage.streamFailed.rawValue

    public let messageLength: Int
    public let messageDigest: String

    public init(message: String) {
        let notes = GenerationTelemetryPrivacy.failureNotes(message: message)
        self.messageLength = Int(notes["failureMessageLength"] ?? "") ?? message.count
        self.messageDigest = notes["failureMessageDigest"] ?? ""
    }

    public init?(dictionary: [String: String]) {
        if let length = dictionary["message_length"].flatMap(Int.init),
           let digest = dictionary["message_digest"], !digest.isEmpty {
            self.messageLength = length
            self.messageDigest = digest
            return
        }
        // Decode legacy metadata without preserving the raw message on re-encode.
        guard let message = dictionary["message"] else {
            return nil
        }
        let notes = GenerationTelemetryPrivacy.failureNotes(message: message)
        self.messageLength = Int(notes["failureMessageLength"] ?? "") ?? message.count
        self.messageDigest = notes["failureMessageDigest"] ?? ""
    }

    public var dictionaryRepresentation: [String: String] {
        [
            "message_length": String(messageLength),
            "message_digest": messageDigest,
        ]
    }
}

public struct StreamFailureFinishReasonMetadata: NativeTelemetryMetadata {
    public static let stage = NativeRuntimeStage.streamFailed.rawValue

    public let finishReason: GenerationFinishReason

    public init(finishReason: GenerationFinishReason) {
        self.finishReason = finishReason
    }

    public init?(dictionary: [String: String]) {
        guard let reasonRaw = dictionary["finish_reason"],
              let finishReason = GenerationFinishReason(rawValue: reasonRaw) else {
            return nil
        }
        self.finishReason = finishReason
    }

    public var dictionaryRepresentation: [String: String] {
        ["finish_reason": finishReason.rawValue]
    }
}
