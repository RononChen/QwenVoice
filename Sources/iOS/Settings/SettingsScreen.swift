import SwiftUI
import QwenVoiceCore

/// Top-level Settings tab entry point. Reads/writes `AppModel`
/// directly so RootView doesn't need binding plumbing.
///
/// Mirrors `design_references/Vocello iOS/screens.jsx` Settings
/// section: per-model rows with install/delete inline buttons,
/// autoplay toggle, storage row, Reduce Motion / Reduce Transparency
/// rows linking to iOS Settings, version footer.
///
/// The actual rendering still lives in the legacy
/// `IOSSettingsContainerView`; Phase 6 lifts the body into a
/// dedicated `SettingsView` and wires the `IOSDeleteModelSheet`
/// flow that was deferred from Track M.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        IOSSettingsContainerView(selectedTab: $appModel.tab)
    }
}
