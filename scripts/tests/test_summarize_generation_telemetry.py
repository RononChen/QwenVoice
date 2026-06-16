import sys
import os
import tempfile
import shutil
import io
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import summarize_generation_telemetry as sgt


def test_iqr_basic():
    assert sgt.iqr([1, 2, 3, 4, 5, 6, 7]) == 4.0


def test_iqr_even_length():
    assert sgt.iqr([1, 2, 3, 4, 5, 6, 7, 8]) == 4.0


def test_iqr_insufficient_values():
    assert sgt.iqr([42]) is None
    assert sgt.iqr([]) is None


def test_iqr_filters_non_numeric():
    assert sgt.iqr([1, 2, "noise", 3, 4, None]) == 2.0


def test_iqr_zero_spread():
    assert sgt.iqr([5, 5, 5, 5]) == 0.0


def test_mad_basic():
    vals = [1, 2, 3, 4, 5]
    assert sgt.mad(vals) == 1.0


def test_mad_empty():
    assert sgt.mad([]) is None


def test_mad_filters_non_numeric():
    assert sgt.mad([1, 2, "x", 3, 4]) == 1.0


def test_reject_outliers():
    vals = [1.0, 2.0, 3.0, 4.0, 5.0, 100.0]
    filtered = sgt.reject_outliers(vals)
    assert 100.0 not in filtered
    assert filtered == [1.0, 2.0, 3.0, 4.0, 5.0]


def test_reject_outliers_custom_factor():
    vals = [1.0, 2.0, 3.0, 4.0, 5.0, 100.0]
    # A very wide factor keeps the extreme value inside the fence.
    assert 100.0 in sgt.reject_outliers(vals, factor=100.0)


def test_reject_outliers_too_few():
    vals = [1.0, 2.0, 3.0]
    assert sgt.reject_outliers(vals) == vals


def test_reject_outliers_minimum_four():
    # With exactly 4 samples the upper quartile includes the extreme value, so the
    # Tukey fence engulfs it; the function should still run without error and return
    # the sorted input unchanged.
    vals = [1.0, 2.0, 3.0, 100.0]
    assert sgt.reject_outliers(vals) == sorted(vals)


def test_reject_outliers_zero_iqr():
    vals = [5.0, 5.0, 5.0, 5.0, 5.0, 100.0]
    filtered = sgt.reject_outliers(vals)
    # Zero IQR collapses the fence to Q1 == Q3, so the non-equal value is rejected.
    assert 100.0 not in filtered


def test_show_variance_integration(monkeypatch):
    """Run the summarizer end-to-end with --show-variance and verify columns appear."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "telemetry_variants.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        monkeypatch.setattr(sys, "argv", ["summarize_generation_telemetry.py", tmp, "--show-variance"])
        out = io.StringIO()
        with redirect_stdout(out):
            rc = sgt.main()
        assert rc == 0
        text = out.getvalue()
        assert "RTF_IQR" in text
        assert "physFoot_IQR" in text


def test_default_table_without_variance(monkeypatch):
    """The default table must not include variance columns."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "telemetry_variants.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        monkeypatch.setattr(sys, "argv", ["summarize_generation_telemetry.py", tmp])
        out = io.StringIO()
        with redirect_stdout(out):
            rc = sgt.main()
        assert rc == 0
        text = out.getvalue()
        assert "RTF_IQR" not in text
        assert "physFoot_IQR" not in text
