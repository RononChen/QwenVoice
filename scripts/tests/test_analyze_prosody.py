#!/usr/bin/env python3
"""Deterministic contracts for the bounded prosody analyzer."""

from __future__ import annotations

import math
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import wave

import numpy as np

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from analyze_prosody import ANALYZER_ALGORITHM_VERSION, analyze
from prosody_quality_gate import evaluate


SAMPLE_RATE = 24_000


def write_pcm16(path: Path, samples: np.ndarray, channels: int = 1) -> None:
    pcm = np.clip(np.rint(samples * 32767.0), -32768, 32767).astype("<i2")
    if channels > 1:
        pcm = np.repeat(pcm[:, None], channels, axis=1).reshape(-1)
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(channels)
        writer.setsampwidth(2)
        writer.setframerate(SAMPLE_RATE)
        writer.writeframes(pcm.tobytes())


def sine(duration: float, frequency: float = 150.0, amplitude: float = 0.55) -> np.ndarray:
    count = int(round(duration * SAMPLE_RATE))
    time = np.arange(count, dtype=np.float64) / SAMPLE_RATE
    return amplitude * np.sin(2.0 * math.pi * frequency * time)


def modulated_sine(duration: float) -> np.ndarray:
    count = int(round(duration * SAMPLE_RATE))
    time = np.arange(count, dtype=np.float64) / SAMPLE_RATE
    frequency = 155.0 + 38.0 * np.sin(2.0 * math.pi * 1.4 * time)
    phase = np.cumsum(2.0 * math.pi * frequency / SAMPLE_RATE)
    return 0.55 * np.sin(phase)


class AnalyzeProsodyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_working_set_is_bounded_independently_of_duration(self) -> None:
        short = self.directory / "short.wav"
        long = self.directory / "long.wav"
        write_pcm16(short, sine(3.0))
        write_pcm16(long, sine(15.0))

        short_report = analyze(str(short))
        long_report = analyze(str(long))

        self.assertNotIn("error", short_report)
        self.assertNotIn("error", long_report)
        self.assertTrue(short_report["analysisWorkingSetDurationBounded"])
        self.assertEqual(short_report["analysisPassCount"], 2)
        self.assertLessEqual(
            abs(
                short_report["analysisMeasuredPeakManagedBufferBytes"]
                - long_report["analysisMeasuredPeakManagedBufferBytes"]
            ),
            int(SAMPLE_RATE * 0.04) * 8,
        )
        self.assertEqual(
            short_report["analysisEstimatedPeakWorkingSetBytes"],
            long_report["analysisEstimatedPeakWorkingSetBytes"],
        )

    def test_repeated_analysis_is_deterministic(self) -> None:
        path = self.directory / "deterministic.wav"
        write_pcm16(path, modulated_sine(4.0))
        self.assertEqual(analyze(str(path)), analyze(str(path)))

    def test_existing_gate_keys_remain_compatible(self) -> None:
        path = self.directory / "consumer.wav"
        write_pcm16(path, modulated_sine(3.0))
        report = analyze(str(path))
        established = {
            "f0_std_hz",
            "f0_turning_points_per_sec",
            "rate_syllable_rate_hz",
            "rate_local_rate_cv",
            "pauses_pause_speech_ratio",
            "pauses_max_pause_seconds",
            "energy_envelope_roughness",
            "rate_cv",
            "pause_ratio",
            "energy_roughness",
        }
        self.assertTrue(established.issubset(report))
        gate = evaluate(str(path))
        self.assertEqual(gate["analyzerAlgorithmVersion"], ANALYZER_ALGORITHM_VERSION)
        self.assertIn("analyzer_peak_working_set_bytes", gate["metrics"])

    def test_silence_gap_spanning_declared_boundary_is_retained(self) -> None:
        path = self.directory / "pause-boundary.wav"
        samples = sine(2.0)
        samples[int(0.75 * SAMPLE_RATE):int(1.25 * SAMPLE_RATE)] = 0.0
        write_pcm16(path, samples)
        report = analyze(str(path), boundary_seconds=[1.0])
        self.assertGreaterEqual(report["pauses_max_pause_seconds"], 0.45)
        self.assertEqual(report["boundaries_observed_count"], 1)
        self.assertEqual(report["boundaries_silence_overlap_count"], 1)

    def test_click_and_clipping_are_counted(self) -> None:
        path = self.directory / "click.wav"
        samples = np.zeros(SAMPLE_RATE, dtype=np.float64)
        midpoint = SAMPLE_RATE // 2
        samples[midpoint] = 1.0
        samples[midpoint + 1] = -1.0
        write_pcm16(path, samples)
        report = analyze(str(path), boundary_seconds=[midpoint / SAMPLE_RATE])
        self.assertGreaterEqual(report["signal_clipping_count"], 2)
        self.assertGreaterEqual(report["signal_click_count"], 2)
        self.assertGreater(report["boundaries_max_sample_jump"], 0.9)

    def test_pitch_flattening_reduces_semitone_spread(self) -> None:
        flat = self.directory / "flat.wav"
        expressive = self.directory / "expressive.wav"
        write_pcm16(flat, sine(5.0))
        write_pcm16(expressive, modulated_sine(5.0))
        flat_report = analyze(str(flat))
        expressive_report = analyze(str(expressive))
        self.assertGreater(
            expressive_report["f0_std_semitones"],
            flat_report["f0_std_semitones"] + 0.2,
        )
        self.assertGreater(
            expressive_report["f0_range_semitones"],
            flat_report["f0_range_semitones"] + 0.5,
        )

    def test_stereo_downmix_remains_supported(self) -> None:
        path = self.directory / "stereo.wav"
        write_pcm16(path, sine(2.0), channels=2)
        report = analyze(str(path))
        self.assertNotIn("error", report)
        self.assertGreater(report["f0_median_hz"], 0)

    def test_float_nan_wav_fails_closed_instead_of_reporting_finite_pcm(self) -> None:
        # stdlib wave can wrap the bytes, but Vocello's quality contract accepts
        # PCM16 only.  NaN/Inf therefore cannot exist in a supported persisted
        # WAV and an IEEE-float payload must fail before signal claims are made.
        path = self.directory / "float-nan.wav"
        with wave.open(str(path), "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(4)
            writer.setframerate(SAMPLE_RATE)
            writer.writeframes(struct.pack("<f", math.nan) * SAMPLE_RATE)
        report = analyze(str(path))
        self.assertIn("error", report)
        self.assertIn("expected 16-bit PCM", report["error"])

    def test_invalid_or_unsorted_boundaries_fail_closed(self) -> None:
        path = self.directory / "boundaries.wav"
        write_pcm16(path, sine(2.0))
        self.assertIn("error", analyze(str(path), boundary_seconds=[1.0, 0.5]))
        self.assertIn("error", analyze(str(path), boundary_seconds=[2.0]))


if __name__ == "__main__":
    unittest.main()
