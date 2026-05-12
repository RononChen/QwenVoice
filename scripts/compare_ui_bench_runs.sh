#!/usr/bin/env bash
# Compare two desktop UI benchmark run directories and surface the
# cache/warmup flags that explain mode-specific speed results.
#
# Usage:
#   scripts/compare_ui_bench_runs.sh <baseline_run_dir> <candidate_run_dir> \
#     [--output-dir <dir>] [--baseline-label <label>] [--candidate-label <label>]
#
# Each run directory should contain:
#   - results.csv from scripts/bench_ui_generation.sh
#   - run-manifest.json with row metadata
#   - ui-traces/*.json from QWENVOICE_UI_PERF_AUDIT

set -euo pipefail

python3 - "$@" <<'PY'
import argparse
import csv
import json
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path


BOOLEAN_KEYS = [
    "generation_ended_by_eos",
    "generation_hit_token_cap",
    "allocation_retry_attempted",
    "allocation_retry_succeeded",
    "prefix_cache_hit",
    "decoder_bucket_cache_hit",
    "custom_prefix_cache_hit",
    "design_conditioning_reused",
    "design_conditioning_prefetch_hit",
    "interactive_design_prefetch_hit",
    "design_prefix_cache_hit",
    "design_stream_step_prefetch_hit",
    "design_conditioning_prewarmed",
    "design_stream_step_prewarmed",
    "prepared_clone_cache_hit",
    "clone_prompt_cache_hit",
    "clone_conditioning_reused",
    "normalized_reference_reused",
    "decoded_reference_reused",
    "reused_normalized_reference",
    "reused_decoded_reference",
    "primed",
]

STRING_KEYS = [
    "memory_policy",
    "post_request_cache_policy",
    "generation_end_reason",
    "generation_finish_reason",
    "token_budget_policy",
    "qwen3_quantization_tier",
]

TIMING_KEYS = [
    "generation",
    "final_write",
    "load_model",
    "mlx_model_load",
    "post_request_cache_clear_applied",
    "cache_clear_count",
    "design_prefix_prepare",
    "design_text_prepare_ms",
    "design_stream_step_eval_total_ms",
    "clone_prompt_resolve",
    "clone_prompt_build",
    "clone_prompt_artifact_load",
    "prime_clone_reference",
    "reference_normalize",
    "reference_decode",
    "clone_stream_step_eval_total_ms",
    "qwen_code_predictor_total",
    "qwen_talker_forward_total",
    "qwen_generated_code_count",
]

EVENT_STAGES = [
    "final_file_ready",
    "final_player_loaded",
    "generation_finished",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare two Vocello desktop UI benchmark run directories."
    )
    parser.add_argument("baseline_run_dir")
    parser.add_argument("candidate_run_dir")
    parser.add_argument("--output-dir")
    parser.add_argument("--baseline-label")
    parser.add_argument("--candidate-label")
    parser.add_argument("--state", default="warm")
    parser.add_argument("--threshold-pct", type=float, default=5.0)
    return parser.parse_args()


