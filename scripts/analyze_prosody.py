#!/usr/bin/env python3
"""Reference-free PROSODY analyzer for Vocello TTS output (deterministic, numpy-only).

Extends scripts/analyze_delivery.py with richer tone/tempo/cadence features:
  - F0 contour dynamics (std, range, turning points, rise/fall rates)
  - Speaking-rate variability (local rate CV, per-window stats)
  - Pause structure (count, durations, pause-to-speech ratio)
  - Energy dynamics (RMS std, dynamic range, envelope roughness)

Designed to run on low-RAM machines: it processes one 24 kHz mono WAV at a
time, keeps only frame-level arrays, and loads no ML models.

Usage:
  scripts/analyze_prosody.py <wav> [<wav> ...] [--json]
  python3 -c "from analyze_prosody import analyze; print(analyze('clip.wav'))"
"""
import sys, json, wave, math
import numpy as np

F0_MIN, F0_MAX = 70.0, 400.0      # voice F0 search band (Hz)
FRAME_MS, HOP_MS = 40.0, 10.0     # analysis frames
VOICING_AC = 0.30                 # normalized autocorr peak threshold for "voiced"
SYLLABLE_SMOOTH_MS = 50.0         # energy envelope smoothing for syllable nuclei
SYLLABLE_THR = 0.15               # relative energy threshold for syllable peaks
PAUSE_RMS_DB = -50.0              # frames below this are considered silent
PAUSE_MIN_MS = 60.0               # shortest gap counted as a pause
RATE_WINDOW_MS = 2000.0           # window for local speaking-rate variability
EDGE_SKIP_MS = 100.0              # ignore leading/trailing edge for pause stats


