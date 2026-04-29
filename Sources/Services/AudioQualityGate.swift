import AVFoundation
import Foundation

enum AudioQualityGate {
    static let clippingThreshold = 0.999
    static let dcOffsetThreshold = 0.01
    static let finalMinimumDurationSeconds = 0.15
    static let finalMinimumRMS = 0.0005
    static let finalMinimumPeak = 0.003
    static let dropoutWindowSeconds = 0.05
    static let dropoutWarningSeconds = 0.35
    static let dropoutFailureSeconds = 0.75
    static let dropoutThresholdDB = -55.0
    static let discontinuityMinimumDiff = 0.45
    static let discontinuityMultiplier = 100.0
    static let discontinuityEdgeMarginSeconds = 0.05
    static let headerOnlyMaxBytes = 4_096

    struct Report: Codable, Equatable {
        let passed: Bool
        let requiredFailures: [String]
        let warnings: [String]
        let metrics: [String: Double]
        let checks: [Check]

        var failureSummary: String {
            if requiredFailures.isEmpty {
                return "Audio quality check passed."
            }
            return "Audio quality check failed: \(requiredFailures.joined(separator: ", "))"
        }
    }

    struct Check: Codable, Equatable {
        let name: String
        let passed: Bool
        let severity: Severity
        let message: String?
        let metrics: [String: Double]
    }

    enum Severity: String, Codable {
        case error
        case warning
    }

    static func evaluate(url: URL) -> Report {
        do {
            let loaded = try loadAudio(url: url)
            return evaluate(loaded: loaded)
        } catch {
            let check = Check(
                name: "wav_readable",
                passed: false,
                severity: .error,
                message: error.localizedDescription,
                metrics: [:]
            )
            return Report(
                passed: false,
                requiredFailures: [check.name],
                warnings: [],
                metrics: [:],
                checks: [check]
            )
        }
    }

    private struct LoadedAudio {
        let samples: [Float]
        let sampleRate: Double
        let fileSizeBytes: Double
        let frameCount: Int
        let channelCount: Int
        let durationSeconds: Double
    }

    private static func loadAudio(url: URL) throws -> LoadedAudio {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .doubleValue ?? 0
        let file = try AVAudioFile(forReading: url)
        let frameCount = Int(file.length)
        let sampleRate = file.processingFormat.sampleRate
        let channelCount = Int(file.processingFormat.channelCount)
        guard frameCount > 0 else {
            return LoadedAudio(
                samples: [],
                sampleRate: sampleRate,
                fileSizeBytes: fileSize,
                frameCount: frameCount,
                channelCount: channelCount,
                durationSeconds: sampleRate > 0 ? Double(frameCount) / sampleRate : 0
            )
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw NSError(
                domain: "AudioQualityGate",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio buffer."]
            )
        }
        try file.read(into: buffer)
        let sampleCount = Int(buffer.frameLength)
        let samples: [Float]
        if let floatData = buffer.floatChannelData {
            samples = Array(UnsafeBufferPointer(start: floatData[0], count: sampleCount))
        } else if let int16Data = buffer.int16ChannelData {
            samples = UnsafeBufferPointer(start: int16Data[0], count: sampleCount).map {
                Float($0) / Float(Int16.max)
            }
        } else {
            throw NSError(
                domain: "AudioQualityGate",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported audio sample format."]
            )
        }
        return LoadedAudio(
            samples: samples,
            sampleRate: sampleRate,
            fileSizeBytes: fileSize,
            frameCount: frameCount,
            channelCount: channelCount,
            durationSeconds: sampleRate > 0 ? Double(frameCount) / sampleRate : 0
        )
    }

