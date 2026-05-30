import Foundation

enum AppPaths {
    static let appSupportOverrideEnvironmentKey = "QWENVOICE_APP_SUPPORT_DIR"
    /// Overrides ONLY the models directory, leaving diagnostics/history/outputs in
    /// the resolved `appSupportDir`. Lets a debug-isolated run (separate
    /// diagnostics/history folder) reuse the real app's downloaded model weights
    /// without copying or symlinking them — useful on storage-tight machines when
    /// capturing telemetry/benchmarks. Unset ⇒ `appSupportDir/models` as before.
    static let modelsDirOverrideEnvironmentKey = "QWENVOICE_MODELS_DIR"

    // Single package: production data lives in `QwenVoice/`. When the runtime
    // debug toggle is on, dev work is isolated in `QwenVoice-Debug/` so it never
    // touches real data. (Resolved once at launch via DebugMode.isEnabled.)
    private static let defaultFolderName: String =
        DebugMode.isEnabled ? "QwenVoice-Debug" : "QwenVoice"

    static var appSupportDir: URL {
        if let overridePath = ProcessInfo.processInfo.environment[appSupportOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        return baseApplicationSupportDir().appendingPathComponent(defaultFolderName, isDirectory: true)
    }

    static var modelsDir: URL {
        if let overridePath = ProcessInfo.processInfo.environment[modelsDirOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        return appSupportDir.appendingPathComponent("models", isDirectory: true)
    }

    static var outputsDir: URL {
        appSupportDir.appendingPathComponent("outputs", isDirectory: true)
    }

    static var voicesDir: URL {
        appSupportDir.appendingPathComponent("voices", isDirectory: true)
    }

    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private static func baseApplicationSupportDir() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(
                fileURLWithPath: (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Library/Application Support"),
                isDirectory: true
            )
    }
}

enum AppDefaults {
    // Mirror the data-folder isolation: when the debug toggle is on, dev
    // preferences live in a separate suite so they never pollute real prefs.
    static var store: UserDefaults {
        if DebugMode.isEnabled,
           let suite = UserDefaults(suiteName: "com.qwenvoice.app.debug") {
            return suite
        }
        return .standard
    }
}
