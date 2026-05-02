#!/usr/bin/env python3
"""Run a UI-only generation benchmark for Vocello.

The benchmark drives the visible macOS app and records UI responsiveness while
the backend is under load. The manual computer-use procedure is the preferred
visual validation posture for UI benchmark runs. This script owns deterministic
timing, trace, process, and audio-QC artifacts, backed by macOS Accessibility/
System Events, AppleScript keyboard/pasteboard actions, `screencapture`, shell
process probes, and optional `cliclick` coordinate fallback only when AX
metadata is unavailable or brittle.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import statistics
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
APP_SUPPORT = Path.home() / "Library/Application Support/QwenVoice"
DEFAULT_UI_DRIVER = "computer-use-first"
PROCESS_PATTERN = (
    "Vocello|QwenVoiceEngineService|xcodebuild|swift-frontend|harness.py|"
    "run_generation_quality_audit.py|run_ui_generation_benchmark.py"
)
LONG_FORM_MAX_CHARACTERS = 900


MODE_IDS = {
    "CustomVoice": "customVoice",
    "VoiceDesign": "voiceDesign",
    "Clones": "voiceCloning",
}

MODE_OUTPUT_SUBFOLDERS = {
    "CustomVoice": "CustomVoice",
    "VoiceDesign": "VoiceDesign",
    "Clones": "Clones",
}

MODE_SCREEN_IDENTIFIERS = {
    "CustomVoice": "screen_customVoice",
    "VoiceDesign": "screen_voiceDesign",
    "Clones": "screen_voiceCloning",
}

MODE_TITLE_TEXT = {
    "CustomVoice": "Custom Voice",
    "VoiceDesign": "Voice Design",
    "Clones": "Voice Cloning",
}

MODE_SIDEBAR_FALLBACK_OFFSETS = {
    "CustomVoice": 270,
    "VoiceDesign": 346,
    "Clones": 421,
}

MODE_READINESS_IDENTIFIERS = {
    "CustomVoice": "customVoice_readiness",
    "VoiceDesign": "voiceDesign_readiness",
    "Clones": "voiceCloning_readiness",
}

GENERATION_STARTED_STAGES = {
    "generate_action_accepted",
    "coordinator_started",
    "preview_setup_started",
    "engine_request_started",
    "first_live_chunk_event",
    "generation_finished",
}


@dataclass
class ResponsivenessSample:
    unix_ms: int
    label: str
    ax_latency_ms: int | None
    ax_ok: bool
    app_rss_mb: float | None
    helper_rss_mb: float | None
    helper_count: int
    app_count: int
    swap_used_mb: float | None


@dataclass
class DirectRunResult:
    kind: str
    mode: str
    case_name: str
    phase: str
    run_index: int
    text_character_count: int
    text_word_count: int
    ready_observed: bool
    ready_wait_ms: int | None
    generate_pressed_at_unix_ms: int | None
    first_file_ms: int | None
    first_non_header_bytes_ms: int | None
    final_size_first_observed_ms: int | None
    stable_final_ms: int | None
    trace_first_live_chunk_ms: int | None
    trace_generation_finished_ms: int | None
    runtime_generation_ms: int | None
    stream_chunk_count: int | None
    streaming_interval_ms: int | None
    output_path: str | None
    output_size_bytes: int | None
    duration_seconds: float | None
    real_time_factor: float | None
    qc_passed: bool
    qc_exit_code: int | None
    qc_json: str | None
    qc_report: str | None
    trace_json: str | None
    screenshot: str | None
    responsiveness_passed: bool | None
    responsiveness_p95_ax_latency_ms: int | None
    responsiveness_max_ax_latency_ms: int | None
    app_rss_peak_mb: float | None
    helper_rss_peak_mb: float | None
    swap_delta_mb: float | None
    error: str | None = None


@dataclass
class RoutingRunResult:
    kind: str
    mode: str
    case_name: str
    text_character_count: int
    text_word_count: int
    routed_to_batch: bool
    route_latency_ms: int | None
    screenshot: str | None
    responsiveness_passed: bool | None
    error: str | None = None


@dataclass
class BatchRunResult:
    kind: str
    mode: str
    case_name: str
    text_character_count: int
    text_word_count: int
    segment_count: int
    batch_wall_ms: int | None
    generated_outputs: int
    failed_outputs: int
    qc_passed: bool
    manifest_path: str | None
    output_paths: list[str]
    qc_reports: list[str]
    screenshot: str | None
    responsiveness_passed: bool | None
    responsiveness_p95_ax_latency_ms: int | None
    app_rss_peak_mb: float | None
    helper_rss_peak_mb: float | None
    swap_delta_mb: float | None
    error: str | None = None


BenchmarkResult = DirectRunResult | RoutingRunResult | BatchRunResult


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


def shell_output(command: list[str], *, check: bool = False, timeout: int | None = None) -> str:
    completed = run(command, check=check, capture=True, timeout=timeout)
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


def now_ms() -> int:
    return int(time.time() * 1_000)


def word_count(text: str) -> int:
    return len([part for part in text.split() if part.strip()])


def process_snapshot() -> str:
    return shell_output(["bash", "-lc", f"pgrep -fl '{PROCESS_PATTERN}' || true"])


def running_vocello_processes() -> str:
    return shell_output(["bash", "-lc", "pgrep -fl 'Vocello|QwenVoiceEngineService' || true"])


def swap_snapshot() -> str:
    return shell_output(["sysctl", "vm.swapusage"])


def memory_pressure_snapshot() -> str:
    return shell_output(["bash", "-lc", "memory_pressure | tail -n 12 || true"])


def parse_swap_used_mb(raw: str) -> float | None:
    marker = "used = "
    if marker not in raw:
        return None
    value = raw.split(marker, 1)[1].split("M", 1)[0].strip()
    try:
        return float(value)
    except ValueError:
        return None


def pids_for_exact_name(name: str) -> list[int]:
    raw = shell_output(["pgrep", "-x", name], check=False).strip()
    if not raw:
        return []
    return [int(line) for line in raw.splitlines() if line.strip().isdigit()]


def rss_mb_for_pids(pids: list[int]) -> float | None:
    if not pids:
        return None
    raw = shell_output(
        ["ps", "-o", "rss=", "-p", ",".join(str(pid) for pid in pids)],
        check=False,
    )
    values: list[int] = []
    for line in raw.splitlines():
        try:
            values.append(int(line.strip()))
        except ValueError:
            pass
    if not values:
        return None
    return sum(values) / 1024.0


class AutomationInputError(RuntimeError):
    """The UI automation failed before a valid product action could be measured."""


class ResponsivenessMonitor:
    def __init__(self, output_dir: Path) -> None:
        self.output_dir = output_dir
        self.samples: list[ResponsivenessSample] = []
        self._label = "idle"
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._start_swap_mb: float | None = None

    def start(self) -> None:
        self._start_swap_mb = parse_swap_used_mb(swap_snapshot())
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="ui-responsiveness-monitor", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=3)
            self._thread = None

    def set_label(self, label: str) -> None:
        with self._lock:
            self._label = label

    def summary(self, label_prefix: str | None = None) -> dict[str, Any]:
        with self._lock:
            samples = list(self.samples)
        if label_prefix:
            samples = [sample for sample in samples if sample.label.startswith(label_prefix)]

        latencies = [sample.ax_latency_ms for sample in samples if sample.ax_latency_ms is not None]
        app_rss = [sample.app_rss_mb for sample in samples if sample.app_rss_mb is not None]
        helper_rss = [sample.helper_rss_mb for sample in samples if sample.helper_rss_mb is not None]
        helper_counts = [sample.helper_count for sample in samples]
        app_counts = [sample.app_count for sample in samples]
        swap_values = [sample.swap_used_mb for sample in samples if sample.swap_used_mb is not None]

        p95_latency = percentile(latencies, 95) if latencies else None
        max_latency = max(latencies) if latencies else None
        max_helper_count = max(helper_counts) if helper_counts else 0
        max_app_count = max(app_counts) if app_counts else 0
        inaccessible = any(not sample.ax_ok for sample in samples)
        swap_delta = None
        if self._start_swap_mb is not None and swap_values:
            swap_delta = max(swap_values) - self._start_swap_mb

        passed = (
            bool(samples)
            and not inaccessible
            and (p95_latency is None or p95_latency <= 750)
            and (max_latency is None or max_latency <= 2_000)
            and max_helper_count <= 1
            and max_app_count <= 1
        )
        return {
            "sample_count": len(samples),
            "passed": passed,
            "p95_ax_latency_ms": p95_latency,
            "max_ax_latency_ms": max_latency,
            "app_rss_peak_mb": max(app_rss) if app_rss else None,
            "helper_rss_peak_mb": max(helper_rss) if helper_rss else None,
            "helper_count_peak": max_helper_count,
            "app_count_peak": max_app_count,
            "swap_delta_mb": swap_delta,
        }

    def write_csv(self) -> None:
        path = self.output_dir / "responsiveness.csv"
        with path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(asdict(ResponsivenessSample(0, "", None, False, None, None, 0, 0, None)).keys()))
            writer.writeheader()
            with self._lock:
                for sample in self.samples:
                    writer.writerow(asdict(sample))

    def _run(self) -> None:
        while not self._stop.is_set():
            sample = self._sample()
            with self._lock:
                self.samples.append(sample)
            self._stop.wait(0.5)

    def _sample(self) -> ResponsivenessSample:
        with self._lock:
            label = self._label
        start = time.monotonic()
        ax_ok = accessibility_window_available(timeout=1.5)
        elapsed_ms = int((time.monotonic() - start) * 1_000)
        app_pids = pids_for_exact_name("Vocello")
        helper_pids = pids_for_exact_name("QwenVoiceEngineService")
        return ResponsivenessSample(
            unix_ms=now_ms(),
            label=label,
            ax_latency_ms=elapsed_ms,
            ax_ok=ax_ok,
            app_rss_mb=rss_mb_for_pids(app_pids),
            helper_rss_mb=rss_mb_for_pids(helper_pids),
            helper_count=len(helper_pids),
            app_count=len(app_pids),
            swap_used_mb=parse_swap_used_mb(swap_snapshot()),
        )


def percentile(values: list[int], pct: int) -> int:
    if not values:
        return 0
    sorted_values = sorted(values)
    index = round((len(sorted_values) - 1) * (pct / 100.0))
    return sorted_values[index]


def accessibility_window_available(*, timeout: float = 1.5) -> bool:
    source = """
