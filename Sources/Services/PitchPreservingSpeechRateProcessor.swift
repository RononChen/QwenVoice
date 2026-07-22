import AVFoundation
import Foundation

enum SpeechRateControl {
    static let minimum = 0.01
    static let maximum = 2.50
    static let normal = 1.00

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return normal }
        let clamped = min(max(value, minimum), maximum)
        return (clamped * 100).rounded() / 100
    }

    static func isNormal(_ value: Double) -> Bool {
        abs(normalized(value) - normal) < 0.000_1
    }

    static func formatted(_ value: Double) -> String {
        String(format: "%.2f", normalized(value))
    }
}

struct SpeechRateProcessingResult: Equatable, Sendable {
    let audioPath: String
    let durationSeconds: Double
    let outputFrameCount: Int64
    let wasProcessed: Bool
}

enum SpeechRateProcessingError: LocalizedError {
    case invalidRate
    case unreadableInput
    case unsupportedFormat
    case ffmpegUnavailable
    case ffmpegFailed
    case emptyOutput
    case unreadableOutput

    var errorDescription: String? {
        switch self {
        case .invalidRate:
            return "Speech rate must be between 0.01 and 2.50."
        case .unreadableInput:
            return "The generated audio could not be opened for speech-rate adjustment."
        case .unsupportedFormat:
            return "The generated audio format is not supported for speech-rate adjustment."
        case .ffmpegUnavailable:
            return "FFmpeg is required for high-quality speech-rate adjustment but was not found."
        case .ffmpegFailed:
            return "FFmpeg could not finish adjusting the speech rate."
        case .emptyOutput:
            return "Speech-rate adjustment produced an empty audio file."
        case .unreadableOutput:
            return "The adjusted audio file could not be verified."
        }
    }
}

/// Applies FFmpeg's pitch-preserving `atempo` filter to one completed WAV.
/// The process streams from the source to a staged file, so memory remains
/// bounded for long narration. The original is replaced only after the staged
/// PCM file passes format and duration validation.
enum PitchPreservingSpeechRateProcessor {
    private static let expectedSampleRate = 24_000
    private static let expectedChannelCount: AVAudioChannelCount = 1
    private static let minimumATempoFactor = 0.5
    private static let maximumATempoFactor = 2.0

    static var isAvailable: Bool {
        resolvedFFmpegExecutableURL() != nil
    }

    static func finalize(
        audioPath: String,
        originalDurationSeconds: Double,
        rate requestedRate: Double
    ) async throws -> SpeechRateProcessingResult {
        let rate = SpeechRateControl.normalized(requestedRate)
        guard rate >= SpeechRateControl.minimum, rate <= SpeechRateControl.maximum else {
            throw SpeechRateProcessingError.invalidRate
        }
        guard !SpeechRateControl.isNormal(rate) else {
            return SpeechRateProcessingResult(
                audioPath: audioPath,
                durationSeconds: originalDurationSeconds,
                outputFrameCount: 0,
                wasProcessed: false
            )
        }

        return try await withThrowingTaskGroup(of: SpeechRateProcessingResult.self) { group in
            group.addTask(priority: .utility) {
                try processSynchronously(
                    audioURL: URL(fileURLWithPath: audioPath),
                    rate: rate
                )
            }
            guard let result = try await group.next() else {
                throw SpeechRateProcessingError.ffmpegFailed
            }
            group.cancelAll()
            return result
        }
    }

    static func atempoFilter(for requestedRate: Double) throws -> String {
        let rate = SpeechRateControl.normalized(requestedRate)
        guard rate.isFinite,
              rate >= SpeechRateControl.minimum,
              rate <= SpeechRateControl.maximum else {
            throw SpeechRateProcessingError.invalidRate
        }

        var remaining = rate
        var factors: [Double] = []
        while remaining < minimumATempoFactor {
            factors.append(minimumATempoFactor)
            remaining /= minimumATempoFactor
        }
        while remaining > maximumATempoFactor {
            factors.append(maximumATempoFactor)
            remaining /= maximumATempoFactor
        }
        if abs(remaining - 1.0) > 0.000_000_1 || factors.isEmpty {
            factors.append(remaining)
        }

        return factors
            .map { "atempo=\(posixDecimal($0))" }
            .joined(separator: ",")
    }

