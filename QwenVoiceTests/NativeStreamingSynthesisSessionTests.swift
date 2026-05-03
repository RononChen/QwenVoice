import Foundation
import XCTest
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@testable import QwenVoiceCore

/// Direct unit tests for `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`.
///
/// Constructed for Session 5c batch 7 of the QwenVoiceNativeRuntime
/// retirement. Until this file landed, the session's retention-flag
/// cleanup path (Tier 1.5 / 4.3) was only covered by
/// `NativeMLXMacEngineTests.testNativeMLXMacEngineCancellationCleansUp
/// StreamSessionArtifacts` driving the legacy NativeMLXMacEngine — when
/// the legacy module retires, that coverage moves here.
///
/// Tests construct a real `NativeStreamingSynthesisSession` (no mocks
/// of the session itself — those would prove nothing about the actual
/// cleanup invariants), drive it with a slow-streaming
/// `UnsafeSpeechGenerationModel`, and assert filesystem state after
/// cancellation.
@MainActor
final class NativeStreamingSynthesisSessionTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = try Self.makeTemporaryRoot()
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try await super.tearDown()
    }

    /// A producer-side error during streaming must trigger the
    /// retention-flag `defer` cleanup: the per-request session directory
    /// under `streamSessionsDirectory` and the (partially written) output
    /// WAV must both be removed before the error propagates out of
    /// `session.run`.
    ///
    /// This is the deterministic equivalent of the legacy
    /// `NativeMLXMacEngineTests.testNativeMLXMacEngineCancellationCleans
    /// UpStreamSessionArtifacts` regression. Cancellation propagation
    /// from outer-Task to the detached `execution.run` consumer is
    /// timing-sensitive (the for-await iterator only checkpoints after
    /// each event arrives, not while blocked on a producer sleep), so
    /// driving the same cleanup defer via a producer-side error gives
    /// the same cleanup-invariant coverage without flaky timing.
    func testStreamingProducerErrorCleansUpSessionDirectoryAndOutput() async throws {
        struct ProducerError: Error {}

        let sessionsRoot = temporaryRoot.appendingPathComponent("stream_sessions", isDirectory: true)
        let outputURL = temporaryRoot.appendingPathComponent("session-cleanup.wav")

        let model = UnsafeSpeechGenerationModel(
            sampleRate: 24_000,
            customPrewarmHandler: { _, _, _, _ in },
            customStreamHandler: { _, _, _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.audio(MLXArray([Float32(0.0), Float32(0.1)])))
                    continuation.yield(.audio(MLXArray([Float32(0.05), Float32(-0.05)])))
                    continuation.finish(throwing: ProducerError())
                }
            }
        )

        let request = GenerationRequest(
            modelID: "test_model",
            text: "Session cleanup",
            outputPath: outputURL.path,
            shouldStream: true,
            payload: .custom(speakerID: "vivian", deliveryStyle: nil)
        )

        let memoryPolicy = NativeMemoryPolicyResolver.policy(
            mode: .custom,
            isBatch: false
        )
        let session = NativeStreamingSynthesisSession(
            requestID: 1,
            request: request,
            model: model,
            streamSessionsDirectory: sessionsRoot,
            warmState: .cold,
            loadCapabilityProfile: .fullCapabilities,
            memoryPolicy: memoryPolicy,
            mlxMemorySnapshots: [:]
        )

        let expectedSessionDirectory = NativeStreamingSynthesisSession.sessionDirectoryURL(
            in: sessionsRoot,
            requestID: 1
        )

        var didThrow = false
        do {
            _ = try await session.run { _ in }
            XCTFail("Expected session.run to throw the producer error.")
        } catch is ProducerError {
            didThrow = true
        } catch {
            // Producer error wrapping is acceptable; the cleanup invariant
            // is what we're guarding here.
            didThrow = true
        }
        XCTAssertTrue(didThrow)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputURL.path),
            "Output WAV must not be left behind after a producer error."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expectedSessionDirectory.path),
            "Per-request session directory must be cleaned up after a producer error."
        )
        let leftoverContents = (try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot.path)) ?? []
        XCTAssertTrue(
            leftoverContents.isEmpty,
            "stream_sessions directory must be empty after a producer error, found: \(leftoverContents)"
        )
    }

    // MARK: - Helpers

    private static func makeTemporaryRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeStreamingSynthesisSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