tell application "System Events"
  if not (exists process "Vocello") then return false
  tell process "Vocello"
    if not (exists window 1) then return false
    return true
  end tell
end tell
"""
    try:
        return apple_script(source, check=False, timeout=max(1, int(timeout))).lower() == "true"
    except subprocess.TimeoutExpired:
        return False
    except Exception:
        return False


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
    raw = apple_script(source, timeout=5)
    parts = [int(float(part.strip())) for part in raw.split(",")]
    if len(parts) != 4:
        raise RuntimeError(f"Unexpected window bounds output: {raw!r}")
    return parts[0], parts[1], parts[2], parts[3]


def wait_for_app_window(timeout: float = 45.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            window_bounds()
            return
        except Exception:
            time.sleep(0.5)
    raise RuntimeError("Vocello window did not become available.")


def click_accessibility_element(identifier: str, *, timeout: float = 5.0) -> bool:
    source = f"""
on clickElement(targetIdentifier)
  tell application "System Events"
    tell process "Vocello"
      if not (exists window 1) then return false
      repeat with itemRef in entire contents of window 1
        try
          if ((value of attribute "AXIdentifier" of itemRef) as text) is targetIdentifier then
            click itemRef
            return true
          end if
        end try
      end repeat
    end tell
  end tell
  return false
end clickElement
return clickElement({apple_string(identifier)})
"""
    try:
        return apple_script(source, check=False, timeout=int(timeout)).lower() == "true"
    except subprocess.TimeoutExpired:
        return False


def focus_accessibility_element(identifier: str, *, timeout: float = 5.0) -> bool:
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
        return apple_script(source, check=False, timeout=int(timeout)).lower() == "true"
    except subprocess.TimeoutExpired:
        return False


def accessibility_identifier_exists(identifier: str, *, timeout: float = 2.0) -> bool:
    source = f"""
on hasElement(targetIdentifier)
  tell application "System Events"
    tell process "Vocello"
      if not (exists window 1) then return false
      repeat with itemRef in entire contents of window 1
        try
          if ((value of attribute "AXIdentifier" of itemRef) as text) is targetIdentifier then return true
        end try
      end repeat
    end tell
  end tell
  return false
end hasElement
return hasElement({apple_string(identifier)})
"""
    try:
        return apple_script(source, check=False, timeout=int(timeout)).lower() == "true"
    except subprocess.TimeoutExpired:
        return False


def accessibility_text_exists(text: str, *, timeout: float = 2.0) -> bool:
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
        return apple_script(source, check=False, timeout=int(timeout)).lower() == "true"
    except subprocess.TimeoutExpired:
        return False


def replace_text(text: str) -> None:
    subprocess.run(["pbcopy"], input=text, text=True, check=True)
    source = """
