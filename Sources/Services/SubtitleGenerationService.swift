@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Observation
import QwenVoiceCore
import QwenVoiceNative
import Synchronization
import whisper

enum SubtitleModelDescriptor {
    static let displayName = "Whisper large-v3 turbo Q5"
    static let huggingFaceRepo = "ggerganov/whisper.cpp"
    static let fileName = "ggml-large-v3-turbo-q5_0.bin"
    static let byteCount: Int64 = 574_041_195
    static let sha256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    static let sourceRevision = "98aa99a0a9db05ae2342309f5096248665f7cba3"
    static let downloadURL = URL(
        string: "https://huggingface.co/\(huggingFaceRepo)/resolve/\(sourceRevision)/\(fileName)?download=true"
    )!
    static let manualDownloadPageURL = URL(
        string: "https://huggingface.co/\(huggingFaceRepo)/blob/\(sourceRevision)/\(fileName)"
    )!

    static var installedURL: URL {
        AppPaths.subtitleModelsDir.appendingPathComponent(fileName, isDirectory: false)
    }
}

enum SubtitleModelError: LocalizedError {
    case unavailable
    case wrongFileSize(expected: Int64, actual: Int64)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Install the subtitle model before generating SRT."
        case .wrongFileSize(let expected, let actual):
            return "The subtitle model download is incomplete (\(actual) of \(expected) bytes)."
        case .checksumMismatch:
            return "The subtitle model failed its integrity check. Download it again."
        }
    }
}

