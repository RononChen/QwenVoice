#!/usr/bin/env python3
"""Versioned prosody profile: calibrated thresholds + delivery-effect weights.

A profile is a plain JSON file with a schema version so future calibrations can
be migrated. It is consumed by:

  - scripts/prosody_quality_gate.py      (pass/fail thresholds)
  - scripts/delivery_adherence.py        (arousal / prosody-effect weights)
  - scripts/bench_delivery_prosody.py    (prosody-effect weights)

Usage:
  from prosody_profile import builtin_profile, load_profile
  profile = load_profile("profiles/warm_narrator.json")
"""
import json
import os

SCHEMA_VERSION = 1

# Built-in defaults mirror the original hard-coded thresholds/weights. They are
# intentionally conservative: they flag obvious prosody issues, not subtle
# artistic choices.
BUILTIN_PROFILE = {
    "schema_version": SCHEMA_VERSION,
    "name": "builtin",
    "description": "Conservative default prosody thresholds and delivery weights.",
    "thresholds": {
        "monotone_f0_std_hz": 8.0,
        "monotone_turning_points_per_sec": 4.0,
        "rushed_syllable_rate_hz": 6.5,
        "rushed_max_pause_ratio": 0.03,
        "flat_envelope_roughness": 0.08,
        "flat_rate_cv": 0.08,
        "pause_max_seconds": 1.2,
        "pause_ratio_max": 0.35,
    },
    "delivery_weights": {
        "arousal": {
            "f0_median_divisor": 10.0,
            "syllable_rate_divisor": 0.5,
            "f0_range_divisor": 20.0,
            "duration_divisor": 0.5,
        },
        "prosody_effect": {
            "f0_std_divisor": 10.0,
            "rate_cv_divisor": 0.1,
            "pause_ratio_divisor": 0.05,
            "energy_roughness_divisor": 0.05,
        },
    },
}


def validate_profile(profile):
    """Return profile if valid, else raise ValueError with a clear message."""
    if not isinstance(profile, dict):
        raise ValueError("profile must be a JSON object")
    version = profile.get("schema_version")
    if version != SCHEMA_VERSION:
        raise ValueError(f"unsupported profile schema version {version!r}; expected {SCHEMA_VERSION}")
    missing = [k for k in BUILTIN_PROFILE.keys() if k not in profile]
    if missing:
        raise ValueError(f"profile missing top-level keys: {missing}")
    builtin_thr = set(BUILTIN_PROFILE["thresholds"].keys())
    prof_thr = set(profile["thresholds"].keys())
    if prof_thr != builtin_thr:
        raise ValueError(
            f"profile thresholds keys mismatch: missing {builtin_thr - prof_thr}, extra {prof_thr - builtin_thr}"
        )
    for key, value in profile["thresholds"].items():
        if not isinstance(value, (int, float)):
            raise ValueError(f"threshold {key} must be numeric")
    # Validate delivery weights shape lightly; default on missing inner keys is
    # handled by callers via .get(..., default).
    if not isinstance(profile.get("delivery_weights"), dict):
        raise ValueError("delivery_weights must be an object")
    return profile


def load_profile(path):
    """Load and validate a profile from JSON file."""
    if not os.path.exists(path):
        raise FileNotFoundError(f"prosody profile not found: {path}")
    with open(path, "r", encoding="utf-8") as f:
        profile = json.load(f)
    return validate_profile(profile)


def builtin_profile():
    """Return a fresh copy of the built-in profile."""
    return json.loads(json.dumps(BUILTIN_PROFILE))


def save_profile(profile, path):
    """Write a validated profile to JSON."""
    validate_profile(profile)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(profile, f, indent=2)


def threshold(profile, key, default=None):
    """Read a threshold, falling back to builtin if the key is missing."""
    return profile["thresholds"].get(key, default if default is not None else BUILTIN_PROFILE["thresholds"][key])


def delivery_weight(profile, section, key, default=None):
    """Read a delivery weight divisor, with built-in fallback."""
    builtin_section = BUILTIN_PROFILE["delivery_weights"][section]
    return profile["delivery_weights"].get(section, {}).get(
        key, default if default is not None else builtin_section[key]
    )
