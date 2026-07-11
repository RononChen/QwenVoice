import AppKit
import Foundation
import SwiftUI

struct AppLaunchConfiguration {
    /// Live read (2026-07-02): honors a mid-session Reduce Motion toggle immediately.
    /// `accessibilityDisplayShouldReduceMotion` is a cheap workspace property — no
    /// caching needed, and the old launch-only snapshot ignored System Settings
    /// changes until restart.
    var animationsEnabled: Bool {
        overriddenAnimationsEnabled ?? !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private let overriddenAnimationsEnabled: Bool?
    private let initialSidebarItemOverride: InitialSidebarItemOverride?

    static let current = AppLaunchConfiguration()

    init(
        animationsEnabled: Bool? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        debugModeEnabled: Bool = DebugMode.isEnabled
    ) {
        self.overriddenAnimationsEnabled = animationsEnabled
        self.initialSidebarItemOverride = InitialSidebarItemOverride.resolve(
            environment: environment,
            debugModeEnabled: debugModeEnabled
        )
    }

    var initialSidebarItem: SidebarItem? {
        guard let initialSidebarItemOverride else { return nil }
        switch initialSidebarItemOverride {
        case .settings:
            return .settings
        case .history:
            return .history
        case .custom:
            return .customVoice
        }
    }

    var shouldOpenSettingsOnLaunch: Bool {
        false
    }

    func animation(_ animation: Animation?) -> Animation? {
        animationsEnabled ? animation : nil
    }

    static func performAnimated<Result>(_ animation: Animation?, _ updates: () -> Result) -> Result {
        withAnimation(current.animation(animation), updates)
    }

    @MainActor static func openSettingsWindowIfNeeded() {
    }
}
