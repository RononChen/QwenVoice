import sys
import os
import tempfile
import shutil
import io
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import summarize_generation_telemetry as sgt


def test_load_merged_runs_frontend_overhead():
    """Merged rows join app TTFC with engine first-chunk mark and compute overhead."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "generations-merged.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copy(fixture_path, os.path.join(tmp, "generations-merged.jsonl"))
        runs = sgt.load_merged_runs(tmp)
        assert len(runs) == 3
        run1 = next(r for r in runs if r["generationID"] == "gen-merged-001")
        assert run1["appTTFCMS"] == 450
        assert run1["engineFirstChunkMS"] == 380
        assert run1["engineServiceFirstChunkMS"] == 390
        assert run1["frontendOverheadMS"] == 70
        run2 = next(r for r in runs if r["generationID"] == "gen-merged-002")
        assert run2["frontendOverheadMS"] == 100
        run3 = next(r for r in runs if r["generationID"] == "gen-merged-003")
        assert "frontendOverheadMS" not in run3


def test_merged_table_cli(monkeypatch):
    """The --merged flag prints the cross-layer first-chunk latency table."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "telemetry_variants.jsonl")
    merged_fixture = os.path.join(os.path.dirname(__file__), "fixtures", "generations-merged.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))
        shutil.copy(merged_fixture, os.path.join(tmp, "generations-merged.jsonl"))

        monkeypatch.setattr(sys, "argv", ["summarize_generation_telemetry.py", tmp, "--merged"])
        out = io.StringIO()
        with redirect_stdout(out):
            rc = sgt.main()
        assert rc == 0
        text = out.getvalue()
        assert "Cross-layer first-chunk latency" in text
        assert "gen-merged-001" in text
        assert "gen-merged-002" in text
        assert "frontendOverheadMS" in text
        # gen-merged-001: 450 - 380 = 70
        assert "70" in text


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


def test_chunk_timeline_first_chunk_arrival():
    """chunkTimeline aggregates are extracted and firstChunkArrivalMS is correct."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-001")
        assert run["firstChunkArrivalMS"] == 12
        assert run["chunkCount"] == 4
        assert run["medianInterChunkMS"] == 33


def test_chunk_timeline_table(monkeypatch):
    """The chunk-timeline summary table appears only when chunkTimeline data exists."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
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
        assert "Chunk timeline summary" in text
        assert "firstChunkMS" in text
        assert "medianInterChunkMS" in text
        assert "codePred" in text
        assert "audioDecoder" in text


def test_chunk_timeline_substage_medians():
    """Per-chunk substage medians are extracted correctly."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-001")
        assert run["chunk_talkerForwardMS"] == 10.5
        assert run["chunk_codePredictorMS"] == 20.5
        assert run["chunk_streamStepEvalMS"] == 5.5
        assert run["chunk_audioDecoderMS"] == 2


def test_chunk_timeline_single_chunk():
    """A single-chunk timeline has no inter-chunk interval."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-004")
        assert run["chunkCount"] == 1
        assert run["firstChunkArrivalMS"] == 18
        assert run["medianInterChunkMS"] is None


def test_chunk_timeline_empty_list():
    """An empty chunkTimeline list leaves all chunk aggregates as None."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-005")
        assert run["chunkCount"] is None
        assert run["firstChunkArrivalMS"] is None
        assert run["medianInterChunkMS"] is None
        assert run["chunk_talkerForwardMS"] is None
        assert run["chunk_codePredictorMS"] is None
        assert run["chunk_streamStepEvalMS"] is None
        assert run["chunk_audioDecoderMS"] is None


def test_chunk_timeline_missing_substage_keys():
    """Missing substage keys in some chunks do not silently default to 0."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        engine_dir = os.path.join(tmp, "engine")
        os.makedirs(engine_dir)
        shutil.copy(fixture_path, os.path.join(engine_dir, "generations.jsonl"))

        runs = sgt.load_runs(tmp)
        run = next(r for r in runs if r["generationID"] == "gen-chunk-006")
        # talkerForwardMS is present in only one chunk; if it defaulted to 0 for the
        # missing chunk the median would be 10, so 20 proves the omission is honored.
        assert run["chunk_talkerForwardMS"] == 20
        assert run["chunk_codePredictorMS"] == 41
        assert run["chunk_streamStepEvalMS"] == 10.5
        assert run["chunk_audioDecoderMS"] == 5.5


def test_chunk_timeline_cell_level_aggregation(monkeypatch):
    """Multiple runs in the same cell are aggregated by median in the printed table."""
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "chunk_timeline.jsonl")
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
        chunk_section = text.split("Chunk timeline summary", 1)[1].split("\n\nRTF =")[0]
        warm_short_line = [
            line for line in chunk_section.splitlines()
            if "custom" in line and "warm" in line and "short" in line
        ]
        assert len(warm_short_line) == 1
        # gen-chunk-001 (12 ms) and gen-chunk-004 (18 ms) share custom/4bit/warm/short.
        assert "15" in warm_short_line[0]
        assert "33" in warm_short_line[0]