    private static func evaluate(loaded: LoadedAudio) -> Report {
        var checks: [Check] = []
        checks.append(readableCheck(loaded))
        checks.append(containerCheck(loaded))
        checks.append(durationCheck(loaded))
        checks.append(nonSilenceCheck(loaded.samples))
        checks.append(clippingCheck(loaded.samples))
        checks.append(dcOffsetCheck(loaded.samples))
        checks.append(discontinuityCheck(loaded.samples, sampleRate: loaded.sampleRate))
        checks.append(dropoutCheck(loaded.samples, sampleRate: loaded.sampleRate))

        let requiredFailures = checks
            .filter { !$0.passed && $0.severity == .error }
            .map(\.name)
        let warnings = checks
            .filter { !$0.passed && $0.severity == .warning }
            .compactMap { $0.message ?? $0.name }
        let mergedMetrics = checks.reduce(into: [String: Double]()) { partial, check in
            check.metrics.forEach { key, value in
                partial["\(check.name).\(key)"] = value
            }
        }
        return Report(
            passed: requiredFailures.isEmpty,
            requiredFailures: requiredFailures,
            warnings: warnings,
            metrics: mergedMetrics,
            checks: checks
        )
    }

    private static func readableCheck(_ loaded: LoadedAudio) -> Check {
        Check(
            name: "wav_readable",
            passed: loaded.sampleRate > 0 && loaded.channelCount > 0,
            severity: .error,
            message: loaded.sampleRate > 0 ? nil : "WAV sample rate is invalid.",
            metrics: [
                "sample_rate": loaded.sampleRate,
                "channel_count": Double(loaded.channelCount),
                "duration_seconds": loaded.durationSeconds,
                "file_size_bytes": loaded.fileSizeBytes,
                "frame_count": Double(loaded.frameCount),
            ]
        )
    }

    private static func containerCheck(_ loaded: LoadedAudio) -> Check {
        let passed = loaded.frameCount > 0 && !(loaded.fileSizeBytes <= Double(headerOnlyMaxBytes) && loaded.frameCount == 0)
        return Check(
            name: "final_file_container",
            passed: passed,
            severity: .error,
            message: passed ? nil : "WAV contains no audio frames.",
            metrics: [
                "frame_count": Double(loaded.frameCount),
                "file_size_bytes": loaded.fileSizeBytes,
            ]
        )
    }

    private static func durationCheck(_ loaded: LoadedAudio) -> Check {
        let passed = loaded.durationSeconds >= finalMinimumDurationSeconds
        return Check(
            name: "final_duration",
            passed: passed,
            severity: .error,
            message: passed ? nil : "Duration is below \(finalMinimumDurationSeconds)s.",
            metrics: ["duration_seconds": loaded.durationSeconds]
        )
    }

    private static func nonSilenceCheck(_ samples: [Float]) -> Check {
        let peak = samples.map { abs(Double($0)) }.max() ?? 0
        let rms = rootMeanSquare(samples)
        let passed = rms >= finalMinimumRMS && peak >= finalMinimumPeak
        return Check(
            name: "final_non_silence",
            passed: passed,
            severity: .error,
            message: passed ? nil : "Audio energy is too low.",
            metrics: ["rms": rms, "peak": peak]
        )
    }

    private static func clippingCheck(_ samples: [Float]) -> Check {
        let clipped = samples.filter { abs(Double($0)) >= clippingThreshold }.count
        return Check(
            name: "clipping_detection",
            passed: clipped == 0,
            severity: .error,
            message: clipped == 0 ? nil : "\(clipped) clipped sample(s) detected.",
            metrics: [
                "clipped_samples": Double(clipped),
                "total_samples": Double(samples.count),
            ]
        )
    }

    private static func dcOffsetCheck(_ samples: [Float]) -> Check {
        let mean = samples.isEmpty ? 0 : samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let passed = abs(mean) <= dcOffsetThreshold
        return Check(
            name: "dc_offset",
            passed: passed,
            severity: .error,
            message: passed ? nil : "DC offset exceeds \(dcOffsetThreshold).",
            metrics: ["mean_value": mean]
        )
    }

