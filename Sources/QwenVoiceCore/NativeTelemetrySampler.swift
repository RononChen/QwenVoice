import Darwin
import Foundation
import Metal

/// Thermal-state snapshot captured at the start and end of a generation, plus the
/// worst state observed while the sampler was running.
public struct ThermalStateSnapshot: Hashable, Codable, Sendable {
    public let start: String
    public let end: String
    public let worst: String

    public init(start: ProcessInfo.ThermalState, end: ProcessInfo.ThermalState, worst: ProcessInfo.ThermalState) {
        self.start = Self.string(for: start)
        self.end = Self.string(for: end)
        self.worst = Self.string(for: worst)
    }

    internal static func string(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}

public struct TelemetrySample: Hashable, Codable, Sendable {
    public let tMS: Int
    public let residentMB: Double?
    public let physFootprintMB: Double?
    public let compressedMB: Double?
    public let headroomMB: Double?
    public let gpuAllocatedMB: Double?
    public let gpuRecommendedWorkingSetMB: Double?
    public let threads: Int
    public let thermalState: String?
    public var stage: String?
    public var chunkIndex: Int?

    public init(
        tMS: Int,
        residentMB: Double?,
        physFootprintMB: Double?,
        compressedMB: Double?,
        headroomMB: Double?,
        gpuAllocatedMB: Double?,
        gpuRecommendedWorkingSetMB: Double?,
        threads: Int,
        thermalState: String? = nil,
        stage: String? = nil,
        chunkIndex: Int? = nil
    ) {
        self.tMS = tMS
        self.residentMB = residentMB
        self.physFootprintMB = physFootprintMB
        self.compressedMB = compressedMB
        self.headroomMB = headroomMB
        self.gpuAllocatedMB = gpuAllocatedMB
        self.gpuRecommendedWorkingSetMB = gpuRecommendedWorkingSetMB
        self.threads = threads
        self.thermalState = thermalState
        self.stage = stage
        self.chunkIndex = chunkIndex
    }
}

public struct TelemetrySummary: Hashable, Codable, Sendable {
    public let residentStartMB: Double?
    public let residentEndMB: Double?
    public let residentPeakMB: Double?
    public let physFootprintPeakMB: Double?
    public let compressedPeakMB: Double?
    public let headroomStartMB: Double?
    public let headroomEndMB: Double?
    public let headroomMinMB: Double?
    public let gpuAllocatedPeakMB: Double?
    public let gpuRecommendedWorkingSetMB: Double?
    public let gpuWorkingSetUsageRatioPeak: Double?
    public let timeToPeakMS: Int?
    public let sampleCount: Int
    public let stageMarks: [NativeTelemetryStageMark]
    public let thermalState: ThermalStateSnapshot?

