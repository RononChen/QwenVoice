import Foundation
import QwenVoiceCore

@MainActor
enum IOSStudioGenerationActions {
    static func cancelGeneration(
        coordinator: StudioGenerationCoordinator,
        ttsEngine: TTSEngineStore,
        audioPlayer: AudioPlayerViewModel
    ) {
        coordinator.generationTask?.cancel()
        // Return the dock to idle immediately. iOS cancel is cooperative — the
        // engine keeps computing to completion and the awaited generate Task
        // discards its result on Task.isCancelled — so don't make the UI wait on
        // the (no-op) engine cancel; the generating waveform would otherwise
        // persist for the take's full duration after the user pressed Stop.
        audioPlayer.abortLivePreviewIfNeeded()
        coordinator.finish()
        Task {
            try? await ttsEngine.cancelActiveGeneration()
        }
    }
}
