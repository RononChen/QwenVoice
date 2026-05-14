import Foundation

enum AppPaths {
    static let appSupportOverrideEnvironmentKey = "QWENVOICE_APP_SUPPORT_DIR"

    private static let defaultFolderName: String = {
        #if DEBUG
        return "QwenVoice-Debug"
        #else
        return "QwenVoice"
        #endif
    }()

    private static let legacyFolderName = "QwenVoice"

    static var appSupportDir: URL {
        if let overridePath = ProcessInfo.processInfo.environment[appSupportOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        return baseApplicationSupportDir().appendingPathComponent(defaultFolderName, isDirectory: true)
    }

    static var modelsDir: URL {
        appSupportDir.appendingPathComponent("models", isDirectory: true)
    }

    static var outputsDir: URL {
        appSupportDir.appendingPathComponent("outputs", isDirectory: true)
    }

    static var voicesDir: URL {
        appSupportDir.appendingPathComponent("voices", isDirectory: true)
    }

    // One-shot: rename ~/Library/Application Support/QwenVoice ->
    // QwenVoice-Debug on first Debug launch so testing data survives the
    // policy switch. Idempotent; skipped when an env-var override is set.
    static func migrateLegacyDataIfNeeded() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[appSupportOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return
        }
        let base = baseApplicationSupportDir()
        let newURL = base.appendingPathComponent(defaultFolderName, isDirectory: true)
        let legacyURL = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: newURL.path),
              fm.fileExists(atPath: legacyURL.path) else { return }
        do {
            try fm.moveItem(at: legacyURL, to: newURL)
            NSLog("AppPaths: migrated legacy data folder %@ -> %@", legacyURL.path, newURL.path)
        } catch {
            NSLog("AppPaths: legacy data folder migration failed: %@", String(describing: error))
        }
        #endif
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
