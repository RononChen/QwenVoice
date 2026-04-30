#!/usr/bin/env python3
"""Run a UI-triggered Custom Voice performance audit for the macOS app.

This intentionally drives the real SwiftUI app through keyboard/mouse events.
The shell only launches the app, collects traces, samples processes, and runs
objective audio QC on the WAV files produced by the UI.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
APP_SUPPORT = Path.home() / "Library/Application Support/QwenVoice"
CUSTOM_OUTPUTS = APP_SUPPORT / "outputs/CustomVoice"
PROCESS_PATTERN = (
    "Vocello|QwenVoiceEngineService|xcodebuild|swift-frontend|harness.py|"
    "run_generation_quality_audit.py"
)


@dataclass
class RunResult:
    phase: str
    index: int
    prompt_characters: int
    ready_observed: bool
    generate_pressed_at_unix_ms: int
    first_file_ms: int | None
    first_non_header_bytes_ms: int | None
    final_size_first_observed_ms: int | None
    stable_final_ms: int | None
    output_path: str | None
    output_size_bytes: int | None
    duration_seconds: float | None
    qc_passed: bool
    qc_exit_code: int | None
    qc_json: str | None
    qc_report: str | None
    trace_json: str | None
    screenshot: str | None
    error: str | None = None


def run(
    command: list[str],
    *,
    cwd: Path = ROOT,
    timeout: int | None = None,
    check: bool = True,
    env: dict[str, str] | None = None,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        timeout=timeout,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def shell_output(command: list[str], *, check: bool = False) -> str:
    completed = run(command, check=check, capture=True)
    return completed.stdout or ""


def apple_script(source: str, *, check: bool = True, timeout: int | None = None) -> str:
    completed = run(
        ["osascript", "-e", source],
        check=check,
        capture=True,
        timeout=timeout,
    )
    return (completed.stdout or "").strip()


def apple_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def process_snapshot() -> str:
    return shell_output(["bash", "-lc", f"pgrep -fl '{PROCESS_PATTERN}' || true"])


def swap_snapshot() -> str:
    return shell_output(["sysctl", "vm.swapusage"])


def memory_pressure_snapshot() -> str:
    return shell_output(["bash", "-lc", "memory_pressure | tail -n 12 || true"])


def running_vocello_processes() -> str:
    return shell_output(["bash", "-lc", "pgrep -fl 'Vocello|QwenVoiceEngineService' || true"])


def collect_custom_outputs() -> set[Path]:
    if not CUSTOM_OUTPUTS.exists():
        return set()
    return {
        path
        for path in CUSTOM_OUTPUTS.rglob("*.wav")
        if path.is_file()
    }


def collect_traces(trace_dir: Path) -> set[Path]:
    if not trace_dir.exists():
        return set()
    return set(trace_dir.glob("custom_voice_ui_trace_*.json"))


def newest(paths: set[Path]) -> Path | None:
    if not paths:
        return None
    return max(paths, key=lambda p: p.stat().st_mtime)


def window_bounds() -> tuple[int, int, int, int]:
    source = """
tell application "System Events"
  tell process "Vocello"
    set frontmost to true
    set p to position of window 1
    set s to size of window 1
    return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
  end tell
end tell
"""
    raw = apple_script(source)
    parts = [int(float(part.strip())) for part in raw.split(",")]
    if len(parts) != 4:
        raise RuntimeError(f"Unexpected window bounds output: {raw!r}")
    return parts[0], parts[1], parts[2], parts[3]


def wait_for_app_window(timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            window_bounds()
            return
        except Exception:
            time.sleep(0.5)
    raise RuntimeError("Vocello window did not become available.")


def accessibility_text_exists(text: str) -> bool:
    source = f"""
on hasText(targetText)
  tell application "System Events"
    tell process "Vocello"
      if not (exists window 1) then return false
      repeat with itemRef in entire contents of window 1
        try
          if ((name of itemRef) as text) is targetText then return true
        end try
      end repeat
    end tell
  end tell
  return false
end hasText
return hasText({apple_string(text)})
"""
    try:
        return apple_script(source, check=False, timeout=2).lower() == "true"
    except subprocess.TimeoutExpired:
        return False
    except Exception:
        return False


def wait_for_ready(timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if accessibility_text_exists("Ready to generate"):
            return True
        time.sleep(0.75)
    return False


def click_custom_voice_and_editor(cliclick: str) -> None:
    x, y, width, height = window_bounds()
    custom_voice_x = x + max(120, min(210, width // 8))
    custom_voice_y = y + max(190, min(260, height // 5))
    editor_x = x + max(520, int(width * 0.32))
    editor_y = y + max(520, int(height * 0.50))
    run([cliclick, f"c:{custom_voice_x},{custom_voice_y}"], check=True)
    time.sleep(0.35)
    focus_accessibility_element("textInput_textEditor")
    run([cliclick, f"c:{editor_x},{editor_y}"], check=True)
    time.sleep(0.25)
    focus_accessibility_element("textInput_textEditor")


def focus_accessibility_element(identifier: str) -> bool:
    source = f"""
