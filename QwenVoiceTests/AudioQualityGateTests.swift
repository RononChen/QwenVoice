import AVFoundation
import XCTest
@testable import QwenVoice

final class AudioQualityGateTests: XCTestCase {
    func testAudioQualityGatePassesHealthySpeechLikeWAV() throws {
        let url = try makeWAV(samples: Self.sineSamples(duration: 1.0, amplitude: 0.2))

        let report = AudioQualityGate.evaluate(url: url)

        XCTAssertTrue(report.passed, "Unexpected failures: \(report.requiredFailures)")
        XCTAssertTrue(report.requiredFailures.isEmpty)
        XCTAssertEqual(report.metrics["wav_readable.sample_rate"], 24_000)
    }

    func testAudioQualityGateFailsHeaderOnlyWAV() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("header_only_\(UUID().uuidString).wav")
        try Self.writeHeaderOnlyWAV(to: url)

        let report = AudioQualityGate.evaluate(url: url)

        XCTAssertFalse(report.passed)
        XCTAssertTrue(
            report.requiredFailures.contains("wav_readable")
                || report.requiredFailures.contains("final_file_container")
        )
    }

    func testAudioQualityGateFailsClippedAudio() throws {
        var samples = Self.sineSamples(duration: 1.0, amplitude: 0.2)
        samples[2_000] = 1.0
        let url = try makeWAV(samples: samples)

        let report = AudioQualityGate.evaluate(url: url)

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.requiredFailures.contains("clipping_detection"))
    }

    func testAudioQualityGateFailsSilentAudio() throws {
        let url = try makeWAV(samples: Array(repeating: 0, count: 24_000))

        let report = AudioQualityGate.evaluate(url: url)

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.requiredFailures.contains("final_non_silence"))
    }

    func testAudioQualityGateFailsAbruptDiscontinuity() throws {
        var samples = Self.sineSamples(duration: 1.0, amplitude: 0.1)
        samples[12_000] = -0.35
        samples[12_001] = 0.35
        let url = try makeWAV(samples: samples)

        let report = AudioQualityGate.evaluate(url: url)

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.requiredFailures.contains("final_abrupt_discontinuities"))
    }

    func testAudioQualityGateFailsInternalDropout() throws {
        var samples = Self.sineSamples(duration: 2.0, amplitude: 0.18)
        let start = 18_000
        let end = start + Int(0.85 * 24_000)
        for index in start..<end {
            samples[index] = 0
        }
        let url = try makeWAV(samples: samples)

        let report = AudioQualityGate.evaluate(url: url)

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.requiredFailures.contains("final_dropouts"))
    }

    private func makeWAV(samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_qc_\(UUID().uuidString).wav")
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 24_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
        return url
    }

    private static func sineSamples(duration: Double, amplitude: Float) -> [Float] {
        let sampleRate = 24_000
        let sampleCount = Int(duration * Double(sampleRate))
        return (0..<sampleCount).map { index in
            let phase = 2.0 * Double.pi * 220.0 * Double(index) / Double(sampleRate)
            return Float(sin(phase)) * amplitude
        }
    }

    private static func writeHeaderOnlyWAV(to url: URL) throws {
        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.append(UInt32(36).littleEndianData)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20])
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt32(24_000).littleEndianData)
        data.append(UInt32(48_000).littleEndianData)
        data.append(UInt16(2).littleEndianData)
        data.append(UInt16(16).littleEndianData)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.append(UInt32(0).littleEndianData)
        try data.write(to: url)
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
