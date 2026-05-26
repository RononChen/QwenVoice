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
        Task {
            try? await ttsEngine.cancelActiveGeneration()
            await MainActor.run {
                audioPlayer.abortLivePreviewIfNeeded()
                coordinator.finish()
            }
        }
    }
}