def read_json(path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def read_csv(path):
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def to_float(value):
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def to_int(value):
    if value in (None, ""):
        return None
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def median(values):
    clean = [value for value in values if value is not None]
    if not clean:
        return None
    return statistics.median(clean)


def pct_delta(candidate, baseline):
    if baseline in (None, 0) or candidate is None:
        return None
    return (candidate - baseline) / baseline * 100.0


def classify(delta, threshold):
    if delta is None:
        return "missing"
    if delta <= -threshold:
        return "faster"
    if delta >= threshold:
        return "slower"
    return "inconclusive"


def format_number(value, digits=1, suffix=""):
    if value is None:
        return "missing"
    return f"{value:.{digits}f}{suffix}"


def format_delta(value):
    if value is None:
        return "missing"
    return f"{value:+.1f}%"


def infer_variant(model_id):
    if not model_id:
        return "unknown"
    if "speed" in model_id:
        return "speed"
    if "quality" in model_id:
        return "quality"
    return "unknown"


def stage_elapsed(trace, stage):
    if not trace:
        return None
    for event in trace.get("events", []):
        if event.get("stage") == stage:
            return to_float(event.get("elapsed_ms"))
    return None


def load_traces(run_dir):
    trace_dir = run_dir / "ui-traces"
    traces = []
    if not trace_dir.is_dir():
        return traces
    for path in sorted(trace_dir.glob("*.json")):
        try:
            trace = read_json(path)
        except json.JSONDecodeError:
            continue
        trace["_path"] = str(path)
        traces.append(trace)
    traces.sort(key=lambda trace: trace.get("started_at_unix_ms") or 0)
    return traces


def trace_output_key(trace):
    output = trace.get("output_file")
    if not output:
        return None
    return Path(output).name


def trace_summary(trace):
    if not trace:
        return {
            "trace_file": None,
            "status": "missing",
            "model_id": None,
            "mode": None,
            "boolean_flags": {},
            "string_flags": {},
            "timings_ms": {},
            "event_elapsed_ms": {},
        }

    boolean_flags = trace.get("runtime_boolean_flags") or {}
    string_flags = trace.get("runtime_string_flags") or {}
    timings = trace.get("runtime_timings_ms") or {}
    return {
        "trace_file": trace.get("_path"),
        "status": trace.get("status", "missing"),
        "model_id": trace.get("model_id"),
        "mode": trace.get("mode"),
        "output_file": trace.get("output_file"),
        "boolean_flags": {key: boolean_flags.get(key) for key in BOOLEAN_KEYS},
        "string_flags": {key: string_flags.get(key) for key in STRING_KEYS},
        "timings_ms": {key: timings.get(key) for key in TIMING_KEYS},
        "event_elapsed_ms": {stage: stage_elapsed(trace, stage) for stage in EVENT_STAGES},
    }


def load_run(run_dir, label):
    manifest_path = run_dir / "run-manifest.json"
    results_path = run_dir / "results.csv"
    if not manifest_path.is_file():
        raise SystemExit(f"missing manifest: {manifest_path}")
    if not results_path.is_file():
        raise SystemExit(f"missing results CSV: {results_path}")

    manifest = read_json(manifest_path)
    csv_rows = read_csv(results_path)
    manifest_rows = manifest.get("rows", [])
    traces = load_traces(run_dir)
    trace_by_output = {
        key: trace for trace in traces if (key := trace_output_key(trace)) is not None
    }

    rows = []
    warnings = []
    if len(manifest_rows) != len(csv_rows):
        warnings.append(
            f"manifest rows ({len(manifest_rows)}) do not match CSV rows ({len(csv_rows)})"
        )

    for index, csv_row in enumerate(csv_rows):
        manifest_row = manifest_rows[index] if index < len(manifest_rows) else {}
        filename = csv_row.get("filename")
        trace = trace_by_output.get(filename)
        if trace is None and index < len(traces):
            trace = traces[index]
        summary = trace_summary(trace)
        model_id = summary.get("model_id")
        variant = manifest_row.get("variant") or infer_variant(model_id)
        row = {
            "index": index,
            "mode": manifest_row.get("mode") or csv_row.get("mode") or "unknown",
            "variant": variant,
            "length": manifest_row.get("length") or csv_row.get("length") or "unknown",
            "state": manifest_row.get("state") or csv_row.get("state") or "unknown",
            "sample": manifest_row.get("sample") if "sample" in manifest_row else csv_row.get("sample"),
            "wall_secs": to_float(csv_row.get("wall_secs")),
            "audio_secs": to_float(csv_row.get("audio_secs")),
            "rtf": to_float(csv_row.get("rtf")),
            "filename": filename,
            "vocello_rss_mb_before": to_float(csv_row.get("vocello_rss_mb_before")),
            "vocello_rss_mb_after": to_float(csv_row.get("vocello_rss_mb_after")),
            "engine_rss_mb_before": to_float(csv_row.get("engine_rss_mb_before")),
            "engine_rss_mb_after": to_float(csv_row.get("engine_rss_mb_after")),
            "trace": summary,
        }
        rows.append(row)

    return {
        "label": label,
        "run_dir": str(run_dir),
        "manifest": manifest,
        "rows": rows,
        "traces": traces,
        "warnings": warnings,
    }


def count_values(values):
    counter = Counter("missing" if value is None else str(value) for value in values)
    return dict(sorted(counter.items()))


def summarize_rows(rows):
    trace_count = sum(1 for row in rows if row["trace"]["status"] != "missing")
    summary = {
        "samples": len(rows),
        "trace_count": trace_count,
        "wall_median_s": median([row["wall_secs"] for row in rows]),
        "wall_min_s": min([row["wall_secs"] for row in rows if row["wall_secs"] is not None], default=None),
        "wall_max_s": max([row["wall_secs"] for row in rows if row["wall_secs"] is not None], default=None),
        "audio_median_s": median([row["audio_secs"] for row in rows]),
        "rtf_median": median([row["rtf"] for row in rows]),
        "vocello_rss_before_median_mb": median([row["vocello_rss_mb_before"] for row in rows]),
        "vocello_rss_after_median_mb": median([row["vocello_rss_mb_after"] for row in rows]),
        "engine_rss_before_median_mb": median([row["engine_rss_mb_before"] for row in rows]),
        "engine_rss_after_median_mb": median([row["engine_rss_mb_after"] for row in rows]),
        "status_counts": count_values([row["trace"]["status"] for row in rows]),
        "string_flag_counts": {},
        "boolean_flag_counts": {},
        "timing_medians_ms": {},
        "event_medians_ms": {},
        "output_files": [row["filename"] for row in rows],
        "trace_files": [
            row["trace"]["trace_file"] for row in rows if row["trace"]["trace_file"] is not None
        ],
    }

    for key in STRING_KEYS:
        summary["string_flag_counts"][key] = count_values(
            [row["trace"]["string_flags"].get(key) for row in rows]
        )
    for key in BOOLEAN_KEYS:
        summary["boolean_flag_counts"][key] = count_values(
            [row["trace"]["boolean_flags"].get(key) for row in rows]
        )
    for key in TIMING_KEYS:
        summary["timing_medians_ms"][key] = median(
            [to_float(row["trace"]["timings_ms"].get(key)) for row in rows]
        )
    for stage in EVENT_STAGES:
        summary["event_medians_ms"][stage] = median(
            [to_float(row["trace"]["event_elapsed_ms"].get(stage)) for row in rows]
        )
    return summary


def group_rows(rows, state):
    groups = defaultdict(list)
    for row in rows:
        if row["state"] != state:
            continue
        key = (row["mode"], row["variant"], row["length"])
        groups[key].append(row)
    return groups


def aggregate_run(run):
    rows = run["rows"]
    return {
        "rows": len(rows),
        "trace_files": len(run["traces"]),
        "status_counts": count_values([row["trace"]["status"] for row in rows]),
        "mode_counts": count_values([row["trace"]["mode"] for row in rows]),
        "model_id_counts": count_values([row["trace"]["model_id"] for row in rows]),
        "memory_policy_counts": count_values(
            [row["trace"]["string_flags"].get("memory_policy") for row in rows]
        ),
        "post_request_cache_policy_counts": count_values(
            [row["trace"]["string_flags"].get("post_request_cache_policy") for row in rows]
        ),
        "post_request_cache_clear_applied_counts": count_values(
            [row["trace"]["timings_ms"].get("post_request_cache_clear_applied") for row in rows]
        ),
        "generation_ended_by_eos_counts": count_values(
            [row["trace"]["boolean_flags"].get("generation_ended_by_eos") for row in rows]
        ),
        "generation_hit_token_cap_counts": count_values(
            [row["trace"]["boolean_flags"].get("generation_hit_token_cap") for row in rows]
        ),
        "allocation_retry_attempted_counts": count_values(
            [row["trace"]["boolean_flags"].get("allocation_retry_attempted") for row in rows]
        ),
    }


def flag_rate(summary, key):
    counts = summary["boolean_flag_counts"].get(key, {})
    total = sum(counts.values())
    true_count = counts.get("True", 0) + counts.get("true", 0)
    if total == 0:
        return "missing"
    return f"{true_count}/{total}"


def cell_cache_summary(mode, summary):
    if mode == "custom":
        return (
            f"prefix {flag_rate(summary, 'prefix_cache_hit')}; "
            f"decoder {flag_rate(summary, 'decoder_bucket_cache_hit')}"
        )
    if mode == "design":
        return (
            f"conditioning {flag_rate(summary, 'design_conditioning_prefetch_hit')}; "
            f"interactive {flag_rate(summary, 'interactive_design_prefetch_hit')}; "
            f"prefix {flag_rate(summary, 'design_prefix_cache_hit')}; "
            f"stream-step {flag_rate(summary, 'design_stream_step_prefetch_hit')}"
        )
    if mode == "clone":
        return (
            f"prepared {flag_rate(summary, 'prepared_clone_cache_hit')}; "
            f"prompt {flag_rate(summary, 'clone_prompt_cache_hit')}; "
            f"conditioning {flag_rate(summary, 'clone_conditioning_reused')}; "
            f"ref {flag_rate(summary, 'normalized_reference_reused')}/"
            f"{flag_rate(summary, 'decoded_reference_reused')}"
        )
    return "n/a"


def compare_runs(baseline, candidate, state, threshold):
    baseline_groups = group_rows(baseline["rows"], state)
    candidate_groups = group_rows(candidate["rows"], state)
    keys = sorted(set(baseline_groups) | set(candidate_groups))
    comparisons = []
    for key in keys:
        mode, variant, length = key
        base_summary = summarize_rows(baseline_groups.get(key, []))
        candidate_summary = summarize_rows(candidate_groups.get(key, []))
        delta = pct_delta(candidate_summary["wall_median_s"], base_summary["wall_median_s"])
        comparisons.append({
            "mode": mode,
            "variant": variant,
            "length": length,
            "baseline": base_summary,
            "candidate": candidate_summary,
            "delta_wall_median_pct": delta,
            "classification": classify(delta, threshold),
            "baseline_cache_summary": cell_cache_summary(mode, base_summary),
            "candidate_cache_summary": cell_cache_summary(mode, candidate_summary),
        })
    return comparisons


def render_counts(counts):
    if not counts:
        return "missing"
    return ", ".join(f"{key}:{value}" for key, value in counts.items())


def render_markdown(report):
    baseline = report["baseline"]
    candidate = report["candidate"]
    lines = [
        "# UI Benchmark Run Comparison",
        "",
        f"- Baseline: `{baseline['label']}` at `{baseline['run_dir']}`",
        f"- Candidate: `{candidate['label']}` at `{candidate['run_dir']}`",
        f"- Compared state: `{report['state']}`",
        f"- Threshold: `{report['threshold_pct']:.1f}%` wall-time median delta",
        "",
        "## Aggregate Trace Evidence",
        "",
        "| Run | Rows | Traces | Status | Policy | Clear Applied | EOS | Token Cap | Allocation Retry |",
        "|---|---:|---:|---|---|---|---|---|---|",
    ]
    for run_key in ("baseline", "candidate"):
        run = report[run_key]
        aggregate = run["aggregate"]
        lines.append(
            "| "
            + " | ".join([
                run["label"],
                str(aggregate["rows"]),
                str(aggregate["trace_files"]),
                render_counts(aggregate["status_counts"]),
                render_counts(aggregate["post_request_cache_policy_counts"]),
                render_counts(aggregate["post_request_cache_clear_applied_counts"]),
                render_counts(aggregate["generation_ended_by_eos_counts"]),
                render_counts(aggregate["generation_hit_token_cap_counts"]),
                render_counts(aggregate["allocation_retry_attempted_counts"]),
            ])
            + " |"
        )

    lines.extend([
        "",
        "## Warm Median Results",
        "",
        "| Mode | Variant | Length | Baseline wall s | Candidate wall s | Delta | Class | Candidate cache/warm flags | Candidate final-ready ms | Candidate generation ms | Candidate engine RSS after MB |",
        "|---|---|---|---:|---:|---:|---|---|---:|---:|---:|",
    ])
    for item in report["comparisons"]:
        candidate_summary = item["candidate"]
        lines.append(
            "| "
            + " | ".join([
                item["mode"],
                item["variant"],
                item["length"],
                format_number(item["baseline"]["wall_median_s"], 1),
                format_number(candidate_summary["wall_median_s"], 1),
                format_delta(item["delta_wall_median_pct"]),
                item["classification"],
                item["candidate_cache_summary"],
                format_number(candidate_summary["event_medians_ms"].get("final_file_ready"), 0),
                format_number(candidate_summary["timing_medians_ms"].get("generation"), 0),
                format_number(candidate_summary.get("engine_rss_after_median_mb"), 1),
            ])
            + " |"
        )

    lines.extend([
        "",
        "## Mode-Specific Diagnostics",
        "",
    ])
    for mode in ("custom", "design", "clone"):
        mode_items = [item for item in report["comparisons"] if item["mode"] == mode]
        if not mode_items:
            continue
        lines.append(f"### {mode.title()}")
        for item in mode_items:
            candidate_summary = item["candidate"]
            baseline_summary = item["baseline"]
            lines.append(
                f"- `{item['variant']} / {item['length']}`: "
                f"{item['classification']} ({format_delta(item['delta_wall_median_pct'])}); "
                f"candidate flags: {item['candidate_cache_summary']}; "
                f"baseline flags: {item['baseline_cache_summary']}; "
                f"candidate policy: {render_counts(candidate_summary['string_flag_counts'].get('post_request_cache_policy', {}))}; "
                f"candidate memory: {render_counts(candidate_summary['string_flag_counts'].get('memory_policy', {}))}; "
                f"candidate clear applied median: {format_number(candidate_summary['timing_medians_ms'].get('post_request_cache_clear_applied'), 0)}"
            )
        lines.append("")

    warnings = baseline.get("warnings", []) + candidate.get("warnings", [])
    if warnings:
        lines.extend(["## Warnings", ""])
        for warning in warnings:
            lines.append(f"- {warning}")
        lines.append("")

    lines.extend([
        "## Interpretation Guardrails",
        "",
        "- Faster means at least the configured threshold faster by warm median wall time.",
        "- Slower means at least the configured threshold slower by warm median wall time.",
        "- Product policy changes still require EOS, token-cap, allocation-retry, and memory-pressure checks.",
    ])
    return "\n".join(lines) + "\n"


def main():
    args = parse_args()
    baseline_dir = Path(args.baseline_run_dir).expanduser().resolve()
    candidate_dir = Path(args.candidate_run_dir).expanduser().resolve()
    output_dir = (
        Path(args.output_dir).expanduser().resolve()
        if args.output_dir
        else candidate_dir.parent / f"{candidate_dir.name}-comparison"
    )

    baseline_label = args.baseline_label or baseline_dir.name
    candidate_label = args.candidate_label or candidate_dir.name
    baseline = load_run(baseline_dir, baseline_label)
    candidate = load_run(candidate_dir, candidate_label)
    comparisons = compare_runs(baseline, candidate, args.state, args.threshold_pct)

    report = {
        "schema_version": 1,
        "created_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "state": args.state,
        "threshold_pct": args.threshold_pct,
        "baseline": {
            "label": baseline["label"],
            "run_dir": baseline["run_dir"],
            "warnings": baseline["warnings"],
            "aggregate": aggregate_run(baseline),
        },
        "candidate": {
            "label": candidate["label"],
            "run_dir": candidate["run_dir"],
            "warnings": candidate["warnings"],
            "aggregate": aggregate_run(candidate),
        },
        "classification_counts": dict(Counter(item["classification"] for item in comparisons)),
        "comparisons": comparisons,
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "comparison.json"
    md_path = output_dir / "comparison.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(report), encoding="utf-8")
    print(md_path)
    print(json_path)


if __name__ == "__main__":
    main()
PY