def read_wav(path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        n = w.getnframes()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        raw = w.readframes(n)
    if sw != 2:
        raise ValueError(f"expected 16-bit PCM, got sampwidth={sw}")
    x = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def frame_sig(x, frame, hop):
    if len(x) < frame:
        return np.empty((0, frame))
    n = 1 + (len(x) - frame) // hop
    idx = np.arange(frame)[None, :] + hop * np.arange(n)[:, None]
    return x[idx]


def f0_autocorr(frame, sr):
    """Normalized-autocorrelation F0 for one frame. Returns (f0_hz, ac_peak) or (0,0)."""
    f = frame - frame.mean()
    win = np.hanning(len(f))
    f = f * win
    energy = np.dot(f, f)
    if energy < 1e-6:
        return 0.0, 0.0
    ac = np.correlate(f, f, mode="full")[len(f) - 1:]
    ac0 = ac[0]
    if ac0 <= 0:
        return 0.0, 0.0
    lag_min = max(1, int(sr / F0_MAX))
    lag_max = min(len(ac) - 1, int(sr / F0_MIN))
    if lag_max <= lag_min:
        return 0.0, 0.0
    seg = ac[lag_min:lag_max + 1]
    k = int(np.argmax(seg))
    peak = seg[k] / ac0
    lag = lag_min + k
    if 0 < k < len(seg) - 1:
        a, b, c = seg[k - 1], seg[k], seg[k + 1]
        denom = (a - 2 * b + c)
        if denom != 0:
            lag = lag + 0.5 * (a - c) / denom
    return (sr / lag if lag > 0 else 0.0), float(peak)


def _pct(a, p):
    return float(np.percentile(a, p)) if len(a) else 0.0


def _smooth(x, k):
    """Centered moving average with reflection padding; k odd."""
    if k <= 1 or len(x) == 0:
        return x
    pad = k // 2
    padded = np.pad(x, pad, mode="edge")
    kernel = np.ones(k) / k
    return np.convolve(padded, kernel, mode="valid")


def _turning_points(y):
    """Count local maxima + minima in a 1-D series (simple neighbor comparison)."""
    if len(y) < 3:
        return 0
    left = y[:-2]
    mid = y[1:-1]
    right = y[2:]
    return int(np.sum((mid > left) & (mid > right)) + np.sum((mid < left) & (mid < right)))


def _analyze_internal(x, sr, path=""):
    dur = len(x) / sr
    frame = int(sr * FRAME_MS / 1000)
    hop = int(sr * HOP_MS / 1000)
    frames = frame_sig(x, frame, hop)
    if len(frames) == 0:
        return {"clip": path.split("/")[-1], "durationSec": round(dur, 3), "error": "too_short"}

    times = (np.arange(len(frames)) * hop + frame / 2) / sr

    # RMS per frame (dBFS, full-scale = 32768 for Int16)
    rms = np.sqrt((frames ** 2).mean(axis=1))
    rms_db = 20 * np.log10(np.maximum(rms, 1e-9) / 32768.0)

    # F0 + voicing per frame
    f0 = np.zeros(len(frames))
    acp = np.zeros(len(frames))
    for i, fr in enumerate(frames):
        f0[i], acp[i] = f0_autocorr(fr, sr)
    voiced = (acp >= VOICING_AC) & (f0 > 0)
    f0v = f0[voiced]

    # Octave-error rejection: anchor on median and keep [0.5x, 2x]
    if len(f0v):
        med0 = float(np.median(f0v))
        f0v = f0v[(f0v >= 0.5 * med0) & (f0v <= 2.0 * med0)]

    # Syllable-nuclei peaks from smoothed energy envelope
    env = rms / (rms.max() + 1e-9)
    k = max(1, int(SYLLABLE_SMOOTH_MS / HOP_MS))
    if k % 2 == 0:
        k += 1
    env_s = _smooth(env, k)
    peaks = []
    for i in range(1, len(env_s) - 1):
        if env_s[i] > env_s[i - 1] and env_s[i] >= env_s[i + 1] and env_s[i] > SYLLABLE_THR:
            peaks.append(i)
    syllable_rate = len(peaks) / dur if dur > 0 else 0.0

    # Local speaking-rate variability in sliding windows
    local_rates = []
    win_frames = max(1, int(RATE_WINDOW_MS / HOP_MS))
    if win_frames >= 3 and len(peaks) > 0:
        peak_arr = np.array(peaks)
        for start in range(0, len(frames) - win_frames, win_frames // 2):
            end = start + win_frames
            n_peak = int(np.sum((peak_arr >= start) & (peak_arr < end)))
            w_dur = (end - start) * HOP_MS / 1000.0
            local_rates.append(n_peak / w_dur if w_dur > 0 else 0.0)
    local_rates_arr = np.array(local_rates)

    # Pause detection from RMS silence
    silence_db = PAUSE_RMS_DB
    silence = rms_db < silence_db
    min_pause_frames = max(1, int(PAUSE_MIN_MS / HOP_MS))
    edge_frames = int(EDGE_SKIP_MS / HOP_MS)

    pauses = []
    in_pause = False
    start = 0
    for i, is_silent in enumerate(silence):
        if is_silent and not in_pause:
            in_pause = True
            start = i
        elif not is_silent and in_pause:
            in_pause = False
            length = i - start
            if length >= min_pause_frames and start >= edge_frames and i <= len(silence) - edge_frames:
                pauses.append(length * HOP_MS / 1000.0)
    if in_pause:
        length = len(silence) - start
        if length >= min_pause_frames and start >= edge_frames:
            pauses.append(length * HOP_MS / 1000.0)

    total_pause = sum(pauses)
    pause_speech_ratio = total_pause / dur if dur > 0 else 0.0

    # F0 dynamics on the (octave-cleaned) voiced contour
    f0_dynamics = {}
    if len(f0v):
        f0_sorted = np.sort(f0v)
        p10 = float(f0_sorted[max(0, int(0.10 * len(f0_sorted)) - 1)])
        p90 = float(f0_sorted[min(len(f0_sorted) - 1, int(0.90 * len(f0_sorted)) - 1)])
        f0_std = float(np.std(f0v))
        f0_range = p90 - p10
        turning_pts = _turning_points(f0v)
        # Rise/fall rates: sign of frame-to-frame differences
        diffs = np.diff(f0v)
        rise_frames = int(np.sum(diffs > 1.0))   # Hz per frame threshold
        fall_frames = int(np.sum(diffs < -1.0))
        voiced_dur = dur * float(voiced.mean()) if dur > 0 else 0.0
        f0_dynamics = {
            "median_hz": round(float(np.median(f0v)), 1),
            "mean_hz": round(float(np.mean(f0v)), 1),
            "std_hz": round(f0_std, 1),
            "range_hz": round(f0_range, 1),
            "p10_hz": round(p10, 1),
            "p90_hz": round(p90, 1),
            "voiced_frac": round(float(voiced.mean()), 3),
            "turning_points_per_sec": round(turning_pts / voiced_dur, 2) if voiced_dur > 0 else 0.0,
            "rising_rate_hz_per_sec": round(rise_frames * HOP_MS / 1000.0 / voiced_dur, 2) if voiced_dur > 0 else 0.0,
            "falling_rate_hz_per_sec": round(fall_frames * HOP_MS / 1000.0 / voiced_dur, 2) if voiced_dur > 0 else 0.0,
        }
    else:
        f0_dynamics = {
            "median_hz": 0.0, "mean_hz": 0.0, "std_hz": 0.0, "range_hz": 0.0,
            "p10_hz": 0.0, "p90_hz": 0.0, "voiced_frac": 0.0,
            "turning_points_per_sec": 0.0, "rising_rate_hz_per_sec": 0.0,
            "falling_rate_hz_per_sec": 0.0,
        }

    # Rate variability
    rate_variability = {
        "syllable_rate_hz": round(syllable_rate, 2),
        "local_rate_mean_hz": round(float(np.mean(local_rates_arr)), 2) if len(local_rates_arr) else 0.0,
        "local_rate_std_hz": round(float(np.std(local_rates_arr)), 2) if len(local_rates_arr) else 0.0,
        "local_rate_cv": round(float(np.std(local_rates_arr) / (np.mean(local_rates_arr) + 1e-9)), 2) if len(local_rates_arr) else 0.0,
        "local_rate_p10_hz": round(_pct(local_rates_arr, 10), 2) if len(local_rates_arr) else 0.0,
        "local_rate_p90_hz": round(_pct(local_rates_arr, 90), 2) if len(local_rates_arr) else 0.0,
    }

    # Pause stats
    pause_stats = {
        "pause_count": len(pauses),
        "total_pause_seconds": round(total_pause, 3),
        "mean_pause_seconds": round(float(np.mean(pauses)), 3) if pauses else 0.0,
        "max_pause_seconds": round(max(pauses), 3) if pauses else 0.0,
        "pause_speech_ratio": round(pause_speech_ratio, 3),
    }

    # Energy dynamics
    energy_stats = {
        "rms_mean_db": round(float(rms_db.mean()), 1),
        "rms_std_db": round(float(rms_db.std()), 1),
        "rms_p10_db": round(_pct(rms_db, 10), 1),
        "rms_p90_db": round(_pct(rms_db, 90), 1),
        "dynamic_range_db": round(_pct(rms_db, 90) - _pct(rms_db, 10), 1),
        "envelope_roughness": round(float(np.std(env_s)), 3) if len(env_s) else 0.0,
    }

    # Flatten the grouped metrics so callers don't need to know the nested layout.
    flat = {
        "clip": path.split("/")[-1],
        "durationSec": round(dur, 3),
    }
    flat.update({f"f0_{k}": v for k, v in f0_dynamics.items()})
    flat.update({f"rate_{k}": v for k, v in rate_variability.items()})
    flat.update({f"pauses_{k}": v for k, v in pause_stats.items()})
    flat.update({f"energy_{k}": v for k, v in energy_stats.items()})
    # Short aliases for the most commonly used deltas.
    flat["rate_cv"] = flat["rate_local_rate_cv"]
    flat["pause_ratio"] = flat["pauses_pause_speech_ratio"]
    flat["energy_roughness"] = flat["energy_envelope_roughness"]
    return flat


def analyze(path):
    try:
        x, sr = read_wav(path)
        return _analyze_internal(x, sr, path=path)
    except Exception as e:
        return {"clip": path.split("/")[-1], "error": str(e), "durationSec": 0.0}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv[1:]
    out = [analyze(p) for p in args]
    if as_json:
        print(json.dumps(out, indent=2))
    else:
        if not out:
            print("usage: analyze_prosody.py <wav> [...] [--json]")
            return
        print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