    private static func processSynchronously(
        audioURL: URL,
        rate: Double
    ) throws -> SpeechRateProcessingResult {
        try Task.checkCancellation()
        guard let executableURL = resolvedFFmpegExecutableURL() else {
            throw SpeechRateProcessingError.ffmpegUnavailable
        }

        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw SpeechRateProcessingError.unreadableInput
        }
        let inputDescription = inputFile.fileFormat.streamDescription.pointee
        guard inputFile.length > 0,
              Int(inputDescription.mSampleRate.rounded()) == expectedSampleRate,
              inputDescription.mChannelsPerFrame == expectedChannelCount,
              inputDescription.mFormatID == kAudioFormatLinearPCM else {
            throw SpeechRateProcessingError.unsupportedFormat
        }

        let expectedOutputFrameCount = max(
            Int64(1),
            Int64((Double(inputFile.length) / rate).rounded())
        )
        let temporaryURL = stagingURL(for: audioURL)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: temporaryURL)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", audioURL.path,
            "-filter:a", try atempoFilter(for: rate),
            "-ar", String(expectedSampleRate),
            "-ac", String(expectedChannelCount),
            "-c:a", "pcm_s16le",
            temporaryURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw SpeechRateProcessingError.ffmpegUnavailable
        }
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        while process.isRunning {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw SpeechRateProcessingError.ffmpegFailed
        }

        synchronizeFile(at: temporaryURL)
        guard let stagedFile = try? AVAudioFile(forReading: temporaryURL),
              stagedFile.length > 0 else {
            throw SpeechRateProcessingError.emptyOutput
        }
        let stagedDescription = stagedFile.fileFormat.streamDescription.pointee
        let durationToleranceFrames = max(
            Int64(expectedSampleRate / 4),
            // Every chained atempo stage has a small finite-window tail loss.
            // It is negligible at narration lengths, but compounds for the
            // deliberately supported 0.01 extreme on very short fixtures.
            expectedOutputFrameCount / 20
        )
        guard Int(stagedDescription.mSampleRate.rounded()) == expectedSampleRate,
              stagedDescription.mChannelsPerFrame == expectedChannelCount,
              stagedDescription.mFormatID == kAudioFormatLinearPCM,
              stagedDescription.mBitsPerChannel == 16,
              abs(stagedFile.length - expectedOutputFrameCount) <= durationToleranceFrames else {
            throw SpeechRateProcessingError.unreadableOutput
        }

        try publishAtomically(temporaryURL: temporaryURL, finalURL: audioURL)

        guard let publishedFile = try? AVAudioFile(forReading: audioURL),
              publishedFile.length == stagedFile.length else {
            throw SpeechRateProcessingError.unreadableOutput
        }

        return SpeechRateProcessingResult(
            audioPath: audioURL.path,
            durationSeconds: Double(publishedFile.length) / publishedFile.processingFormat.sampleRate,
            outputFrameCount: publishedFile.length,
            wasProcessed: true
        )
    }

    private static func resolvedFFmpegExecutableURL() -> URL? {
        // Production releases carry the separately built, separately signed
        // LGPL-only helper outside Resources. Local package-manager paths are
        // retained only as a developer fallback for ordinary Xcode builds.
        var candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("ffmpeg-vocello", isDirectory: false),
        ]
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            URL(fileURLWithPath: "/opt/local/bin/ffmpeg"),
        ])

        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    }

    private static func posixDecimal(_ value: Double) -> String {
        var text = String(
            format: "%.10f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.append("0") }
        return text
    }

    private static func stagingURL(for finalURL: URL) -> URL {
        let stem = finalURL.deletingPathExtension().lastPathComponent
        let pathExtension = finalURL.pathExtension.isEmpty ? "wav" : finalURL.pathExtension
        return finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(stem).\(UUID().uuidString).speech-rate.tmp.\(pathExtension)"
        )
    }

    private static func synchronizeFile(at url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.synchronize()
        try? handle.close()
    }

    private static func publishAtomically(temporaryURL: URL, finalURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(
                finalURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        }
    }
}
