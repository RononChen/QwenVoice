import CryptoKit
import Foundation

/// Complete schema-v9 streaming telemetry writer, validator, and privacy-safe
/// sidecar publisher.
///
/// Shipping JSONL rows remain schema v8 with a nested transition projection.
/// This type validates and publishes the complete v9 document when a producer
/// can supply every required domain, without inventing zeros for missing fields.
public enum GenerationStreamingTelemetryV9Publication: Sendable {
    public static let sidecarFileExtension = "streaming-telemetry-v9.json"
    public static let sessionIdentityVersion = 1
    public static let outputAdapterIdentityVersion = 1

    public enum PublicationError: Error, Equatable, Sendable {
        case validationFailed
        case writeFailed
        case transitionNotPublicationReady
    }

    /// Stable privacy-safe identity notes for the shipping actor session and
    /// product output adapter. Stamping these onto a generation row replaces
    /// stale "not shipping" unavailability reasons in the nested transition.
    public static var shippingIdentityNotes: [String: String] {
        [
            "streamingV9SessionDigest": identityDigest(
                namespace: "vocello.telemetry.v9.session",
                components: [
                    "VocelloQwen3ClassifiedGenerationSession",
                    String(sessionIdentityVersion),
                ]
            ),
            "streamingV9SessionVersion": String(sessionIdentityVersion),
            "streamingV9OutputAdapterDigest": identityDigest(
                namespace: "vocello.telemetry.v9.output-adapter",
                components: [
                    "GenerationOutputAdapter",
                    String(outputAdapterIdentityVersion),
                ]
            ),
            "streamingV9OutputAdapterVersion": String(outputAdapterIdentityVersion),
        ]
    }

    /// Unavailable reasons that do not block nested-v9 publication readiness.
    /// Layer-specific `notApplicable` entries and known non-shipping player /
    /// transport-list gaps must not prevent engine-domain readiness once the
    /// required producers observe their evidence.
    private static let nonBlockingUnavailableReasons: Set<GenerationStreamingUnavailableReasonV9> = [
        .notApplicable,
        .currentTransportStoresAggregateOnly,
        .currentPlayerHasNoRenderObservation,
        .currentFrontendStoresMillisecondsOnly,
    ]

    /// A transition is publication-ready when every required producer domain was
    /// observed. Non-blocking layer gaps (notApplicable / aggregate-only transport
    /// list / missing player render callback) may remain listed without inventing
    /// zeros.
    public static func isPublicationReady(
        _ transition: GenerationStreamingTelemetryTransitionV9
    ) -> Bool {
        let blockingUnavailable = transition.unavailable.filter {
            !nonBlockingUnavailableReasons.contains($0.reason)
        }
        return blockingUnavailable.isEmpty
            && transition.identities.plan != nil
            && transition.identities.sampling != nil
            && transition.identities.chunk != nil
            && transition.identities.memory != nil
            && transition.identities.outputPolicy != nil
            && transition.identities.qualityPolicy != nil
            && transition.identities.session != nil
            && transition.identities.outputAdapter != nil
            && transition.audioChannel != nil
            && transition.frameFlow.codecFramesGenerated != nil
            && transition.frameFlow.codecFramesMaterialized != nil
            && transition.frameFlow.audioFramesMaterialized != nil
            && transition.frameFlow.audioFramesWritten != nil
            && transition.frameFlow.audioFramesPreviewPublished != nil
            && transition.terminals.modelTerminalAtNS != nil
            && transition.terminals.productTerminalAtNS != nil
            && !transition.chunks.isEmpty
            && transition.chunks.allSatisfy {
                $0.codecStartFrame != nil && $0.codecEndFrameExclusive != nil
            }
    }

    public static func validate(_ document: GenerationStreamingTelemetryV9) throws {
        try document.validate()
    }

    /// Writes a complete v9 sidecar. Never embeds absolute paths, prompts, or
    /// private metadata in the document body.
    @discardableResult
    public static func publishSidecar(
        document: GenerationStreamingTelemetryV9,
        directory: URL
    ) throws -> URL {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw PublicationError.validationFailed
        }
        let url = directory.appendingPathComponent(
            "\(document.generationID.uuidString.lowercased()).\(sidecarFileExtension)"
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw PublicationError.writeFailed
        }
        return url
    }

    /// Fail-closed gate used by promotion tooling: refuse to treat a nested
    /// transition as a complete v9 publication when domains are still missing.
    public static func requirePublicationReady(
        _ transition: GenerationStreamingTelemetryTransitionV9
    ) throws {
        guard isPublicationReady(transition) else {
            throw PublicationError.transitionNotPublicationReady
        }
    }

    public static func identityDigest(namespace: String, components: [String]) -> String {
        let serialization = ([namespace] + components)
            .map { "\($0.utf8.count):\($0)" }
            .joined()
        return SHA256.hash(data: Data(serialization.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
