import AVFoundation
import XCTest

final class PitchPreservingSpeechRateProcessorTests: XCTestCase {
    func testRateNormalizationClampsAndRoundsToTwoDecimalPlaces() {
        XCTAssertEqual(SpeechRateControl.normalized(-1), 0.01)
        XCTAssertEqual(SpeechRateControl.normalized(0.854), 0.85)
        XCTAssertEqual(SpeechRateControl.normalized(0.856), 0.86)
        XCTAssertEqual(SpeechRateControl.normalized(3), 2.50)
        XCTAssertEqual(SpeechRateControl.formatted(1), "1.00")
    }

    func testNormalRateIsABytePreservingBypass() async throws {
        let missingPath = "/private/tmp/vocello-normal-rate-bypass-does-not-open.wav"
        let result = try await PitchPreservingSpeechRateProcessor.finalize(
            audioPath: missingPath,
            originalDurationSeconds: 12.5,
            rate: 1.00
        )

        XCTAssertEqual(result.audioPath, missingPath)
        XCTAssertEqual(result.durationSeconds, 12.5)
        XCTAssertFalse(result.wasProcessed)
    }

    func testATempoFilterUsesOnlySupportedFactorsAndPreservesRequestedProduct() throws {
        XCTAssertEqual(
            try PitchPreservingSpeechRateProcessor.atempoFilter(for: 0.85),
            "atempo=0.85"
        )
        XCTAssertEqual(
            try PitchPreservingSpeechRateProcessor.atempoFilter(for: 2.50),
            "atempo=2.0,atempo=1.25"
        )

        let extreme = try PitchPreservingSpeechRateProcessor.atempoFilter(for: 0.01)
        let factors = extreme.split(separator: ",").compactMap { component -> Double? in
            Double(component.replacingOccurrences(of: "atempo=", with: ""))
        }
        XCTAssertFalse(factors.isEmpty)
        XCTAssertTrue(factors.allSatisfy { 0.5...2.0 ~= $0 })
        XCTAssertEqual(factors.reduce(1, *), 0.01, accuracy: 0.000_000_1)
    }

    func testPitchPreservingRateProducesExpectedDurationAndReadablePCM() async throws {
        guard PitchPreservingSpeechRateProcessor.isAvailable else {
            throw XCTSkip("FFmpeg is unavailable in this test host.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-speech-rate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for rate in [0.85, 2.50, 0.01] {
            let sourceDuration = rate == 0.01 ? 0.50 : 1.00
            let url = directory.appendingPathComponent("rate-\(rate).wav")
            try writeSineWave(to: url, durationSeconds: sourceDuration)

            let result = try await PitchPreservingSpeechRateProcessor.finalize(
                audioPath: url.path,
                originalDurationSeconds: sourceDuration,
                rate: rate
            )
            let file = try AVAudioFile(forReading: url)
            let expectedDuration = sourceDuration / rate

            XCTAssertTrue(result.wasProcessed)
            XCTAssertEqual(file.processingFormat.sampleRate, 24_000, accuracy: 0.5)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            XCTAssertEqual(
                result.durationSeconds,
                expectedDuration,
                accuracy: max(0.25, expectedDuration / 20)
            )
        }
    }

    private func writeSineWave(to url: URL, durationSeconds: Double) throws {
        let sampleRate = 24_000.0
        let frameCount = AVAudioFrameCount((durationSeconds * sampleRate).rounded())
        let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: frameCount
        )!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frameCount) {
            samples[index] = Float(
                sin(2 * Double.pi * 440 * Double(index) / sampleRate) * 0.25
            )
        }
        try file.write(from: buffer)
    }
}
