import Foundation
import Observation
import QwenVoiceCore

/// Per-mode generation lifecycle state. Lifted out of the three legacy
/// per-mode views (`IOSCustomVoiceView`, `IOSVoiceDesignView`,
/// `IOSVoiceCloningView`) where it used to live as scattered `@State`.
///
/// `AppModel` owns three instances (one per `GenerationMode`). Views
/// read state via `@Environment(AppModel.self)` and mutate via the
/// `start()` / `finish()` / `complete(...)` lifecycle methods.
///
/// The actual `await ttsEngine.generate(...)` call still lives in the
/// per-mode views for now — they have to assemble mode-specific
/// `GenerationRequest` payloads from their drafts + speakers + delivery
/// state — but UI-visible state (`isGenerating`, `errorMessage`,
/// `lastCompletedOutput`) now flows through this Observable so the
/// unified StudioScreen + StudioDock can react without per-mode
/// branching.
@MainActor
@Observable
final class StudioGenerationCoordinator {
    let mode: GenerationMode

    /// `true` while a generation request is in flight. Drives the
    /// generating-state animation + Cancel button in the dock area.
    var isGenerating: Bool = false

    /// Last error surfaced to the user. Cleared when a fresh attempt
    /// starts.
    var errorMessage: String?

    /// The most-recently completed take, surfaced as an inline player
    /// card. Nil while no take has completed (or after Dismiss).
    var lastCompletedOutput: IOSStudioInlinePlayerItem?

    /// In-flight generation task, retained so callers can cancel it.
    /// Stored as `AnyObject` to keep the coordinator type-erased from
    /// Swift concurrency generics; callers do the casting.
    var generationTask: Task<Void, Never>?

    init(mode: GenerationMode) {
        self.mode = mode
    }

    /// Marks a generation attempt as started. Clears any prior error.
    func start() {
        errorMessage = nil
        isGenerating = true
    }

    /// Marks the in-flight attempt as completed (success or failure).
    /// Use `.complete(_:)` to also surface the inline player item.
    func finish() {
        isGenerating = false
        generationTask = nil
    }

    /// Surfaces a completed take to the dock area + clears in-flight.
    func complete(_ item: IOSStudioInlinePlayerItem) {
        lastCompletedOutput = item
        isGenerating = false
        generationTask = nil
    }

    /// Sets an error and clears the in-flight flag.
    func fail(_ message: String) {
        errorMessage = message
        isGenerating = false
        generationTask = nil
    }

    /// Clears the inline player (user dismissed it).
    func dismissInlinePlayer() {
        lastCompletedOutput = nil
    }
}
