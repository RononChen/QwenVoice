import AppKit
import Foundation

enum AppStateRestorationPolicy {
    static func allowsStateRestoration() -> Bool {
        true
    }
}

@MainActor
final class QwenVoiceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
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
    }
}
