import SwiftUI
import QwenVoiceCore

/// Top-level Voices tab entry point. Reads/writes `AppModel` state
/// directly so the screen doesn't need binding plumbing from
/// RootView.
///
/// Mirrors `design_references/Vocello iOS/screens.jsx` Voices section:
/// the unified built-in + saved voices list with search + filter chips
/// + a dashed "Save a new voice" CTA. The actual list rendering lives
/// in `IOSVoicesView` (already aligned with the design); this screen
/// is the AppModel-aware shell around it.
///
/// Routing semantics:
/// - Tap a built-in speaker → preset `customVoiceDraft.selectedSpeaker`,
///   switch to Custom mode, jump to Studio tab.
/// - Tap a saved voice → stage `PendingVoiceCloningHandoff`, switch to
///   Clone mode, jump to Studio.
struct VoicesScreen: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        IOSVoicesView(
            selectedTab: $appModel.tab,
            onSelectBuiltInSpeaker: { speaker in
                appModel.customVoiceDraft.selectedSpeaker = speaker.id
                appModel.studioMode = .custom
                appModel.tab = .studio
            },
            onSelectSavedVoice: { voice in
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
