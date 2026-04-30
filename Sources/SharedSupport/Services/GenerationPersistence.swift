import Foundation

#if canImport(QwenVoiceCore)
import QwenVoiceCore
#endif

#if canImport(QwenVoiceNative)
import QwenVoiceNative
#endif

#if canImport(QwenVoiceNative)
typealias PersistenceGenerationResult = QwenVoiceNative.GenerationResult
#elseif canImport(QwenVoiceCore)
typealias PersistenceGenerationResult = QwenVoiceCore.GenerationResult
#endif

/// Shared generation persistence and autoplay logic used by all three generation views.
@MainActor
enum GenerationPersistence {

    enum PersistenceError: LocalizedError {
        case postPlaybackPersistenceFailed(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .postPlaybackPersistenceFailed(let underlyingError):
                return underlyingError.localizedDescription
            }
        }
    }

    /// Saves a generation to the database, posts a notification, and triggers autoplay if configured.
    static func persistAndAutoplay(
        _ generation: inout Generation,
        result: PersistenceGenerationResult,
        text: String,
        audioPlayer: AudioPlayerViewModel,
        caller: String
    ) throws {
        AppPerformanceSignposts.emit("Final File Ready")
        CustomVoiceUIPerformanceTrace.mark(
            .finalFileReady,
            metadata: [
                "caller": caller,
                "used_streaming": result.usedStreaming ? "true" : "false",
            ],
            metrics: [
                "duration_ms": Int(result.durationSeconds * 1_000),
            ]
        )

        var didHandoffPlayback = false
        if result.usedStreaming {
            audioPlayer.completeStreamingPreview(
                result: result,
                title: String(text.prefix(40)),
                shouldAutoPlay: AudioService.shouldAutoPlay
            )
            didHandoffPlayback = true
        } else {
            let autoplayStart = DispatchTime.now().uptimeNanoseconds
            audioPlayer.playFile(
                result.audioPath,
                title: String(text.prefix(40)),
                isAutoplay: AudioService.shouldAutoPlay,
                presentationContext: .generatePreview
            )
            didHandoffPlayback = true
            #if DEBUG
            print("[Performance][\(caller)] autoplay_start_wall_ms=\(elapsedMs(since: autoplayStart))")
            #endif
        }

        var persistenceError: Swift.Error?
        do {
            let saveStart = DispatchTime.now().uptimeNanoseconds
            try DatabaseService.shared.saveGeneration(&generation)
            #if DEBUG
            print("[Performance][\(caller)] db_save_wall_ms=\(elapsedMs(since: saveStart))")
            #endif
            CustomVoiceUIPerformanceTrace.mark(
                .databaseSaveFinished,
                metrics: [
                    "wall_ms": elapsedMs(since: saveStart),
                ]
            )

            let notificationStart = DispatchTime.now().uptimeNanoseconds
            #if canImport(QwenVoiceNative)
            GenerationLibraryEvents.shared.announceGenerationSaved()
            #else
            NotificationCenter.default.post(name: .generationSaved, object: nil)
            #endif
            #if DEBUG
            print("[Performance][\(caller)] history_notification_wall_ms=\(elapsedMs(since: notificationStart))")
            #endif
            CustomVoiceUIPerformanceTrace.mark(
                .historyNotificationFinished,
                metrics: [
                    "wall_ms": elapsedMs(since: notificationStart),
                ]
            )
        } catch {
            persistenceError = error
        }

        if let persistenceError {
            if didHandoffPlayback {
                throw PersistenceError.postPlaybackPersistenceFailed(persistenceError)
            }
            throw persistenceError
        }
        CustomVoiceUIPerformanceTrace.mark(.persistenceFinished)
    }

    private static func elapsedMs(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
