import SwiftUI
import QwenVoiceCore

/// Debug-only accessibility hooks for the UI-driven on-device bench
/// (`VocelloiOSBenchUITests` via `scripts/ios_device.sh bench-ui`) — the iOS
/// counterpart of macOS `MacUITestSurfaceMarkers`.
///
/// Rendered by `StudioScreen` only when `QWENVOICE_UI_TEST_HOOKS=1` is in the
/// launch environment (the bench driver always sets it; never set in production
/// launches). Exposes:
///
/// - `iosStudio_lastGenerationComplete` — the file name of the most recently
///   completed take's audio across all three mode coordinators ("none" until the
///   first take). The bench waits for this VALUE TO CHANGE per take instead of
///   polling player chrome, which stays visible between takes.
/// - `iosStudio_generationError` — the active mode's error message ("none" when
///   clear) so a failed take aborts the wait immediately instead of timing out.
/// - `iosStudio_benchClearScript` — a hidden button that clears all three mode
///   drafts, giving warm in-session takes a deterministic composer without
///   fighting UITextView text selection.
struct IOSStudioBenchHooks: View {
    @Environment(AppModel.self) private var appModel

    static var isEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["QWENVOICE_UI_TEST_HOOKS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value else { return false }
        return ["1", "true", "on", "yes"].contains(value)
    }

    var body: some View {
        VStack(spacing: 0) {
            marker(value: lastCompletedValue, identifier: "iosStudio_lastGenerationComplete")
            marker(value: errorValue, identifier: "iosStudio_generationError")
            Button {
                appModel.customVoiceDraft.text = ""
                appModel.voiceDesignDraft.text = ""
                appModel.voiceCloningDraft.text = ""
                // Warm in-session takes reuse one launch; dismiss the inline
                // player so the dock returns to the Generate CTA for the next take.
                for mode in [GenerationMode.custom, .design, .clone] {
                    appModel.coordinator(for: mode).dismissInlinePlayer()
                }
            } label: {
                Color.clear.frame(width: 8, height: 8)
            }
            .accessibilityIdentifier("iosStudio_benchClearScript")
            .accessibilityLabel("bench clear script")
        }
        .opacity(0.011)
        .allowsHitTesting(true)
    }

    /// Newest completed take across the three coordinators. Each take writes a
    /// distinct output file, so the file name is a unique per-take token.
    private var lastCompletedValue: String {
        if let item = appModel.coordinator(for: appModel.studioMode.mode).lastCompletedOutput {
            return item.audioURL.lastPathComponent
        }
        // Fall back to any mode (handoffs can land takes outside the visible mode).
        for mode in [GenerationMode.custom, .design, .clone] {
            if let item = appModel.coordinator(for: mode).lastCompletedOutput {
                return item.audioURL.lastPathComponent
            }
        }
        return "none"
    }

    private var errorValue: String {
        appModel.coordinator(for: appModel.studioMode.mode).errorMessage ?? "none"
    }

    private func marker(value: String, identifier: String) -> some View {
        Text(value)
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityLabel(value)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
            .accessibilityHidden(false)
    }
}
