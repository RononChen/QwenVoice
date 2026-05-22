import Darwin
import Foundation
import Metal

public enum IOSMemoryPressureBand: String, Codable, Hashable, Sendable {
    case healthy
    case guarded
    case critical

    public var severityRank: Int {
        switch self {
        case .healthy:
            return 0
        case .guarded:
            return 1
        case .critical:
            return 2
        }
    }
}

public enum NativeMemoryTrimLevel: String, Codable, Hashable, Sendable {
    case softTrim
    case hardTrim
    case fullUnload
}

public enum IOSMemoryProcessRole: String, Codable, Hashable, Sendable {
    case app
    case engineExtension
    case simulator
    case currentProcess
}

public struct IOSMemorySnapshot: Hashable, Codable, Sendable {
    public let processRole: IOSMemoryProcessRole
    public let pid: Int32
    public let capturedAtUptimeSeconds: Double
    public let totalDeviceRAMBytes: UInt64
    public let availableHeadroomBytes: UInt64?
    public let residentBytes: UInt64?
    public let physFootprintBytes: UInt64?
    public let compressedBytes: UInt64?
    public let gpuAllocatedBytes: UInt64?
    public let gpuRecommendedWorkingSetBytes: UInt64?
    public let hasUnifiedMemory: Bool?

    public init(
        processRole: IOSMemoryProcessRole = .currentProcess,
        pid: Int32 = getpid(),
        capturedAtUptimeSeconds: Double = ProcessInfo.processInfo.systemUptime,
        totalDeviceRAMBytes: UInt64,
        availableHeadroomBytes: UInt64?,
        residentBytes: UInt64?,
        physFootprintBytes: UInt64?,
        compressedBytes: UInt64?,
        gpuAllocatedBytes: UInt64?,
        gpuRecommendedWorkingSetBytes: UInt64?,
        hasUnifiedMemory: Bool?
    ) {
        self.processRole = processRole
        self.pid = pid
        self.capturedAtUptimeSeconds = capturedAtUptimeSeconds
        self.totalDeviceRAMBytes = totalDeviceRAMBytes
        self.availableHeadroomBytes = availableHeadroomBytes
        self.residentBytes = residentBytes
        self.physFootprintBytes = physFootprintBytes
        self.compressedBytes = compressedBytes
        self.gpuAllocatedBytes = gpuAllocatedBytes
        self.gpuRecommendedWorkingSetBytes = gpuRecommendedWorkingSetBytes
        self.hasUnifiedMemory = hasUnifiedMemory
    }

    public var residentMB: Double? {
        Self.bytesToMB(residentBytes)
    }

    public var physFootprintMB: Double? {
        Self.bytesToMB(physFootprintBytes)
    }

    public var compressedMB: Double? {
        Self.bytesToMB(compressedBytes)
    }

    public var availableHeadroomMB: Double? {
        Self.bytesToMB(availableHeadroomBytes)
    }

    public var gpuAllocatedMB: Double? {
        Self.bytesToMB(gpuAllocatedBytes)
    }

    public var gpuRecommendedWorkingSetMB: Double? {
        Self.bytesToMB(gpuRecommendedWorkingSetBytes)
    }

    public static func capture(
        role: IOSMemoryProcessRole = .currentProcess,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) -> IOSMemorySnapshot {
        let metrics = taskMemoryMetrics()
        return IOSMemorySnapshot(
            processRole: role,
            pid: getpid(),
            capturedAtUptimeSeconds: ProcessInfo.processInfo.systemUptime,
            totalDeviceRAMBytes: ProcessInfo.processInfo.physicalMemory,
            availableHeadroomBytes: availableProcessMemory(),
            residentBytes: metrics.residentBytes,
            physFootprintBytes: metrics.physFootprintBytes,
            compressedBytes: metrics.compressedBytes,
            gpuAllocatedBytes: device.map { UInt64($0.currentAllocatedSize) },
            gpuRecommendedWorkingSetBytes: device.map { $0.recommendedMaxWorkingSetSize },
            hasUnifiedMemory: device?.hasUnifiedMemory
        )
    }

