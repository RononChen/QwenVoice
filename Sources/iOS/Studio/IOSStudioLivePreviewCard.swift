import SwiftUI

/// Live-preview hero player shown in Studio's dock area WHILE generation is still
/// in flight and the shared `AudioPlayerViewModel` is streaming audible audio.
///
/// Visually near-identical to `IOSStudioInlinePlayerCard` (same chrome + waveform
/// row) so the `.live → .complete` dock swap doesn't flash. It mirrors/forwards the
/// shared player (no second AVAudioPlayer) via `IOSInlinePlaybackController.adoptLive`,
/// shows a progressing waveform + elapsed/estimated time, a play/pause button, a
/// "Generating…" status, and a Cancel control. Scrubbing + Save/Download are absent
/// (no final file yet); they appear once this becomes the completed inline card.
struct IOSStudioLivePreviewCard: View {
    let item: IOSStudioLivePreviewItem
    let tint: Color
    let onCancel: () -> Void

    @State private var controller = IOSInlinePlaybackController()
    @State private var pulse = false
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @Environment(\.iosReduceMotionEnabled) private var reduceMotion

    private let referenceHeight: CGFloat = 127

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InlineWaveformProgressRow(
                controller: controller,
                waveformSeed: item.waveformSeed,
                tint: tint,
                scrubEnabled: false
            )
            controlsRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .frame(height: referenceHeight)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 13 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.85))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 5, x: 0, y: 2)
        .transition(cardTransition)
        .task {
            // Singular live session for this card's lifetime — mirror the shared player.
            controller.adoptLive(sharedPlayer: audioPlayer)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onDisappear {
            controller.stop()   // stops mirroring only; never the shared player
        }
        .accessibilityIdentifier("studio_livePreviewPlayer")
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    // MARK: - Controls row

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button {
                controller.togglePlayback()
                IOSHaptics.selection()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.accentForeground)
                    .frame(width: 48, height: 48)
                    .background {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        tint,
                                        tint.mix(with: .black, by: 0.20, in: .perceptual),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("studio_livePreview_playPause")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.voiceName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .lineLimit(1)
                liveStatusLabel
            }
            .padding(.leading, 4)

            Spacer(minLength: 0)

            Button(action: onCancel) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle().fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.7))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel generation")
            .accessibilityIdentifier("studio_livePreview_cancel")
        }
    }

    private var liveStatusLabel: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .opacity(reduceMotion ? 1.0 : (pulse ? 1.0 : 0.3))
            Text("Generating… · \(item.modeLabel)")
                .font(.system(size: 11))
                .foregroundStyle(IOSAppTheme.textSecondary)
                .lineLimit(1)
        }
    }
}
