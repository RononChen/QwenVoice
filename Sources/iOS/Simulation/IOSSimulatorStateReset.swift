import Foundation

#if targetEnvironment(simulator)

/// Hermetic reset of all simulator-only state. Called once at launch when
/// `QVOICE_SIM_RESET_STATE=1` is set (e.g., by XCUITest `relaunchWith(scenario:)`).
@MainActor
enum IOSSimulatorStateReset {
    static func perform(registry: IOSSimulatorFakeInstallRegistry) {
        registry.resetAll()
        clearSavedVoices()
        clearHistory()
        clearPreparedAudio()
        clearImportedReferenceAudio()
        clearOutputs()
        clearStreamSessions()
    }

    private static func clearSavedVoices() {
        clearDirectory(AppPaths.voicesDir)
    }

    private static func clearHistory() {
        DatabaseService.shared.deleteAllGenerations()
        clearDirectory(AppPaths.outputsDir)
    }

    private static func clearPreparedAudio() {
        clearDirectory(AppPaths.preparedAudioDir)
        clearDirectory(AppPaths.normalizedCloneReferenceDir)
    }

    private static func clearImportedReferenceAudio() {
        clearDirectory(AppPaths.importedReferenceAudioDir)
    }

    private static func clearOutputs() {
        clearDirectory(AppPaths.outputsDir)
    }

    private static func clearStreamSessions() {
        clearDirectory(AppPaths.streamSessionsDir)
    }

    private static func clearDirectory(_ url: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let child as URL in enumerator {
            try? fm.removeItem(at: child)
        }
    }
}

#endif
