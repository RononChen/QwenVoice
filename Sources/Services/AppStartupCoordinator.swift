import Foundation
import QwenVoiceCore

@MainActor
final class AppStartupCoordinator: ObservableObject {
    @Published private(set) var launchDiagnostics: AppLaunchDiagnosticsSnapshot?
    private var didSetUpAppSupport = false

    func setupAppSupport() {
        guard !didSetUpAppSupport else { return }
        didSetUpAppSupport = true

        let fm = FileManager.default
        let outputSubdirectories = Set(TTSModel.all.map(\.outputSubfolder))

        // A process termination can strand segment WAVs. Long-form workspaces
        // are never user assets, so sweep only our UUID-owned children before
        // recreating the cache directory for this launch.
        try? LongFormTaskWorkspace.removeOrphanedTasks(
            in: AppPaths.longFormWorkDir,
            fileManager: fm
        )

        let dirs = [
            QwenVoiceApp.appSupportDir.path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("models").path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("outputs").path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("voices").path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("cache").path,
            QwenVoiceApp.appSupportDir.appendingPathComponent("cache/stream_sessions").path,
            AppPaths.longFormWorkDir.path,
        ] + outputSubdirectories.sorted().map {
            QwenVoiceApp.appSupportDir.appendingPathComponent("outputs/\($0)").path
        }

        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        AppPaths.excludeFromBackup(QwenVoiceApp.appSupportDir.appendingPathComponent("models", isDirectory: true))
        AppPaths.excludeFromBackup(QwenVoiceApp.appSupportDir.appendingPathComponent("cache", isDirectory: true))
    }

    func refreshLaunchDiagnostics() {
        launchDiagnostics = AppLaunchPreflight.run()
    }

    func clearLaunchDiagnostics() {
        launchDiagnostics = nil
    }
}