tell application "System Events"
  tell process "Vocello"
    set frontmost to true
    keystroke "a" using command down
    key code 51
    keystroke "v" using command down
  end tell
end tell
"""
    apple_script(source, timeout=5)


def capture_screenshot(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    run(["screencapture", "-x", str(path)], check=False)


def output_dir_for_mode(mode: str) -> Path:
    return APP_SUPPORT / "outputs" / MODE_OUTPUT_SUBFOLDERS[mode]


def collect_outputs(mode: str) -> set[Path]:
    directory = output_dir_for_mode(mode)
    if not directory.exists():
        return set()
    return {path for path in directory.rglob("*.wav") if path.is_file()}


def collect_manifests(mode: str) -> set[Path]:
    directory = output_dir_for_mode(mode)
    if not directory.exists():
        return set()
    return {path for path in directory.rglob("long_form_manifest.json") if path.is_file()}


def collect_traces(trace_dir: Path) -> set[Path]:
    if not trace_dir.exists():
        return set()
    return {
        *trace_dir.glob("*_ui_trace_*.json"),
        *trace_dir.glob("custom_voice_ui_trace_*.json"),
    }


def newest(paths: Iterable[Path]) -> Path | None:
    items = list(paths)
    if not items:
        return None
    return max(items, key=lambda path: path.stat().st_mtime)


def wait_for_identifier(identifier: str, timeout: float = 10.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if accessibility_identifier_exists(identifier, timeout=2):
            return True
        time.sleep(0.25)
    return False


def wait_for_mode_active(mode: str, timeout: float = 15.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if accessibility_identifier_exists(MODE_SCREEN_IDENTIFIERS[mode], timeout=1):
            return True
        if accessibility_text_exists(MODE_TITLE_TEXT[mode], timeout=1):
            return True
        time.sleep(0.25)
    return False


def wait_for_ready(mode: str, timeout: float = 60.0) -> tuple[bool, int | None]:
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        if accessibility_text_exists("Ready to generate", timeout=2):
            return True, int((time.monotonic() - start) * 1_000)
        time.sleep(0.5)
    return False, None


def wait_for_generating_live_preview(timeout: float = 3.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if accessibility_text_exists("Generating live preview", timeout=2):
            return True
        time.sleep(0.15)
    return False


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
    timeout: float = 4.0,
) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if wait_for_generating_live_preview(timeout=0.25):
            return True
        trace = newest(collect_traces(trace_dir) - before_traces)
        if trace_reports_generation_started(trace):
            return True
        time.sleep(0.1)
    return False


def click_generate_button(cliclick: str | None, *, before_traces: set[Path], trace_dir: Path) -> None:
    apple_script(
        'tell application "System Events" to tell process "Vocello" to keystroke return using command down',
        check=False,
        timeout=2,
    )
    if wait_for_generation_started(before_traces, trace_dir):
        return

    if click_accessibility_element("textInput_generateButton", timeout=3):
        if wait_for_generation_started(before_traces, trace_dir):
            return

    if cliclick is None:
        raise AutomationInputError(
            "Generate could not be activated through keyboard or AX, and cliclick fallback is unavailable."
        )
    x, y, width, height = window_bounds()
    generate_x = x + max(600, min(width - 260, 650))
    generate_y = y + max(760, min(height - 150, height - 175))
    run([cliclick, f"c:{generate_x},{generate_y}"], check=True)
    _ = wait_for_generation_started(before_traces, trace_dir, timeout=5.0)


def select_mode(mode: str, *, monitor: ResponsivenessMonitor, cliclick: str | None = None) -> None:
    monitor.set_label(f"{mode}:select")
    if wait_for_mode_active(mode, timeout=1):
        return
    if mode == "CustomVoice":
        # Fresh launches default to Custom Voice. Some SwiftUI text/marker
        # elements are not exposed through AppleScript's entire-contents tree,
        # so trust the launch default and let the editor focus step verify it.
        return
    identifier = f"sidebar_{MODE_IDS[mode]}"
    clicked = click_accessibility_element(identifier, timeout=5)
    if not clicked:
        if cliclick is None:
            raise AutomationInputError(
                f"Could not select {mode} through AX, and cliclick fallback is unavailable."
            )
        x, y, _width, _height = window_bounds()
        run(
            [
                cliclick,
                f"c:{x + 185},{y + MODE_SIDEBAR_FALLBACK_OFFSETS[mode]}",
            ],
            check=True,
        )
    time.sleep(1.0)
    _ = wait_for_mode_active(mode, timeout=3)


def verify_script_character_count(expected: int, *, timeout: float = 3.0) -> bool:
    labels = [f"{expected} characters", f"{expected} character"]
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(accessibility_text_exists(label, timeout=1) for label in labels):
            return True
        time.sleep(0.2)
    return False


def paste_main_script(text: str, *, cliclick: str | None = None) -> None:
    _ = focus_accessibility_element("textInput_textEditor", timeout=3)
    if cliclick is not None:
        x, y, width, height = window_bounds()
        run(
            [
                cliclick,
                f"c:{x + max(620, int(width * 0.42))},{y + max(760, int(height * 0.57))}",
            ],
            check=True,
        )
    time.sleep(0.2)
    replace_text(text)
    time.sleep(0.25)
    if verify_script_character_count(len(text)):
        return

    _ = focus_accessibility_element("textInput_textEditor", timeout=3)
    replace_text(text)
    time.sleep(0.4)
    if not verify_script_character_count(len(text)):
        raise AutomationInputError(
            f"Script input did not visibly update to {len(text)} characters after retry."
        )


def paste_voice_design_brief() -> None:
    if not focus_accessibility_element("voiceDesign_voiceDescriptionField", timeout=5):
        raise RuntimeError("Could not focus Voice Design brief field.")
    replace_text("A warm, clean studio voice with relaxed pacing and crisp articulation.")


def paste_clone_transcript(transcript: str) -> None:
    if not focus_accessibility_element("voiceCloning_transcriptInput", timeout=5):
        if not focus_accessibility_element("voiceCloning_transcriptField", timeout=5):
            raise RuntimeError("Could not focus Voice Cloning transcript field.")
    replace_text(transcript)


def import_clone_reference(reference: Path) -> None:
    if accessibility_identifier_exists("voiceCloning_activeReference", timeout=1):
        return
    if not click_accessibility_element("voiceCloning_importButton", timeout=8):
        raise RuntimeError("Could not click Voice Cloning import button.")
    time.sleep(0.7)
    subprocess.run(["pbcopy"], input=str(reference), text=True, check=True)
    source = """
