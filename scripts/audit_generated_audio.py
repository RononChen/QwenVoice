#!/usr/bin/env python3
"""Audit generated QwenVoice/Vocello audio artifacts.

This is a local-only quality-control helper. It never launches the app and
never triggers model generation; it analyzes existing WAV files or retained
streaming chunk sessions.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import wave
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np  # type: ignore[import-unresolved]

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from harness_lib.audio_analysis import (  # noqa: E402
    load_chunk_directory,
    run_all_analyses,
    run_final_file_analyses,
)
from harness_lib.paths import APP_SUPPORT_DIR, BUILD_ROOT, ensure_directory  # noqa: E402

MODE_OUTPUT_FOLDERS = {
    "CustomVoice": "CustomVoice",
    "VoiceDesign": "VoiceDesign",
    "Clones": "Clones",
}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analyze generated QwenVoice/Vocello WAV files for objective audio glitches.",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", help="Path to a final generated WAV file.")
    source.add_argument(
        "--latest",
        choices=sorted(MODE_OUTPUT_FOLDERS.keys()),
        help="Analyze the newest WAV under the mode's app-support output folder.",
    )
    source.add_argument(
        "--session-dir",
        help="Analyze a retained live-preview session directory with chunk_*.wav and optional final.wav.",
    )
    source.add_argument(
        "--self-test",
        action="store_true",
        help="Run synthetic fixture checks for the audio analyzer itself.",
    )
    parser.add_argument("--json-out", help="Write a JSON report to this path.")
    parser.add_argument("--report-out", help="Write a Markdown report to this path.")

    args = parser.parse_args()
    try:
        if args.self_test:
            report = run_self_test()
        elif args.file:
            report = analyze_file(Path(args.file))
        elif args.latest:
            report = analyze_latest(args.latest)
        elif args.session_dir:
            report = analyze_session_dir(Path(args.session_dir))
        else:
            parser.error("No analysis source selected")
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
    except NotADirectoryError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)

    write_outputs(report, args.json_out, args.report_out)
    print(render_markdown_report(report))

    if report["overall_pass"]:
        raise SystemExit(0)
    raise SystemExit(1)


def analyze_latest(mode: str) -> dict[str, Any]:
    folder = MODE_OUTPUT_FOLDERS[mode]
    output_dir = APP_SUPPORT_DIR / "outputs" / folder
    if not output_dir.is_dir():
        raise FileNotFoundError(f"No output directory for {mode}: {output_dir}")
    candidates = sorted(
        output_dir.glob("*.wav"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise FileNotFoundError(f"No WAV outputs found for {mode}: {output_dir}")
    return analyze_file(candidates[0], label=f"latest:{mode}", mode=mode)


def analyze_file(path: Path, *, label: str | None = None, mode: str | None = None) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"Audio file not found: {path}")
    if not path.is_file():
        raise FileNotFoundError(f"Audio path is not a file: {path}")

    checks = run_final_file_analyses(path)
    return build_report(
        kind="file",
        label=label or path.name,
        mode=mode,
        source_path=path,
        checks=checks,
    )


def analyze_session_dir(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"Session directory not found: {path}")
    if not path.is_dir():
        raise NotADirectoryError(f"Session path is not a directory: {path}")

    chunks, final_audio, sample_rate = load_chunk_directory(path)
    checks = run_all_analyses(chunks, final_audio, sample_rate)
    final_path = resolve_session_final_file(path)
    if final_path is not None:
        for name, result in run_final_file_analyses(final_path).items():
            checks[f"final_{name}"] = result
    return build_report(
        kind="session",
        label=path.name,
        mode=None,
        source_path=path,
        checks=checks,
    )


def resolve_session_final_file(path: Path) -> Path | None:
    for name in ("final.wav", "test.wav", "output.wav"):
        candidate = path / name
        if candidate.exists():
            return candidate
    return None


def build_report(
    *,
    kind: str,
    label: str,
    mode: str | None,
    source_path: Path,
    checks: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    normalized = {
        name: normalize_check(result)
        for name, result in checks.items()
    }
    failed_required = [
        name for name, result in normalized.items()
        if not result.get("passed", False) and result.get("severity", "error") == "error"
    ]
    warnings = [
        name for name, result in normalized.items()
        if result.get("warning") or (
            not result.get("passed", False)
            and result.get("severity") == "warning"
        )
    ]
    return {
        "tool": "audit_generated_audio",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "kind": kind,
        "label": label,
        "mode": mode,
        "source_path": str(source_path),
        "overall_pass": not failed_required,
        "failed_required_checks": failed_required,
        "warning_checks": warnings,
        "checks": normalized,
    }


def normalize_check(result: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(result)
    normalized.setdefault("severity", "error")
    if "metric" not in normalized:
        metric_keys = [
            key for key in normalized
            if key not in {"passed", "severity", "error", "skip_reason", "warning"}
        ]
        if metric_keys:
            normalized["metric"] = {key: normalized[key] for key in metric_keys[:8]}
    if "threshold" not in normalized:
        normalized["threshold"] = None
    return normalized


def write_outputs(
    report: dict[str, Any],
    json_out: str | None,
    report_out: str | None,
) -> None:
    if json_out:
        path = Path(json_out)
        ensure_directory(path.parent)
        path.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    if report_out:
        path = Path(report_out)
        ensure_directory(path.parent)
        path.write_text(render_markdown_report(report), encoding="utf-8")


def render_markdown_report(report: dict[str, Any]) -> str:
    status = "PASS" if report["overall_pass"] else "FAIL"
    lines = [
        f"# Audio QC Report: {status}",
        "",
        f"- Source: `{report['source_path']}`",
        f"- Kind: `{report['kind']}`",
        f"- Label: `{report['label']}`",
        f"- Created: `{report['created_at']}`",
        "",
    ]
    if report["failed_required_checks"]:
        lines.append("## Failed Required Checks")
        lines.append("")
        for name in report["failed_required_checks"]:
            check = report["checks"][name]
            lines.append(f"- `{name}`: {check.get('error', 'failed')}")
        lines.append("")
    if report["warning_checks"]:
        lines.append("## Warnings")
        lines.append("")
        for name in report["warning_checks"]:
            check = report["checks"][name]
            lines.append(f"- `{name}`: {check.get('warning') or check.get('error') or 'warning'}")
        lines.append("")

    lines.append("## Checks")
    lines.append("")
    lines.append("| Check | Status | Severity | Metric | Threshold |")
    lines.append("| --- | --- | --- | --- | --- |")
    for name, check in report["checks"].items():
        check_status = "PASS" if check.get("passed") else "FAIL"
        metric = _compact_json(check.get("metric"))
        threshold = _compact_json(check.get("threshold"))
        lines.append(
            f"| `{name}` | {check_status} | {check.get('severity', 'error')} | "
            f"`{metric}` | `{threshold}` |"
        )
    lines.append("")
    return "\n".join(lines)


def _compact_json(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value.replace("|", "\\|")
    return json.dumps(value, sort_keys=True, separators=(",", ":")).replace("|", "\\|")


def run_self_test() -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="qwenvoice-audio-qc-") as tmp:
        root = Path(tmp)
        valid = root / "valid.wav"
        header_only = root / "header-only.wav"
        clipped = root / "clipped.wav"
        silence_gap = root / "silence-gap.wav"
        discontinuity = root / "discontinuity.wav"
        mismatch_session = root / "mismatch-session"
        mismatch_session.mkdir()

        sample_rate = 24_000
        t = np.linspace(0, 1.2, int(sample_rate * 1.2), endpoint=False)
        envelope = np.linspace(0.2, 1.0, t.size)
        valid_samples = (0.12 * envelope * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
        write_wav(valid, valid_samples, sample_rate)

        header_only.write_bytes(b"RIFF" + b"\x00" * (4096 - 4))

        clipped_samples = valid_samples.copy()
        clipped_samples[100:110] = 1.0
        write_wav(clipped, clipped_samples, sample_rate)

        gap_samples = np.concatenate([
            valid_samples[:sample_rate // 2],
            np.zeros(int(sample_rate * 0.9), dtype=np.float32),
            valid_samples[:sample_rate // 2],
        ])
        write_wav(silence_gap, gap_samples, sample_rate)

        jump_samples = np.concatenate([
            np.full(sample_rate // 2, -0.35, dtype=np.float32),
            np.full(sample_rate // 2, 0.35, dtype=np.float32),
        ])
        write_wav(discontinuity, jump_samples, sample_rate)

        chunk_a = valid_samples[:sample_rate // 4]
        chunk_b = valid_samples[sample_rate // 4:sample_rate // 2]
        write_wav(mismatch_session / "chunk_000.wav", chunk_a, sample_rate)
        write_wav(mismatch_session / "chunk_001.wav", chunk_b, sample_rate)
        write_wav(mismatch_session / "final.wav", valid_samples[sample_rate // 2:sample_rate], sample_rate)

        valid_report = analyze_file(valid)
        header_report = analyze_file(header_only)
        clipped_report = analyze_file(clipped)
        silence_report = analyze_file(silence_gap)
        discontinuity_report = analyze_file(discontinuity)
        mismatch_report = analyze_session_dir(mismatch_session)

        expectations = {
            "valid_fixture_passes": valid_report["overall_pass"],
            "header_only_fails": not header_report["overall_pass"],
            "clipping_fails": "clipping_detection" in clipped_report["failed_required_checks"],
            "silence_gap_fails": "final_dropouts" in silence_report["failed_required_checks"],
            "discontinuity_fails": (
                "final_abrupt_discontinuities"
                in discontinuity_report["failed_required_checks"]
            ),
            "chunk_final_mismatch_fails": (
                "chunk_sample_fidelity"
                in mismatch_report["failed_required_checks"]
            ),
        }

    checks = {
        name: {
            "passed": bool(passed),
            "severity": "error",
            "metric": bool(passed),
            "threshold": True,
            **({} if passed else {"error": f"Self-test expectation failed: {name}"}),
        }
        for name, passed in expectations.items()
    }
    return build_report(
        kind="self-test",
        label="synthetic-audio-qc-fixtures",
        mode=None,
        source_path=BUILD_ROOT / "audio-qc" / "self-test",
        checks=checks,
    )


def write_wav(path: Path, samples: np.ndarray, sample_rate: int) -> None:
    clipped = np.clip(samples, -1.0, 1.0)
    pcm = (clipped * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm.tobytes())


if __name__ == "__main__":
    main()
