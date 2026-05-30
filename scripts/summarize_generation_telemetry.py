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
            }
        )
    return runs


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
        f"{'peakGPU':>8} {'peakRSS':>8}"
    )
    print(f"\nTelemetry summary — {diag_dir}")
    print(f"({len(runs)} runs across {len(cells)} cells; warm shows median)\n")
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
            f"{fmt(med(r['peakRssMB'] for r in group), 0):>8}"
        )

    print(
        "\nRTF = audioSeconds / wallSeconds (>1 faster than realtime). "
        "tok/s = codec tokens/s. TTFC = submit→first chunk. "
        "decode ms = qwen_token_loop_total. peak* = MB."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