actor SubtitleModelRepository {
    static let shared = SubtitleModelRepository()

    private var installationTask: Task<URL, Error>?

    func installedModelURL() async throws -> URL {
        let url = SubtitleModelDescriptor.installedURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SubtitleModelError.unavailable
        }
        guard try Self.fileSize(at: url) == SubtitleModelDescriptor.byteCount,
              try Self.sha256(of: url) == SubtitleModelDescriptor.sha256 else {
            throw SubtitleModelError.unavailable
        }
        return url
    }

    func isInstalled() async -> Bool {
        (try? await installedModelURL()) != nil
    }

    func install() async throws -> URL {
        if let installed = try? await installedModelURL() {
            return installed
        }
        if let installationTask {
            return try await installationTask.value
        }

        let task = Task.detached(priority: .utility) {
            try await Self.downloadAndInstall()
        }
        installationTask = task
        defer { installationTask = nil }
        return try await task.value
    }

    func importModel(from sourceURL: URL) async throws -> URL {
        if let installationTask {
            return try await installationTask.value
        }

        let task = Task.detached(priority: .utility) {
            try Self.importAndInstall(from: sourceURL)
        }
        installationTask = task
        defer { installationTask = nil }
        return try await task.value
    }

    private nonisolated static func downloadAndInstall() async throws -> URL {
        let fileManager = FileManager.default
        let directory = AppPaths.subtitleModelsDir
        let downloader = HuggingFaceDownloader(progressHandler: nil)
        try await downloader.downloadFiles(
            [
                HuggingFaceDownloader.RepoFile(
                    path: SubtitleModelDescriptor.fileName,
                    size: SubtitleModelDescriptor.byteCount,
                    sha256: SubtitleModelDescriptor.sha256,
                    absoluteURL: SubtitleModelDescriptor.downloadURL
                )
            ],
            repo: SubtitleModelDescriptor.huggingFaceRepo,
            revision: SubtitleModelDescriptor.sourceRevision,
            to: directory,
            requestIdentity: ModelDownloadRequestIdentity(
                logicalRequestID: UUID().uuidString,
                modelID: "whisper-large-v3-turbo-q5",
                artifactVersion: SubtitleModelDescriptor.sourceRevision
            )
        )

        let destination = SubtitleModelDescriptor.installedURL
        let actualSize = try fileSize(at: destination)
        guard actualSize == SubtitleModelDescriptor.byteCount else {
            throw SubtitleModelError.wrongFileSize(
                expected: SubtitleModelDescriptor.byteCount,
                actual: actualSize
            )
        }
        guard try sha256(of: destination) == SubtitleModelDescriptor.sha256 else {
            throw SubtitleModelError.checksumMismatch
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        AppPaths.excludeFromBackup(directory)
        AppPaths.excludeFromBackup(destination)
        return destination
    }

    private nonisolated static func importAndInstall(from sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let destination = SubtitleModelDescriptor.installedURL
        if sourceURL.standardizedFileURL == destination.standardizedFileURL {
            let actualSize = try fileSize(at: sourceURL)
            guard actualSize == SubtitleModelDescriptor.byteCount else {
                throw SubtitleModelError.wrongFileSize(
                    expected: SubtitleModelDescriptor.byteCount,
                    actual: actualSize
                )
            }
            guard try sha256(of: sourceURL) == SubtitleModelDescriptor.sha256 else {
                throw SubtitleModelError.checksumMismatch
            }
            return destination
        }

        let directory = AppPaths.subtitleModelsDir
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        AppPaths.excludeFromBackup(directory)
        let stagingURL = directory.appendingPathComponent(
            ".\(SubtitleModelDescriptor.fileName).\(UUID().uuidString).import",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)

        let actualSize = try fileSize(at: stagingURL)
        guard actualSize == SubtitleModelDescriptor.byteCount else {
            throw SubtitleModelError.wrongFileSize(
                expected: SubtitleModelDescriptor.byteCount,
                actual: actualSize
            )
        }
        guard try sha256(of: stagingURL) == SubtitleModelDescriptor.sha256 else {
            throw SubtitleModelError.checksumMismatch
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destination)
        }
        AppPaths.excludeFromBackup(destination)
        return destination
    }

    private nonisolated static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class SubtitleModelManager {
    enum State: Equatable {
        case checking
        case notInstalled
        case downloading
        case ready
        case failed(String)
    }

    static let shared = SubtitleModelManager()

    private(set) var state: State = .checking
    @ObservationIgnored private var installationTask: Task<Void, Never>?

    var isReady: Bool {
        state == .ready
    }

    var isBusy: Bool {
        state == .checking || state == .downloading
    }

    private init() {
        refresh()
    }

    func refresh() {
        guard installationTask == nil else { return }
        state = .checking
        installationTask = Task {
            let installed = await SubtitleModelRepository.shared.isInstalled()
            guard !Task.isCancelled else { return }
            state = installed ? .ready : .notInstalled
            installationTask = nil
        }
    }

    func install() {
        guard installationTask == nil, !isReady else { return }
        state = .downloading
        installationTask = Task {
            do {
                _ = try await SubtitleModelRepository.shared.install()
                guard !Task.isCancelled else { return }
                state = .ready
            } catch is CancellationError {
                state = .notInstalled
            } catch {
                state = .failed(error.localizedDescription)
            }
            installationTask = nil
        }
    }

    func importModel(from sourceURL: URL) {
        guard installationTask == nil else { return }
        state = .checking
        installationTask = Task {
            let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                installationTask = nil
            }
            do {
                _ = try await SubtitleModelRepository.shared.importModel(from: sourceURL)
                guard !Task.isCancelled else { return }
                state = .ready
            } catch is CancellationError {
                state = .notInstalled
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct SubtitleTranscriptionSegment: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct SubtitleCue: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

enum SubtitleGenerationError: LocalizedError {
    case audioFormat
    case modelInitialization
    case transcriptionFailed(code: Int32)
    case noSpeechRecognized
    case emptyScript

    var errorDescription: String? {
        switch self {
        case .audioFormat:
            return "The final WAV could not be converted for subtitle recognition."
        case .modelInitialization:
            return "The subtitle recognition model could not be loaded."
        case .transcriptionFailed(let code):
            return "Subtitle recognition failed (code \(code))."
        case .noSpeechRecognized:
            return "No usable speech was recognized in the final WAV."
        case .emptyScript:
            return "The script is empty, so an SRT file cannot be created."
        }
    }
}

actor SubtitleGenerationService {
    static let shared = SubtitleGenerationService()

    private static let recognitionSampleRate = 16_000.0
    private static let chunkDuration: TimeInterval = 10 * 60
    private static let overlapDuration: TimeInterval = 2

    func generateSRT(
        script: String,
        audioURL: URL,
        language: Qwen3SupportedLanguage
    ) async throws -> URL {
        try Task.checkCancellation()
        let modelURL = try await SubtitleModelRepository.shared.installedModelURL()
        let chunks = SubtitleAlignment.subtitleChunks(script)
        guard !chunks.isEmpty else { throw SubtitleGenerationError.emptyScript }

        guard let context = Self.makeContext(modelURL: modelURL) else {
            throw SubtitleGenerationError.modelInitialization
        }
        defer { whisper_free(context) }

        let audio = try AVAudioFile(forReading: audioURL)
        let sourceSampleRate = audio.processingFormat.sampleRate
        guard sourceSampleRate > 0 else { throw SubtitleGenerationError.audioFormat }
        let duration = Double(audio.length) / sourceSampleRate
        let segments = try Self.transcribe(
            audio: audio,
            duration: duration,
            context: context,
            languageCode: Self.whisperLanguageCode(language)
        )
        guard !segments.isEmpty else { throw SubtitleGenerationError.noSpeechRecognized }

        let cues = SubtitleAlignment.alignedCues(
            chunks: chunks,
            segments: segments,
            audioDuration: duration
        )
        let destination = audioURL.deletingPathExtension().appendingPathExtension("srt")
        try SubtitleAlignment.writeSRT(cues, to: destination)
        return destination
    }

    private static func makeContext(modelURL: URL) -> OpaquePointer? {
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        return whisper_init_from_file_with_params(modelURL.path, params)
    }

    private static func transcribe(
        audio: AVAudioFile,
        duration: TimeInterval,
        context: OpaquePointer,
        languageCode: String?
    ) throws -> [SubtitleTranscriptionSegment] {
        var output: [SubtitleTranscriptionSegment] = []
        var uniqueStart: TimeInterval = 0

        while uniqueStart < duration {
            try Task.checkCancellation()
            let readStart = max(0, uniqueStart - (uniqueStart > 0 ? overlapDuration : 0))
            let readEnd = min(duration, uniqueStart + chunkDuration)
            let samples = try readMono16K(audio: audio, start: readStart, end: readEnd)
            guard !samples.isEmpty else { break }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.translate = false
            params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            params.offset_ms = 0
            params.no_context = true
            params.no_timestamps = false
            params.single_segment = false
            params.temperature = 0
            params.greedy.best_of = 1

            let resultCode: Int32
            if let languageCode {
                resultCode = languageCode.withCString { languagePointer in
                    params.language = languagePointer
                    return samples.withUnsafeBufferPointer { buffer in
                        whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                    }
                }
            } else {
                params.language = nil
                resultCode = samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
            guard resultCode == 0 else {
                throw SubtitleGenerationError.transcriptionFailed(code: resultCode)
            }

            let segmentCount = whisper_full_n_segments(context)
            for index in 0..<segmentCount {
                let text = String(cString: whisper_full_get_segment_text(context, index))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = readStart + Double(whisper_full_get_segment_t0(context, index)) * 0.01
                let end = readStart + Double(whisper_full_get_segment_t1(context, index)) * 0.01
                if uniqueStart > 0, (start + end) / 2 < uniqueStart {
                    continue
                }
                output.append(
                    SubtitleTranscriptionSegment(
                        text: text,
                        start: max(uniqueStart, start),
                        end: min(duration, max(start + 0.05, end))
                    )
                )
            }

            uniqueStart = readEnd
        }
        return output
    }

    private static func readMono16K(
        audio: AVAudioFile,
        start: TimeInterval,
        end: TimeInterval
    ) throws -> [Float] {
        let inputFormat = audio.processingFormat
        let startFrame = AVAudioFramePosition(start * inputFormat.sampleRate)
        let requestedFrames = max(
            0,
            AVAudioFramePosition((end - start) * inputFormat.sampleRate)
        )
        guard requestedFrames > 0,
              requestedFrames <= AVAudioFramePosition(UInt32.max),
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(requestedFrames)
              ),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: recognitionSampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SubtitleGenerationError.audioFormat
        }

        audio.framePosition = startFrame
        try audio.read(into: inputBuffer, frameCount: AVAudioFrameCount(requestedFrames))
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * recognitionSampleRate / inputFormat.sampleRate)
        ) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw SubtitleGenerationError.audioFormat
        }

        let suppliedInput = Mutex(false)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            let shouldSupply = suppliedInput.withLock { supplied in
                if supplied { return false }
                supplied = true
                return true
            }
            if !shouldSupply {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil,
              status != .error,
              let channel = outputBuffer.floatChannelData?[0] else {
            throw conversionError ?? SubtitleGenerationError.audioFormat
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }

    private static func whisperLanguageCode(_ language: Qwen3SupportedLanguage) -> String? {
        switch language {
        case .auto: return nil
        case .chinese: return "zh"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .german: return "de"
        case .french: return "fr"
        case .russian: return "ru"
        case .portuguese: return "pt"
        case .spanish: return "es"
        case .italian: return "it"
        }
    }
}

@MainActor
enum SubtitlePostProcessor {
    static func generateIfRequested(
        _ isRequested: Bool,
        script: String,
        audioPath: String,
        language: Qwen3SupportedLanguage,
        engineStore: TTSEngineStore
    ) async -> String? {
        guard isRequested else { return nil }
        do {
            // Release the multi-gigabyte TTS model before loading Whisper.
            // This keeps the optional post-processing stage comfortable on
            // the documented 16 GB baseline.
            try? await engineStore.unloadModel()
            _ = try await SubtitleGenerationService.shared.generateSRT(
                script: script,
                audioURL: URL(fileURLWithPath: audioPath),
                language: language
            )
            return nil
        } catch {
            return AppLocalization.format(
                "The WAV was saved, but SRT generation failed: %@",
                error.localizedDescription
            )
        }
    }
}

enum SubtitleAlignment {
    private static let sentenceTerminators: Set<Character> = [
        "。", "！", "？", "!", "?", "；", ";", ".",
    ]
    private static let softTerminators: Set<Character> = [
        "，", "、", "：", ":", ",", " ",
    ]

    static func subtitleChunks(
        _ script: String,
        minimumCharacters: Int = 12,
        maximumCharacters: Int = 32
    ) -> [String] {
        let cleaned = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var rawChunks: [String] = []
        var current = ""
        var lastSoftBoundary: String.Index?

        func flush(_ count: Int? = nil) {
            let splitIndex: String.Index
            if let count {
                splitIndex = current.index(current.startIndex, offsetBy: count)
            } else {
                splitIndex = current.endIndex
            }
            let prefix = String(current[..<splitIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { rawChunks.append(prefix) }
            current = String(current[splitIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lastSoftBoundary = nil
            for index in current.indices where softTerminators.contains(current[index]) {
                lastSoftBoundary = current.index(after: index)
            }
        }

        for character in cleaned {
            if character == "\n" {
                if !current.isEmpty { flush() }
                continue
            }
            current.append(character)
            if softTerminators.contains(character) {
                lastSoftBoundary = current.endIndex
            }
            if sentenceTerminators.contains(character) {
                flush()
            } else if current.count >= maximumCharacters {
                if let lastSoftBoundary {
                    flush(current.distance(from: current.startIndex, to: lastSoftBoundary))
                } else {
                    flush(maximumCharacters)
                }
            }
        }
        if !current.isEmpty { flush() }

        var merged: [String] = []
        var pending = ""
        for chunk in rawChunks {
            if pending.isEmpty {
                pending = chunk
            } else if pending.count < minimumCharacters,
                      pending.count + chunk.count <= maximumCharacters {
                pending += chunk
            } else {
                merged.append(pending)
                pending = chunk
            }
        }
        if !pending.isEmpty { merged.append(pending) }
        return merged
    }

    static func alignedCues(
        chunks: [String],
        segments: [SubtitleTranscriptionSegment],
        audioDuration: TimeInterval,
        leadIn: TimeInterval = 0.25,
        tailOut: TimeInterval = 0.25
    ) -> [SubtitleCue] {
        let chunkRanges = normalizedRanges(chunks)
        let recognized = timedCharacters(segments)
        guard !chunkRanges.text.isEmpty, !recognized.text.isEmpty else { return [] }
        let positions = positionMap(source: chunkRanges.text, recognized: recognized.text)
        let timelineEnd = max(0, audioDuration - tailOut)
        var previousEnd = min(max(0, leadIn), timelineEnd)

        return zip(chunks, chunkRanges.ranges).map { chunk, range in
            let mapped = range.compactMap { positions[$0] }
                .filter { recognized.times.indices.contains($0) }
            var start: TimeInterval
            var end: TimeInterval
            if let first = mapped.min(), let last = mapped.max() {
                start = max(leadIn, recognized.times[first].start - 0.04)
                end = min(audioDuration - tailOut, recognized.times[last].end + 0.08)
            } else {
                start = previousEnd
                end = min(timelineEnd, start + max(1, Double(chunk.count) / 6))
            }
            start = min(max(start, previousEnd), timelineEnd)
            end = min(timelineEnd, max(start, end))
            previousEnd = end
            return SubtitleCue(text: chunk, start: start, end: end)
        }
    }

    static func writeSRT(_ cues: [SubtitleCue], to destination: URL) throws {
        let blocks = cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(srtTime(cue.start)) --> \(srtTime(cue.end))
            \(wrapped(cue.text))
            """
        }
        let data = Data((blocks.joined(separator: "\n\n") + "\n").utf8)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func normalize(_ text: String) -> [Character] {
        text.lowercased().filter { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
                    || (0x4E00...0x9FFF).contains(Int($0.value))
            }
        }
    }

    private static func normalizedRanges(_ chunks: [String]) -> (
        text: [Character],
        ranges: [Range<Int>]
    ) {
        var text: [Character] = []
        var ranges: [Range<Int>] = []
        for chunk in chunks {
            let normalized = normalize(chunk)
            let start = text.count
            text.append(contentsOf: normalized)
            ranges.append(start..<text.count)
        }
        return (text, ranges)
    }

    private static func timedCharacters(_ segments: [SubtitleTranscriptionSegment]) -> (
        text: [Character],
        times: [(start: TimeInterval, end: TimeInterval)]
    ) {
        var text: [Character] = []
        var times: [(start: TimeInterval, end: TimeInterval)] = []
        for segment in segments {
            let normalized = normalize(segment.text)
            guard !normalized.isEmpty else { continue }
            let duration = max(0.05, segment.end - segment.start)
            let step = duration / Double(normalized.count)
            for (index, character) in normalized.enumerated() {
                text.append(character)
                times.append((
                    segment.start + Double(index) * step,
                    segment.start + Double(index + 1) * step
                ))
            }
        }
        return (text, times)
    }

    /// Monotonic six-character anchors keep long CJK scripts aligned in
    /// linear time. Between trustworthy anchors, source positions are mapped
    /// proportionally to the recognized timeline.
    private static func positionMap(
        source: [Character],
        recognized: [Character]
    ) -> [Int?] {
        guard !source.isEmpty, !recognized.isEmpty else {
            return Array(repeating: nil, count: source.count)
        }
        let anchorWidth = 6
        guard source.count >= anchorWidth, recognized.count >= anchorWidth else {
            return source.indices.map {
                min(recognized.count - 1, $0 * recognized.count / source.count)
            }
        }

        var recognizedAnchors: [String: [Int]] = [:]
        for index in 0...(recognized.count - anchorWidth) {
            recognizedAnchors[String(recognized[index..<(index + anchorWidth)]), default: []]
                .append(index)
        }

        var anchors: [(source: Int, recognized: Int)] = [(0, 0)]
        var minimumRecognizedIndex = 0
        let globalRatio = Double(recognized.count) / Double(source.count)
        var sourceIndex = 0
        while sourceIndex <= source.count - anchorWidth {
            let token = String(source[sourceIndex..<(sourceIndex + anchorWidth)])
            if let candidates = recognizedAnchors[token] {
                let expected = Int(Double(sourceIndex) * globalRatio)
                if let candidate = candidates
                    .filter({ $0 >= minimumRecognizedIndex })
                    .min(by: { abs($0 - expected) < abs($1 - expected) }) {
                    anchors.append((sourceIndex, candidate))
                    minimumRecognizedIndex = candidate + anchorWidth
                    sourceIndex += anchorWidth
                    continue
                }
            }
            sourceIndex += 2
        }
        anchors.append((source.count, recognized.count))

        var mapping = Array<Int?>(repeating: nil, count: source.count)
        for pairIndex in 0..<(anchors.count - 1) {
            let lower = anchors[pairIndex]
            let upper = anchors[pairIndex + 1]
            let sourceSpan = max(1, upper.source - lower.source)
            let recognizedSpan = upper.recognized - lower.recognized
            guard lower.source < min(upper.source, source.count) else { continue }
            for index in lower.source..<min(upper.source, source.count) {
                let progress = Double(index - lower.source) / Double(sourceSpan)
                let recognizedIndex = lower.recognized + Int(progress * Double(recognizedSpan))
                mapping[index] = min(max(recognizedIndex, 0), recognized.count - 1)
            }
        }
        return mapping
    }

    private static func wrapped(_ text: String, lineCharacters: Int = 18) -> String {
        guard text.count > lineCharacters else { return text }
        var lines: [String] = []
        var remaining = text
        while remaining.count > lineCharacters {
            let split = remaining.index(remaining.startIndex, offsetBy: lineCharacters)
            lines.append(String(remaining[..<split]))
            remaining = String(remaining[split...])
        }
        if !remaining.isEmpty { lines.append(remaining) }
        return lines.joined(separator: "\n")
    }

    private static func srtTime(_ seconds: TimeInterval) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let secs = (milliseconds % 60_000) / 1_000
        let millis = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
