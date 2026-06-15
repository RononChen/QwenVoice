#!/usr/bin/env python3
"""Reference-free prosody quality gate for Vocello TTS output.

Flags perceptual tone/tempo/cadence issues that signal-level QC cannot catch:
  - monotone      : low F0 variation + few turning points
  - rushed        : fast syllable rate with little pausing
  - slurred/flat  : low energy dynamics + low rate variability
  - pause_issue   : very long interior pause or extreme pause-to-speech ratio

Deterministic, numpy-only, low-RAM. Designed to run on every vocello bench take.

Usage:
  scripts/prosody_quality_gate.py <wav> [<wav> ...] [--json]
  python3 -c "from prosody_quality_gate import evaluate; print(evaluate('clip.wav'))"
"""
import sys, json
from analyze_prosody import analyze

# Conservative default thresholds. These are intended to flag *obvious* issues,
# not subtle artistic choices. Calibrate against a labeled good/bad corpus for
# your target speakers and delivery styles.
DEFAULT_THRESHOLDS = {
    # monotone: F0 std below this (Hz) AND turning points below this (/sec voiced)
    "monotone_f0_std_hz": 8.0,
    "monotone_turning_points_per_sec": 4.0,
    # rushed: syllable rate above this (Hz) AND pause ratio below this
    "rushed_syllable_rate_hz": 6.5,
    "rushed_max_pause_ratio": 0.03,
    # slurred/flat: energy envelope roughness below this AND rate CV below this
    "flat_envelope_roughness": 0.08,
    "flat_rate_cv": 0.08,
    # pause_issue: max interior pause above this (sec) OR pause ratio above this
    "pause_max_seconds": 1.2,
    "pause_ratio_max": 0.35,
}


def evaluate(path, thresholds=None):
    """Return a gate report for a single WAV."""
    thr = thresholds or DEFAULT_THRESHOLDS
    pros = analyze(path)

    if "error" in pros:
        return {
            "clip": pros.get("clip", path.split("/")[-1]),
            "passed": False,
            "flags": ["analysis_failed"],
            "reason": pros["error"],
            "metrics": {},
        }

    flags = []

    # Monotone: very little pitch movement
    if pros["f0_std_hz"] < thr["monotone_f0_std_hz"] and pros["f0_turning_points_per_sec"] < thr["monotone_turning_points_per_sec"]:
        flags.append("monotone")

    # Rushed: fast with almost no pausing
    if pros["rate_syllable_rate_hz"] > thr["rushed_syllable_rate_hz"] and pros["pauses_pause_speech_ratio"] < thr["rushed_max_pause_ratio"]:
        flags.append("rushed")

    # Flat/slurred: little energy variation and little rate variation
    if pros["energy_envelope_roughness"] < thr["flat_envelope_roughness"] and pros["rate_local_rate_cv"] < thr["flat_rate_cv"]:
        flags.append("flat")

    # Pause issue: unnaturally long silence or too much silence
    if pros["pauses_max_pause_seconds"] > thr["pause_max_seconds"]:
        flags.append("long_pause")
    if pros["pauses_pause_speech_ratio"] > thr["pause_ratio_max"]:
        flags.append("high_pause_ratio")

    summary_metrics = {
        "f0_std_hz": pros["f0_std_hz"],
        "turning_points_per_sec": pros["f0_turning_points_per_sec"],
        "syllable_rate_hz": pros["rate_syllable_rate_hz"],
        "rate_cv": pros["rate_local_rate_cv"],
        "pause_ratio": pros["pauses_pause_speech_ratio"],
        "max_pause_sec": pros["pauses_max_pause_seconds"],
        "envelope_roughness": pros["energy_envelope_roughness"],
    }

    return {
        "clip": pros["clip"],
        "passed": len(flags) == 0,
        "flags": flags,
        "reason": "; ".join(flags) if flags else "prosody gate passed",
        "metrics": summary_metrics,
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv[1:]
    out = [evaluate(p) for p in args]
    if as_json:
        print(json.dumps(out, indent=2))
    else:
        if not out:
            print("usage: prosody_quality_gate.py <wav> [...] [--json]")
            return
        print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
