#!/usr/bin/env python3
"""Run QwenVoice/Vocello generation benchmarks with clean surface semantics.

V2 separates two benchmark surfaces:

* ``headless-xpc`` drives the real macOS XPC helper through the maintained live
  XCTest path. The embedded XPC service still requires a test-host app process,
  but the app is launched in a headless benchmark-host mode without visible UI.
* ``ui-app`` launches the visible ``Vocello.app`` and records UI timing,
  responsiveness, screenshots, process state, and audio QC.

Visual validation for ``ui-app`` benchmark runs follows the manual
computer-use procedure documented in the bench runbook. ``headless-xpc``
remains backend-focused and does not put the full app UI onscreen.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


PROJECT_DIR = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = PROJECT_DIR / "scripts"
DEFAULT_MODES = ("CustomVoice", "VoiceDesign", "Clones")
SUPPORTED_MODES = set(DEFAULT_MODES)
CUSTOM_VOICE_PROFILES = ("baseline", "balanced-short", "conservative-short", "fast-short")
UI_DRIVER = "computer-use-first"
GENERATION_SPEED_PROFILES = (
    "current",
    "legacy123-memory",
    "adaptive-failure-only",
    "balanced-all-modes",
)
POST_REQUEST_CACHE_POLICIES = (
    "current",
    "always",
    "failure-only",
    "never",
)
NORMAL_PREFLIGHT_WARN_SWAP_MB = 4_000.0
NORMAL_PREFLIGHT_ABORT_SWAP_MB = 6_000.0
STRESS_PREFLIGHT_WARN_SWAP_MB = 6_000.0
STRESS_PREFLIGHT_ABORT_SWAP_MB = 8_000.0
PREFLIGHT_MIN_FREE_SWAP_MB = 512.0


class UsageError(Exception):
    """Invalid benchmark invocation."""


@dataclass(frozen=True)
class ProfileConfig:
    headless_profile: str
    ui_profile: str
    cold_runs: int
    warm_runs: int
    repeat_count: int


PROFILE_CONFIGS = {
    "smoke": ProfileConfig(
        headless_profile="repeat",
        ui_profile="smoke",
        cold_runs=1,
        warm_runs=1,
        repeat_count=1,
    ),
    "balanced": ProfileConfig(
        headless_profile="cold-warm",
        ui_profile="balanced",
        cold_runs=2,
        warm_runs=3,
        repeat_count=1,
    ),
    "exhaustive": ProfileConfig(
        headless_profile="exhaustive",
        ui_profile="exhaustive",
        cold_runs=3,
        warm_runs=5,
        repeat_count=1,
    ),
    "stress": ProfileConfig(
        headless_profile="exhaustive",
        ui_profile="stress",
        cold_runs=3,
        warm_runs=5,
        repeat_count=1,
    ),
}


def main() -> int:
    args = parse_args()
    try:
        modes = parse_modes(args.modes)
        if args.memory_clear_cadence is not None and args.memory_clear_cadence < 0:
            raise UsageError("--memory-clear-cadence must be 0 or greater.")
        if args.phase != "combined" and args.surface != "headless-xpc":
            raise UsageError("--phase build-for-testing/test-without-building requires --surface headless-xpc.")
        output_dir = resolve_output_dir(args)
        output_dir.mkdir(parents=True, exist_ok=True)
        if args.self_test:
            return run_self_test(output_dir)

        config = PROFILE_CONFIGS[args.profile]
        preflight = capture_system_snapshot("preflight")
        memory_decision = classify_memory_policy(preflight, args.memory_policy)
        write_json(output_dir / "benchmark-plan.json", benchmark_plan(args, modes, output_dir, config, memory_decision))
        if memory_decision.get("severity") == "abort":
            result = {
                "surface": args.surface,
                "overall_pass": False,
                "exit_code": 2,
                "delegate_summary": "",
                "delegate_log": "",
                "postflight": capture_system_snapshot("postflight"),
                "memory_decision": memory_decision,
            }
            write_json(output_dir / "run-manifest.json", result)
            write_v2_summary(output_dir, args, modes, config, preflight, result)
            return 2
        if args.surface == "headless-xpc":
            result = run_headless(args, modes, output_dir, config, preflight, memory_decision)
        else:
            result = run_ui(args, modes, output_dir, config, preflight, memory_decision)
        write_v2_summary(output_dir, args, modes, config, preflight, result)
        return int(result.get("exit_code", 1))
    except UsageError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--surface", choices=["headless-xpc", "ui-app"], required=False, default="headless-xpc")
    parser.add_argument("--profile", choices=sorted(PROFILE_CONFIGS), default="smoke")
    parser.add_argument("--modes", default=",".join(DEFAULT_MODES))
    parser.add_argument("--memory-policy", choices=["normal", "stress"], default="normal")
    parser.add_argument("--allow-model-load", action="store_true")
    parser.add_argument("--clone-reference", type=Path)
    parser.add_argument("--clone-transcript")
    parser.add_argument(
        "--custom-voice-profile",
        choices=CUSTOM_VOICE_PROFILES,
        default=None,
        help=(
            "Headless Custom Voice override passed to run_generation_quality_audit.py. "
            "Omit to measure the product default."
        ),
    )
    parser.add_argument(
        "--stream-step-eval-policy",
        choices=["full", "eos-only", "deferred"],
        default=None,
        help="Headless benchmark-only Qwen3 stream-step eval policy.",
    )
    parser.add_argument(
        "--generation-speed-profile",
        choices=GENERATION_SPEED_PROFILES,
        default=None,
        help="Headless benchmark-only Qwen3 generation speed profile.",
    )
    parser.add_argument(
        "--memory-clear-cadence",
        type=int,
        default=None,
        help="Headless benchmark-only Qwen3 generation-loop MLX cache clear cadence; 0 disables per-step clears.",
    )
    parser.add_argument(
        "--post-request-cache-policy",
        choices=POST_REQUEST_CACHE_POLICIES,
        default=None,
        help="Headless benchmark-only post-request MLX cache trim policy.",
    )
    parser.add_argument("--output-dir", type=Path, default=None)
    parser.add_argument("--keep-app-running", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--phase",
        choices=["combined", "build-for-testing", "test-without-building"],
        default="combined",
        help=(
            "headless-xpc matrix phase. 'combined' (default) builds + tests in one xcodebuild "
            "invocation. 'build-for-testing' compiles the test target into the shared cache and "
            "exits without consuming any per-profile env vars. 'test-without-building' runs the "
            "cached test bundle with per-profile env vars and assumes a prior 'build-for-testing' "
            "against the same shared cache. Use the split phases when running a multi-profile "
            "matrix to skip the swift-frontend rebuild on profiles 2..N."
        ),
    )
    return parser.parse_args()


def parse_modes(raw_modes: str) -> list[str]:
    modes = [part.strip() for part in raw_modes.split(",") if part.strip()]
    if not modes:
        modes = list(DEFAULT_MODES)
    unsupported = [mode for mode in modes if mode not in SUPPORTED_MODES]
    if unsupported:
        raise UsageError(f"Unsupported mode(s): {', '.join(unsupported)}")
    deduped: list[str] = []
    for mode in modes:
        if mode not in deduped:
            deduped.append(mode)
    return deduped


def resolve_output_dir(args: argparse.Namespace) -> Path:
    if args.output_dir is not None:
        return (args.output_dir if args.output_dir.is_absolute() else PROJECT_DIR / args.output_dir).resolve()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return (PROJECT_DIR / "build/audio-qc/benchmark-v2" / args.surface / stamp).resolve()


def run_self_test(output_dir: Path) -> int:
    assertions = [
        parse_modes("CustomVoice,VoiceDesign,Clones") == list(DEFAULT_MODES),
        PROFILE_CONFIGS["smoke"].headless_profile == "repeat",
        PROFILE_CONFIGS["balanced"].ui_profile == "balanced",
        PROFILE_CONFIGS["stress"].ui_profile == "stress",
        classify_memory_policy({"swap_used_mb": 4_500.0, "memory_pressure": "System-wide memory free percentage: 30%"}, "normal")["severity"] == "warn",
        classify_memory_policy({"swap_used_mb": 6_500.0, "memory_pressure": "System-wide memory free percentage: 30%"}, "normal")["severity"] == "abort",
        classify_memory_policy({"swap_used_mb": 6_500.0, "memory_pressure": "System-wide memory free percentage: 28%"}, "stress")["severity"] == "warn",
        classify_memory_policy({"swap_used_mb": 8_500.0, "memory_pressure": "System-wide memory free percentage: 28%"}, "stress")["severity"] == "abort",
        classify_memory_policy({"swap_used_mb": 800.0, "swap_free_mb": 400.0, "memory_pressure": "System-wide memory free percentage: 45%"}, "stress")["severity"] == "abort",
        classify_memory_policy({"swap_used_mb": 2_000.0, "memory_pressure": "critical"}, "stress")["severity"] == "abort",
        UI_DRIVER in computer_use_runbook_text("smoke", ["CustomVoice"], "normal"),
    ]
    payload = {
        "passed": all(assertions),
        "assertions": assertions,
        "profiles": {
            name: config.__dict__
            for name, config in sorted(PROFILE_CONFIGS.items())
        },
    }
    write_json(output_dir / "self-test.json", payload)
    print(f"Wrote benchmark V2 self-test to {output_dir}")
    return 0 if all(assertions) else 1


def run_headless(
    args: argparse.Namespace,
    modes: list[str],
    output_dir: Path,
    config: ProfileConfig,
    preflight: dict[str, Any],
    memory_decision: dict[str, Any],
) -> dict[str, Any]:
    is_build_only = args.phase == "build-for-testing"
    if not is_build_only and not args.allow_model_load:
        raise UsageError("--surface headless-xpc requires --allow-model-load.")
    if not is_build_only:
        validate_clone_inputs(args, modes)

    delegate_dir = output_dir / "headless-xpc-run"
    command = [
        sys.executable,
        str(SCRIPTS_DIR / "run_generation_quality_audit.py"),
        "--source",
        "live-xpc",
        "--modes",
        ",".join(modes),
        "--output-dir",
        str(delegate_dir),
        "--benchmark-profile",
        config.headless_profile,
        "--cold-runs",
        str(config.cold_runs),
        "--warm-runs",
        str(config.warm_runs),
        "--repeat-count",
        str(config.repeat_count),
        "--xcode-build-cache-dir",
        str((PROJECT_DIR / "build/audio-qc/benchmark-v2/shared-live-xpc-build").resolve()),
    ]
    if args.phase != "combined":
        command.extend(["--phase", args.phase])
    if not is_build_only:
        command.append("--allow-model-load")
        if args.clone_reference:
            command.extend(["--clone-reference", str(args.clone_reference.resolve())])
        if args.clone_transcript:
            command.extend(["--clone-transcript", args.clone_transcript])
        if args.custom_voice_profile:
            command.extend(["--custom-voice-profile", args.custom_voice_profile])
        if args.stream_step_eval_policy:
            command.extend(["--stream-step-eval-policy", args.stream_step_eval_policy])
        if args.generation_speed_profile:
            command.extend(["--generation-speed-profile", args.generation_speed_profile])
        if args.memory_clear_cadence is not None:
            command.extend(["--memory-clear-cadence", str(args.memory_clear_cadence)])
        if args.post_request_cache_policy:
            command.extend(["--post-request-cache-policy", args.post_request_cache_policy])

    result = run_delegate(command, output_dir / "headless-xpc.log", timeout=None)
    summary_path = delegate_dir / "summary.json"
    delegate_summary = read_json(summary_path)
    if not is_build_only:
        copy_if_exists(delegate_dir / "timing-runs.csv", output_dir / "timing-runs.csv")
        write_headless_memory_samples(output_dir / "memory-samples.csv", delegate_summary)
    postflight = capture_system_snapshot("postflight")
    manifest = run_manifest(
        surface="headless-xpc",
        command=command,
        delegate_dir=delegate_dir,
        summary_path=summary_path,
        result=result,
        preflight=preflight,
        postflight=postflight,
        memory_decision=memory_decision,
    )
    manifest["phase"] = args.phase
    write_json(output_dir / "run-manifest.json", manifest)
    return manifest


def run_ui(
    args: argparse.Namespace,
    modes: list[str],
    output_dir: Path,
    config: ProfileConfig,
    preflight: dict[str, Any],
    memory_decision: dict[str, Any],
) -> dict[str, Any]:
    validate_clone_inputs(args, modes)
    delegate_parent = output_dir / "ui-app-run"
    delegate_parent.mkdir(parents=True, exist_ok=True)
    runbook_path = output_dir / "computer-use-runbook.md"
    runbook_path.write_text(
        computer_use_runbook_text(args.profile, modes, args.memory_policy),
        encoding="utf-8",
    )
    command = [
        sys.executable,
        str(SCRIPTS_DIR / "run_ui_generation_benchmark.py"),
        "--profile",
        config.ui_profile,
        "--modes",
        ",".join(modes),
        "--driver",
        UI_DRIVER,
        "--memory-policy",
        args.memory_policy,
        "--output-dir",
        str(delegate_parent),
    ]
    if args.keep_app_running:
        command.append("--keep-app-running")
    if args.clone_reference:
        command.extend(["--clone-reference", str(args.clone_reference.resolve())])
    if args.clone_transcript:
        command.extend(["--clone-transcript", args.clone_transcript])

    result = run_delegate(command, output_dir / "ui-app.log", timeout=None)
    delegate_dir = newest_summary_parent(delegate_parent)
    summary_path = delegate_dir / "summary.json" if delegate_dir else delegate_parent / "summary.json"
    delegate_summary = read_json(summary_path)
    copy_if_exists(delegate_dir / "timing-runs.csv" if delegate_dir else delegate_parent / "timing-runs.csv", output_dir / "timing-runs.csv")
    copy_if_exists(delegate_dir / "responsiveness.csv" if delegate_dir else delegate_parent / "responsiveness.csv", output_dir / "responsiveness.csv")
    copy_if_exists(output_dir / "responsiveness.csv", output_dir / "memory-samples.csv")
    postflight = capture_system_snapshot("postflight")
    manifest = run_manifest(
        surface="ui-app",
        command=command,
        delegate_dir=delegate_dir or delegate_parent,
        summary_path=summary_path,
        result=result,
        preflight=preflight,
        postflight=postflight,
        memory_decision=memory_decision,
        extra={
            "computer_use_runbook": str(runbook_path),
            "ui_driver": UI_DRIVER,
            "ui_interaction_policy": {
                "primary_visual_validation": "manual computer-use procedure",
                "structured_probe": "macOS Accessibility and AppleScript",
                "coordinate_fallback": "cliclick only when AX metadata is unavailable or brittle",
                "screenshots": "screencapture artifacts from the benchmark script",
            },
            "delegate_summary": delegate_summary,
        },
    )
    write_json(output_dir / "run-manifest.json", manifest)
    return manifest


def validate_clone_inputs(args: argparse.Namespace, modes: list[str]) -> None:
    if "Clones" not in modes:
        return
    if args.clone_reference is None:
        raise UsageError("--clone-reference is required when Clones is included.")
    if not args.clone_reference.is_file():
        raise UsageError(f"Clone reference does not exist: {args.clone_reference}")


def run_delegate(command: list[str], log_path: Path, timeout: int | None) -> dict[str, Any]:
    started = time.perf_counter()
    with log_path.open("w", encoding="utf-8") as log:
        proc = subprocess.run(
            command,
            cwd=PROJECT_DIR,
            text=True,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    return {
        "exit_code": proc.returncode,
        "duration_ms": int((time.perf_counter() - started) * 1000),
        "log_path": str(log_path),
    }


def benchmark_plan(
    args: argparse.Namespace,
    modes: list[str],
    output_dir: Path,
    config: ProfileConfig,
    memory_decision: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "surface": args.surface,
        "profile": args.profile,
        "modes": modes,
        "output_dir": str(output_dir),
        "memory_policy": args.memory_policy,
        "custom_voice_profile": args.custom_voice_profile,
        "generation_speed_profile": args.generation_speed_profile,
        "memory_clear_cadence": args.memory_clear_cadence,
        "post_request_cache_policy": args.post_request_cache_policy,
        "memory_decision": memory_decision,
        "profile_config": config.__dict__,
        "artifacts": [
            "summary.md",
            "summary.json",
            "timing-runs.csv",
            "memory-samples.csv",
            "run-manifest.json",
            "per-run trace/QC/screenshot artifacts under delegate run directories",
        ],
    }


def run_manifest(
    *,
    surface: str,
    command: list[str],
    delegate_dir: Path,
    summary_path: Path,
    result: dict[str, Any],
    preflight: dict[str, Any],
    postflight: dict[str, Any],
    memory_decision: dict[str, Any],
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    summary = read_json(summary_path)
    overall_pass = bool(summary.get("overall_pass", summary.get("responsiveness", {}).get("passed", False)))
    if result["exit_code"] != 0:
        overall_pass = False
    manifest = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "surface": surface,
        "command": command,
        "delegate_dir": str(delegate_dir),
        "delegate_summary": str(summary_path),
        "delegate_exit_code": result["exit_code"],
        "delegate_duration_ms": result["duration_ms"],
        "delegate_log": result["log_path"],
        "overall_pass": overall_pass,
        "exit_code": 0 if overall_pass else 1,
        "preflight": preflight,
        "postflight": postflight,
        "memory_decision": memory_decision,
    }
    if extra:
        manifest.update(extra)
    return manifest


def write_v2_summary(
    output_dir: Path,
    args: argparse.Namespace,
    modes: list[str],
    config: ProfileConfig,
    preflight: dict[str, Any],
    result: dict[str, Any],
) -> None:
    delegate_summary_raw = result.get("delegate_summary") or ""
    summary_path = Path(delegate_summary_raw) if delegate_summary_raw else None
    delegate_summary = read_json(summary_path) if summary_path else {}
    summary = {
        "schema_version": 1,
        "tool": "run_generation_benchmark",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "surface": args.surface,
        "profile": args.profile,
        "modes": modes,
        "memory_policy": args.memory_policy,
        "custom_voice_profile": args.custom_voice_profile,
        "generation_speed_profile": args.generation_speed_profile,
        "memory_clear_cadence": args.memory_clear_cadence,
        "post_request_cache_policy": args.post_request_cache_policy,
        "profile_config": config.__dict__,
        "overall_pass": result.get("overall_pass", False),
        "exit_code": result.get("exit_code", 1),
        "delegate_summary": str(summary_path) if summary_path else "",
        "delegate_log": result.get("delegate_log"),
        "preflight": preflight,
        "postflight": result.get("postflight"),
        "memory_decision": result.get("memory_decision"),
        "timing_csv": str(output_dir / "timing-runs.csv") if (output_dir / "timing-runs.csv").exists() else None,
        "memory_samples_csv": str(output_dir / "memory-samples.csv") if (output_dir / "memory-samples.csv").exists() else None,
    }
    if args.surface == "ui-app":
        summary["ui_driver"] = result.get("ui_driver")
        summary["computer_use_runbook"] = result.get("computer_use_runbook")
        summary["responsiveness_csv"] = str(output_dir / "responsiveness.csv") if (output_dir / "responsiveness.csv").exists() else None
    if delegate_summary:
        summary["delegate"] = compact_delegate_summary(delegate_summary)
    write_json(output_dir / "summary.json", summary)
    (output_dir / "summary.md").write_text(render_summary_markdown(summary), encoding="utf-8")


def compact_delegate_summary(summary: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "overall_pass",
        "source",
        "profile",
        "driver",
        "ui_interaction_policy",
        "benchmark_profile",
        "responsiveness",
        "timing_summary",
        "reports",
        "mode_summaries",
    ]
    return {key: summary.get(key) for key in keys if key in summary}


def render_summary_markdown(summary: dict[str, Any]) -> str:
    status = "PASS" if summary.get("overall_pass") else "FAIL"
    lines = [
        f"# Benchmark V2: {status}",
        "",
        f"- Surface: `{summary.get('surface')}`",
        f"- Profile: `{summary.get('profile')}`",
        f"- Modes: `{', '.join(summary.get('modes') or [])}`",
        f"- Memory policy: `{summary.get('memory_policy')}`",
        f"- Custom Voice profile override: `{summary.get('custom_voice_profile') or 'product-default'}`",
        f"- Generation speed profile: `{summary.get('generation_speed_profile') or 'product-default'}`",
        f"- Memory clear cadence override: `{summary.get('memory_clear_cadence') if summary.get('memory_clear_cadence') is not None else 'profile-default'}`",
        f"- Post-request cache policy override: `{summary.get('post_request_cache_policy') or 'profile-default'}`",
        f"- Delegate summary: `{summary.get('delegate_summary')}`",
        f"- Delegate log: `{summary.get('delegate_log')}`",
        f"- Timing CSV: `{summary.get('timing_csv') or 'n/a'}`",
        f"- Memory samples CSV: `{summary.get('memory_samples_csv') or 'n/a'}`",
        "",
    ]
    if summary.get("surface") == "ui-app":
        lines.extend(
            [
                "## UI Validation",
                "",
                "Manual computer-use validation is the primary visual layer for the V2 UI procedure. "
                "The benchmark script records deterministic AX/AppleScript probes, traces, screenshots, "
                "process state, responsiveness samples, and audio-QC artifacts; `cliclick` remains a last-resort coordinate fallback.",
                "",
                f"- UI driver: `{summary.get('ui_driver')}`",
                f"- Computer Use runbook: `{summary.get('computer_use_runbook')}`",
                f"- Responsiveness CSV: `{summary.get('responsiveness_csv') or 'n/a'}`",
                "",
            ]
        )
    decision = summary.get("memory_decision") or {}
    lines.extend(
        [
            "## Memory Policy",
            "",
            f"- Severity: `{decision.get('severity', 'unknown')}`",
            f"- Reason: {decision.get('reason', 'n/a')}",
            "",
        ]
    )
    delegate = summary.get("delegate") or {}
    if delegate.get("responsiveness"):
        resp = delegate["responsiveness"]
        lines.extend(
            [
                "## Responsiveness",
                "",
                "| Pass | Samples | p95 AX | Max AX | App RSS peak | Helper RSS peak | Swap delta |",
                "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
                (
                    f"| {str(resp.get('passed')).lower()} | {resp.get('sample_count')} | "
                    f"{format_value(resp.get('p95_ax_latency_ms'))} | {format_value(resp.get('max_ax_latency_ms'))} | "
                    f"{format_value(resp.get('app_rss_peak_mb'))} | {format_value(resp.get('helper_rss_peak_mb'))} | "
                    f"{format_value(resp.get('swap_delta_mb'))} |"
                ),
                "",
            ]
        )
    if delegate.get("timing_summary"):
        lines.extend(["## Timing Summary", ""])
        for item in delegate["timing_summary"]:
            wall = ((item.get("wall_clock_ms") or {}).get("median"))
            rtf = ((item.get("real_time_factor") or {}).get("median"))
            lines.append(
                f"- `{item.get('mode')}` / `{item.get('phase')}`: "
                f"samples `{item.get('sample_count')}`, wall median `{format_value(wall)}`, "
                f"RTF median `{format_value(rtf)}`"
            )
        lines.append("")
    return "\n".join(lines)


def capture_system_snapshot(label: str) -> dict[str, Any]:
    swap_raw = shell_output(["sysctl", "vm.swapusage"])
    memory_pressure = shell_output(["bash", "-lc", "memory_pressure | tail -n 12 || true"])
    processes = shell_output(
        [
            "bash",
            "-lc",
            "pgrep -fl 'Vocello|QwenVoiceEngineService|xcodebuild|swift-frontend|harness.py|run_generation_quality_audit.py|run_ui_generation_benchmark.py|run_generation_benchmark.py' || true",
        ]
    )
    return {
        "label": label,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "swap": swap_raw,
        "swap_used_mb": parse_swap_used_mb(swap_raw),
        "swap_free_mb": parse_swap_value_mb(swap_raw, "free"),
        "memory_pressure": memory_pressure,
        "processes": processes,
    }


def classify_memory_policy(snapshot: dict[str, Any], policy: str) -> dict[str, Any]:
    swap_used = snapshot.get("swap_used_mb")
    swap_free = snapshot.get("swap_free_mb")
    pressure = str(snapshot.get("memory_pressure") or "").lower()
    if "critical" in pressure:
        return {
            "severity": "abort",
            "reason": "memory_pressure reported critical pressure",
        }
    if isinstance(swap_free, (int, float)) and swap_free <= PREFLIGHT_MIN_FREE_SWAP_MB:
        return {
            "severity": "abort",
            "reason": (
                "preflight swap free is too low for a live benchmark "
                f"({swap_free:.0f} MB <= {PREFLIGHT_MIN_FREE_SWAP_MB:.0f} MB); "
                "let memory pressure settle first"
            ),
        }
    if policy == "normal":
        if swap_used is not None and swap_used >= NORMAL_PREFLIGHT_ABORT_SWAP_MB:
            return {
                "severity": "abort",
                "reason": (
                    "normal policy will not start live benchmarks with swap at or above "
                    f"{NORMAL_PREFLIGHT_ABORT_SWAP_MB:.0f} MB; current swap is {swap_used:.0f} MB"
                ),
            }
        if swap_used is not None and swap_used >= NORMAL_PREFLIGHT_WARN_SWAP_MB:
            return {
                "severity": "warn",
                "reason": (
                    "normal policy prefers swap below "
                    f"{NORMAL_PREFLIGHT_WARN_SWAP_MB:.0f} MB; current swap is {swap_used:.0f} MB"
                ),
            }
        return {"severity": "ok", "reason": "normal policy preflight is acceptable"}
    if swap_used is not None and swap_used >= STRESS_PREFLIGHT_ABORT_SWAP_MB:
        return {
            "severity": "abort",
            "reason": (
                "stress policy can push memory during a run, but will not start from "
                f"{swap_used:.0f} MB swap; reboot or let pressure settle first"
            ),
        }
    if swap_used is not None and swap_used >= STRESS_PREFLIGHT_WARN_SWAP_MB:
        return {
            "severity": "warn",
            "reason": (
                "stress policy accepts elevated swap but runtime guards hard-stop before "
                f"swap exhaustion; current swap is {swap_used:.0f} MB"
            ),
        }
    return {"severity": "ok", "reason": "stress policy preflight is acceptable"}


def parse_swap_used_mb(raw: str) -> float | None:
    return parse_swap_value_mb(raw, "used")


def parse_swap_value_mb(raw: str, key: str) -> float | None:
    marker = f"{key} = "
    if marker not in raw:
        return None
    value = raw.split(marker, 1)[1].split("M", 1)[0].strip()
    try:
        return float(value)
    except ValueError:
        return None


def write_headless_memory_samples(path: Path, summary: dict[str, Any]) -> None:
    snapshots = ((summary.get("xcodebuild") or {}).get("process_snapshots")) or []
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "elapsed_ms",
                "captured_at",
                "swap_used_mb",
                "swap_free_mb",
                "label",
                "pid",
                "rss_mb",
                "command",
            ],
        )
        writer.writeheader()
        for snapshot in snapshots:
            for process in snapshot.get("processes") or []:
                writer.writerow(
                    {
                        "elapsed_ms": snapshot.get("elapsed_ms"),
                        "captured_at": snapshot.get("captured_at"),
                        "swap_used_mb": snapshot.get("swap_used_mb"),
                        "swap_free_mb": snapshot.get("swap_free_mb"),
                        "label": process.get("label"),
                        "pid": process.get("pid"),
                        "rss_mb": process.get("rss_mb"),
                        "command": process.get("command"),
                    }
                )


def computer_use_runbook_text(profile: str, modes: list[str], memory_policy: str) -> str:
    return "\n".join(
        [
            "# Computer Use UI Benchmark Runbook",
            "",
            f"Driver: `{UI_DRIVER}`",
            "",
            "Use the manual computer-use procedure as the primary visual validation layer for visible UI benchmark runs. The script also records macOS Accessibility/System Events probes, AppleScript keyboard and pasteboard actions, `screencapture` screenshots, shell process probes, and optional `cliclick` coordinate fallback.",
            "",
            f"- Profile: `{profile}`",
            f"- Modes: `{', '.join(modes)}`",
            f"- Memory policy: `{memory_policy}`",
            "",
            "Computer Use checklist:",
            "",
            "1. Start from a clean app state before the benchmark launches.",
            "2. Ensure exactly one `Vocello.app` instance is active for the script-owned run.",
            "3. Use Computer Use for visible mode switching, text entry, Generate activation, busy feedback, playback/save checks, and screenshots.",
            "4. Use `cliclick` only as the optional coordinate fallback when AX metadata is unavailable or brittle.",
            "5. Trust timing, memory, trace, screenshot, responsiveness, and audio-QC artifacts emitted by the script.",
            "",
            "If Computer Use or the structured probe cannot prove a UI action, preserve screenshots and classify the sample as UI validation failed rather than trusting the timing number.",
        ]
    ) + "\n"


def newest_summary_parent(parent: Path) -> Path | None:
    candidates = [
        path
        for path in parent.iterdir()
        if path.is_dir() and (path / "summary.json").is_file()
    ] if parent.exists() else []
    if not candidates:
        return parent if (parent / "summary.json").is_file() else None
    return max(candidates, key=lambda path: (path / "summary.json").stat().st_mtime)


def read_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def copy_if_exists(source: Path, destination: Path) -> None:
    if source.is_file():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def shell_output(command: list[str]) -> str:
    try:
        return subprocess.run(
            command,
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        ).stdout
    except Exception as error:
        return f"{type(error).__name__}: {error}"


def format_value(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


if __name__ == "__main__":
    raise SystemExit(main())