tell application "System Events"
  keystroke "g" using {command down, shift down}
  delay 0.3
  keystroke "v" using command down
  delay 0.2
  key code 36
  delay 0.6
  key code 36
end tell
"""
    apple_script(source, check=False, timeout=10)
    if not wait_for_identifier("voiceCloning_activeReference", timeout=20):
        raise RuntimeError("Clone reference did not appear after import.")


def setup_mode_requirements(mode: str, clone_reference: Path | None, clone_transcript: str | None) -> None:
    if mode == "VoiceDesign":
        paste_voice_design_brief()
    elif mode == "Clones":
        if clone_reference is None:
            raise RuntimeError("--clone-reference is required for Clones.")
        import_clone_reference(clone_reference)
        paste_clone_transcript(clone_transcript or "")


def wait_for_output(
    mode: str,
    before_outputs: set[Path],
    *,
    start: float,
    timeout: float,
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
        candidates = collect_outputs(mode) - before_outputs
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


def wait_for_trace(before_traces: set[Path], trace_dir: Path, *, mode: str, timeout: float = 15.0) -> Path | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        candidates = collect_traces(trace_dir) - before_traces
        for trace in sorted(candidates, key=lambda path: path.stat().st_mtime, reverse=True):
            try:
                payload = json.loads(trace.read_text())
            except Exception:
                continue
            if payload.get("mode") == mode:
                return trace
        time.sleep(0.25)
    return None


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
    heartbeat = trace.get("main_thread_heartbeat_summary", {})
    return {
        "trace_first_live_chunk_ms": event_times.get("first_live_chunk_event"),
        "trace_generation_finished_ms": event_times.get("generation_finished"),
        "trace_final_file_ready_ms": event_times.get("final_file_ready"),
        "runtime_generation_ms": runtime_timings.get("generation"),
        "stream_chunk_count": runtime_timings.get("stream_chunk_count"),
        "streaming_interval_ms": runtime_timings.get("streaming_interval_ms"),
        "main_thread_p95_ms": heartbeat.get("p95_ms"),
        "main_thread_max_ms": heartbeat.get("max_ms"),
    }


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


def run_audio_qc(path: Path, output_dir: Path, label: str) -> tuple[bool, int, Path, Path]:
    safe_label = label.replace("/", "-").replace(" ", "-")
    json_out = output_dir / f"{safe_label}-audio-qc.json"
    report_out = output_dir / f"{safe_label}-audio-qc.md"
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
        timeout=120,
    )
    if completed.stdout:
        (output_dir / f"{safe_label}-audio-qc.log").write_text(completed.stdout)
    return completed.returncode == 0, completed.returncode, json_out, report_out


def run_direct_generation(
    *,
    mode: str,
    case_name: str,
    phase: str,
    run_index: int,
    text: str,
    output_dir: Path,
    trace_dir: Path,
    cliclick: str | None,
    monitor: ResponsivenessMonitor,
    clone_reference: Path | None,
    clone_transcript: str | None,
    timeout: float,
) -> DirectRunResult:
    label = f"{mode}:{case_name}:{phase}:{run_index}"
    monitor.set_label(f"{label}:setup")
    select_mode(mode, monitor=monitor, cliclick=cliclick)
    setup_mode_requirements(mode, clone_reference, clone_transcript)
    try:
        paste_main_script(text, cliclick=cliclick)
    except AutomationInputError as error:
        screenshot_path = output_dir / "screenshots" / f"{label}-automation-input-failed.png"
        capture_screenshot(screenshot_path)
        response = monitor.summary(f"{label}:")
        return DirectRunResult(
            kind="direct",
            mode=mode,
            case_name=case_name,
            phase=phase,
            run_index=run_index,
            text_character_count=len(text),
            text_word_count=word_count(text),
            ready_observed=False,
            ready_wait_ms=None,
            generate_pressed_at_unix_ms=None,
            first_file_ms=None,
            first_non_header_bytes_ms=None,
            final_size_first_observed_ms=None,
            stable_final_ms=None,
            trace_first_live_chunk_ms=None,
            trace_generation_finished_ms=None,
            runtime_generation_ms=None,
            stream_chunk_count=None,
            streaming_interval_ms=None,
            output_path=None,
            output_size_bytes=None,
            duration_seconds=None,
            real_time_factor=None,
            qc_passed=False,
            qc_exit_code=None,
            qc_json=None,
            qc_report=None,
            trace_json=None,
            screenshot=str(screenshot_path) if screenshot_path.exists() else None,
            responsiveness_passed=response["passed"],
            responsiveness_p95_ax_latency_ms=response["p95_ax_latency_ms"],
            responsiveness_max_ax_latency_ms=response["max_ax_latency_ms"],
            app_rss_peak_mb=response["app_rss_peak_mb"],
            helper_rss_peak_mb=response["helper_rss_peak_mb"],
            swap_delta_mb=response["swap_delta_mb"],
            error=f"automation_input_failed: {error}",
        )

    monitor.set_label(f"{label}:ready")
    ready_observed, ready_wait_ms = wait_for_ready(mode, timeout=90)
    before_outputs = collect_outputs(mode)
    before_traces = collect_traces(trace_dir)
    time.sleep(0.2)

    monitor.set_label(f"{label}:generation")
    start = time.monotonic()
    generate_pressed_at_unix_ms = now_ms()
    capture_screenshot(output_dir / "screenshots" / f"{label}-pre-generate.png")
    click_generate_button(cliclick, before_traces=before_traces, trace_dir=trace_dir)
    output_path, timings = wait_for_output(mode, before_outputs, start=start, timeout=timeout)

    screenshot_path = output_dir / "screenshots" / f"{label}-completion.png"
    capture_screenshot(screenshot_path)
    trace_path = wait_for_trace(before_traces, trace_dir, mode=mode)
    trace_metrics = summarize_trace(str(trace_path) if trace_path else None)
    response = monitor.summary(f"{label}:")

    qc_passed = False
    qc_exit_code: int | None = None
    qc_json: Path | None = None
    qc_report: Path | None = None
    duration_seconds: float | None = None
    size_bytes: int | None = None
    error: str | None = None
    real_time_factor: float | None = None

    if output_path is None:
        error = f"No {mode} WAV appeared before timeout."
    else:
        size_bytes = output_path.stat().st_size
        duration_seconds = afinfo_duration(output_path)
        qc_passed, qc_exit_code, qc_json, qc_report = run_audio_qc(output_path, output_dir, label)
        if duration_seconds and trace_metrics.get("runtime_generation_ms"):
            real_time_factor = (trace_metrics["runtime_generation_ms"] / 1000.0) / duration_seconds

    return DirectRunResult(
        kind="direct",
        mode=mode,
        case_name=case_name,
        phase=phase,
        run_index=run_index,
        text_character_count=len(text),
        text_word_count=word_count(text),
        ready_observed=ready_observed,
        ready_wait_ms=ready_wait_ms,
        generate_pressed_at_unix_ms=generate_pressed_at_unix_ms,
        first_file_ms=timings["first_file_ms"],
        first_non_header_bytes_ms=timings["first_non_header_bytes_ms"],
        final_size_first_observed_ms=timings["final_size_first_observed_ms"],
        stable_final_ms=timings["stable_final_ms"],
        trace_first_live_chunk_ms=trace_metrics.get("trace_first_live_chunk_ms"),
        trace_generation_finished_ms=trace_metrics.get("trace_generation_finished_ms"),
        runtime_generation_ms=trace_metrics.get("runtime_generation_ms"),
        stream_chunk_count=trace_metrics.get("stream_chunk_count"),
        streaming_interval_ms=trace_metrics.get("streaming_interval_ms"),
        output_path=str(output_path) if output_path else None,
        output_size_bytes=size_bytes,
        duration_seconds=duration_seconds,
        real_time_factor=real_time_factor,
        qc_passed=qc_passed,
        qc_exit_code=qc_exit_code,
        qc_json=str(qc_json) if qc_json else None,
        qc_report=str(qc_report) if qc_report else None,
        trace_json=str(trace_path) if trace_path else None,
        screenshot=str(screenshot_path) if screenshot_path.exists() else None,
        responsiveness_passed=response["passed"],
        responsiveness_p95_ax_latency_ms=response["p95_ax_latency_ms"],
        responsiveness_max_ax_latency_ms=response["max_ax_latency_ms"],
        app_rss_peak_mb=response["app_rss_peak_mb"],
        helper_rss_peak_mb=response["helper_rss_peak_mb"],
        swap_delta_mb=response["swap_delta_mb"],
        error=error,
    )


def run_direct_stress_route(
    *,
    mode: str,
    case_name: str,
    text: str,
    output_dir: Path,
    trace_dir: Path,
    cliclick: str | None,
    monitor: ResponsivenessMonitor,
    clone_reference: Path | None,
    clone_transcript: str | None,
) -> RoutingRunResult:
    del trace_dir
    label = f"{mode}:{case_name}:route"
    monitor.set_label(f"{label}:setup")
    select_mode(mode, monitor=monitor, cliclick=cliclick)
    setup_mode_requirements(mode, clone_reference, clone_transcript)
    paste_main_script(text, cliclick=cliclick)
    before_outputs = collect_outputs(mode)
    start = time.monotonic()
    monitor.set_label(f"{label}:click")
    click_accessibility_element("textInput_generateButton", timeout=5)
    routed = wait_for_identifier("batch_textEditor", timeout=10)
    route_latency_ms = int((time.monotonic() - start) * 1_000) if routed else None
    new_outputs = collect_outputs(mode) - before_outputs
    if routed:
        click_accessibility_element("batch_cancelButton", timeout=3)
    screenshot_path = output_dir / "screenshots" / f"{label}-route.png"
    capture_screenshot(screenshot_path)
    response = monitor.summary(f"{label}:")
    error = None
    if not routed:
        error = "Oversized direct Generate did not route to the Batch sheet."
    elif new_outputs:
        error = "Oversized direct Generate produced output instead of routing only."
    return RoutingRunResult(
        kind="route",
        mode=mode,
        case_name=case_name,
        text_character_count=len(text),
        text_word_count=word_count(text),
        routed_to_batch=routed and not new_outputs,
        route_latency_ms=route_latency_ms,
        screenshot=str(screenshot_path) if screenshot_path.exists() else None,
        responsiveness_passed=response["passed"],
        error=error,
    )


def run_batch_generation(
    *,
    mode: str,
    case_name: str,
    text: str,
    output_dir: Path,
    trace_dir: Path,
    cliclick: str | None,
    monitor: ResponsivenessMonitor,
    clone_reference: Path | None,
    clone_transcript: str | None,
    timeout: float,
) -> BatchRunResult:
    del trace_dir
    label = f"{mode}:{case_name}:batch"
    monitor.set_label(f"{label}:setup")
    select_mode(mode, monitor=monitor, cliclick=cliclick)
    setup_mode_requirements(mode, clone_reference, clone_transcript)
    paste_main_script(text, cliclick=cliclick)
    before_outputs = collect_outputs(mode)
    before_manifests = collect_manifests(mode)

    monitor.set_label(f"{label}:route")
    if not click_accessibility_element("textInput_generateButton", timeout=5):
        raise RuntimeError("Could not click Generate to route long-form batch.")
    if not wait_for_identifier("batch_textEditor", timeout=12):
        raise RuntimeError("Long-form Batch sheet did not appear.")

    monitor.set_label(f"{label}:generation")
    start = time.monotonic()
    if not click_accessibility_element("batch_generateAllButton", timeout=5):
        apple_script('tell application "System Events" to keystroke return', check=False, timeout=2)
    completed = wait_for_batch_completion(timeout=timeout)
    batch_wall_ms = int((time.monotonic() - start) * 1_000)
    screenshot_path = output_dir / "screenshots" / f"{label}-completion.png"
    capture_screenshot(screenshot_path)

    outputs = sorted(collect_outputs(mode) - before_outputs, key=lambda path: path.stat().st_mtime)
    manifests = collect_manifests(mode) - before_manifests
    manifest = newest(manifests)
    qc_reports: list[str] = []
    failed_outputs = 0
    for index, output_path in enumerate(outputs, start=1):
        passed, _code, json_out, report_out = run_audio_qc(
            output_path,
            output_dir,
            f"{label}-segment-{index}",
        )
        qc_reports.extend([str(json_out), str(report_out)])
        if not passed:
            failed_outputs += 1

    response = monitor.summary(f"{label}:")
    error = None
    if not completed:
        error = "Batch sheet did not report completion before timeout."
    elif failed_outputs:
        error = f"{failed_outputs} generated batch segment(s) failed audio QC."

    return BatchRunResult(
        kind="batch",
        mode=mode,
        case_name=case_name,
        text_character_count=len(text),
        text_word_count=word_count(text),
        segment_count=segment_count_for_text(text),
        batch_wall_ms=batch_wall_ms if completed else None,
        generated_outputs=len(outputs),
        failed_outputs=failed_outputs,
        qc_passed=bool(outputs) and failed_outputs == 0 and completed,
        manifest_path=str(manifest) if manifest else None,
        output_paths=[str(path) for path in outputs],
        qc_reports=qc_reports,
        screenshot=str(screenshot_path) if screenshot_path.exists() else None,
        responsiveness_passed=response["passed"],
        responsiveness_p95_ax_latency_ms=response["p95_ax_latency_ms"],
        app_rss_peak_mb=response["app_rss_peak_mb"],
        helper_rss_peak_mb=response["helper_rss_peak_mb"],
        swap_delta_mb=response["swap_delta_mb"],
        error=error,
    )


def wait_for_batch_completion(timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if accessibility_text_exists("Batch Complete", timeout=2) or accessibility_text_exists("Batch Stopped", timeout=2):
            return True
        time.sleep(1.0)
    return False


def segment_count_for_text(text: str) -> int:
    lines = long_form_segments(text, max_characters=LONG_FORM_MAX_CHARACTERS)
    return len(lines)


def long_form_segments(text: str, *, max_characters: int) -> list[str]:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    paragraphs = [
        collapse_whitespace(part.replace("\n", " "))
        for part in normalized.split("\n\n")
    ]
    segments: list[str] = []
    for paragraph in paragraphs:
        if not paragraph:
            continue
        segments.extend(split_paragraph(paragraph, max_characters=max_characters))
    return segments


def split_paragraph(paragraph: str, *, max_characters: int) -> list[str]:
    if len(paragraph) <= max_characters:
        return [paragraph]
    sentences = split_sentences(paragraph)
    segments: list[str] = []
    current = ""
    for sentence in sentences:
        if len(sentence) > max_characters:
            if current.strip():
                segments.append(current.strip())
            current = ""
            segments.extend(split_words(sentence, max_characters=max_characters))
            continue
        candidate = sentence if not current else f"{current} {sentence}"
        if len(candidate) <= max_characters:
            current = candidate
        else:
            if current.strip():
                segments.append(current.strip())
            current = sentence
    if current.strip():
        segments.append(current.strip())
    return segments


def split_sentences(text: str) -> list[str]:
    sentences: list[str] = []
    current: list[str] = []
    for character in text:
        current.append(character)
        if character in ".!?":
            sentence = collapse_whitespace("".join(current))
            if sentence:
                sentences.append(sentence)
            current = []
    trailing = collapse_whitespace("".join(current))
    if trailing:
        sentences.append(trailing)
    return sentences


def split_words(text: str, *, max_characters: int) -> list[str]:
    words = text.split()
    segments: list[str] = []
    current = ""
    for word in words:
        if len(word) > max_characters:
            if current:
                segments.append(current)
                current = ""
            segments.append(word)
            continue
        candidate = word if not current else f"{current} {word}"
        if len(candidate) <= max_characters:
            current = candidate
        else:
            if current:
                segments.append(current)
            current = word
    if current:
        segments.append(current)
    return segments


def collapse_whitespace(text: str) -> str:
    return " ".join(text.split()).strip()


def make_text(length: int, *, mode: str, case_name: str) -> str:
    seed = (
        f"{mode} {case_name} benchmark. The app should remain responsive while the "
        "engine creates a clean spoken clip with steady pacing, no playback glitches, "
        "and a complete saved result. "
    )
    parts: list[str] = []
    while len("".join(parts)) < length:
        parts.append(seed)
    text = "".join(parts)[:length]
    if len(text) < length:
        text = text.ljust(length, ".")
    return text


def launch_app(output_dir: Path, trace_dir: Path) -> None:
    build_log = output_dir / "build_and_run.log"
    run(["launchctl", "setenv", "QWENVOICE_UI_PERF_AUDIT", "1"], check=True)
    run(["launchctl", "setenv", "QWENVOICE_UI_PERF_AUDIT_DIR", str(trace_dir)], check=True)
    with build_log.open("a") as log:
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


def cleanup_launch_env() -> None:
    run(["launchctl", "unsetenv", "QWENVOICE_UI_PERF_AUDIT"], check=False)
    run(["launchctl", "unsetenv", "QWENVOICE_UI_PERF_AUDIT_DIR"], check=False)


def terminate_app() -> None:
    run(["osascript", "-e", 'tell application "Vocello" to quit'], check=False)
    time.sleep(1.0)
    run(["pkill", "-x", "Vocello"], check=False)
    run(["pkill", "-x", "QwenVoiceEngineService"], check=False)


def write_timing_csv(output_dir: Path, results: list[BenchmarkResult]) -> None:
    path = output_dir / "timing-runs.csv"
    fieldnames = [
        "kind", "mode", "case_name", "phase", "run_index",
        "text_character_count", "text_word_count", "segment_count",
        "ready_wait_ms", "trace_first_live_chunk_ms", "runtime_generation_ms",
        "stable_final_ms", "batch_wall_ms", "duration_seconds", "real_time_factor",
        "qc_passed", "responsiveness_passed", "responsiveness_p95_ax_latency_ms",
        "app_rss_peak_mb", "helper_rss_peak_mb", "swap_delta_mb", "error",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for result in results:
            data = asdict(result)
            writer.writerow({key: data.get(key) for key in fieldnames})


def write_summary(
    output_dir: Path,
    results: list[BenchmarkResult],
    preflight: dict[str, str],
    postflight: dict[str, str],
    monitor: ResponsivenessMonitor,
    *,
    profile: str,
    driver: str,
    memory_policy: str,
) -> None:
    serializable_results = [asdict(result) for result in results]
    summary = {
        "schema_version": 1,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "profile": profile,
        "driver": driver,
        "memory_policy": memory_policy,
        "ui_interaction_policy": {
            "primary_visual_validation": "manual computer-use procedure",
            "structured_probe": "macOS Accessibility and AppleScript",
            "coordinate_fallback": "cliclick only when AX metadata is unavailable or brittle",
            "screenshots": "screencapture artifacts from the benchmark script",
        },
        "results": serializable_results,
        "responsiveness": monitor.summary(),
        "preflight": preflight,
        "postflight": postflight,
    }
    summary["overall_pass"] = all(result_passed(result) for result in results) and bool(results)
    (output_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
    write_timing_csv(output_dir, results)

    lines = [
        "# UI-Only Exhaustive Generation Benchmark",
        "",
        f"Created: `{summary['created_at']}`",
        f"Profile: `{profile}`",
        f"Driver: `{driver}`",
        f"Memory policy: `{memory_policy}`",
        "",
        "The manual computer-use procedure is the preferred visual validation posture. "
        "The benchmark script records deterministic AX/AppleScript probes, traces, screenshots, "
        "process state, responsiveness samples, and audio-QC artifacts; `cliclick` remains a last-resort coordinate fallback.",
        "",
        "## Responsiveness",
        "",
        "| Samples | Pass | p95 AX latency | Max AX latency | App RSS peak | Helper RSS peak | Swap delta |",
        "| ---: | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    resp = summary["responsiveness"]
    lines.append(
        f"| {resp['sample_count']} | {str(resp['passed']).lower()} | "
        f"{format_value(resp['p95_ax_latency_ms'])} | {format_value(resp['max_ax_latency_ms'])} | "
        f"{format_value(resp['app_rss_peak_mb'])} | {format_value(resp['helper_rss_peak_mb'])} | "
        f"{format_value(resp['swap_delta_mb'])} |"
    )
    lines.extend(["", "## Direct Generation", ""])
    lines.extend([
        "| Mode | Case | Phase | Run | Chars | Ready wait | First chunk | Runtime gen | Stable final | RTF | QC | UI | Error |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |",
    ])
    for result in results:
        if not isinstance(result, DirectRunResult):
            continue
        lines.append(
            f"| {result.mode} | {result.case_name} | {result.phase} | {result.run_index} | "
            f"{result.text_character_count} | {format_value(result.ready_wait_ms)} | "
            f"{format_value(result.trace_first_live_chunk_ms)} | {format_value(result.runtime_generation_ms)} | "
            f"{format_value(result.stable_final_ms)} | {format_value(result.real_time_factor)} | "
            f"{'pass' if result.qc_passed else 'fail'} | {pass_fail(result.responsiveness_passed)} | {result.error or ''} |"
        )
    lines.extend(["", "## Oversized Routing", ""])
    lines.extend([
        "| Mode | Case | Chars | Routed To Batch | Route latency | UI | Error |",
        "| --- | --- | ---: | --- | ---: | --- | --- |",
    ])
    for result in results:
        if not isinstance(result, RoutingRunResult):
            continue
        lines.append(
            f"| {result.mode} | {result.case_name} | {result.text_character_count} | "
            f"{str(result.routed_to_batch).lower()} | {format_value(result.route_latency_ms)} | "
            f"{pass_fail(result.responsiveness_passed)} | {result.error or ''} |"
        )
    lines.extend(["", "## Long-Form Batch", ""])
    lines.extend([
        "| Mode | Case | Chars | Segments | Wall | Outputs | QC | UI | Manifest | Error |",
        "| --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- |",
    ])
    for result in results:
        if not isinstance(result, BatchRunResult):
            continue
        manifest_name = Path(result.manifest_path).name if result.manifest_path else ""
        lines.append(
            f"| {result.mode} | {result.case_name} | {result.text_character_count} | "
            f"{result.segment_count} | {format_value(result.batch_wall_ms)} | {result.generated_outputs} | "
            f"{'pass' if result.qc_passed else 'fail'} | {pass_fail(result.responsiveness_passed)} | "
            f"{manifest_name} | {result.error or ''} |"
        )
    lines.extend(
        [
            "",
            "## Process Evidence",
            "",
            "### Before",
            "```text",
            preflight.get("processes", "").strip(),
            preflight.get("swap", "").strip(),
            "```",
            "",
            "### After",
            "```text",
            postflight.get("processes", "").strip(),
            postflight.get("swap", "").strip(),
            "```",
        ]
    )
    (output_dir / "summary.md").write_text("\n".join(lines) + "\n")


def format_value(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def pass_fail(value: bool | None) -> str:
    if value is None:
        return "n/a"
    return "pass" if value else "fail"


def result_passed(result: BenchmarkResult) -> bool:
    if isinstance(result, DirectRunResult):
        return result.error is None and result.qc_passed and result.responsiveness_passed is not False
    if isinstance(result, RoutingRunResult):
        return result.error is None and result.routed_to_batch and result.responsiveness_passed is not False
    if isinstance(result, BatchRunResult):
        return result.error is None and result.qc_passed and result.responsiveness_passed is not False
    return False


def parse_modes(raw: str) -> list[str]:
    modes: list[str] = []
    for part in raw.split(","):
        value = part.strip()
        if value not in MODE_IDS:
            raise argparse.ArgumentTypeError(f"Unsupported mode {value!r}. Expected one of: {', '.join(MODE_IDS)}")
        modes.append(value)
    return modes


def normalize_driver(raw: str) -> str:
    return raw


def run_self_test(output_dir: Path) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    short = make_text(80, mode="CustomVoice", case_name="short")
    medium = make_text(450, mode="VoiceDesign", case_name="medium")
    max_direct = make_text(900, mode="Clones", case_name="max-direct")
    stress = make_text(901, mode="CustomVoice", case_name="direct-stress")
    long = make_text(2700, mode="VoiceDesign", case_name="long-form")
    assertions = [
        len(short) == 80,
        len(medium) == 450,
        len(max_direct) == 900,
        len(stress) == 901,
        segment_count_for_text(long) >= 3,
        parse_modes("CustomVoice,VoiceDesign,Clones") == ["CustomVoice", "VoiceDesign", "Clones"],
        percentile([10, 20, 30, 40], 95) == 40,
        workload_plan("smoke")[0] == ("direct", "short", "cold", 1, 80),
        any(item[1] == "direct-stress-901" for item in workload_plan("balanced")),
        any(item[0] == "batch" and item[1] == "long-form-9000" for item in workload_plan("exhaustive")),
        normalize_driver("computer-use-first") == "computer-use-first",
        normalize_driver("ax-fallback") == "ax-fallback",
        normalize_driver(DEFAULT_UI_DRIVER) == DEFAULT_UI_DRIVER,
    ]
    payload = {
        "passed": all(assertions),
        "text_lengths": {
            "short": len(short),
            "medium": len(medium),
            "max_direct": len(max_direct),
            "stress": len(stress),
            "long_segments": segment_count_for_text(long),
        },
    }
    (output_dir / "self-test.json").write_text(json.dumps(payload, indent=2, sort_keys=True))
    print(f"Wrote UI benchmark self-test to {output_dir}")
    return 0 if all(assertions) else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--profile",
        choices=["smoke", "balanced", "bounded-exhaustive", "exhaustive", "stress"],
        default="bounded-exhaustive",
    )
    parser.add_argument("--modes", type=parse_modes, default=parse_modes("CustomVoice,VoiceDesign,Clones"))
    parser.add_argument("--clone-reference", type=Path)
    parser.add_argument("--clone-transcript")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/audio-qc/ui-generation-benchmark")
    parser.add_argument(
        "--driver",
        choices=["computer-use-first", "ax-fallback"],
        default=DEFAULT_UI_DRIVER,
        help=(
            "UI benchmark driver. computer-use-first keeps the manual computer-use procedure as "
            "the preferred visual validation posture; ax-fallback relies on Accessibility/System "
            "Events, AppleScript, screencapture, and optional cliclick fallback."
        ),
    )
    parser.add_argument(
        "--memory-policy",
        choices=["normal", "stress"],
        default="normal",
        help="Benchmark memory posture. stress tolerates higher swap but still stops on responsiveness failures.",
    )
    parser.add_argument("--ready-timeout", type=float, default=90.0)
    parser.add_argument("--direct-timeout", type=float, default=240.0)
    parser.add_argument("--batch-timeout", type=float, default=2_400.0)
    parser.add_argument("--keep-app-running", action="store_true")
    parser.add_argument("--self-test", action="store_true", help="Run deterministic parser/text/responsiveness math checks only.")
    args = parser.parse_args()
    args.driver = normalize_driver(args.driver)
    return args


WorkloadSpec = tuple[str, str, str, int, int]


def workload_plan(profile: str) -> list[WorkloadSpec]:
    if profile == "smoke":
        return [
            ("direct", "short", "cold", 1, 80),
        ]
    if profile == "balanced":
        return [
            ("direct", "short", "cold", 1, 80),
            ("direct", "short", "warm", 1, 80),
            ("direct", "medium", "warm", 1, 450),
            ("direct", "max-direct", "warm", 1, 900),
            ("route", "direct-stress-901", "route", 1, 901),
            ("batch", "long-form-2700", "batch", 1, 2700),
        ]
    return [
        ("direct", "short", "cold", 1, 80),
        *[("direct", "short", "warm", index, 80) for index in range(1, 4)],
        *[("direct", "medium", "warm", index, 450) for index in range(1, 4)],
        ("direct", "max-direct", "warm", 1, 900),
        ("route", "direct-stress-901", "route", 1, 901),
        ("route", "direct-stress-2700", "route", 1, 2700),
        ("batch", "long-form-2700", "batch", 1, 2700),
        ("batch", "long-form-9000", "batch", 1, 9000),
    ]


def main() -> int:
    args = parse_args()
    base_output_dir = args.output_dir if args.output_dir.is_absolute() else ROOT / args.output_dir
    if args.self_test:
        return run_self_test(base_output_dir / "self-test")

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_dir = base_output_dir / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)
    trace_dir = output_dir / "traces"
    trace_dir.mkdir(parents=True, exist_ok=True)

    cliclick = shutil.which("cliclick")
    if cliclick is None:
        print(
            "warning: cliclick is unavailable; UI benchmark will use keyboard and AX only. "
            "Coordinate fallback will be disabled.",
            file=sys.stderr,
        )

    clone_transcript = args.clone_transcript
    if "Clones" in args.modes:
        if args.clone_reference is None:
            print("error: --clone-reference is required when Clones is included.", file=sys.stderr)
            return 2
        if clone_transcript is None:
            sibling = args.clone_reference.with_suffix(".txt")
            clone_transcript = sibling.read_text().strip() if sibling.exists() else ""

    preflight = {
        "processes": process_snapshot(),
        "swap": swap_snapshot(),
        "memory_pressure": memory_pressure_snapshot(),
    }
    (output_dir / "preflight-processes.txt").write_text(preflight["processes"])
    (output_dir / "preflight-memory.txt").write_text(preflight["swap"] + "\n" + preflight["memory_pressure"])

    monitor = ResponsivenessMonitor(output_dir)
    results: list[BenchmarkResult] = []
    exit_code = 0
    monitor.start()
    try:
        for mode in args.modes:
            monitor.set_label(f"{mode}:launch")
            launch_app(output_dir, trace_dir)
            capture_screenshot(output_dir / "screenshots" / f"{mode}-launch.png")

            for kind, case_name, phase, run_index, character_count in workload_plan(args.profile):
                text = make_text(character_count, mode=mode, case_name=case_name)
                if kind == "direct":
                    result = run_direct_generation(
                        mode=mode,
                        case_name=case_name,
                        phase=phase,
                        run_index=run_index,
                        text=text,
                        output_dir=output_dir,
                        trace_dir=trace_dir,
                        cliclick=cliclick,
                        monitor=monitor,
                        clone_reference=args.clone_reference,
                        clone_transcript=clone_transcript,
                        timeout=args.direct_timeout,
                    )
                    results.append(result)
                    if result.error or not result.qc_passed or not result.responsiveness_passed:
                        exit_code = 1
                elif kind == "route":
                    result = run_direct_stress_route(
                        mode=mode,
                        case_name=case_name,
                        text=text,
                        output_dir=output_dir,
                        trace_dir=trace_dir,
                        cliclick=cliclick,
                        monitor=monitor,
                        clone_reference=args.clone_reference,
                        clone_transcript=clone_transcript,
                    )
                    results.append(result)
                    if result.error or not result.routed_to_batch or not result.responsiveness_passed:
                        exit_code = 1
                elif kind == "batch":
                    result = run_batch_generation(
                        mode=mode,
                        case_name=case_name,
                        text=text,
                        output_dir=output_dir,
                        trace_dir=trace_dir,
                        cliclick=cliclick,
                        monitor=monitor,
                        clone_reference=args.clone_reference,
                        clone_transcript=clone_transcript,
                        timeout=args.batch_timeout,
                    )
                    results.append(result)
                    if result.error or not result.qc_passed or not result.responsiveness_passed:
                        exit_code = 1
                time.sleep(1.0)

            terminate_app()
            time.sleep(2.0)
    except Exception as error:
        exit_code = 1
        (output_dir / "fatal-error.txt").write_text(f"{type(error).__name__}: {error}\n")
        print(f"fatal: {error}", file=sys.stderr)
    finally:
        postflight = {
            "processes": running_vocello_processes(),
            "swap": swap_snapshot(),
            "memory_pressure": memory_pressure_snapshot(),
        }
        monitor.stop()
        monitor.write_csv()
        write_summary(
            output_dir,
            results,
            preflight,
            postflight,
            monitor,
            profile=args.profile,
            driver=args.driver,
            memory_policy=args.memory_policy,
        )
        if not args.keep_app_running:
            terminate_app()
        cleanup_launch_env()

    print(f"Wrote UI-only generation benchmark to {output_dir}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
