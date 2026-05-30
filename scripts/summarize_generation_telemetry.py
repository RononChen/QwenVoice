#!/usr/bin/env python3
"""Summarize per-generation telemetry into a mode × model × cold/warm table.

READ-ONLY analysis of the JSONL the runtime telemetry already writes — it never
drives a generation, never writes baselines, and takes no committed input. It joins
the per-layer rows by `generationID` and prints a comparison table; for the warm
runs in a cell it reports the median, for cold the single value (median if several).

Usage:
    python3 scripts/summarize_generation_telemetry.py [DIAGNOSTICS_DIR]

Default DIAGNOSTICS_DIR:
    ~/Library/Application Support/QwenVoice-Debug/diagnostics

See docs/reference/telemetry-and-benchmarking.md for the benchmark procedure.
"""

from __future__ import annotations

import json
import os
import statistics
import sys
from collections import defaultdict

DEFAULT_DIR = os.path.expanduser(
    "~/Library/Application Support/QwenVoice-Debug/diagnostics"
)


def read_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def load_runs(diag_dir):
    """Join engine + app rows by generationID. Returns list of per-run dicts."""
    engine = {r.get("generationID"): r for r in read_jsonl(os.path.join(diag_dir, "engine", "generations.jsonl"))}
    app = {r.get("generationID"): r for r in read_jsonl(os.path.join(diag_dir, "app", "generations.jsonl"))}

    runs = []
    for gid, e in engine.items():
        derived = e.get("derivedMetrics") or {}
        timings = e.get("timingsMS") or {}
        summary = e.get("summary") or {}
        a = app.get(gid) or {}
        app_timings = a.get("timingsMS") or {}
        trim_count, pressure_count, worst = count_memory_events(e, summary)
        runs.append(
            {
                "generationID": gid,
                "mode": e.get("mode") or "?",
                "modelID": e.get("modelID") or "?",
                "warmState": e.get("warmState") or "?",
                "finishReason": e.get("finishReason"),
                "rtf": derived.get("audioSecondsPerWallSecond"),
                "tokps": derived.get("tokensPerSecond"),
                "audioSec": derived.get("audioSeconds"),
                "ttfcMS": app_timings.get("submitToFirstChunkMS"),
                "decodeLoopMS": timings.get("qwen_token_loop_total"),
                "peakGpuMB": summary.get("gpuAllocatedPeakMB"),
                "peakRssMB": summary.get("residentPeakMB"),
                # phys_footprint is the figure Jetsam judges on Apple Silicon — the
                # most OOM-relevant peak. headroomMin = closest the process came to
                # exhausting its available memory budget during the run.
                "physFootMB": summary.get("physFootprintPeakMB"),
                "headMinMB": summary.get("headroomMinMB"),
                "compressedMB": summary.get("compressedPeakMB"),
                # Kernel memory-pressure activity during the run (stage marks).
                "trims": trim_count,
                "pressure": pressure_count,
                "worstTrim": worst,
                # Resolved device tier this row ran under (notes.deviceClass) —
                # reveals a forced-tier benchmark and the floor Quality→Speed fallback.
                "deviceClass": (e.get("notes") or {}).get("deviceClass") or "?",
                # GPU peak MB at pipeline boundaries (mlxMemoryByStage) — shows WHERE
                # GPU memory grows and how much a trim reclaims.
                "gpuByStage": gpu_peak_by_stage(e.get("mlxMemoryByStage") or {}),
            }
        )
    return runs


# Boundary stages we surface for GPU growth, in pipeline order. Each cell takes the
# first stage present (streaming and quality-first paths name them differently).
_GPU_STAGE_GROUPS = [
    ("load", ["after_load", "after_clone_conditioning", "after_prewarm"]),
    ("stream", ["before_stream", "first_chunk", "before_quality_generation"]),
    ("peak", ["after_final_write", "after_stream"]),
    ("trim", ["after_generation_trim"]),
]


def gpu_peak_by_stage(mlx_by_stage):
    """Pick GPU peak MB at each pipeline boundary group from mlxMemoryByStage."""
    out = {}
    for label, candidates in _GPU_STAGE_GROUPS:
        for stage in candidates:
            snap = mlx_by_stage.get(stage)
            if snap and snap.get("peakMB") is not None:
                out[label] = snap.get("peakMB")
                break
    return out


# Worst-first ranking of trim levels for the `trims` column annotation.
_TRIM_SEVERITY = {"fullUnload": 3, "hardTrim": 2, "softTrim": 1}


def count_memory_events(engine_row, summary):
    """Count memory_trim / memory_pressure stage marks and the worst trim level.

    Marks live on the engine row's top-level `stageMarks` (and mirror into
    `summary.stageMarks`); each carries `stage` + `metadata.level`. These are
    written by NativeEngineRuntime.trimMemory (memory_trim) and
    recordMemoryPressureObserved (memory_pressure)."""
    marks = engine_row.get("stageMarks") or summary.get("stageMarks") or []
    trim_count = 0
    pressure_count = 0
    worst_rank = 0
    worst_label = None
    for mark in marks:
        stage = mark.get("stage")
        level = (mark.get("metadata") or {}).get("level")
        if stage == "memory_trim":
            trim_count += 1
            rank = _TRIM_SEVERITY.get(level, 0)
            if rank > worst_rank:
                worst_rank, worst_label = rank, level
        elif stage == "memory_pressure":
            pressure_count += 1
    return trim_count, pressure_count, worst_label


