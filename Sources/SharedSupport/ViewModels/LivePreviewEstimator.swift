import Foundation

#if canImport(QwenVoiceCore)
import QwenVoiceCore
#endif

/// Forecasts the audio duration and engine RTF for an upcoming
/// generation, so `AudioPlayerViewModel.shouldStartLivePlayback` can
/// compute a "smooth playback" prebuffer that covers the production
/// deficit. Single source of truth for the empirical constants —
/// future tuning lives here.
///
/// Constants are sourced from the May 2026 cross-layer-probe
/// benchmark (`scripts/bench_ui_generation.sh` + 30-sample matrix at
/// `/tmp/all-modes-bench-results.csv`), validated against per-chunk
/// `infer_ms` medians on M1 Mac mini 8 GB:
///   - Custom Voice (warm, medium/long): RTF ≈ 2.0× (was 1.65×;
///     measured 2.17-2.22 at warm steady state)
///   - Voice Design (warm, medium/long): RTF ≈ 1.7× (was 1.50×;
///     measured 1.59-1.83)
///   - Voice Cloning (warm, medium/long): RTF ≈ 2.3× (was 1.65×;
///     measured 2.37-2.45)
///
/// Words-to-audio rate of ~0.40 audio s / word matches ~150 wpm
/// English speech. Empirical: 50-word texts → ~0.34 s/word, 110-word
/// → ~0.34-0.45 s/word. The 0.40 estimate sits in the middle and
/// slightly over-estimates — that's intentional. Oversized prebuffer
/// is safe; undersized risks underrun mid-play.
enum LivePreviewEstimator {
    /// Approximate audio duration for the given English word count.
    /// Conservative (slightly over-estimates) so the predictive
    /// prebuffer leans toward "smooth" rather than "almost smooth."
    static func estimatedAudioSeconds(forWordCount wordCount: Int) -> TimeInterval {
        guard wordCount > 0 else { return 0 }
        return Double(wordCount) * 0.40
    }

    /// Convenience for callers that have raw text. Splits on
    /// whitespace and counts non-empty tokens.
    static func estimatedAudioSeconds(forText text: String) -> TimeInterval {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.isEmpty }
            .count
        return estimatedAudioSeconds(forWordCount: words)
    }

    #if canImport(QwenVoiceCore)
    /// Empirical engine RTF for the given mode (warm, medium/long).
    /// Returns nil for modes where the production deficit isn't a
    /// concern in practice.
    static func estimatedRTF(for mode: GenerationMode) -> Double? {
        switch mode {
        case .custom: return 2.0
        case .design: return 1.7
        case .clone:  return 2.3
        }
    }
    #endif
}
