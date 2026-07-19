import Foundation
@testable import QwenVoiceCore
import VocelloQwen3Core
import XCTest

final class AtomicWAVGenerationOutputSinkTests: XCTestCase {
    func testSinkPublishesOnlyAfterPersistedFastQCPasses() async throws {
        let outputURL = temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let sink = try AtomicWAVGenerationOutputSink(
            outputURL: outputURL,
            sampleRate: 24_000,
            expectedPauseCount: 0
        )
        let samples = (0 ..< 4_800).map { index in
            Float(sin(2 * Double.pi * 220 * Double(index) / 24_000) * 0.2)
        }
        let chunk = VocelloQwen3AudioChunkEvent(
            generationID: UUID(),
            sequence: 0,
            samples: samples,
            sampleRate: 24_000
        )

        let preview = try await sink.consume(chunk)
        XCTAssertEqual(preview.frameCount, samples.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        let disposition = try await sink.finalize(modelTerminal: terminal(
            generationID: chunk.generationID,
            frameCount: samples.count
        ))
        let outputResult = await sink.result()
        let result = try XCTUnwrap(outputResult)
        XCTAssertEqual(disposition, .published)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(result.frameCount, samples.count)
        XCTAssertNotEqual(result.audioQC.verdict, .fail)

        let repeated = try await sink.finalize(modelTerminal: terminal(
            generationID: chunk.generationID,
            frameCount: samples.count
        ))
        XCTAssertEqual(repeated, .published)
        do {
            _ = try await sink.finalize(modelTerminal: terminal(
                generationID: UUID(),
                frameCount: samples.count
            ))
            XCTFail("a conflicting repeated terminal must not reuse publication")
        } catch {
            XCTAssertEqual(
                error as? AtomicWAVGenerationOutputSinkError,
                .generationIdentityMismatch
            )
        }
    }

    func testSinkRejectsUnstableOutputBeforePublication() async throws {
        let outputURL = temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let sink = try AtomicWAVGenerationOutputSink(
            outputURL: outputURL,
            sampleRate: 24_000,
            expectedPauseCount: 0
        )
        let chunk = VocelloQwen3AudioChunkEvent(
            generationID: UUID(),
            sequence: 0,
            samples: [Float.nan] + Array(repeating: Float(0.2), count: 4_799),
            sampleRate: 24_000
        )
        _ = try await sink.consume(chunk)

        do {
            _ = try await sink.finalize(modelTerminal: terminal(
                generationID: chunk.generationID,
                frameCount: chunk.frameCount
            ))
            XCTFail("non-finite model output must fail Fast QC")
        } catch {
            XCTAssertEqual(error as? AtomicWAVGenerationOutputSinkError, .fastQCFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testSinkRejectsCrossGenerationAndNonContiguousChunks() async throws {
        let outputURL = temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let sink = try AtomicWAVGenerationOutputSink(
            outputURL: outputURL,
            sampleRate: 24_000,
            expectedPauseCount: 0
        )
        let generationID = UUID()
        _ = try await sink.consume(VocelloQwen3AudioChunkEvent(
            generationID: generationID,
            sequence: 0,
            samples: Array(repeating: 0.1, count: 2_400),
            sampleRate: 24_000
        ))

        do {
            _ = try await sink.consume(VocelloQwen3AudioChunkEvent(
                generationID: generationID,
                sequence: 2,
                samples: Array(repeating: 0.1, count: 2_400),
                sampleRate: 24_000
            ))
            XCTFail("a sequence gap must fail before publication")
        } catch {
            XCTAssertEqual(
                error as? AtomicWAVGenerationOutputSinkError,
                .nonContiguousSequence(expected: 1, actual: 2)
            )
        }
        do {
            _ = try await sink.consume(VocelloQwen3AudioChunkEvent(
                generationID: UUID(),
                sequence: 1,
                samples: Array(repeating: 0.1, count: 2_400),
                sampleRate: 24_000
            ))
            XCTFail("a cross-generation chunk must fail before publication")
        } catch {
            XCTAssertEqual(
                error as? AtomicWAVGenerationOutputSinkError,
                .generationIdentityMismatch
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testSinkRejectsTerminalFrameCountMismatch() async throws {
        let outputURL = temporaryOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let sink = try AtomicWAVGenerationOutputSink(
            outputURL: outputURL,
            sampleRate: 24_000,
            expectedPauseCount: 0
        )
        let generationID = UUID()
        _ = try await sink.consume(VocelloQwen3AudioChunkEvent(
            generationID: generationID,
            sequence: 0,
            samples: Array(repeating: 0.1, count: 4_800),
            sampleRate: 24_000
        ))

        do {
            _ = try await sink.finalize(modelTerminal: terminal(
                generationID: generationID,
                frameCount: 4_799
            ))
            XCTFail("terminal frame-count drift must fail before publication")
        } catch {
            XCTAssertEqual(
                error as? AtomicWAVGenerationOutputSinkError,
                .terminalFrameCountMismatch(expected: 4_800, actual: 4_799)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private func temporaryOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-output-sink-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("output.wav")
    }

    private func terminal(
        generationID: UUID,
        frameCount: Int
    ) -> VocelloQwen3TerminalEvent {
        VocelloQwen3TerminalEvent(
            generationID: generationID,
            outcome: .completed(.endOfSequence),
            generatedTokenCount: 10,
            emittedAudioFrameCount: frameCount,
            elapsedMilliseconds: 100
        )
    }
}
