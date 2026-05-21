import SwiftUI
import QwenVoiceCore

/// Top-level History tab entry point. Reads/writes `AppModel` directly
/// so RootView doesn't need binding plumbing.
///
/// Mirrors `design_references/Vocello iOS/screens.jsx` History section:
/// date-bucketed rows with mini-waveform thumbnails, search field, mode
/// filter chips, and a three-dot menu (Play / Save audio / Delete) on
/// each row. Tap on the row body presents the full-screen Player sheet
/// via the `\.presentIOSPlayerSheet` environment closure.
///
/// The actual row + section rendering lives in
/// `IOSLibraryContainerView` (with the History section forced); this
/// screen is the AppModel-aware shell around it. Phase 6 collapses
/// the library container into a dedicated History view file.
struct HistoryScreen: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        IOSLibraryContainerView(
            selectedTab: $appModel.tab,
            selectedSection: .constant(.history),
            showsHeader: false,
            onUseVoiceInClone: { voice in
                appModel.pendingVoiceCloningHandoff = PendingVoiceCloningHandoff(
                    savedVoiceID: voice.id,
                    wavPath: voice.wavPath,
                    transcript: (try? voice.loadTranscript()) ?? "",
                    transcriptLoadError: nil
                )
                appModel.studioMode = .clone
                appModel.tab = .studio
            }
        )
    }
}