    private static func taskMemoryMetrics() -> (
        residentBytes: UInt64?,
        physFootprintBytes: UInt64?,
        compressedBytes: UInt64?
    ) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    integerPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return (nil, nil, nil)
        }

        return (
            residentBytes: info.resident_size,
            physFootprintBytes: info.phys_footprint,
            compressedBytes: info.compressed
        )
    }

    private static func availableProcessMemory() -> UInt64? {
        var headroom: UInt64 = 0
        guard QVoiceGetOSProcAvailableMemory(&headroom) else {
            return nil
        }
#if targetEnvironment(simulator)
        guard headroom > 0 else {
            return nil
        }
#endif
        return headroom
    }

    private static func bytesToMB(_ bytes: UInt64?) -> Double? {
        guard let bytes else { return nil }
        return Double(bytes) / 1_048_576
    }
}

public struct IOSMemoryContext: Hashable, Codable, Sendable {
    public let appSnapshot: IOSMemorySnapshot
    public let engineExtensionSnapshot: IOSMemorySnapshot?
    public let pressureBand: IOSMemoryPressureBand
    public let worstProcessRole: IOSMemoryProcessRole?
    public let reason: String
    public let source: String

    public init(
        appSnapshot: IOSMemorySnapshot,
        engineExtensionSnapshot: IOSMemorySnapshot?,
        pressureBand: IOSMemoryPressureBand,
        worstProcessRole: IOSMemoryProcessRole?,
        reason: String,
        source: String
    ) {
        self.appSnapshot = appSnapshot
        self.engineExtensionSnapshot = engineExtensionSnapshot
        self.pressureBand = pressureBand
        self.worstProcessRole = worstProcessRole
        self.reason = reason
        self.source = source
    }

    public var snapshots: [IOSMemorySnapshot] {
        if let engineExtensionSnapshot {
            return [appSnapshot, engineExtensionSnapshot]
        }
        return [appSnapshot]
    }

    public var minimumHeadroomBytes: UInt64? {
        snapshots.compactMap(\.availableHeadroomBytes).min()
    }

    public var peakPhysFootprintBytes: UInt64? {
        snapshots.compactMap(\.physFootprintBytes).max()
    }

    public var peakResidentBytes: UInt64? {
        snapshots.compactMap(\.residentBytes).max()
    }

    public var peakGPUAllocatedBytes: UInt64? {
        snapshots.compactMap(\.gpuAllocatedBytes).max()
    }
}

public struct IOSMemoryBudgetPolicy: Hashable, Codable, Sendable {
    public let healthyHeadroomBytes: UInt64
    public let guardedHeadroomBytes: UInt64
    public let criticalGPUWorkingSetUsageRatio: Double

    public init(
        healthyHeadroomBytes: UInt64,
        guardedHeadroomBytes: UInt64,
        criticalGPUWorkingSetUsageRatio: Double
    ) {
        self.healthyHeadroomBytes = healthyHeadroomBytes
        self.guardedHeadroomBytes = guardedHeadroomBytes
        self.criticalGPUWorkingSetUsageRatio = criticalGPUWorkingSetUsageRatio
    }

    public static let iPhoneShippingDefault = IOSMemoryBudgetPolicy(
        healthyHeadroomBytes: 768 * 1_048_576,
        guardedHeadroomBytes: 384 * 1_048_576,
        criticalGPUWorkingSetUsageRatio: 0.80
    )

    public func band(for snapshot: IOSMemorySnapshot) -> IOSMemoryPressureBand {
        if let gpuAllocated = snapshot.gpuAllocatedBytes,
           let gpuRecommendedWorkingSet = snapshot.gpuRecommendedWorkingSetBytes,
           gpuRecommendedWorkingSet > 0,
           Double(gpuAllocated) / Double(gpuRecommendedWorkingSet) >= criticalGPUWorkingSetUsageRatio {
            return .critical
        }

        guard let headroom = snapshot.availableHeadroomBytes ?? fallbackHeadroom(from: snapshot) else {
            return .healthy
        }

        if headroom < guardedHeadroomBytes {
            return .critical
        }
        if headroom < healthyHeadroomBytes {
            return .guarded
        }
        return .healthy
    }

