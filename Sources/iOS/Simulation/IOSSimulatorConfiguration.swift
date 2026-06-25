import Foundation
import QwenVoiceCore

/// Typed, single-source-of-truth configuration for the simulator fake backend.
/// All `QVOICE_SIM_*` environment variables are parsed once at launch.
struct IOSSimulatorConfiguration: Sendable {
    enum BackendScenario: String, Sendable {
        case success
        case slow
        case fail
        case cancelMid = "cancel_mid"
        case cloneMissingRef = "clone_missing_ref"
    }

    enum DownloadScenario: String, Sendable {
        case success
        case slow
        case failMid = "fail_mid"
        case failVerify = "fail_verify"
    }

    /// Which catalog models report `.installed` at launch. `nil` means leave
    /// the persisted fake registry alone (useful for relaunch-resume tests).
    let fakeModels: [String]?
    let seedData: SeedData
    let backendScenario: BackendScenario
    let downloadScenario: DownloadScenario
    let backendDelayMilliseconds: Int
    let downloadDelayMilliseconds: Int
    let cloneCapableOverride: Bool?
    let resetStateOnLaunch: Bool

    struct SeedData: OptionSet, Sendable {
        let rawValue: Int
        static let voices = SeedData(rawValue: 1 << 0)
        static let history = SeedData(rawValue: 1 << 1)
    }

    static let `default` = IOSSimulatorConfiguration()

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let backendScenario = Self.parseBackendScenario(environment["QVOICE_SIM_BACKEND_SCENARIO"])
        self.fakeModels = Self.parseFakeModels(environment["QVOICE_SIM_FAKE_MODELS"])
        self.seedData = Self.parseSeedData(environment["QVOICE_SIM_SEED_DATA"])
        self.backendScenario = backendScenario
        self.downloadScenario = Self.parseDownloadScenario(environment["QVOICE_SIM_DOWNLOAD_SCENARIO"])
        self.backendDelayMilliseconds = Self.parseDelay(environment["QVOICE_SIM_BACKEND_DELAY_MS"], default: Self.defaultDelay(for: backendScenario))
        self.downloadDelayMilliseconds = Self.parseDelay(environment["QVOICE_SIM_DOWNLOAD_DELAY_MS"], default: backendDelayMilliseconds)
        self.cloneCapableOverride = Self.parseTriState(environment["QVOICE_SIM_CLONE_CAPABLE"])
        self.resetStateOnLaunch = Self.parseTriState(environment["QVOICE_SIM_RESET_STATE"]) == true
    }

    var backendDelayNanoseconds: UInt64 {
        UInt64(max(0, min(backendDelayMilliseconds, 30_000))) * 1_000_000
    }

    var downloadDelayNanoseconds: UInt64 {
        UInt64(max(0, min(downloadDelayMilliseconds, 30_000))) * 1_000_000
    }

    // MARK: - Parsers

    private static func parseFakeModels(_ raw: String?) -> [String]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let tokens = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if tokens.contains(where: { $0.lowercased() == "none" }) { return [] }
        return tokens
    }

    private static func parseSeedData(_ raw: String?) -> SeedData {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }
        let tokens = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        var result: SeedData = []
        if tokens.contains("voices") { result.insert(.voices) }
        if tokens.contains("history") { result.insert(.history) }
        return result
    }

    private static func parseBackendScenario(_ raw: String?) -> BackendScenario {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let value = BackendScenario(rawValue: raw) else {
            return .success
        }
        return value
    }

    private static func parseDownloadScenario(_ raw: String?) -> DownloadScenario {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let value = DownloadScenario(rawValue: raw) else {
            return .success
        }
        return value
    }

    private static func parseDelay(_ raw: String?, default: Int) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw) else {
            return `default`
        }
        return max(0, min(value, 30_000))
    }

    private static func parseTriState(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "false", "no", "off": return false
        case "1", "true", "yes", "on": return true
        default: return nil
        }
    }

    private static func defaultDelay(for scenario: BackendScenario) -> Int {
        switch scenario {
        case .success: return 900
        case .slow: return 6_000
        case .fail: return 900
        case .cancelMid: return 12_000
        case .cloneMissingRef: return 900
        }
    }
}