    private static func discontinuityCheck(_ samples: [Float], sampleRate: Double) -> Check {
        guard samples.count >= 4, sampleRate > 0 else {
            return Check(
                name: "final_abrupt_discontinuities",
                passed: true,
                severity: .error,
                message: nil,
                metrics: ["hit_count": 0, "max_diff": 0, "median_diff": 0]
            )
        }
        let diffs = zip(samples.dropFirst(), samples).map { abs(Double($0) - Double($1)) }
        let edge = max(0, Int(discontinuityEdgeMarginSeconds * sampleRate))
        let interior = diffs.enumerated().compactMap { index, value in
            index >= edge && index < diffs.count - edge ? value : nil
        }
        let medianDiff = median(interior)
        let maxDiff = interior.max() ?? 0
        let threshold = max(discontinuityMinimumDiff, medianDiff * discontinuityMultiplier)
        let hitCount = interior.filter { $0 > threshold }.count
        return Check(
            name: "final_abrupt_discontinuities",
            passed: hitCount == 0,
            severity: .error,
            message: hitCount == 0 ? nil : "\(hitCount) abrupt discontinuity sample(s) detected.",
            metrics: [
                "hit_count": Double(hitCount),
                "max_diff": maxDiff,
                "median_diff": medianDiff,
                "threshold": threshold,
            ]
        )
    }

    private static func dropoutCheck(_ samples: [Float], sampleRate: Double) -> Check {
        guard sampleRate > 0, !samples.isEmpty else {
            return Check(
                name: "final_dropouts",
                passed: false,
                severity: .error,
                message: "No audio.",
                metrics: ["dropout_count": 0, "longest_dropout_seconds": 0]
            )
        }
        let window = max(1, Int(dropoutWindowSeconds * sampleRate))
        guard samples.count >= window * 4 else {
            return Check(
                name: "final_dropouts",
                passed: true,
                severity: .warning,
                message: nil,
                metrics: ["dropout_count": 0, "longest_dropout_seconds": 0]
            )
        }
        let edge = max(window * 2, Int(0.1 * sampleRate))
        let region = samples.count > edge * 2 + window
            ? Array(samples[edge..<(samples.count - edge)])
            : samples
        let threshold = pow(10.0, dropoutThresholdDB / 20.0)
        var silentWindows: [Bool] = []
        var start = 0
        while start + window <= region.count {
            let segment = Array(region[start..<(start + window)])
            silentWindows.append(rootMeanSquare(segment) < threshold)
            start += window
        }

        var gaps: [(start: Int, end: Int)] = []
        var ignoredEdgeGaps: [(start: Int, end: Int)] = []
        var runStart: Int?
        for (index, silent) in silentWindows.enumerated() {
            if silent, runStart == nil {
                runStart = index
            }
            if (!silent || index == silentWindows.count - 1), let activeStart = runStart {
                let runEnd = silent && index == silentWindows.count - 1 ? index + 1 : index
                let duration = Double(runEnd - activeStart) * dropoutWindowSeconds
                if duration >= dropoutWarningSeconds {
                    if activeStart == 0 || runEnd == silentWindows.count {
                        ignoredEdgeGaps.append((activeStart, runEnd))
                    } else {
                        gaps.append((activeStart, runEnd))
                    }
                }
                runStart = nil
            }
        }

        let longest = gaps
            .map { Double($0.end - $0.start) * dropoutWindowSeconds }
            .max() ?? 0
        let failed = longest >= dropoutFailureSeconds
        let message: String?
        if failed {
            message = "\(gaps.count) suspicious internal dropout(s) detected."
        } else if !gaps.isEmpty {
            message = "\(gaps.count) short low-energy pause(s) detected."
        } else {
            message = nil
        }
        return Check(
            name: "final_dropouts",
            passed: !failed,
            severity: failed ? .error : .warning,
            message: message,
            metrics: [
                "dropout_count": Double(gaps.count),
                "ignored_edge_dropout_count": Double(ignoredEdgeGaps.count),
                "longest_dropout_seconds": longest,
            ]
        )
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let squares = samples.reduce(0.0) { partial, sample in
            partial + Double(sample) * Double(sample)
        }
        return sqrt(squares / Double(samples.count))
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
