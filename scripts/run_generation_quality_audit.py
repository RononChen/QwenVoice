#!/usr/bin/env python3
"""Run autonomous generated-audio quality review workflows.

This is the orchestration layer above ``audit_generated_audio.py``. It can
analyze existing latest outputs, run the analyzer self-test, or opt into a live
macOS XPC generation pass that creates fresh clips and audits both final WAVs
and retained live-preview chunk sessions.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from harness_lib.contract import load_contract  # noqa: E402
from harness_lib.paths import APP_MODELS_DIR, BUILD_ROOT, PROJECT_DIR, ensure_directory  # noqa: E402
from harness_lib.ui_test_support import resolve_xcodebuild_timeout_seconds  # noqa: E402

MODE_MODEL_IDS = {
    "CustomVoice": "pro_custom",
    "VoiceDesign": "pro_design",
    "Clones": "pro_clone",
}
DEFAULT_MODES = ["CustomVoice", "VoiceDesign"]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run autonomous QwenVoice/Vocello generated-audio quality review.",
    )
    parser.add_argument(
        "--source",
        choices=["self-test", "latest", "live-xpc"],
        default="self-test",
        help="Audit source. live-xpc generates fresh clips through the macOS XPC engine.",
    )
    parser.add_argument(
        "--modes",
        default=",".join(DEFAULT_MODES),
        help="Comma-separated modes: CustomVoice, VoiceDesign, Clones.",
    )
    parser.add_argument(
        "--allow-model-load",
        action="store_true",
        help="Required for --source live-xpc because it may load MLX models.",
    )
    parser.add_argument("--clone-reference", help="Reference WAV/audio path required for Clones live generation.")
    parser.add_argument("--clone-transcript", help="Optional transcript for Clones live generation.")
    parser.add_argument(
        "--models-root",
        default=str(APP_MODELS_DIR),
        help="Installed model root used by --source live-xpc.",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Audit artifact directory. Defaults to build/audio-qc/<timestamp>.",
    )

    args = parser.parse_args()
    output_dir = Path(args.output_dir) if args.output_dir else default_output_dir(args.source)
    ensure_directory(output_dir)

    try:
        modes = parse_modes(args.modes)
        if args.source == "self-test":
            summary = run_self_test(output_dir)
        elif args.source == "latest":
            summary = run_latest_analysis(output_dir, modes)
        else:
            summary = run_live_xpc_analysis(output_dir, modes, args)
    except UsageError as exc:
        summary = build_base_summary(output_dir, args.source, parse_modes_lenient(args.modes))
        summary["overall_pass"] = False
        summary["error"] = str(exc)
        write_summary(output_dir, summary)
        print(render_summary_markdown(summary))
        raise SystemExit(2)

    write_summary(output_dir, summary)
    print(render_summary_markdown(summary))
    raise SystemExit(summary.get("exit_code", 0 if summary["overall_pass"] else 1))


class UsageError(Exception):
    """Invalid invocation or unavailable source artifact."""


def default_output_dir(source: str) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return BUILD_ROOT / "audio-qc" / f"{source}-{stamp}"


def parse_modes(raw_modes: str) -> list[str]:
    modes = [part.strip() for part in raw_modes.split(",") if part.strip()]
    if not modes:
        modes = list(DEFAULT_MODES)
    unsupported = [mode for mode in modes if mode not in MODE_MODEL_IDS]
    if unsupported:
        raise UsageError(f"Unsupported mode(s): {', '.join(unsupported)}")
    deduped: list[str] = []
    for mode in modes:
        if mode not in deduped:
            deduped.append(mode)
    return deduped


def parse_modes_lenient(raw_modes: str) -> list[str]:
    try:
        return parse_modes(raw_modes)
    except UsageError:
        return [part.strip() for part in raw_modes.split(",") if part.strip()]


def run_self_test(output_dir: Path) -> dict[str, Any]:
    summary = build_base_summary(output_dir, "self-test", [])
    report = run_audio_audit(
        output_dir=output_dir,
        name="self-test",
        args=["--self-test"],
    )
    summary["reports"].append(report)
    summary["overall_pass"] = report["exit_code"] == 0
    return summary


def run_latest_analysis(output_dir: Path, modes: list[str]) -> dict[str, Any]:
    summary = build_base_summary(output_dir, "latest", modes)
    for mode in modes:
        report = run_audio_audit(
            output_dir=output_dir,
            name=f"latest-{mode}",
            args=["--latest", mode],
        )
        summary["reports"].append(report)
        if report["exit_code"] == 2:
            summary["error"] = f"Missing latest output for {mode}."
            summary["overall_pass"] = False
            summary["exit_code"] = 2
            return summary
    summary["overall_pass"] = all(report["exit_code"] == 0 for report in summary["reports"])
    return summary


def run_live_xpc_analysis(output_dir: Path, modes: list[str], args: argparse.Namespace) -> dict[str, Any]:
    if not args.allow_model_load:
        raise UsageError("--source live-xpc requires --allow-model-load.")
    if "Clones" in modes and not args.clone_reference:
        raise UsageError("--modes including Clones requires --clone-reference for live-xpc.")
    if args.clone_reference and not Path(args.clone_reference).is_file():
        raise UsageError(f"Clone reference does not exist: {args.clone_reference}")

    models_root = Path(args.models_root).expanduser()
    validate_required_models(modes, models_root)

    summary = build_base_summary(output_dir, "live-xpc", modes)
    summary["models_root"] = str(models_root)
    xcode_result = run_live_xcode_test(output_dir, modes, models_root, args)
    summary["xcodebuild"] = xcode_result
    if xcode_result["exit_code"] != 0:
        summary["overall_pass"] = False
        summary["error"] = "Live XPC generation test failed."
        return summary

    manifest_path = output_dir / "generation-manifest.json"
    if not manifest_path.exists():
        summary["overall_pass"] = False
        summary["error"] = f"Live XPC generation did not write {manifest_path}."
        return summary

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    summary["generation_manifest"] = str(manifest_path)
    summary["generated_artifacts"] = manifest.get("artifacts", [])
    for artifact in manifest.get("artifacts", []):
        mode = artifact.get("mode", "unknown")
        output_path = artifact.get("outputPath")
        if output_path:
            summary["reports"].append(
                run_audio_audit(
                    output_dir=output_dir,
                    name=f"live-{mode}-final",
                    args=["--file", output_path],
                )
            )
        session_dir = artifact.get("streamSessionDirectory")
        if session_dir and Path(session_dir).is_dir():
            ensure_session_final(session_dir, output_path)
            summary["reports"].append(
                run_audio_audit(
                    output_dir=output_dir,
                    name=f"live-{mode}-session",
                    args=["--session-dir", session_dir],
                )
            )

    summary["overall_pass"] = bool(summary["reports"]) and all(
        report["exit_code"] == 0 for report in summary["reports"]
    )
    return summary


def validate_required_models(modes: list[str], models_root: Path) -> None:
    contract = load_contract()
    by_id = {model["id"]: model for model in contract.get("models", [])}
    for mode in modes:
        model_id = MODE_MODEL_IDS[mode]
        model = by_id.get(model_id)
        if not model:
            raise UsageError(f"Contract is missing model {model_id} for {mode}.")
        model_dir = models_root / model["folder"]
        missing = [
            str(model_dir / relative)
            for relative in model.get("requiredRelativePaths", [])
            if not (model_dir / relative).exists()
        ]
        if not model_dir.is_dir() or missing:
            missing_text = "\n  - ".join(missing or [str(model_dir)])
            raise UsageError(
                f"Installed model for {mode} is incomplete under {models_root}:\n  - {missing_text}"
            )


def run_live_xcode_test(
    output_dir: Path,
    modes: list[str],
    models_root: Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    log_path = output_dir / "xcodebuild.log"
    result_bundle = output_dir / "GenerationQualityAuditLiveTests.xcresult"
    derived_data = output_dir / "derived-data"
    source_packages = output_dir / "source-packages"
    request_file = BUILD_ROOT / "audio-qc" / "live-request.json"
    if result_bundle.exists():
        shutil.rmtree(result_bundle)
    ensure_directory(request_file.parent)

    command = [
        "xcodebuild",
        "-project",
        str(PROJECT_DIR / "QwenVoice.xcodeproj"),
        "-scheme",
        "QwenVoice Foundation",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        str(derived_data),
        "-clonedSourcePackagesDirPath",
        str(source_packages),
        "-resultBundlePath",
        str(result_bundle),
        "test",
        "-only-testing:QwenVoiceTests/GenerationQualityAuditLiveTests",
    ]
    environment = dict(os.environ)
    environment.update(
        {
            "QWENVOICE_AUDIO_QC_LIVE": "1",
            "QWENVOICE_AUDIO_QC_ALLOW_MODEL_LOAD": "1",
            "QWENVOICE_AUDIO_QC_OUTPUT_DIR": str(output_dir),
            "QWENVOICE_AUDIO_QC_MODES": ",".join(modes),
            "QWENVOICE_AUDIO_QC_MODELS_ROOT": str(models_root),
        }
    )
    if args.clone_reference:
        environment["QWENVOICE_AUDIO_QC_CLONE_REFERENCE"] = str(Path(args.clone_reference).resolve())
    if args.clone_transcript:
        environment["QWENVOICE_AUDIO_QC_CLONE_TRANSCRIPT"] = args.clone_transcript

    started = time.perf_counter()
    expires_at = datetime.fromtimestamp(time.time() + 1800, timezone.utc)
    request_payload = {
        "live": True,
        "allowModelLoad": True,
        "outputDirectory": str(output_dir.resolve()),
        "modes": modes,
        "modelsRoot": str(models_root.resolve()),
        "cloneReference": str(Path(args.clone_reference).resolve()) if args.clone_reference else None,
        "cloneTranscript": args.clone_transcript,
        "expiresAt": expires_at.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }
    request_file.write_text(
        json.dumps(request_payload, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    try:
        with log_path.open("w", encoding="utf-8") as log_file:
            proc = subprocess.run(
                command,
                cwd=str(PROJECT_DIR),
                env=environment,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=resolve_xcodebuild_timeout_seconds(),
            )
    finally:
        try:
            request_file.unlink()
        except FileNotFoundError:
            pass
    return {
        "exit_code": proc.returncode,
        "duration_ms": int((time.perf_counter() - started) * 1000),
        "command": command,
        "request_file": str(request_file),
        "log_path": str(log_path),
        "result_bundle": str(result_bundle),
    }


def ensure_session_final(session_dir: str, output_path: str | None) -> None:
    if not output_path:
        return
    session_path = Path(session_dir)
    final_path = session_path / "final.wav"
    source = Path(output_path)
    if final_path.exists() or not source.exists():
        return
    shutil.copy2(source, final_path)


def run_audio_audit(
    *,
    output_dir: Path,
    name: str,
    args: list[str],
) -> dict[str, Any]:
    json_report = output_dir / f"{name}.json"
    markdown_report = output_dir / f"{name}.md"
    command = [
        sys.executable,
        str(PROJECT_DIR / "scripts" / "audit_generated_audio.py"),
        *args,
        "--json-out",
        str(json_report),
        "--report-out",
        str(markdown_report),
    ]
    started = time.perf_counter()
    proc = subprocess.run(
        command,
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=180,
    )
    return {
        "name": name,
        "exit_code": proc.returncode,
        "duration_ms": int((time.perf_counter() - started) * 1000),
        "command": command,
        "json_report": str(json_report),
        "markdown_report": str(markdown_report),
        "stdout_tail": proc.stdout.splitlines()[-20:],
        "stderr_tail": proc.stderr.splitlines()[-20:],
    }


def build_base_summary(output_dir: Path, source: str, modes: list[str]) -> dict[str, Any]:
    return {
        "tool": "run_generation_quality_audit",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source": source,
        "modes": modes,
        "output_dir": str(output_dir),
        "overall_pass": False,
        "reports": [],
    }


def write_summary(output_dir: Path, summary: dict[str, Any]) -> None:
    ensure_directory(output_dir)
    (output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    (output_dir / "summary.md").write_text(render_summary_markdown(summary), encoding="utf-8")


def render_summary_markdown(summary: dict[str, Any]) -> str:
    status = "PASS" if summary.get("overall_pass") else "FAIL"
    lines = [
        f"# Generation Audio Quality Audit: {status}",
        "",
        f"- Source: `{summary.get('source')}`",
        f"- Modes: `{', '.join(summary.get('modes') or [])}`",
        f"- Output: `{summary.get('output_dir')}`",
        f"- Created: `{summary.get('created_at')}`",
        "",
    ]
    if summary.get("error"):
        lines.extend(["## Error", "", str(summary["error"]), ""])
    if summary.get("xcodebuild"):
        xcode = summary["xcodebuild"]
        lines.extend(
            [
                "## Live Generation",
                "",
                f"- Exit code: `{xcode.get('exit_code')}`",
                f"- Log: `{xcode.get('log_path')}`",
                f"- Result bundle: `{xcode.get('result_bundle')}`",
                "",
            ]
        )
    if summary.get("generated_artifacts"):
        lines.extend(["## Generated Artifacts", ""])
        for artifact in summary["generated_artifacts"]:
            lines.append(
                f"- `{artifact.get('mode')}`: `{artifact.get('outputPath')}` "
                f"({artifact.get('durationSeconds')}s)"
            )
        lines.append("")
    lines.extend(["## QC Reports", ""])
    if not summary.get("reports"):
        lines.append("- No reports were produced.")
    for report in summary.get("reports", []):
        report_status = "PASS" if report.get("exit_code") == 0 else "FAIL"
        lines.append(
            f"- {report_status} `{report.get('name')}`: "
            f"[markdown]({report.get('markdown_report')}) "
            f"[json]({report.get('json_report')})"
        )
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    main()
