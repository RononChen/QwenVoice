import SwiftUI
import QwenVoiceCore

/// Debug-only accessibility hooks for the UI-driven on-device bench
/// (`VocelloiOSBenchUITests` / `bench-ui-mirroir` via `scripts/ios_device.sh`) — the iOS
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
/// - `iosStudio_benchClearScript` — clears all three mode drafts and dismisses
///   the inline player. OCR-visible **Clear script** label for mirroir agent bench;
///   XCUITest taps the same control by accessibility id.
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
        VStack(alignment: .leading, spacing: 2) {
            marker(value: lastCompletedValue, identifier: "iosStudio_lastGenerationComplete")
            marker(value: errorValue, identifier: "iosStudio_generationError")
            Button {
                clearAllDraftsAndDismissPlayer()
            } label: {
                Text("Clear script")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityIdentifier("iosStudio_benchClearScript")
            .accessibilityLabel("Clear script")
        }
        .padding(4)
    }

    private func clearAllDraftsAndDismissPlayer() {
        appModel.customVoiceDraft.text = ""
        appModel.voiceDesignDraft.text = ""
        appModel.voiceCloningDraft.text = ""
        for mode in [GenerationMode.custom, .design, .clone] {
            appModel.coordinator(for: mode).dismissInlinePlayer()
        }
    }

    /// Newest completed take across the three coordinators. Each take writes a
    /// distinct output file, so the file name is a unique per-take token.
    private var lastCompletedValue: String {
        if let item = appModel.coordinator(for: appModel.studioMode.mode).lastCompletedOutput {
            return item.audioURL.lastPathComponent
        }
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
            .opacity(0.011)
    }
}