on focusElement(targetIdentifier)
  tell application "System Events"
    tell process "Vocello"
      if not (exists window 1) then return false
      repeat with itemRef in entire contents of window 1
        try
          if ((value of attribute "AXIdentifier" of itemRef) as text) is targetIdentifier then
            set focused of itemRef to true
            click itemRef
            return true
          end if
        end try
      end repeat
    end tell
  end tell
  return false
end focusElement
return focusElement({apple_string(identifier)})
"""
    try:
        return apple_script(source, check=False, timeout=3).lower() == "true"
    except subprocess.TimeoutExpired:
        return False


def replace_text(prompt: str) -> None:
    subprocess.run(["pbcopy"], input=prompt, text=True, check=True)
    source = f"""
tell application "System Events"
  tell process "Vocello"
    set frontmost to true
    keystroke "a" using command down
    key code 51
    keystroke "v" using command down
  end tell
end tell
"""
    apple_script(source)


GENERATION_STARTED_STAGES = {
    "generate_action_accepted",
    "coordinator_started",
    "preview_setup_started",
    "engine_request_started",
    "first_live_chunk_event",
    "generation_finished",
}


def trace_reports_generation_started(trace_path: Path | None) -> bool:
    if trace_path is None:
        return False
    try:
        trace = json.loads(trace_path.read_text())
    except Exception:
        return False
    return any(
        event.get("stage") in GENERATION_STARTED_STAGES
        for event in trace.get("events", [])
        if isinstance(event, dict)
    )


def wait_for_generation_started(
    before_traces: set[Path],
    trace_dir: Path,
    *,
    timeout: float = 2.5,
) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if wait_for_generating_live_preview(timeout=0.2):
            return True
        trace = newest(collect_traces(trace_dir) - before_traces)
        if trace_reports_generation_started(trace):
            return True
        time.sleep(0.1)
    return False


def click_generate_button(cliclick: str, *, before_traces: set[Path], trace_dir: Path) -> None:
    run([cliclick, "kd:cmd", "kp:return", "ku:cmd"], check=False)
    if wait_for_generation_started(before_traces, trace_dir):
        return

    shortcut_source = """
tell application "System Events"
  tell process "Vocello"
    set frontmost to true
    keystroke return using command down
  end tell
end tell
"""
    apple_script(shortcut_source, check=False, timeout=2)
    if wait_for_generation_started(before_traces, trace_dir):
        return

    source = """
on clickGenerate()
  tell application "System Events"
    tell process "Vocello"
      if not (exists window 1) then return false
      repeat with itemRef in entire contents of window 1
        try
          if ((value of attribute "AXIdentifier" of itemRef) as text) is "textInput_generateButton" then
            click itemRef
            return true
          end if
        end try
        try
          if ((role of itemRef) as text) is "AXButton" and ((name of itemRef) as text) is "Generate" then
            click itemRef
            return true
          end if
        end try
      end repeat
    end tell
  end tell
  return false
