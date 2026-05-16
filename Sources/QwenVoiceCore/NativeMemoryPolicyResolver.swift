import Foundation
import MLX

public enum NativeMemoryPolicyResolver {
    private static let oneGB = 1_024 * 1_024 * 1_024

    public static func deviceClass(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        isIPhone: Bool = {
            #if os(iOS)
            return true
            #else
            return false
            #endif
        }()
    ) -> NativeDeviceMemoryClass {
        if isIPhone {
            return .iPhonePro
        }
        if physicalMemoryBytes <= UInt64(10 * oneGB) {
            return .floor8GBMac
        }
        if physicalMemoryBytes <= UInt64(24 * oneGB) {
            return .mid16GBMac
        }
        return .highMemoryMac
    }

    public static func policy(
        deviceClass: NativeDeviceMemoryClass = deviceClass(),
        mode: GenerationMode,
        isBatch: Bool
    ) -> NativeMemoryPolicy {
        switch deviceClass {
        case .floor8GBMac:
            return NativeMemoryPolicy(
                name: "floor_8gb_mac_\(mode.rawValue)_\(isBatch ? "batch" : "single")",
                deviceClass: deviceClass,
                cacheLimitBytes: 256 * 1_024 * 1_024,
                clearCacheAfterGeneration: !isBatch,
                unloadAfterIdleSeconds: 120
            )
        case .mid16GBMac:
            return NativeMemoryPolicy(
                name: "mid_16gb_mac_\(mode.rawValue)_\(isBatch ? "batch" : "single")",
                deviceClass: deviceClass,
                cacheLimitBytes: 512 * 1_024 * 1_024,
                clearCacheAfterGeneration: false,
                unloadAfterIdleSeconds: 600
            )
        case .highMemoryMac:
            return NativeMemoryPolicy(
                name: "high_memory_mac_\(mode.rawValue)_\(isBatch ? "batch" : "single")",
                deviceClass: deviceClass,
                cacheLimitBytes: 1_024 * 1_024 * 1_024,
                clearCacheAfterGeneration: false,
                unloadAfterIdleSeconds: nil
            )
        case .iPhonePro:
            return NativeMemoryPolicy(
                name: "iphone_pro_\(mode.rawValue)_\(isBatch ? "batch" : "single")",
                deviceClass: deviceClass,
                cacheLimitBytes: 128 * 1_024 * 1_024,
                clearCacheAfterGeneration: true,
                unloadAfterIdleSeconds: 30
            )
        }
    }

    public static func apply(_ policy: NativeMemoryPolicy) {
        Memory.cacheLimit = policy.cacheLimitBytes
        if let memoryLimitBytes = policy.memoryLimitBytes {
            Memory.memoryLimit = memoryLimitBytes
        }
    }

    public static func minimumStreamingInterval(
        for policy: NativeMemoryPolicy,
        request: GenerationRequest
    ) -> Double {
        if request.batchTotal != nil {
            return 0.8
        }

        switch policy.deviceClass {
        case .floor8GBMac, .iPhonePro:
            return 0.6
        case .mid16GBMac, .highMemoryMac:
            return 0.4
        }
    }

    public static func effectiveStreamingInterval(
        requested: Double?,
        request: GenerationRequest,
        policy: NativeMemoryPolicy
    ) -> Double {
        let adaptiveInterval = minimumStreamingInterval(for: policy, request: request)
        guard let requested else {
            return adaptiveInterval
        }
        guard policy.deviceClass == .floor8GBMac || policy.deviceClass == .iPhonePro || request.batchTotal != nil else {
            return requested
        }
        return max(requested, adaptiveInterval)
    }

    public static func cloneCacheCapacity(deviceClass: NativeDeviceMemoryClass = deviceClass()) -> Int {
        switch deviceClass {
        case .floor8GBMac, .iPhonePro:
            // Down from 2 to 1 on the lowest-RAM tier. Holding two
            // primed clone references in memory simultaneously costs
            // ~200-400 MB of peak RSS during the second reference's
            // prime, which on an 8 GB Mac can be the difference
            // between a smooth generation and an OOM-bound stall.
            // The on-disk clone-normalization cache (introduced in
            // a sibling commit) covers the case where a user toggles
            // between two references repeatedly — they pay the prime
            // again on switch but the audio normalization step
            // (the bulkier one) reuses cached parquet.
            return 1
        case .mid16GBMac:
            return 8
        case .highMemoryMac:
            return 16
        }
    }

    public static func postBatchTrimLevel(
        deviceClass: NativeDeviceMemoryClass = deviceClass()
    ) -> NativeMemoryTrimLevel? {
        switch deviceClass {
        case .floor8GBMac:
            return .hardTrim
        case .iPhonePro, .mid16GBMac, .highMemoryMac:
            return nil
        }
    }

    public static func snapshot() -> NativeMLXMemorySnapshot {
        let snapshot = Memory.snapshot()
        return NativeMLXMemorySnapshot(
            activeMB: bytesToMB(snapshot.activeMemory),
            cacheMB: bytesToMB(snapshot.cacheMemory),
            peakMB: bytesToMB(snapshot.peakMemory)
        )
    }

    public static func resetPeakMemory() {
        Memory.peakMemory = 0
    }

    private static func bytesToMB(_ bytes: Int) -> Double {
        Double(bytes) / Double(1_024 * 1_024)
    }
}
