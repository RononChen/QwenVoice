import AVFoundation
import Foundation

/// Tiny audio player for reviewing a just-recorded (or just-generated) reference clip inside the
/// "Save this voice" sheet: play/pause + a 0…1 progress for the waveform playhead + the clip's
/// duration. Deliberately small — the Studio `AudioPlayerViewModel` is too coupled to the
/// generation flow, and `IOSVoicePreviewPlayer` has no progress.
@MainActor
final class ClipReviewPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0   // 0…1
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var url: URL?
    private var timer: Timer?

    /// Prepare the player + read the duration without starting playback.
    func load(url: URL) {
        guard self.url != url else { return }
        stop()
        self.url = url
        if let prepared = try? AVAudioPlayer(contentsOf: url) {
            prepared.delegate = self
            prepared.prepareToPlay()
            player = prepared
            duration = prepared.duration
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    private func play() {
        guard let player else { return }
        #if os(iOS)
        // The recorder leaves the session on `.record`/deactivated — switch to playback so the
        // clip comes out of the speaker. (macOS has no AVAudioSession; output routing is direct.)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true, options: [])
        #endif
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        url = nil
        isPlaying = false
        progress = 0
        duration = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player, player.duration > 0 else { return }
        progress = min(1, player.currentTime / player.duration)
    }
}

extension ClipReviewPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.progress = 0
            self.stopTimer()
            self.player?.currentTime = 0
        }
    }
}
