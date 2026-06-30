import Foundation
import QwenVoiceCore

/// Runtime matrix overrides for macOS XPC UI bench (`scripts/macos_test.sh bench-ui`).
enum VocelloMacBenchMatrixConfig {
    private static let overridePath = "/tmp/vocello-bench-matrix.json"

    struct Parsed: Sendable {
        let modes: [String]
        let lengths: [String]
        let warm: Int
    }

    static func load() -> Parsed {
        if let file = loadOverrideFile() {
            return file
        }
        let env = ProcessInfo.processInfo.environment
        let modes = parseList(env["QVOICE_MAC_BENCH_MODES"], defaultValue: BenchMatrixSpec.defaultModes)
        let lengths = parseList(env["QVOICE_MAC_BENCH_LENGTHS"], defaultValue: BenchMatrixSpec.defaultLengths)
        let warm = Int(env["QVOICE_MAC_BENCH_WARM"] ?? "") ?? BenchMatrixSpec.defaultWarmReps
        return Parsed(modes: modes, lengths: lengths, warm: warm)
    }

    private static func loadOverrideFile() -> Parsed? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: overridePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let modes = parseList(json["modes"] as? String, defaultValue: BenchMatrixSpec.defaultModes)
        let lengths = parseList(json["lengths"] as? String, defaultValue: BenchMatrixSpec.defaultLengths)
        let warm: Int
        if let n = json["warm"] as? Int {
            warm = n
        } else if let s = json["warm"] as? String, let n = Int(s) {
            warm = n
        } else {
            warm = BenchMatrixSpec.defaultWarmReps
        }
        return Parsed(modes: modes, lengths: lengths, warm: warm)
    }

    private static func parseList(_ raw: String?, defaultValue: [String]) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultValue
        }
        return raw.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
}
