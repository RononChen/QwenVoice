import sys
import os
import json
import shutil
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import summarize_generation_telemetry as sgt


def _make_cell(key, rtf, tokps, ttfc, phys, qc):
    return {
        "cellKey": list(key),
        "mode": key[0],
        "modelID": key[1],
        "warmState": key[2],
        "lenBucket": key[3],
        "n": 1,
        "rtf": rtf,
        "tokps": tokps,
        "ttfcMS": ttfc,
        "physFootMB": phys,
        "qcVerdict": qc,
    }


def test_rtf_increase_regression():
    key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "medium")
    baseline = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    current = [_make_cell(key, rtf=1.1, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    regressions = sgt.compare_summaries(baseline, current, threshold=0.05)
    assert len(regressions) == 1
    assert regressions[0]["metric"] == "rtf"
    assert abs(regressions[0]["delta"] - 0.1) < 1e-9


def test_tokps_decrease_regression():
    key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "medium")
    baseline = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    current = [_make_cell(key, rtf=1.0, tokps=900.0, ttfc=300.0, phys=4000.0, qc="pass")]
    regressions = sgt.compare_summaries(baseline, current, threshold=0.05)
    assert len(regressions) == 1
    assert regressions[0]["metric"] == "tokps"
    assert abs(regressions[0]["delta"] - (-0.1)) < 1e-9


def test_within_threshold_no_regression():
    key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "medium")
    baseline = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    current = [_make_cell(key, rtf=1.02, tokps=990.0, ttfc=305.0, phys=4020.0, qc="pass")]
    regressions = sgt.compare_summaries(baseline, current, threshold=0.05)
    assert regressions == []


def test_qc_verdict_worsens():
    key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "medium")
    baseline = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    current = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="warn:clipping")]
    regressions = sgt.compare_summaries(baseline, current, threshold=0.05)
    assert len(regressions) == 1
    assert regressions[0]["metric"] == "qcVerdict"
    assert regressions[0]["baseline"] == "pass"
    assert regressions[0]["current"] == "warn:clipping"


def test_cell_missing_in_baseline():
    """A cell present only in current is ignored, not treated as a regression."""
    key1 = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "medium")
    key2 = ("custom", "Qwen3-TTS-12Hz-1.7B-8bit", "warm", "medium")
    baseline = [_make_cell(key1, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    current = [
        _make_cell(key1, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass"),
        _make_cell(key2, rtf=1.2, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass"),
    ]
    regressions = sgt.compare_summaries(baseline, current, threshold=0.05)
    assert regressions == []


def test_cell_missing_in_current():
    """A cell present only in baseline is simply not compared."""
    key1 = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "medium")
    key2 = ("custom", "Qwen3-TTS-12Hz-1.7B-8bit", "warm", "medium")
    baseline = [
        _make_cell(key1, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass"),
        _make_cell(key2, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass"),
    ]
    current = [_make_cell(key1, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    regressions = sgt.compare_summaries(baseline, current, threshold=0.05)
    assert regressions == []


def test_missing_metric_none():
    """A None metric on either side is skipped."""
    key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "medium")
    baseline = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    current = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    baseline[0]["rtf"] = None
    regressions = sgt.compare_summaries(baseline, current, threshold=0.05)
    assert regressions == []


def test_exact_same_values_no_regression():
    """Zero delta never triggers a regression."""
    key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "medium")
    baseline = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    current = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    regressions = sgt.compare_summaries(baseline, current, threshold=0.05)
    assert regressions == []


def test_improvement_no_regression():
    """Improvements (RTF down, tokps up) are never flagged."""
    key = ("custom", "Qwen3-TTS-12Hz-1.7B-4bit", "warm", "medium")
    baseline = [_make_cell(key, rtf=1.0, tokps=1000.0, ttfc=300.0, phys=4000.0, qc="pass")]
    current = [_make_cell(key, rtf=0.5, tokps=2000.0, ttfc=150.0, phys=2000.0, qc="pass")]
    regressions = sgt.compare_summaries(baseline, current, threshold=0.05)
    assert regressions == []


def test_save_and_compare_baseline_cli(monkeypatch):
    """End-to-end: save a baseline, compare unchanged (exit 0), mutate baseline to force regression (exit 2)."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "telemetry_variants.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))
        baseline_path = os.path.join(tmp, "baseline.json")

        # Save baseline.
        monkeypatch.setattr(
            sys, "argv",
            ["summarize_generation_telemetry.py", tmp, "--save-baseline", baseline_path],
        )
        assert sgt.main() == 0
        with open(baseline_path, "r", encoding="utf-8") as f:
            baseline = json.load(f)
        assert isinstance(baseline, list)
        assert all("cellKey" in cell for cell in baseline)

        # Compare unchanged baseline: no regression.
        monkeypatch.setattr(
            sys, "argv",
            ["summarize_generation_telemetry.py", tmp, "--compare-baseline", baseline_path],
        )
        assert sgt.main() == 0

        # Mutate saved baseline so the current run appears regressed.
        for cell in baseline:
            cell["rtf"] = 0.1  # baseline claims RTF was much better; current is worse
        with open(baseline_path, "w", encoding="utf-8") as f:
            json.dump(baseline, f, indent=2)

        monkeypatch.setattr(
            sys, "argv",
            ["summarize_generation_telemetry.py", tmp, "--compare-baseline", baseline_path],
        )
        assert sgt.main() == 2
