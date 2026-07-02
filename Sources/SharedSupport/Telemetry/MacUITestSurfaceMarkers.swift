import Foundation
import Observation
import QwenVoiceCore

/// Debug-only accessibility markers for macOS XCUITest (human + bench drivers).
///
/// Audit J1: this must be `@Observable` — the hidden marker `Text`s in
/// `ContentView.HiddenWindowMarkers` render these values, and with plain
/// statics SwiftUI never invalidated the view when a marker changed, so the
/// bench driver's telemetry-flush wait watched a permanently stale "none" and
/// cold relaunches raced the async JSONL writes (engine 29 rows vs app 27).
@MainActor
@Observable
final class MacUITestSurfaceMarkers {
    static let shared = MacUITestSurfaceMarkers()

    private static let hooksKey = "QWENVOICE_UI_TEST_HOOKS"

    static var isEnabled: Bool {
        if TelemetryGate.appProcessIntendedEnabled { return true }
        let value = ProcessInfo.processInfo.environment[hooksKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value else { return false }
        return ["1", "true", "on", "yes"].contains(value)
    }

    private(set) var composeReadyCustom = false
    private(set) var composeReadyDesign = false
    private(set) var composeReadyClone = false
    private(set) var lastGenerationCompleteID: String?
    private(set) var lastTelemetryFlushedID: String?

    static func setComposeReady(mode: String, ready: Bool) {
        guard isEnabled else { return }
        switch mode {
        case "custom", "customVoice": shared.composeReadyCustom = ready
        case "design", "voiceDesign": shared.composeReadyDesign = ready
        case "clone", "voiceCloning": shared.composeReadyClone = ready
        default: break
        }
    }

    static func markGenerationComplete(id: UUID?) {
        guard isEnabled, let id else { return }
        shared.lastGenerationCompleteID = id.uuidString
    }

    static func markTelemetryFlushed(id: String?) {
        guard isEnabled, let id else { return }
        shared.lastTelemetryFlushedID = id
    }
}