    public init(
        residentStartMB: Double?,
        residentEndMB: Double?,
        residentPeakMB: Double?,
        physFootprintPeakMB: Double?,
        compressedPeakMB: Double?,
        headroomStartMB: Double?,
        headroomEndMB: Double?,
        headroomMinMB: Double?,
        gpuAllocatedPeakMB: Double?,
        gpuRecommendedWorkingSetMB: Double?,
        gpuWorkingSetUsageRatioPeak: Double?,
        timeToPeakMS: Int?,
        sampleCount: Int,
        stageMarks: [NativeTelemetryStageMark],
        thermalState: ThermalStateSnapshot?
    ) {
        self.residentStartMB = residentStartMB
        self.residentEndMB = residentEndMB
        self.residentPeakMB = residentPeakMB
        self.physFootprintPeakMB = physFootprintPeakMB
        self.compressedPeakMB = compressedPeakMB
        self.headroomStartMB = headroomStartMB
        self.headroomEndMB = headroomEndMB
        self.headroomMinMB = headroomMinMB
        self.gpuAllocatedPeakMB = gpuAllocatedPeakMB
        self.gpuRecommendedWorkingSetMB = gpuRecommendedWorkingSetMB
        self.gpuWorkingSetUsageRatioPeak = gpuWorkingSetUsageRatioPeak
        self.timeToPeakMS = timeToPeakMS
        self.sampleCount = sampleCount
        self.stageMarks = stageMarks
        self.thermalState = thermalState
    }
}

public actor NativeTelemetrySampler {
    private let startUptimeSeconds: TimeInterval
    private let sampleIntervalMS: Int
    private let buffer = TelemetrySampleBuffer()
    private var samplingTask: Task<Void, Never>?
    /// Resolved once per generation instead of per sample. `IOSMemorySnapshot.capture`
    /// defaults `device:` to `MTLCreateSystemDefaultDevice()`, which would otherwise
    /// allocate a fresh Metal device object on every tick — wasteful on restricted
    /// hardware where the sampler runs alongside generation.
    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    public init(
        startUptimeSeconds: TimeInterval,
        sampleIntervalMS: Int
    ) {
        self.startUptimeSeconds = startUptimeSeconds
        self.sampleIntervalMS = sampleIntervalMS
    }

    public func start() async {
        await buffer.append(sample: Self.captureSample(startUptimeSeconds: startUptimeSeconds, device: metalDevice))
        let intervalNanos = UInt64(max(sampleIntervalMS, 1)) * 1_000_000
        let buffer = self.buffer
        let startUptimeSeconds = self.startUptimeSeconds
        let device = self.metalDevice
        samplingTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                guard !Task.isCancelled else { break }
                await buffer.append(
                    sample: Self.captureSample(startUptimeSeconds: startUptimeSeconds, device: device)
                )
            }
        }
    }

    public func stop(stageMarks: [NativeTelemetryStageMark]) async -> (summary: TelemetrySummary, samples: [TelemetrySample]) {
        samplingTask?.cancel()
        _ = await samplingTask?.value
        await buffer.append(sample: Self.captureSample(startUptimeSeconds: startUptimeSeconds, device: metalDevice))
        let rawSamples = await buffer.snapshot()
        let samples = Self.decorate(samples: rawSamples, stageMarks: stageMarks)
        let summary = Self.summarize(samples: samples, stageMarks: stageMarks)
        return (summary, samples)
    }

    private static func decorate(
        samples: [TelemetrySample],
        stageMarks: [NativeTelemetryStageMark]
    ) -> [TelemetrySample] {
        let sortedMarks = stageMarks.sorted { lhs, rhs in
            if lhs.tMS == rhs.tMS {
                return lhs.stage < rhs.stage
            }
            return lhs.tMS < rhs.tMS
        }

        var nextMarkIndex = 0
        var currentStage: String?
        var currentChunkIndex: Int?
        return samples.map { sample in
            var sample = sample
            while nextMarkIndex < sortedMarks.count, sortedMarks[nextMarkIndex].tMS <= sample.tMS {
                let mark = sortedMarks[nextMarkIndex]
                currentStage = mark.stage
                currentChunkIndex = mark.metadata["chunk_index"].flatMap(Int.init)
                nextMarkIndex += 1
            }
            sample.stage = currentStage
            sample.chunkIndex = currentChunkIndex
            return sample
        }
    }

    private static func summarize(
        samples: [TelemetrySample],
        stageMarks: [NativeTelemetryStageMark]
    ) -> TelemetrySummary {
        let residentStartMB = samples.first?.residentMB
        let residentEndMB = samples.last?.residentMB
        let residentPeakSample = samples.max { lhs, rhs in
            (lhs.residentMB ?? 0) < (rhs.residentMB ?? 0)
        }
        let physFootprintPeakMB = samples.compactMap(\.physFootprintMB).max()
        let compressedPeakMB = samples.compactMap(\.compressedMB).max()
        let headroomStartMB = samples.first?.headroomMB
        let headroomEndMB = samples.last?.headroomMB
        let headroomMinMB = samples.compactMap(\.headroomMB).min()
        let gpuAllocatedPeakMB = samples.compactMap(\.gpuAllocatedMB).max()
        let gpuRecommendedWorkingSetMB = samples.compactMap(\.gpuRecommendedWorkingSetMB).max()
        let gpuWorkingSetUsageRatioPeak = samples.compactMap { sample -> Double? in
            guard let allocated = sample.gpuAllocatedMB,
                  let recommended = sample.gpuRecommendedWorkingSetMB,
                  recommended > 0 else { return nil }
            return allocated / recommended
        }.max()

        let thermalSnapshot: ThermalStateSnapshot? = {
            guard let first = samples.first?.thermalState,
                  let last = samples.last?.thermalState else { return nil }
            let worst = samples.compactMap(\.thermalState).max { lhs, rhs in
                thermalRank(lhs) < thermalRank(rhs)
            } ?? first
            return ThermalStateSnapshot(start: state(from: first), end: state(from: last), worst: state(from: worst))
        }()

        return TelemetrySummary(
            residentStartMB: residentStartMB,
            residentEndMB: residentEndMB,
            residentPeakMB: residentPeakSample?.residentMB,
            physFootprintPeakMB: physFootprintPeakMB,
            compressedPeakMB: compressedPeakMB,
            headroomStartMB: headroomStartMB,
            headroomEndMB: headroomEndMB,
            headroomMinMB: headroomMinMB,
            gpuAllocatedPeakMB: gpuAllocatedPeakMB,
            gpuRecommendedWorkingSetMB: gpuRecommendedWorkingSetMB,
            gpuWorkingSetUsageRatioPeak: gpuWorkingSetUsageRatioPeak,
            timeToPeakMS: residentPeakSample?.tMS,
            sampleCount: samples.count,
            stageMarks: stageMarks,
            thermalState: thermalSnapshot
        )
    }

    private static func thermalRank(_ state: String) -> Int {
        switch state {
        case "nominal": return 0
        case "fair": return 1
        case "serious": return 2
        case "critical": return 3
        default: return -1
        }
    }

    private static func state(from string: String) -> ProcessInfo.ThermalState {
        switch string {
        case "fair": return .fair
        case "serious": return .serious
        case "critical": return .critical
        default: return .nominal
        }
    }

    private static func captureSample(startUptimeSeconds: TimeInterval, device: MTLDevice?) -> TelemetrySample {
        let tMS = Int((ProcessInfo.processInfo.systemUptime - startUptimeSeconds) * 1_000)
        let snapshot = IOSMemorySnapshot.capture(device: device)
        return TelemetrySample(
            tMS: tMS,
            residentMB: snapshot.residentMB,
            physFootprintMB: snapshot.physFootprintMB,
            compressedMB: snapshot.compressedMB,
            headroomMB: snapshot.availableHeadroomMB,
            gpuAllocatedMB: snapshot.gpuAllocatedMB,
            gpuRecommendedWorkingSetMB: snapshot.gpuRecommendedWorkingSetMB,
            threads: threadCount(),
            thermalState: ThermalStateSnapshot.string(for: ProcessInfo.processInfo.thermalState)
        )
    }

    private static func threadCount() -> Int {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        defer {
            if let threadList {
                vm_deallocate(
                    mach_task_self_,
                    vm_address_t(UInt(bitPattern: threadList)),
                    vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
                )
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        return Int(threadCount)
    }
}

private actor TelemetrySampleBuffer {
    private var samples: [TelemetrySample] = []

    func append(sample: TelemetrySample) {
        samples.append(sample)
    }

    func snapshot() -> [TelemetrySample] {
        samples
    }
}