def short_model(model_id):
    """Compact a long model id to its distinguishing tail (e.g. 4bit / 8bit)."""
    if not model_id or model_id == "?":
        return "?"
    tail = model_id.replace("Qwen3-TTS-12Hz-1.7B-", "")
    return tail[:26]


def med(values):
    nums = [v for v in values if isinstance(v, (int, float))]
    return statistics.median(nums) if nums else None


def fmt(value, places=2):
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.{places}f}"
    return str(value)


def main():
    diag_dir = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    runs = load_runs(diag_dir)
    if not runs:
        print(f"No telemetry rows under {diag_dir}/engine/generations.jsonl")
        print("Run the benchmark first (see docs/reference/telemetry-and-benchmarking.md).")
        return 1

    # Group by (mode, modelID, warmState).
    cells = defaultdict(list)
    for run in runs:
        cells[(run["mode"], run["modelID"], run["warmState"])].append(run)

    header = (
        f"{'mode':<8} {'model':<26} {'state':<5} {'n':>2} "
        f"{'RTF':>6} {'tok/s':>7} {'TTFC ms':>8} {'decode ms':>9} "
        f"{'peakGPU':>8} {'peakRSS':>8} {'physFoot':>8} {'headMin':>8} {'trims':>9}"
    )
    tiers = sorted({r["deviceClass"] for r in runs})
    print(f"\nTelemetry summary — {diag_dir}")
    print(f"({len(runs)} runs across {len(cells)} cells; warm shows median)")
    print(f"tier: {', '.join(tiers)}"
          + ("   ⚠ forced (QWENVOICE_FORCE_MEMORY_CLASS)"
             if any(t in ("floor_8gb_mac", "mid_16gb_mac", "iphone_pro") for t in tiers)
             else "") + "\n")
    print(header)
    print("-" * len(header))

    for key in sorted(cells.keys(), key=lambda k: (k[0], short_model(k[1]), k[2] != "cold")):
        mode, model_id, state = key
        group = cells[key]
        n = len(group)
        print(
            f"{mode:<8} {short_model(model_id):<26} {state:<5} {n:>2} "
            f"{fmt(med(r['rtf'] for r in group)):>6} "
            f"{fmt(med(r['tokps'] for r in group)):>7} "
            f"{fmt(med(r['ttfcMS'] for r in group), 0):>8} "
            f"{fmt(med(r['decodeLoopMS'] for r in group), 0):>9} "
            f"{fmt(med(r['peakGpuMB'] for r in group), 0):>8} "
            f"{fmt(med(r['peakRssMB'] for r in group), 0):>8} "
            f"{fmt(med(r['physFootMB'] for r in group), 0):>8} "
            f"{fmt(med(r['headMinMB'] for r in group), 0):>8} "
            f"{fmt_trims(group):>9}"
        )

    # GPU memory by pipeline stage (peak MB) — shows WHERE GPU memory grows and how
    # much the post-generation trim reclaims. Median over each cell's runs.
    gpu_header = (
        f"{'mode':<8} {'model':<26} {'state':<5} "
        f"{'load':>8} {'stream':>8} {'peak':>8} {'trim':>8}"
    )
    print("\nGPU MB by stage (peak; median over cell) — mlxMemoryByStage\n")
    print(gpu_header)
    print("-" * len(gpu_header))
    for key in sorted(cells.keys(), key=lambda k: (k[0], short_model(k[1]), k[2] != "cold")):
        mode, model_id, state = key
        group = cells[key]
        print(
            f"{mode:<8} {short_model(model_id):<26} {state:<5} "
            f"{fmt(med(r['gpuByStage'].get('load') for r in group), 0):>8} "
            f"{fmt(med(r['gpuByStage'].get('stream') for r in group), 0):>8} "
            f"{fmt(med(r['gpuByStage'].get('peak') for r in group), 0):>8} "
            f"{fmt(med(r['gpuByStage'].get('trim') for r in group), 0):>8}"
        )

    print(
        "\nRTF = audioSeconds / wallSeconds (>1 faster than realtime). "
        "tok/s = codec tokens/s. TTFC = submit→first chunk. "
        "decode ms = qwen_token_loop_total. peak*/physFoot/headMin/GPU-stage = MB."
    )
    print(
        "physFoot = phys_footprint peak (the figure Jetsam judges — the OOM-relevant "
        "peak). headMin = min available headroom during the run. "
        "trims = median memory_trim count [worst level]; raw kernel pressure events "
        "are also recorded as memory_pressure marks. On the 8 GB tier, a rising "
        "physFoot or any hardTrim is the early OOM signal."
    )
    return 0


def fmt_trims(group):
    """Median memory_trim count for the cell, annotated with the worst level seen."""
    count = med(r["trims"] for r in group)
    worst = None
    worst_rank = 0
    for r in group:
        rank = _TRIM_SEVERITY.get(r.get("worstTrim"), 0)
        if rank > worst_rank:
            worst_rank, worst = rank, r["worstTrim"]
    if count is None:
        return "-"
    label = f"{int(count)}"
    if worst:
        # soft/hard/full — short tag keeps the column narrow.
        label += f" {worst.replace('Trim', '').replace('Unload', '')[:4]}"
    return label


if __name__ == "__main__":
    raise SystemExit(main())
