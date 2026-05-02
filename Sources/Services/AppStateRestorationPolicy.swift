import AppKit
import Foundation

enum AppStateRestorationPolicy {
    static func allowsStateRestoration() -> Bool {
#if QW_TEST_SUPPORT
        allowsStateRestoration(
            isUITestLaunch: AppLaunchConfiguration.current.isUITest,
            isAudioQualityHeadlessHost: AppLaunchConfiguration.current.isAudioQualityHeadlessHost
        )
#else
        true
#endif
    }

#if QW_TEST_SUPPORT
    static func allowsStateRestoration(
        isUITestLaunch: Bool,
        isAudioQualityHeadlessHost: Bool
    ) -> Bool {
        !isUITestLaunch && !isAudioQualityHeadlessHost
    }
#endif
}

@MainActor
final class QwenVoiceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
#if QW_TEST_SUPPORT
        AppLaunchConfiguration.configureAudioQualityHeadlessHostIfNeeded()
#endif
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        AppStateRestorationPolicy.allowsStateRestoration()
    }

    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        AppStateRestorationPolicy.allowsStateRestoration()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if QW_TEST_SUPPORT
        if AppLaunchConfiguration.current.isAudioQualityHeadlessHost {
            AppLaunchConfiguration.hideAudioQualityHeadlessHostWindowsIfNeeded()
            return
        }
        guard AppLaunchConfiguration.current.isUITest else { return }

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
#endif
    }
}
