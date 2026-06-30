import Foundation
import QwenVoiceCore

/// Debug-only accessibility markers for macOS XCUITest (human + bench drivers).
@MainActor
enum MacUITestSurfaceMarkers {
    private static let hooksKey = "QWENVOICE_UI_TEST_HOOKS"

    static var isEnabled: Bool {
        if TelemetryGate.appProcessIntendedEnabled { return true }
        let value = ProcessInfo.processInfo.environment[hooksKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value else { return false }
        return ["1", "true", "on", "yes"].contains(value)
    }

    private(set) static var composeReadyCustom = false
    private(set) static var composeReadyDesign = false
    private(set) static var composeReadyClone = false
    private(set) static var lastGenerationCompleteID: String?
    private(set) static var lastTelemetryFlushedID: String?

    static func setComposeReady(mode: String, ready: Bool) {
        guard isEnabled else { return }
        switch mode {
        case "custom", "customVoice": composeReadyCustom = ready
        case "design", "voiceDesign": composeReadyDesign = ready
        case "clone", "voiceCloning": composeReadyClone = ready
        default: break
        }
    }

    static func markGenerationComplete(id: UUID?) {
        guard isEnabled, let id else { return }
        lastGenerationCompleteID = id.uuidString
    }

    static func markTelemetryFlushed(id: String?) {
        guard isEnabled, let id else { return }
        lastTelemetryFlushedID = id
    }
}