end clickGenerate
return clickGenerate()
"""
    try:
        if apple_script(source, check=False, timeout=3).lower() == "true":
            if wait_for_generation_started(before_traces, trace_dir):
                return
    except subprocess.TimeoutExpired:
        pass

    x, y, width, height = window_bounds()
    generate_x = x + max(700, min(740, int(width * 0.285)))
    generate_y = y + max(760, int(height * 0.86))
    run([cliclick, f"c:{generate_x},{generate_y}"], check=True)
    if not wait_for_generation_started(before_traces, trace_dir, timeout=4.0):
        raise RuntimeError("Generate action did not start according to UI state or trace events.")


def wait_for_generating_live_preview(timeout: float = 2.5) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if accessibility_text_exists("Generating live preview"):
            return True
        time.sleep(0.15)
    return False


def summarize_trace(trace_json: str | None) -> dict[str, Any]:
    if trace_json is None:
        return {}
    try:
        trace = json.loads(Path(trace_json).read_text())
    except Exception:
        return {}
    event_times = {
        event.get("stage"): event.get("elapsed_ms")
        for event in trace.get("events", [])
        if isinstance(event, dict)
    }
    runtime_timings = trace.get("runtime_timings_ms", {})
    runtime_boolean_flags = trace.get("runtime_boolean_flags", {})
    return {
        "trace_first_live_chunk_ms": event_times.get("first_live_chunk_event"),
        "trace_final_file_ready_ms": event_times.get("final_file_ready"),
        "trace_generation_finished_ms": event_times.get("generation_finished"),
        "benchmark_first_chunk_ms": runtime_timings.get("benchmark_first_chunk_ms"),
        "runtime_generation_ms": runtime_timings.get("generation"),
        "stream_chunk_count": runtime_timings.get("stream_chunk_count"),
        "streaming_interval_ms": runtime_timings.get("streaming_interval_ms"),
        "prefix_cache_hit": runtime_boolean_flags.get("prefix_cache_hit"),
        "custom_prefix_cache_hit": runtime_boolean_flags.get("custom_prefix_cache_hit"),
        "decoder_bucket_cache_hit": runtime_boolean_flags.get("decoder_bucket_cache_hit"),
    }


def capture_screenshot(path: Path) -> None:
    run(["screencapture", "-x", str(path)], check=False)


def wait_for_output(
    before_outputs: set[Path],
    *,
    start: float,
    timeout: float = 150.0,
) -> tuple[Path | None, dict[str, int | None]]:
    deadline = time.monotonic() + timeout
    first_file_ms: int | None = None
    first_non_header_ms: int | None = None
    final_size_first_ms: int | None = None
    stable_final_ms: int | None = None
    output_path: Path | None = None
    last_size: int | None = None
    last_change = time.monotonic()

    while time.monotonic() < deadline:
        candidates = collect_custom_outputs() - before_outputs
        candidate = newest(candidates)
        if candidate is not None and candidate.exists():
            output_path = candidate
            elapsed_ms = int((time.monotonic() - start) * 1_000)
            size = candidate.stat().st_size
            if first_file_ms is None:
                first_file_ms = elapsed_ms
            if first_non_header_ms is None and size > 4_096:
                first_non_header_ms = elapsed_ms
            if size != last_size:
                last_size = size
                last_change = time.monotonic()
                final_size_first_ms = elapsed_ms
            elif size > 4_096 and time.monotonic() - last_change >= 2.0:
                stable_final_ms = elapsed_ms
                break
        time.sleep(0.25)

    return output_path, {
        "first_file_ms": first_file_ms,
        "first_non_header_bytes_ms": first_non_header_ms,
        "final_size_first_observed_ms": final_size_first_ms,
        "stable_final_ms": stable_final_ms,
    }


def wait_for_trace(before_traces: set[Path], trace_dir: Path, timeout: float = 12.0) -> Path | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        trace = newest(collect_traces(trace_dir) - before_traces)
        if trace is not None:
            try:
                json.loads(trace.read_text())
                return trace
            except Exception:
                pass
        time.sleep(0.25)
    return None


def trace_reports_ready_at_click(trace_path: Path | None) -> bool:
    if trace_path is None:
        return False
    try:
        trace = json.loads(trace_path.read_text())
    except Exception:
        return False
    for event in trace.get("events", []):
        if event.get("stage") != "generate_action_accepted":
            continue
        metadata = event.get("metadata", {})
        snapshot_load_state = str(metadata.get("snapshot_load_state", ""))
        return snapshot_load_state.startswith("loaded:pro_custom")
    return False


def afinfo_duration(path: Path) -> float | None:
    output = shell_output(["afinfo", str(path)])
    for line in output.splitlines():
        if line.strip().startswith("estimated duration:"):
            raw = line.split(":", 1)[1].strip().split()[0]
            try:
                return float(raw)
            except ValueError:
                return None
    return None


def run_audio_qc(path: Path, output_dir: Path, phase: str, index: int) -> tuple[bool, int, Path, Path]:
    json_out = output_dir / f"{phase}-{index}-audio-qc.json"
    report_out = output_dir / f"{phase}-{index}-audio-qc.md"
    completed = run(
        [
            sys.executable,
            "scripts/audit_generated_audio.py",
            "--file",
            str(path),
            "--json-out",
            str(json_out),
            "--report-out",
            str(report_out),
        ],
        check=False,
        timeout=90,
    )
    if completed.stdout:
        (output_dir / f"{phase}-{index}-audio-qc.log").write_text(completed.stdout)
    return completed.returncode == 0, completed.returncode, json_out, report_out


def run_one_generation(
    *,
    phase: str,
    index: int,
    prompt: str,
    output_dir: Path,
    trace_dir: Path,
    cliclick: str,
    ready_timeout: float,
) -> RunResult:
    before_outputs = collect_custom_outputs()
    before_traces = collect_traces(trace_dir)
    screenshot_path = output_dir / f"{phase}-{index}-after.png"
    error: str | None = None
    click_custom_voice_and_editor(cliclick)
    replace_text(prompt)
    ready_observed = wait_for_ready(ready_timeout)
    time.sleep(0.2)
    start = time.monotonic()
    generate_pressed_at_unix_ms = int(time.time() * 1_000)
    click_generate_button(cliclick, before_traces=before_traces, trace_dir=trace_dir)

    output_path, timings = wait_for_output(before_outputs, start=start)
    capture_screenshot(screenshot_path)
    trace_path = wait_for_trace(before_traces, trace_dir)
    ready_observed = ready_observed or trace_reports_ready_at_click(trace_path)

    qc_passed = False
    qc_exit_code: int | None = None
    qc_json: Path | None = None
    qc_report: Path | None = None
    duration_seconds: float | None = None
    size_bytes: int | None = None

    if output_path is None:
        error = "No Custom Voice WAV appeared before timeout."
    else:
        size_bytes = output_path.stat().st_size
        duration_seconds = afinfo_duration(output_path)
        qc_passed, qc_exit_code, qc_json, qc_report = run_audio_qc(output_path, output_dir, phase, index)

    return RunResult(
        phase=phase,
        index=index,
        prompt_characters=len(prompt),
        ready_observed=ready_observed,
        generate_pressed_at_unix_ms=generate_pressed_at_unix_ms,
        first_file_ms=timings["first_file_ms"],
        first_non_header_bytes_ms=timings["first_non_header_bytes_ms"],
        final_size_first_observed_ms=timings["final_size_first_observed_ms"],
        stable_final_ms=timings["stable_final_ms"],
        output_path=str(output_path) if output_path else None,
        output_size_bytes=size_bytes,
        duration_seconds=duration_seconds,
        qc_passed=qc_passed,
        qc_exit_code=qc_exit_code,
        qc_json=str(qc_json) if qc_json else None,
        qc_report=str(qc_report) if qc_report else None,
        trace_json=str(trace_path) if trace_path else None,
        screenshot=str(screenshot_path) if screenshot_path.exists() else None,
        error=error,
    )


def write_summary(output_dir: Path, results: list[RunResult], preflight: dict[str, str], postflight: dict[str, str]) -> None:
    summary = {
        "schema_version": 1,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "runs": [asdict(result) for result in results],
        "preflight": preflight,
        "postflight": postflight,
    }
    (output_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True))

    lines = [
        "# Custom Voice UI Performance Audit",
        "",
        f"Created: `{summary['created_at']}`",
        "",
        "| Phase | Run | Ready Seen | File First Bytes | Stable Final | Trace First Chunk | Runtime Generation | Chunks | Interval | QC | Trace |",
        "| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |",
    ]
    for result in results:
        trace = Path(result.trace_json).name if result.trace_json else "missing"
        trace_metrics = summarize_trace(result.trace_json)
        lines.append(
            "| "
            f"{result.phase} | {result.index} | {str(result.ready_observed).lower()} | "
            f"{result.first_non_header_bytes_ms if result.first_non_header_bytes_ms is not None else 'n/a'} | "
            f"{result.stable_final_ms if result.stable_final_ms is not None else 'n/a'} | "
            f"{trace_metrics.get('trace_first_live_chunk_ms', 'n/a')} | "
            f"{trace_metrics.get('runtime_generation_ms', 'n/a')} | "
            f"{trace_metrics.get('stream_chunk_count', 'n/a')} | "
            f"{trace_metrics.get('streaming_interval_ms', 'n/a')} | "
            f"{'pass' if result.qc_passed else 'fail'} | {trace} |"
        )
    lines.extend(
        [
            "",
            "## Process Snapshots",
            "",
            "### Before",
            "",
            "```text",
            preflight.get("processes", "").strip(),
            preflight.get("swap", "").strip(),
            "```",
            "",
            "### After",
            "",
            "```text",
            postflight.get("processes", "").strip(),
            postflight.get("swap", "").strip(),
            "```",
        ]
    )
    (output_dir / "summary.md").write_text("\n".join(lines) + "\n")


def launch_app(output_dir: Path, trace_dir: Path) -> None:
    build_log = output_dir / "build_and_run.log"
    run(["launchctl", "setenv", "QWENVOICE_UI_PERF_AUDIT", "1"], check=True)
    run(["launchctl", "setenv", "QWENVOICE_UI_PERF_AUDIT_DIR", str(trace_dir)], check=True)
    with build_log.open("w") as log:
        completed = subprocess.run(
            ["./scripts/build_and_run.sh", "--verify"],
            cwd=ROOT,
            text=True,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=900,
        )
    if completed.returncode != 0:
        raise RuntimeError(f"build_and_run.sh failed; see {build_log}")
    wait_for_app_window()


def launch_existing_debug_app(trace_dir: Path) -> None:
    app_path = ROOT / "build/DerivedData/Build/Products/Debug/Vocello.app"
    if not app_path.exists():
        raise RuntimeError(f"Debug app not found at {app_path}; run without --skip-build first.")
    run(["launchctl", "setenv", "QWENVOICE_UI_PERF_AUDIT", "1"], check=True)
    run(["launchctl", "setenv", "QWENVOICE_UI_PERF_AUDIT_DIR", str(trace_dir)], check=True)
    if "Vocello" not in running_vocello_processes():
        run(["open", "-na", str(app_path)], check=True)
    wait_for_app_window()


def cleanup_launch_env() -> None:
    run(["launchctl", "unsetenv", "QWENVOICE_UI_PERF_AUDIT"], check=False)
    run(["launchctl", "unsetenv", "QWENVOICE_UI_PERF_AUDIT_DIR"], check=False)


def terminate_app() -> None:
    run(["osascript", "-e", 'tell application "Vocello" to quit'], check=False)
    time.sleep(1.0)
    run(["pkill", "-x", "Vocello"], check=False)
    run(["pkill", "-x", "QwenVoiceEngineService"], check=False)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cold-runs", type=int, default=1)
    parser.add_argument("--warm-runs", type=int, default=3)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/audio-qc/customvoice-ui-perf")
    parser.add_argument(
        "--ready-timeout",
        type=float,
        default=12.0,
        help="Best-effort readiness wait. The app trace is authoritative for loaded-state at click.",
    )
    parser.add_argument("--skip-build", action="store_true", help="Use the currently running app instead of build_and_run.sh.")
    parser.add_argument("--keep-app-running", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_dir = args.output_dir if args.output_dir.is_absolute() else ROOT / args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    trace_dir = output_dir / "traces"
    trace_dir.mkdir(parents=True, exist_ok=True)

    cliclick = shutil.which("cliclick")
    if cliclick is None:
        print("error: cliclick is required for this UI audit. Install with `brew install cliclick`.", file=sys.stderr)
        return 2

    preflight = {
        "processes": process_snapshot(),
        "swap": swap_snapshot(),
        "memory_pressure": memory_pressure_snapshot(),
    }
    (output_dir / "preflight-processes.txt").write_text(preflight["processes"])
    (output_dir / "preflight-memory.txt").write_text(preflight["swap"] + "\n" + preflight["memory_pressure"])

    if not args.skip_build:
        active = preflight["processes"].strip()
        if active:
            (output_dir / "preflight-active-processes.txt").write_text(active + "\n")
        launch_app(output_dir, trace_dir)
    else:
        launch_existing_debug_app(trace_dir)

    prompts: list[tuple[str, int, str]] = []
    for index in range(1, args.cold_runs + 1):
        prompts.append(("cold", index, f"Cold custom voice UI performance run {index}. Please speak clearly."))
    for index in range(1, args.warm_runs + 1):
        prompts.append(("warm", index, f"Warm custom voice UI performance run {index}. Please speak clearly."))

    results: list[RunResult] = []
    exit_code = 0
    try:
        capture_screenshot(output_dir / "launch.png")
        for phase, index, prompt in prompts:
            result = run_one_generation(
                phase=phase,
                index=index,
                prompt=prompt,
                output_dir=output_dir,
                trace_dir=trace_dir,
                cliclick=cliclick,
                ready_timeout=args.ready_timeout,
            )
            results.append(result)
            (output_dir / f"{phase}-{index}-processes.txt").write_text(running_vocello_processes())
            (output_dir / f"{phase}-{index}-memory.txt").write_text(swap_snapshot())
            if result.error or not result.qc_passed or result.trace_json is None:
                exit_code = 1
            time.sleep(1.0)
    finally:
        postflight = {
            "processes": running_vocello_processes(),
            "swap": swap_snapshot(),
            "memory_pressure": memory_pressure_snapshot(),
        }
        write_summary(output_dir, results, preflight, postflight)
        if not args.keep_app_running:
            terminate_app()
        cleanup_launch_env()

    print(f"Wrote Custom Voice UI performance audit to {output_dir}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
