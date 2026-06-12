import AppKit
import SwiftUI

struct AppLaunchConfiguration {
    let animationsEnabled: Bool

    static let current = AppLaunchConfiguration()

    /// Resolved once at launch, like the rest of this configuration —
    /// Reduce Motion is honored on the next launch if toggled mid-session.
    init(animationsEnabled: Bool = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.animationsEnabled = animationsEnabled
    }

    var initialSidebarItem: SidebarItem? {
        nil
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