    public func context(
        appSnapshot: IOSMemorySnapshot,
        engineExtensionSnapshot: IOSMemorySnapshot?,
        reason: String,
        source: String
    ) -> IOSMemoryContext {
        let candidates = [appSnapshot, engineExtensionSnapshot].compactMap { snapshot -> (
            snapshot: IOSMemorySnapshot,
            band: IOSMemoryPressureBand
        )? in
            guard let snapshot else { return nil }
            return (snapshot, band(for: snapshot))
        }
        let worst = candidates.max { lhs, rhs in
            if lhs.band.severityRank != rhs.band.severityRank {
                return lhs.band.severityRank < rhs.band.severityRank
            }
            return pressureTieBreakerScore(for: lhs.snapshot) < pressureTieBreakerScore(for: rhs.snapshot)
        }

        return IOSMemoryContext(
            appSnapshot: appSnapshot,
            engineExtensionSnapshot: engineExtensionSnapshot,
            pressureBand: worst?.band ?? .healthy,
            worstProcessRole: worst?.snapshot.processRole,
            reason: reason,
            source: source
        )
    }

    private func fallbackHeadroom(from snapshot: IOSMemorySnapshot) -> UInt64? {
        let usedBytes = snapshot.physFootprintBytes ?? snapshot.residentBytes
        guard let usedBytes, snapshot.totalDeviceRAMBytes > usedBytes else {
            return nil
        }
        return snapshot.totalDeviceRAMBytes - usedBytes
    }

    private func pressureTieBreakerScore(for snapshot: IOSMemorySnapshot) -> UInt64 {
        if let headroom = snapshot.availableHeadroomBytes {
            return snapshot.totalDeviceRAMBytes > headroom
                ? snapshot.totalDeviceRAMBytes - headroom
                : 0
        }
        return snapshot.physFootprintBytes ?? snapshot.residentBytes ?? 0
    }

    public func allowsProactiveWarmOperations(for band: IOSMemoryPressureBand) -> Bool {
        band == .healthy
    }

    public func allowsModelAdmission(for band: IOSMemoryPressureBand) -> Bool {
        band != .critical
    }

    public func engineExecutionBand(for context: IOSMemoryContext) -> IOSMemoryPressureBand {
        guard let engineExtensionSnapshot = context.engineExtensionSnapshot else {
            return .healthy
        }
        return band(for: engineExtensionSnapshot)
    }

    public func allowsModelAdmission(for context: IOSMemoryContext) -> Bool {
        allowsModelAdmission(for: engineExecutionBand(for: context))
    }

    public func postGenerationTrimLevel(for band: IOSMemoryPressureBand) -> NativeMemoryTrimLevel? {
        switch band {
        case .healthy:
            return nil
        case .guarded:
            return .hardTrim
        case .critical:
            return .fullUnload
        }
    }

    public func trimLevelForPressureEvent(
        snapshot: IOSMemorySnapshot,
        isBackgroundTransition: Bool
    ) -> NativeMemoryTrimLevel {
        if isBackgroundTransition {
            return .fullUnload
        }

        switch band(for: snapshot) {
        case .healthy:
            return .softTrim
        case .guarded:
            return .hardTrim
        case .critical:
            return .fullUnload
        }
    }

    public func trimLevelForPressureEvent(
        context: IOSMemoryContext,
        isBackgroundTransition: Bool
    ) -> NativeMemoryTrimLevel {
        if isBackgroundTransition {
            return .fullUnload
        }

        switch context.pressureBand {
        case .healthy:
            return .softTrim
        case .guarded:
            return .hardTrim
        case .critical:
            return .fullUnload
        }
    }
}
