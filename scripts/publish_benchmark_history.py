#!/usr/bin/env python3
"""Validate non-UI benchmark evidence and publish a compact history record.

This is the sole adapter between model-dependent non-UI runners and
``scripts/benchmark_history.py``.  It never copies raw audio, telemetry, labels,
or traces into Git.  Every subcommand first writes an atomic, allowlisted
``benchmark-evidence.json`` beside the untracked run artifacts, then asks the
registry to record it.  Once that manifest exists, delayed repair always calls
the registry directly so the frozen evidence is never regenerated.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import wave
from typing import Any, Iterable
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
HISTORY_SCRIPT = ROOT / "scripts" / "benchmark_history.py"
SUCCESS_FINISH = {"eos", "max_tokens", "maxtokens", "completed", "complete", "success", "ok"}
TRIM_SEVERITY = {"softTrim": 1, "hardTrim": 2, "fullUnload": 3}


class PublicationError(RuntimeError):
    pass


def _load_history_module():
    spec = importlib.util.spec_from_file_location("benchmark_history_runtime", HISTORY_SCRIPT)
    if spec is None or spec.loader is None:
        raise PublicationError("benchmark history module is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PublicationError(f"cannot read JSON {path}: {error}") from error
    if not isinstance(payload, dict):
        raise PublicationError(f"expected a JSON object: {path}")
    return payload


def canonical_hardware_profile(platform: str) -> dict[str, Any]:
    payload = load_json(ROOT / "benchmarks" / "hardware-profiles.json")
    profiles = payload.get("profiles")
    if payload.get("schemaVersion") != 1 or not isinstance(profiles, list):
        raise PublicationError("hardware-profiles.json has an unsupported schema")
    matches = [
        profile for profile in profiles
        if isinstance(profile, dict)
        and profile.get("platform") == platform
        and profile.get("canonical") is True
    ]
    if len(matches) != 1:
        raise PublicationError(f"expected exactly one canonical {platform} hardware profile")
    return matches[0]


def _required_command_output(arguments: list[str], description: str) -> str:
    completed = subprocess.run(
        arguments, cwd=ROOT, text=True, capture_output=True, check=False
    )
    if completed.returncode:
        detail = completed.stderr.strip() or completed.stdout.strip() or "unknown failure"
        raise PublicationError(f"could not verify {description}: {detail}")
    value = completed.stdout.strip()
    if not value:
        raise PublicationError(f"could not verify {description}: empty result")
    return value


def verify_canonical_hardware(
    platform: str,
    *,
    ios_evidence: Iterable[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Prove the live benchmark host matches the tracked canonical profile.

    The registry's profile defaults are descriptive metadata, not runtime
    evidence.  Publication therefore performs this independent check before a
    profile ID is allowed into a manifest.
    """
    profile = canonical_hardware_profile(platform)
    if platform == "macos":
        model = _required_command_output(["sysctl", "-n", "hw.model"], "Mac model")
        memory_text = _required_command_output(
            ["sysctl", "-n", "hw.memsize"], "Mac physical memory"
        )
        try:
            memory_bytes = int(memory_text)
        except ValueError as error:
            raise PublicationError("Mac physical-memory evidence is not an integer") from error
        if model != profile.get("modelIdentifier") or memory_bytes != profile.get("memoryBytes"):
            raise PublicationError(
                "live Mac hardware does not match the canonical benchmark profile "
                f"({model}, {memory_bytes} bytes)"
            )
        return {"profileID": str(profile["id"])}

    if platform != "ios":
        raise PublicationError(f"unsupported benchmark platform: {platform}")
    records = list(ios_evidence or [])
    if not records:
        raise PublicationError("iOS hardware verification requires device sentinel evidence")
    versions: set[str] = set()
    for record in records:
        if (
            record.get("deviceModel") != "iPhone"
            or record.get("systemName") != "iOS"
            or not isinstance(record.get("systemVersion"), str)
            or not record.get("systemVersion")
        ):
            raise PublicationError("iOS sentinel lacks exact physical-iPhone OS evidence")
        versions.add(str(record["systemVersion"]))
    if len(versions) != 1:
        raise PublicationError("iOS benchmark sentinels do not share one OS version")

    descriptor, temporary = tempfile.mkstemp(prefix="vocello-hardware-", suffix=".json")
    os.close(descriptor)
    try:
        completed = subprocess.run(
            [
                "xcrun", "devicectl", "list", "devices", "--quiet", "--timeout", "5",
                "--json-output", temporary,
            ],
            cwd=ROOT, text=True, capture_output=True, check=False,
        )
        if completed.returncode:
            detail = completed.stderr.strip() or completed.stdout.strip() or "unknown failure"
            raise PublicationError(f"could not verify physical iPhone hardware: {detail}")
        payload = load_json(Path(temporary))
    finally:
        Path(temporary).unlink(missing_ok=True)

    devices = (payload.get("result") or {}).get("devices")
    if not isinstance(devices, list):
        raise PublicationError("devicectl returned no device inventory")
    expected_version = next(iter(versions))
    candidates: list[dict[str, Any]] = []
    for device in devices:
        if not isinstance(device, dict):
            continue
        hardware = device.get("hardwareProperties") or {}
        properties = device.get("deviceProperties") or {}
        connection = device.get("connectionProperties") or {}
        reachable = (
            connection.get("pairingState") == "paired"
            or connection.get("tunnelState") in {"connected", "available"}
        )
        if (
            hardware.get("platform") == "iOS"
            and properties.get("osVersionNumber") == expected_version
            and reachable
        ):
            candidates.append(device)
    if len(candidates) != 1:
        raise PublicationError(
            "iOS sentinel evidence does not resolve to exactly one reachable CoreDevice"
        )
    observed_model = (candidates[0].get("hardwareProperties") or {}).get("productType")
    if observed_model != profile.get("modelIdentifier"):
        raise PublicationError(
            "physical iPhone does not match the canonical benchmark profile "
            f"({observed_model!r})"
        )
    return {"profileID": str(profile["id"])}


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    ).encode("utf-8")


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise PublicationError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=True, allow_nan=False) + "\n").encode("utf-8")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def history_git_state() -> dict[str, Any]:
    return _load_history_module().git_state()


def crash_digests(scope: str, diagnostics: Path | None = None) -> list[str]:
    if scope == "none":
        return []
    if scope == "macos":
        root = Path.home() / "Library" / "Logs" / "DiagnosticReports"
        candidates = [
            path for path in root.glob("*.ips")
            if path.name.startswith(("Vocello-", "QwenVoiceEngineService-"))
            or "engine-service" in path.name.lower()
        ] if root.is_dir() else []
    elif scope == "ios":
        if diagnostics is None or not diagnostics.is_dir():
            raise PublicationError("iOS crash proof requires a pulled pre-run diagnostics directory")
        candidates = [
            path for path in diagnostics.rglob("*")
            if path.is_file() and "crashes" in {part.lower() for part in path.parts}
        ]
    else:
        raise PublicationError(f"unsupported crash proof scope: {scope}")
    return sorted({digest_file(path) for path in candidates})


def capture_snapshot(output: Path, crash_scope: str, crash_diagnostics: Path | None = None) -> None:
    state = history_git_state()
    atomic_json(output, {
        "schemaVersion": 1,
        "capturedAt": utc_now(),
        "source": state,
        "crashEvidence": {
            "scope": crash_scope,
            "digests": crash_digests(crash_scope, crash_diagnostics),
        },
    })


def source_from_snapshot(snapshot_path: Path) -> dict[str, Any]:
    if not snapshot_path.is_file():
        raise PublicationError(
            f"missing pre-run source snapshot: {snapshot_path}; rerun the benchmark from the start"
        )
    if snapshot_path.name != "benchmark-source.json":
        raise PublicationError("pre-run snapshot must be named benchmark-source.json")
    return _load_history_module().source_state_for_artifact(snapshot_path.parent)


def crash_delta_from_snapshot(
    snapshot_path: Path,
    *,
    expected_scope: str,
    diagnostics: Path | None = None,
) -> dict[str, Any]:
    snapshot = load_json(snapshot_path)
    crash_evidence = snapshot.get("crashEvidence")
    if not isinstance(crash_evidence, dict) or crash_evidence.get("scope") != expected_scope:
        raise PublicationError(f"pre-run snapshot lacks {expected_scope} crash evidence")
    before = crash_evidence.get("digests")
    if not isinstance(before, list) or not all(isinstance(item, str) for item in before):
        raise PublicationError("pre-run crash digest set is malformed")
    after = crash_digests(expected_scope, diagnostics)
    added = sorted(set(after) - set(before))
    if added:
        raise PublicationError(f"benchmark produced {len(added)} new crash report(s)")
    return {"passed": True, "count": 0}


def finite_number(value: Any) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value)):
        return float(value)
    return None


def find_engine_files(diagnostics: Path) -> list[Path]:
    direct = diagnostics / "engine" / "generations.jsonl"
    if direct.is_file():
        return [direct]
    paths = sorted(
        path for path in diagnostics.rglob("generations.jsonl")
        if path.parent.name == "engine" and path.is_file()
    )
    if not paths:
        raise PublicationError(f"no engine/generations.jsonl under {diagnostics}")
    return paths


def load_engine_rows(diagnostics: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in find_engine_files(diagnostics):
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise PublicationError(f"invalid telemetry JSON at {path}:{line_number}: {error}") from error
            if isinstance(row, dict) and row.get("layer") == "engine":
                rows.append(row)
    return rows


def rows_by_generation(rows: Iterable[dict[str, Any]], generation_ids: Iterable[str]) -> list[dict[str, Any]]:
    indexed: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        generation_id = row.get("generationID")
        if isinstance(generation_id, str):
            indexed.setdefault(generation_id.lower(), []).append(row)
    selected: list[dict[str, Any]] = []
    for generation_id in generation_ids:
        matches = indexed.get(generation_id.lower(), [])
        if len(matches) != 1:
            raise PublicationError(
                f"generation {generation_id} has {len(matches)} engine rows; expected exactly one"
            )
        selected.append(matches[0])
    return selected


def successful_row(row: dict[str, Any]) -> None:
    finish = str(row.get("finishReason", "")).lower()
    if finish not in SUCCESS_FINISH:
        raise PublicationError(f"generation {row.get('generationID')} has unsuccessful finishReason={finish!r}")
    output = row.get("outputMetrics")
    if not isinstance(output, dict) or output.get("readableWAV") is not True or output.get("atomicallyPublished") is not True:
        raise PublicationError(f"generation {row.get('generationID')} lacks readable atomic WAV proof")
    qc = row.get("audioQC")
    if int(row.get("schemaVersion", 0)) >= 7 and (
        not isinstance(qc, dict)
        or any(qc.get(key) is None for key in ("verdict", "instabilityVerdict", "writtenOutputVerdict"))
    ):
        raise PublicationError(
            f"generation {row.get('generationID')} lacks schema-v7 instability/written-output QC verdicts"
        )
    if int(row.get("schemaVersion", 0)) >= 7 and not isinstance(row.get("backendMetrics"), dict):
        raise PublicationError(f"generation {row.get('generationID')} lacks schema-v7 backendMetrics")
    verdicts = [
        str(qc.get(key)).lower()
        for key in ("verdict", "instabilityVerdict", "writtenOutputVerdict")
        if isinstance(qc, dict) and qc.get(key) is not None
    ]
    if not verdicts or any(verdict not in {"pass", "warn"} for verdict in verdicts):
        raise PublicationError(f"generation {row.get('generationID')} has unacceptable audio QC={verdicts!r}")


def row_metrics(row: dict[str, Any], take: dict[str, Any] | None = None) -> dict[str, float]:
    derived = row.get("derivedMetrics") if isinstance(row.get("derivedMetrics"), dict) else {}
    summary = row.get("summary") if isinstance(row.get("summary"), dict) else {}
    timings = row.get("timingsMS") if isinstance(row.get("timingsMS"), dict) else {}
    backend = row.get("backendMetrics") if isinstance(row.get("backendMetrics"), dict) else {}
    typed_timings = {
        item.get("key"): item.get("milliseconds")
        for item in backend.get("timings", [])
        if isinstance(item, dict)
    }
    resources = summary.get("processResourceUsage") if isinstance(summary.get("processResourceUsage"), dict) else {}
    minor_faults = finite_number(resources.get("minorPageFaults")) or 0.0
    major_faults = finite_number(resources.get("majorPageFaults")) or 0.0
    voluntary_switches = finite_number(resources.get("voluntaryContextSwitches")) or 0.0
    involuntary_switches = finite_number(resources.get("involuntaryContextSwitches")) or 0.0
    block_inputs = finite_number(resources.get("blockInputOperations")) or 0.0
    block_outputs = finite_number(resources.get("blockOutputOperations")) or 0.0
    stage_marks = backend.get("stages") or row.get("stageMarks") or summary.get("stageMarks") or []
    trim_levels = [
        (mark.get("metadata") or {}).get("level")
        for mark in stage_marks
        if isinstance(mark, dict) and mark.get("stage") == "memory_trim"
    ]
    candidates = {
        "rtf": derived.get("audioSecondsPerWallSecond"),
        "tokensPerSecond": derived.get("tokensPerSecond"),
        "decodeWallSeconds": derived.get("decodeWallSeconds"),
        "audioSeconds": derived.get("audioSeconds"),
        "generatedTokens": derived.get("generatedTokenCount"),
        "modelLoadMS": typed_timings.get("modelLoad", timings.get("native_model_load_ms")),
        "prewarmMS": typed_timings.get("explicitPrewarm", timings.get("native_prewarm_ms")),
        "finalizationMS": typed_timings.get("finalWAVFinish", timings.get("native_final_wav_finish_ms")),
        "peakPhysicalFootprintMB": summary.get("physFootprintPeakMB"),
        "peakResidentMB": summary.get("residentPeakMB"),
        "peakCompressedMB": summary.get("compressedPeakMB"),
        "peakGPUAllocatedMB": summary.get("gpuAllocatedPeakMB"),
        "minimumHeadroomMB": summary.get("headroomMinMB"),
        "cpuUserSeconds": (
            float(resources["userCPUTimeMS"]) / 1_000.0
            if finite_number(resources.get("userCPUTimeMS")) is not None else None
        ),
        "cpuSystemSeconds": (
            float(resources["systemCPUTimeMS"]) / 1_000.0
            if finite_number(resources.get("systemCPUTimeMS")) is not None else None
        ),
        "pageFaults": minor_faults + major_faults if resources else None,
        "contextSwitches": voluntary_switches + involuntary_switches if resources else None,
        "blockIOOperations": block_inputs + block_outputs if resources else None,
        "samplerTargetIntervalMS": (
            float(summary["targetIntervalNS"]) / 1_000_000.0
            if finite_number(summary.get("targetIntervalNS")) is not None else None
        ),
        "samplerEffectiveMedianIntervalMS": (
            float(summary["effectiveIntervalNS"]) / 1_000_000.0
            if finite_number(summary.get("effectiveIntervalNS")) is not None else None
        ),
        "samplerMaximumLatenessMS": (
            float(summary["maximumLatenessNS"]) / 1_000_000.0
            if finite_number(summary.get("maximumLatenessNS")) is not None else None
        ),
        "samplerMaximumDriftMS": (
            float(summary["maximumDriftNS"]) / 1_000_000.0
            if finite_number(summary.get("maximumDriftNS")) is not None else None
        ),
        "samplerBoundarySampleCount": summary.get("boundarySampleCount"),
        "samplerCaptureFailureCount": summary.get("captureFailureCount"),
        "memoryTrimCount": len(trim_levels),
        "maximumTrimLevel": max(
            (TRIM_SEVERITY.get(level, 0) for level in trim_levels), default=0
        ),
    }
    if take is not None:
        candidates["ttfcMS"] = take.get("firstChunkMS")
        wall = finite_number(take.get("wallSeconds"))
        audio = finite_number(take.get("audioSeconds"))
        if wall and wall > 0 and audio is not None:
            candidates["rtf"] = audio / wall
    return {
        key: number for key, value in candidates.items()
        if (number := finite_number(value)) is not None
    }


def qc_record(row: dict[str, Any]) -> dict[str, Any]:
    qc = row["audioQC"]
    verdicts = [
        str(qc.get(key)).lower()
        for key in ("verdict", "instabilityVerdict", "writtenOutputVerdict")
        if qc.get(key) is not None
    ]
    rank = {"pass": 0, "warn": 1, "fail": 2}
    verdict = max(verdicts or ["pass"], key=lambda item: rank.get(item, 99))
    flags = [str(item) for item in qc.get("flags", []) if isinstance(item, str)]
    if str(qc.get("instabilityVerdict", "pass")).lower() == "warn":
        flags.append("instability-warn")
    if str(qc.get("writtenOutputVerdict", "pass")).lower() == "warn":
        flags.append("written-output-warn")
    metrics: dict[str, float] = {}
    for source, target in (
        ("clickEvents", "discontinuityCount"),
        ("clippedSamples", "clipCount"),
        ("nonFiniteSamples", "nonFiniteCount"),
        ("longestSilenceMS", "longestSilenceMS"),
        ("dcOffset", "dcOffset"),
    ):
        if (value := finite_number(qc.get(source))) is not None:
            metrics[target] = value
    return {
        "algorithmVersion": int(qc.get("algorithmVersion", 1)),
        "verdict": verdict,
        "instabilityVerdict": str(qc.get("instabilityVerdict", qc.get("verdict", "pass"))).lower(),
        "writtenOutputVerdict": str(qc.get("writtenOutputVerdict", qc.get("verdict", "pass"))).lower(),
        "warningCodes": sorted(set(flags)) if verdict == "warn" else [],
        "metrics": metrics,
    }


def thermal_state(row: dict[str, Any]) -> str:
    thermal = row.get("thermalState")
    if isinstance(thermal, dict):
        value = thermal.get("worst") or thermal.get("end") or thermal.get("start")
    else:
        value = thermal
    return str(value or "unknown").lower()


def hardware_context(rows: Iterable[dict[str, Any]]) -> dict[str, Any]:
    environments: list[dict[str, Any]] = []
    thermal_values: list[str] = []
    for row in rows:
        summary = row.get("summary") if isinstance(row.get("summary"), dict) else {}
        environment = summary.get("runEnvironment")
        if isinstance(environment, dict):
            environments.append(environment)
            thermal_values.append(str(environment.get("thermalState", "unknown")).lower())
        thermal_values.append(thermal_state(row))
    result: dict[str, Any] = {}
    if environments:
        first = environments[0]
        if (value := finite_number(first.get("loadAverage1Minute"))) is not None:
            result["loadAverage1M"] = value
        free_values = [
            value for environment in environments
            if (value := finite_number(environment.get("freeStorageBytes"))) is not None
        ]
        uptime_values = [
            value for environment in environments
            if (value := finite_number(environment.get("uptimeSeconds"))) is not None
        ]
        if free_values:
            result["freeStorageBytes"] = int(min(free_values))
        if uptime_values:
            result["uptimeSeconds"] = min(uptime_values)
        low_power = [environment.get("lowPowerModeEnabled") for environment in environments]
        if all(isinstance(value, bool) for value in low_power):
            result["lowPowerMode"] = any(low_power)
    thermal_rank = {"nominal": 0, "fair": 1, "serious": 2, "critical": 3, "unknown": -1}
    known_thermal = [value for value in thermal_values if value in thermal_rank and value != "unknown"]
    if known_thermal:
        result["thermalState"] = max(known_thermal, key=lambda value: thermal_rank[value])
    return result


def uses_forced_memory_profile(rows: Iterable[dict[str, Any]]) -> bool:
    for row in rows:
        notes = row.get("notes") if isinstance(row.get("notes"), dict) else {}
        if str(notes.get("deviceClassForced", "false")).lower() == "true":
            return True
        if notes.get("memoryProfile") or notes.get("simulatedProcessLimitMB"):
            return True
    return False


def prompt_corpus_digest(rows: Iterable[dict[str, Any]]) -> str:
    ordered: list[str] = []
    for row in rows:
        notes = row.get("notes") if isinstance(row.get("notes"), dict) else {}
        digest = notes.get("promptDigest")
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise PublicationError(
                f"generation {row.get('generationID')} lacks a privacy-safe prompt digest"
            )
        ordered.append(digest)
    if not ordered:
        raise PublicationError("benchmark has no prompt corpus identity")
    return digest_bytes(canonical_bytes(ordered))


def exact_models(platform: str, takes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return _load_history_module().default_models({
        "run": {"platform": platform},
        "takes": takes,
    })


def runtime_identity(row: dict[str, Any], *, mode: str, model_id: str) -> dict[str, str]:
    """Return the complete typed model/runtime identity for one engine row.

    Schema-v7 evidence must never fall back to the historical free-form maps.
    Older rows remain decodable for local analysis, but only the typed payload is
    authoritative for a new v1 history record.
    """
    schema = int(row.get("schemaVersion", 0))
    identity = row.get("modelRuntimeIdentity")
    if schema >= 7:
        if not isinstance(identity, dict):
            raise PublicationError("schema-v7 engine telemetry lacks modelRuntimeIdentity")
        resolved = identity.get("resolvedModelID")
        required = {
            "modelRepository": identity.get("modelRepository"),
            "modelRevision": identity.get("huggingFaceRevision"),
            "modelArtifactVersion": identity.get("artifactVersion"),
            "modelQuantization": identity.get("quantization"),
            "modelIntegrityDigest": identity.get("integrityManifestDigest"),
            "runtimeProfileSignature": identity.get("runtimeProfileSignature"),
        }
        if resolved != model_id:
            raise PublicationError(
                f"typed resolved model {resolved!r} does not match telemetry model {model_id!r}"
            )
        for field, value in required.items():
            if not isinstance(value, str) or not value:
                raise PublicationError(f"schema-v7 engine telemetry lacks {field}")
        if required["modelQuantization"] not in {"4-bit", "8-bit", "unquantized"}:
            raise PublicationError("schema-v7 engine telemetry has invalid modelQuantization")
        for field in ("modelRevision", "modelIntegrityDigest"):
            value = required[field]
            expected_length = 40 if field == "modelRevision" else 64
            if len(value) != expected_length or any(character not in "0123456789abcdef" for character in value):
                raise PublicationError(f"schema-v7 engine telemetry has invalid {field}")
        fixture_digest = identity.get("fixtureDigest")
    else:
        notes = row.get("notes") if isinstance(row.get("notes"), dict) else {}
        required = {
            "modelRepository": str(notes.get("modelRepository", "not-applicable")),
            "modelRevision": str(notes.get("huggingFaceRevision", "not-applicable")),
            "modelArtifactVersion": str(notes.get("artifactVersion", "not-applicable")),
            "modelQuantization": str(notes.get("quantization", "not-applicable")),
            "modelIntegrityDigest": str(notes.get("integrityManifestDigest", "not-applicable")),
            "runtimeProfileSignature": str(notes.get("qwen3RuntimeProfileSignature") or model_id),
        }
        fixture_digest = notes.get("fixtureDigest")
    if fixture_digest is not None:
        if (
            not isinstance(fixture_digest, str)
            or len(fixture_digest) != 64
            or any(character not in "0123456789abcdef" for character in fixture_digest)
        ):
            raise PublicationError(f"invalid typed fixture digest for {mode}")
    if mode in {"design", "clone"} and fixture_digest is None:
        raise PublicationError(f"schema-v7 {mode} telemetry lacks fixtureDigest")
    required["fixtureDigest"] = str(fixture_digest or "not-applicable")
    return {field: str(value) for field, value in required.items()}


def require_fixture_cross_check(
    takes: list[dict[str, Any]],
    expected: dict[str, str],
    *,
    source: str,
) -> None:
    for mode in {str(take.get("mode")) for take in takes} & {"design", "clone"}:
        observed = {take.get("fixtureDigest") for take in takes if take.get("mode") == mode}
        if len(observed) != 1 or None in observed:
            raise PublicationError(f"{mode} takes do not share one typed fixture digest")
        expected_digest = expected.get(mode)
        if expected_digest != next(iter(observed)):
            raise PublicationError(f"{source} {mode} fixture digest does not match engine telemetry")


def wave_output(path: Path, row: dict[str, Any]) -> dict[str, Any]:
    if not path.is_file():
        raise PublicationError(f"benchmark output is missing: {path}")
    try:
        with wave.open(str(path), "rb") as stream:
            frames = stream.getnframes()
            sample_rate = stream.getframerate()
            channels = stream.getnchannels()
    except (OSError, wave.Error) as error:
        raise PublicationError(f"benchmark output is not a readable WAV: {path}: {error}") from error
    if frames <= 0 or sample_rate <= 0 or channels <= 0:
        raise PublicationError(f"benchmark output has an invalid WAV header: {path}")
    duration = frames / sample_rate
    return {
        "readableWAV": True,
        "atomicPublish": True,
        "durationSeconds": duration,
        "sampleRate": sample_rate,
        "channels": channels,
        "frames": frames,
        "fileDigest": digest_file(path),
    }


def telemetry_output(row: dict[str, Any]) -> dict[str, Any]:
    output = row["outputMetrics"]
    duration = finite_number(output.get("durationSeconds"))
    result: dict[str, Any] = {"readableWAV": True, "atomicPublish": True}
    if duration is not None:
        result["durationSeconds"] = duration
    return result


def engine_take(
    index: int,
    take: dict[str, Any],
    row: dict[str, Any],
    output_dir: Path | None,
    *,
    run_id: str,
) -> dict[str, Any]:
    successful_row(row)
    generation_id = str(take.get("generationID", ""))
    notes = row.get("notes") if isinstance(row.get("notes"), dict) else {}
    if notes.get("benchRunID") != run_id:
        raise PublicationError(f"generation {generation_id} has the wrong or missing benchRunID")
    if notes.get("benchTakeIndex") is None or str(notes.get("benchTakeIndex")) != str(index):
        raise PublicationError(f"generation {generation_id} has the wrong benchTakeIndex")
    if not isinstance(notes.get("benchCell"), str) or notes.get("benchCell") != take.get("cell"):
        raise PublicationError(f"generation {generation_id} has the wrong ordered cell")
    if row.get("mode") != take.get("mode") or row.get("modelID") != take.get("modelID"):
        raise PublicationError(f"generation {generation_id} telemetry identity does not match bench results")
    mode = str(take.get("mode"))
    model_id = str(take.get("modelID"))
    identity = runtime_identity(row, mode=mode, model_id=model_id)
    qc = qc_record(row)
    output = (
        wave_output(output_dir / str(take.get("outputFileName", "")), row)
        if output_dir is not None else telemetry_output(row)
    )
    duration = finite_number(take.get("wallSeconds"))
    result: dict[str, Any] = {
        "takeIndex": index,
        "generationID": generation_id,
        "cell": str(take.get("cell")),
        "mode": mode,
        "modelID": model_id,
        "variant": str(take.get("variant", "speed")),
        "warmState": str(take.get("warmState", row.get("warmState", "unknown"))),
        "length": str(take.get("length", "not-applicable")),
        "finishReason": "completed",
        "status": "passedWithWarnings" if qc["verdict"] == "warn" else "passed",
        "layerCompleteness": "complete",
        "layers": ["engine"],
        "metrics": row_metrics(row, take),
        "output": output,
        "audioQC": qc,
        "thermalState": thermal_state(row),
        "warnings": list(qc["warningCodes"]),
        **identity,
    }
    if duration is not None:
        result["durationSeconds"] = duration
    return result


def minimal_take(index: int, cell: str, row: dict[str, Any]) -> dict[str, Any]:
    successful_row(row)
    notes = row.get("notes") if isinstance(row.get("notes"), dict) else {}
    qc = qc_record(row)
    model_id = str(row.get("modelID", "not-applicable"))
    mode = str(row.get("mode", "not-applicable"))
    identity = runtime_identity(row, mode=mode, model_id=model_id)
    variant = "quality" if model_id.endswith("quality") else "speed"
    result = {
        "takeIndex": index,
        "generationID": str(row.get("generationID")),
        "cell": cell,
        "mode": mode,
        "modelID": model_id,
        "variant": variant,
        "warmState": str(row.get("warmState", notes.get("benchWarmState", "unknown"))),
        "length": "not-applicable",
        "finishReason": "completed",
        "status": "passedWithWarnings" if qc["verdict"] == "warn" else "passed",
        "layerCompleteness": "complete",
        "layers": ["engine"],
        "metrics": row_metrics(row),
        "output": telemetry_output(row),
        "audioQC": qc,
        "thermalState": thermal_state(row),
        "warnings": list(qc["warningCodes"]),
        **identity,
    }
    return result


def record_shell(
    *,
    kind: str,
    platform: str,
    run_id: str,
    label: str,
    started_at: str,
    finished_at: str,
    matrix_scope: str,
    artifact_dir: Path,
    snapshot: Path,
    takes: list[dict[str, Any]],
    raw_digest: str,
    telemetry_schema: int | str,
    qc_algorithm: int | str,
    inputs: dict[str, Any] | None = None,
    trace: dict[str, Any] | None = None,
    executable_paths: dict[str, str] | None = None,
    optimization: str = "-Onone",
    classification: str | None = None,
    hardware: dict[str, Any] | None = None,
    hardware_evidence: Iterable[dict[str, Any]] | None = None,
    models: list[dict[str, Any]] | None = None,
    crash_delta: dict[str, Any] | None = None,
) -> dict[str, Any]:
    effective_label = label or run_id
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}", effective_label):
        raise PublicationError(
            "benchmark label must be an opaque 1-96 character identifier"
        )
    source = source_from_snapshot(snapshot)
    verified_hardware = verify_canonical_hardware(
        platform, ios_evidence=hardware_evidence
    )
    runtime_hardware = dict(hardware or {})
    supplied_profile = runtime_hardware.pop("profileID", None)
    if supplied_profile is not None and supplied_profile != verified_hardware["profileID"]:
        raise PublicationError("supplied hardware profile conflicts with live hardware evidence")
    warnings = sorted({warning for take in takes for warning in take.get("warnings", [])})
    status = "passedWithWarnings" if warnings else "passed"
    if crash_delta is None or crash_delta.get("passed") is not True:
        raise PublicationError("an observed crash-delta verdict is required before publication")
    evidence: dict[str, Any] = {
        "validatorSchemaVersion": 1,
        "telemetrySchemaVersion": telemetry_schema,
        "qcAlgorithmVersion": qc_algorithm,
        "validatorPassed": True,
        "crashDeltaPassed": True,
        "crashCount": int(crash_delta.get("count", 0)),
        "expectedTakeCount": len(takes),
        "actualTakeCount": len(takes),
        "resultBundleDigest": "not-applicable",
        "rawTelemetryDigest": raw_digest,
        "screenshotDigests": [],
    }
    if trace is not None:
        evidence["trace"] = trace
    history_record: dict[str, Any] = {
        "schemaVersion": 1,
        "run": {
            "id": run_id,
            "kind": kind,
            "platform": platform,
            "label": effective_label,
            "startedAt": started_at,
            "finishedAt": finished_at,
            "status": status,
            "matrixScope": matrix_scope,
            "warnings": warnings,
            **({"classification": classification} if classification else {}),
        },
        "toolchain": {"optimization": optimization},
        "hardware": {
            **verified_hardware,
            **runtime_hardware,
        },
        "source": source,
        "inputs": inputs or {},
        "evidence": evidence,
        "takes": takes,
    }
    if models is not None:
        history_record["models"] = models
    outer: dict[str, Any] = {
        "schemaVersion": 1,
        "benchmarkKind": kind,
        "platform": platform,
        "runID": run_id,
        "status": status,
        "matrixScope": matrix_scope,
        "expectedTakeCount": len(takes),
        "actualTakeCount": len(takes),
        "telemetrySchemaVersion": telemetry_schema,
        "qcAlgorithmVersion": qc_algorithm,
        "crashDeltaPassed": True,
        "crashCount": int(crash_delta.get("count", 0)),
        "rawTelemetryDigest": raw_digest,
        "historyRecord": history_record,
    }
    outer["optimization"] = optimization
    if executable_paths is not None:
        outer["executableRelativePaths"] = executable_paths
    return outer


def write_and_record(
    artifact_dir: Path,
    manifest: dict[str, Any],
    *,
    defer_record: bool = False,
) -> Path:
    manifest_path = artifact_dir / "benchmark-evidence.json"
    atomic_json(manifest_path, manifest)
    if defer_record:
        return manifest_path
    completed = subprocess.run(
        [sys.executable, str(HISTORY_SCRIPT), "record", "--artifact-dir", str(artifact_dir)],
        cwd=ROOT, text=True, capture_output=True, check=False,
    )
    if completed.returncode:
        detail = completed.stderr.strip() or completed.stdout.strip() or "unknown registry failure"
        repair = shlex.join([
            sys.executable,
            "scripts/benchmark_history.py",
            "record",
            "--artifact-dir",
            str(artifact_dir),
        ])
        raise PublicationError(f"history publication failed: {detail}\nrepair: {repair}")
    return manifest_path


def engine_command(args: argparse.Namespace, *, kind: str = "engine-generation", trace: dict[str, Any] | None = None) -> Path:
    results = load_json(args.results)
    if results.get("schemaVersion") != 1 or results.get("runID") != args.run_id:
        raise PublicationError("bench-results.json identity or schema does not match the requested run")
    result_takes = results.get("takes")
    if not isinstance(result_takes, list) or not result_takes:
        raise PublicationError("bench-results.json contains no takes")
    telemetry_mode = results.get("telemetryMode")
    streaming = results.get("streaming")
    seed = results.get("seed")
    if telemetry_mode not in {"lightweight", "verbose"} or not isinstance(streaming, bool):
        raise PublicationError("bench-results.json lacks exact telemetry/streaming configuration")
    if seed is not None and (not isinstance(seed, int) or isinstance(seed, bool) or seed < 0):
        raise PublicationError("bench-results.json has an invalid sampling seed")
    generation_ids: list[str] = []
    for index, take in enumerate(result_takes, start=1):
        if not isinstance(take, dict) or take.get("takeIndex") != index:
            raise PublicationError("bench-results take indices must be contiguous and one-based")
        generation_id = take.get("generationID")
        if not isinstance(generation_id, str) or not generation_id or generation_id.lower() in {item.lower() for item in generation_ids}:
            raise PublicationError("bench-results generation IDs must be unique non-empty strings")
        generation_ids.append(generation_id)
    selected = rows_by_generation(load_engine_rows(args.diagnostics), generation_ids)
    takes = [
        engine_take(index, result_take, row, args.output_dir, run_id=args.run_id)
        for index, (result_take, row) in enumerate(zip(result_takes, selected), start=1)
    ]
    delivery_takes = [take for take in result_takes if take.get("delivery")]
    prosody_path = args.diagnostics / "bench-prosody.json"
    prosody_rows: list[dict[str, Any]] = []
    analysis_profile_digest = "not-applicable"
    if delivery_takes:
        try:
            loaded = json.loads(prosody_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise PublicationError(f"delivery benchmark lacks valid prosody evidence: {error}") from error
        if not isinstance(loaded, list):
            raise PublicationError("bench-prosody.json must be an array")
        prosody_rows = [row for row in loaded if isinstance(row, dict)]
        profile_digests = {
            row.get("profileDigest") for row in prosody_rows
            if isinstance(row.get("profileDigest"), str)
        }
        if len(profile_digests) != 1:
            raise PublicationError("delivery prosody rows do not share one analysis profile")
        analysis_profile_digest = profile_digests.pop()
        if (
            len(analysis_profile_digest) != 64
            or any(character not in "0123456789abcdef" for character in analysis_profile_digest)
        ):
            raise PublicationError("delivery prosody analysis profile digest is invalid")
        for result_take, tracked_take in zip(result_takes, takes):
            delivery = result_take.get("delivery")
            if not delivery:
                continue
            matches = [
                row for row in prosody_rows
                if row.get("mode") == result_take.get("mode")
                and row.get("model") == result_take.get("modelID")
                and row.get("delivery") == delivery
            ]
            if len(matches) != 1:
                raise PublicationError(
                    f"delivery take {tracked_take['generationID']} has {len(matches)} prosody rows"
                )
            metrics = matches[0].get("deliveryMetrics")
            if not isinstance(metrics, dict) or "error" in metrics:
                raise PublicationError("delivery prosody analysis is incomplete")
            mapping = {
                "f0_mean_hz": "f0MeanHz",
                "f0_std_hz": "f0StdHz",
                "f0_turning_points_per_sec": "f0TurningPointsPerSecond",
                "rate_syllable_rate_hz": "syllableRateHz",
                "rate_local_rate_cv": "localRateCV",
                "pauses_max_pause_seconds": "maximumPauseSeconds",
                "pauses_pause_speech_ratio": "pauseSpeechRatio",
                "energy_envelope_roughness": "energyEnvelopeRoughness",
            }
            for source, target in mapping.items():
                if (value := finite_number(metrics.get(source))) is not None:
                    tracked_take["metrics"][target] = value
    telemetry_schema = max(int(row.get("schemaVersion", 0)) for row in selected)
    qc_algorithm = max(int((row.get("audioQC") or {}).get("algorithmVersion", 1)) for row in selected)
    raw_digest = digest_bytes(canonical_bytes({"telemetry": selected, "prosody": prosody_rows}))
    started_at = str(results.get("startedAt"))
    finished_at = str(results.get("finishedAt"))
    matrix_scope = "instrumented" if kind == "instrument-profile" else "focused"
    fixture_digests = results.get("fixtureDigests")
    if not isinstance(fixture_digests, dict):
        raise PublicationError("bench-results fixtureDigests must be an object")
    require_fixture_cross_check(takes, fixture_digests, source="bench-results")
    manifest = record_shell(
        kind=kind, platform=args.platform, run_id=args.run_id,
        label=str(results.get("label") or args.label or args.run_id),
        started_at=started_at, finished_at=finished_at, matrix_scope=matrix_scope,
        artifact_dir=args.artifact_dir, snapshot=args.snapshot, takes=takes,
        raw_digest=raw_digest, telemetry_schema=telemetry_schema,
        qc_algorithm=qc_algorithm, trace=trace,
        inputs={
            "corpusHash": prompt_corpus_digest(selected),
            "matrixHash": digest_bytes(canonical_bytes({
                "cells": [take.get("cell") for take in result_takes],
                "telemetryMode": telemetry_mode,
                "streaming": streaming,
                "seed": seed,
            })),
            "analysisProfileHash": analysis_profile_digest,
        },
        hardware=hardware_context(selected),
        models=exact_models(args.platform, takes),
        crash_delta=crash_delta_from_snapshot(
            args.snapshot,
            expected_scope="macos" if args.platform == "macos" else "ios",
            diagnostics=args.diagnostics if args.platform == "ios" else None,
        ),
        executable_paths={"vocello": "build/vocello"} if args.platform == "macos" else {"Vocello": "build/ios/Build/Products/Release-iphoneos/Vocello.app/Vocello"},
        optimization="-Onone",
        classification=(
            "instrumented" if kind == "instrument-profile"
            else "exploratory" if uses_forced_memory_profile(selected)
            else None
        ),
    )
    return write_and_record(
        args.artifact_dir, manifest,
        defer_record=bool(getattr(args, "defer_record", False)),
    )


def ios_engine_command(
    args: argparse.Namespace,
    *,
    kind: str = "engine-generation",
    trace: dict[str, Any] | None = None,
) -> Path:
    sentinel = load_json(args.sentinel)
    if sentinel.get("runID") != args.run_id or sentinel.get("status") != "ok":
        raise PublicationError("iOS sentinel does not describe this successful run")
    generation_id = sentinel.get("generationID")
    if not isinstance(generation_id, str) or not generation_id:
        raise PublicationError("iOS sentinel has no generation ID")
    rows = rows_by_generation(load_engine_rows(args.diagnostics), [generation_id])
    row = rows[0]
    successful_row(row)
    mode = str(sentinel.get("mode"))
    model_id = str(row.get("modelID", sentinel.get("modelID", "not-applicable")))
    variant = str(sentinel.get("variant", "speed"))
    take_source = {
        "generationID": generation_id,
        "cell": f"{mode}/{variant}/device",
        "mode": mode,
        "modelID": model_id,
        "variant": variant,
        "warmState": str(row.get("warmState", "unknown")),
        "length": "not-applicable",
        "wallSeconds": sentinel.get("wallSeconds"),
        "audioSeconds": sentinel.get("durationSeconds"),
    }
    take = engine_take(1, take_source, row, None, run_id=args.run_id)
    fixture_digest = sentinel.get("fixtureDigest")
    require_fixture_cross_check(
        [take],
        {mode: fixture_digest} if isinstance(fixture_digest, str) else {},
        source="iOS sentinel",
    )
    manifest = record_shell(
        kind=kind, platform="ios", run_id=args.run_id,
        label=args.label or args.run_id,
        started_at=str(sentinel.get("startedAt")), finished_at=str(sentinel.get("finishedAt")),
        matrix_scope="instrumented" if kind == "instrument-profile" else "focused",
        artifact_dir=args.artifact_dir, snapshot=args.snapshot,
        takes=[take], raw_digest=digest_bytes(canonical_bytes(rows)),
        telemetry_schema=int(row.get("schemaVersion", 0)),
        qc_algorithm=int((row.get("audioQC") or {}).get("algorithmVersion", 1)),
        inputs={"corpusHash": prompt_corpus_digest(rows)},
        trace=trace,
        hardware=hardware_context(rows),
        hardware_evidence=[sentinel],
        models=exact_models("ios", [take]),
        crash_delta=crash_delta_from_snapshot(
            args.snapshot, expected_scope="ios", diagnostics=args.diagnostics
            if getattr(args, "crash_diagnostics", None) is None else args.crash_diagnostics
        ),
        executable_paths={"Vocello": "build/ios/Build/Products/Release-iphoneos/Vocello.app/Vocello"},
        optimization="-Onone",
        classification=(
            "instrumented" if kind == "instrument-profile"
            else "exploratory" if uses_forced_memory_profile(rows)
            else None
        ),
    )
    return write_and_record(
        args.artifact_dir, manifest,
        defer_record=bool(getattr(args, "defer_record", False)),
    )


def selected_language_cells(matrix_path: Path, subset: str) -> list[dict[str, Any]]:
    matrix = load_json(matrix_path)
    cells = matrix.get("cells")
    if not isinstance(cells, list):
        raise PublicationError("language matrix has no cells")
    selected = cells if subset == "full" else [cell for cell in cells if cell.get("quick")]
    if not selected:
        raise PublicationError("language matrix selection is empty")
    return selected


def sanitized_asr_evidence(
    *,
    cell: dict[str, Any],
    sentinel: dict[str, Any],
    engine_row: dict[str, Any],
    parent_run_id: str,
) -> dict[str, Any]:
    """Return the bounded, non-transcript ASR proof bound to one engine row."""
    cell_id = str(cell.get("id"))
    expected_child_run = f"{parent_run_id}--{cell_id}"
    if sentinel.get("runID") != expected_child_run:
        raise PublicationError(f"language cell {cell_id} has the wrong child run ID")
    if sentinel.get("generationID") != engine_row.get("generationID"):
        raise PublicationError(f"language cell {cell_id} ASR evidence belongs to another generation")
    verification = sentinel.get("outputVerification")
    if not isinstance(verification, dict):
        raise PublicationError(f"language cell {cell_id} lacks output-verification evidence")
    expected_language = cell.get("expectedHint")
    if verification.get("expectedLanguage") != expected_language:
        raise PublicationError(f"language cell {cell_id} has the wrong expected ASR language")
    detected_language = verification.get("detectedLanguage")
    if not isinstance(detected_language, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{1,31}", detected_language):
        raise PublicationError(f"language cell {cell_id} has invalid detected-language evidence")
    language_score = finite_number(verification.get("languageMatchScore"))
    word_error_rate = finite_number(verification.get("wordErrorRate"))
    boolean_fields = {
        key: verification.get(key) for key in ("languagePass", "accuracyPass", "pass")
    }
    if (
        language_score is None or not 0.0 <= language_score <= 1.0
        or word_error_rate is None or word_error_rate < 0.0
    ):
        raise PublicationError(f"language cell {cell_id} has non-finite ASR scores")
    if any(not isinstance(value, bool) for value in boolean_fields.values()):
        raise PublicationError(f"language cell {cell_id} has malformed ASR verdicts")
    if verification.get("skipReason") is not None or not all(boolean_fields.values()):
        raise PublicationError(f"language cell {cell_id} failed output verification")
    return {
        "cell": cell_id,
        "runID": expected_child_run,
        "generationID": str(engine_row.get("generationID")),
        "expectedLanguage": str(expected_language),
        "detectedLanguage": detected_language,
        "languageMatchScore": language_score,
        "wordErrorRate": word_error_rate,
        **boolean_fields,
    }


def language_command(args: argparse.Namespace) -> Path:
    cells = selected_language_cells(args.matrix, args.subset)
    expected_ids = [str(cell.get("id")) for cell in cells]
    rows = [
        row for row in load_engine_rows(args.diagnostics)
        if (row.get("notes") or {}).get("benchRunID") == args.run_id
    ]
    by_cell: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        by_cell.setdefault(str((row.get("notes") or {}).get("benchCell")), []).append(row)
    selected: list[dict[str, Any]] = []
    for cell in cells:
        cell_id = str(cell.get("id"))
        matches = by_cell.get(cell_id, [])
        if len(matches) != 1:
            raise PublicationError(f"language cell {cell_id} has {len(matches)} rows; expected one")
        row = matches[0]
        successful_row(row)
        expected_hint = str(cell.get("expectedHint"))
        if (row.get("notes") or {}).get("languageHint") != expected_hint:
            raise PublicationError(f"language cell {cell_id} has the wrong resolved hint")
        selected.append(row)
    unexpected = sorted(set(by_cell) - set(expected_ids))
    if unexpected:
        raise PublicationError(f"language run has unexpected cells: {', '.join(unexpected)}")
    takes = [minimal_take(index, cell_id, row) for index, (cell_id, row) in enumerate(zip(expected_ids, selected), start=1)]
    output_verified = args.output_gate == "pass"
    sentinels: dict[str, dict[str, Any]] = {}
    if args.platform == "ios":
        for path in args.diagnostics.rglob("device-diagnostics-done.json"):
            record = load_json(path)
            child_run_id = record.get("runID")
            if isinstance(child_run_id, str) and child_run_id.startswith(f"{args.run_id}--"):
                cell_id = child_run_id[len(args.run_id) + 2 :]
                if cell_id in sentinels:
                    raise PublicationError(f"duplicate output-verification sentinel for {cell_id}")
                sentinels[cell_id] = record
    asr_evidence: list[dict[str, Any]] = []
    if output_verified:
        for cell, row, take in zip(cells, selected, takes):
            if cell.get("skipOutputVerification"):
                continue
            cell_id = str(cell.get("id"))
            sentinel = sentinels.get(cell_id)
            if not isinstance(sentinel, dict) or sentinel.get("status") != "ok":
                raise PublicationError(f"language cell {cell_id} lacks successful output-verification evidence")
            evidence = sanitized_asr_evidence(
                cell=cell,
                sentinel=sentinel,
                engine_row=row,
                parent_run_id=args.run_id,
            )
            asr_evidence.append(evidence)
            take["metrics"].update({
                "wordErrorRate": evidence["wordErrorRate"],
                "languageMatchScore": evidence["languageMatchScore"],
                "outputLanguagePass": 1.0,
                "outputAccuracyPass": 1.0,
            })
    for take in takes:
        take["metrics"]["hintCellsPassed"] = float(len(cells))
        take["metrics"]["hintCellsExpected"] = float(len(cells))
        if output_verified:
            expected_output = sum(not bool(cell.get("skipOutputVerification")) for cell in cells)
            take["metrics"]["outputCellsPassed"] = float(expected_output)
            take["metrics"]["outputCellsExpected"] = float(expected_output)
    matrix_scope = "focused" if output_verified else "partial"
    started = args.started_at
    finished = args.finished_at or utc_now()
    fixture_digests: dict[str, str] = {}
    if args.platform == "ios" and any(take["mode"] == "design" for take in takes):
        design_digests = {
            str(sentinels.get(cell_id, {}).get("fixtureDigest"))
            for cell_id, take in zip(expected_ids, takes)
            if take["mode"] == "design" and sentinels.get(cell_id, {}).get("fixtureDigest")
        }
        if len(design_digests) != 1:
            raise PublicationError(
                "iOS language design cells must expose one consistent payload fixture digest"
            )
        fixture_digests["design"] = design_digests.pop()
    elif getattr(args, "design_fixture_digest", None):
        fixture_digests["design"] = args.design_fixture_digest
    require_fixture_cross_check(takes, fixture_digests, source=f"{args.platform} language runner")
    manifest = record_shell(
        kind="language", platform=args.platform, run_id=args.run_id,
        label=args.label or args.run_id, started_at=started, finished_at=finished,
        matrix_scope=matrix_scope, artifact_dir=args.artifact_dir, snapshot=args.snapshot,
        takes=takes, raw_digest=digest_bytes(canonical_bytes({
            "telemetry": selected,
            "outputVerification": asr_evidence,
        })),
        telemetry_schema=max(int(row.get("schemaVersion", 0)) for row in selected),
        qc_algorithm=max(int((row.get("audioQC") or {}).get("algorithmVersion", 1)) for row in selected),
        inputs={"matrixHash": digest_file(args.matrix), "corpusHash": digest_file(args.corpus)},
        hardware=hardware_context(selected),
        hardware_evidence=[
            sentinels[cell_id] for cell_id in expected_ids if cell_id in sentinels
        ] if args.platform == "ios" else None,
        models=exact_models(args.platform, takes),
        crash_delta=crash_delta_from_snapshot(
            args.snapshot,
            expected_scope="macos" if args.platform == "macos" else "ios",
            diagnostics=(getattr(args, "crash_diagnostics", None) or args.diagnostics)
            if args.platform == "ios" else None,
        ),
        executable_paths={"vocello": "build/vocello"} if args.platform == "macos" else {"Vocello": "build/ios/Build/Products/Release-iphoneos/Vocello.app/Vocello"},
        optimization="-Onone",
        classification=("exploratory" if uses_forced_memory_profile(selected) else None),
    )
    return write_and_record(
        args.artifact_dir, manifest,
        defer_record=bool(getattr(args, "defer_record", False)),
    )


def telemetry_overhead_command(args: argparse.Namespace) -> Path:
    verdict = load_json(args.verdict)
    if verdict.get("status") != "pass" or verdict.get("schemaVersion") != 2:
        raise PublicationError("telemetry-overhead verdict is not successful schema v2 evidence")
    summary = verdict.get("summary")
    if not isinstance(summary, dict) or summary.get("pcmParity") is not True or summary.get("failures"):
        raise PublicationError("telemetry-overhead parity or threshold gate did not pass")
    telemetry_schema = summary.get("telemetrySchemaVersion")
    model_id = summary.get("modelID")
    model_runtime_identity = summary.get("modelRuntimeIdentity")
    if telemetry_schema != 7 or model_id != "pro_custom_speed":
        raise PublicationError("telemetry-overhead lacks exact schema-v7 Custom Speed identity")
    typed_identity = runtime_identity({
        "schemaVersion": telemetry_schema,
        "modelID": model_id,
        "modelRuntimeIdentity": model_runtime_identity,
    }, mode="custom", model_id=model_id)
    results = summary.get("results")
    if not isinstance(results, dict):
        raise PublicationError("telemetry-overhead results are missing")
    expected_pcm_keys = {
        f"r{rotation}-t{measured}"
        for rotation in range(1, 4) for measured in range(1, 3)
    }
    empty_pcm_digest = hashlib.sha256(b"").hexdigest()
    pcm_maps: dict[str, dict[str, str]] = {}
    for mode in ("off", "lightweight", "verbose"):
        pcm = (results.get(mode) or {}).get("pcmSHA256")
        if not isinstance(pcm, dict) or set(pcm) != expected_pcm_keys:
            raise PublicationError(
                f"telemetry-overhead mode {mode} lacks six exact PCM digests"
            )
        normalized = {str(key): str(value) for key, value in pcm.items()}
        if any(
            not re.fullmatch(r"[0-9a-f]{64}", value) or value == empty_pcm_digest
            for value in normalized.values()
        ):
            raise PublicationError(
                f"telemetry-overhead mode {mode} contains empty or invalid PCM evidence"
            )
        pcm_maps[mode] = normalized
    if any(pcm_maps[mode] != pcm_maps["off"] for mode in ("lightweight", "verbose")):
        raise PublicationError("telemetry-overhead PCM digest maps do not have exact parity")
    ordered_samples: list[dict[str, Any]] = []
    for mode in ("off", "lightweight", "verbose"):
        samples = (results.get(mode) or {}).get("samples")
        if not isinstance(samples, list) or len(samples) != 6:
            raise PublicationError(f"telemetry-overhead mode {mode} does not contain six measured takes")
        for sample in samples:
            ordered_samples.append({**sample, "telemetryMode": mode})
    ordered_samples.sort(key=lambda sample: (
        int(sample.get("rotation", 0)),
        int(sample.get("modeOrder", 0)),
        int(sample.get("measuredTake", 0)),
    ))
    contexts = summary.get("machineContext")
    context_by_lane: dict[tuple[int, int, str], dict[str, Any]] = {}
    if isinstance(contexts, list):
        for context in contexts:
            if isinstance(context, dict):
                context_by_lane[(
                    int(context.get("rotation", 0)),
                    int(context.get("order", 0)),
                    str(context.get("mode", "")),
                )] = context
    thermal_rank = {"nominal": 0, "fair": 1, "serious": 2, "critical": 3, "unknown": -1}
    takes: list[dict[str, Any]] = []
    for index, sample in enumerate(ordered_samples, start=1):
        mode = str(sample["telemetryMode"])
        rotation = int(sample["rotation"])
        mode_order = int(sample["modeOrder"])
        measured_take = int(sample["measuredTake"])
        context = context_by_lane.get((rotation, mode_order, mode), {})
        before = context.get("before") if isinstance(context.get("before"), dict) else {}
        after = context.get("after") if isinstance(context.get("after"), dict) else {}
        environment = sample.get("environment") if isinstance(sample.get("environment"), dict) else {}
        audio_seconds = finite_number(sample.get("audioSeconds"))
        rtf = finite_number(sample.get("rtf"))
        ttfc = finite_number(sample.get("ttfcMS"))
        if audio_seconds is None or audio_seconds <= 0 or rtf is None or rtf <= 0 or ttfc is None or ttfc < 0:
            raise PublicationError(
                f"telemetry-overhead mode {mode} contains empty audio or invalid timing"
            )
        take_metrics = {
            "rtf": rtf,
            "ttfcMS": ttfc,
            "audioSeconds": audio_seconds,
        }
        load = environment.get("loadAverage1Minute")
        if (value := finite_number(load)) is not None:
            take_metrics["loadAverage1M"] = value
        elif isinstance(before.get("loadAverage"), list) and before["loadAverage"] \
                and (value := finite_number(before["loadAverage"][0])) is not None:
            take_metrics["loadAverage1M"] = value
        if (value := finite_number(environment.get("freeStorageBytes"))) is not None:
            take_metrics["freeStorageBytes"] = value
        elif (value := finite_number(before.get("freeStorageBytes"))) is not None:
            take_metrics["freeStorageBytes"] = value
        if (value := finite_number(environment.get("uptimeSeconds"))) is not None:
            take_metrics["uptimeSeconds"] = value
        elif (value := finite_number(before.get("uptimeSeconds"))) is not None:
            take_metrics["uptimeSeconds"] = value
        if isinstance(environment.get("lowPowerModeEnabled"), bool):
            take_metrics["lowPowerMode"] = 1.0 if environment["lowPowerModeEnabled"] else 0.0
        elif isinstance(before.get("lowPowerMode"), bool):
            take_metrics["lowPowerMode"] = 1.0 if before["lowPowerMode"] else 0.0
        thermal_values = [
            str(value).lower() for value in (
                environment.get("thermalState"), before.get("thermalState"), after.get("thermalState")
            )
            if str(value).lower() in thermal_rank
        ]
        take_thermal = max(thermal_values, key=lambda value: thermal_rank[value]) if thermal_values else "unknown"
        takes.append({
                "takeIndex": index,
                "generationID": str(sample.get("generationID")),
                "cell": f"rotation-{rotation}/order-{mode_order}/{mode}/take-{measured_take}",
                "mode": "custom",
                "modelID": "pro_custom_speed",
                "variant": "speed",
                "warmState": "warm",
                "length": "medium",
                "finishReason": "completed",
                "status": "passed",
                "output": {
                    "readableWAV": True,
                    "atomicPublish": True,
                    "durationSeconds": audio_seconds,
                    "fileDigest": pcm_maps[mode][f"r{rotation}-t{measured_take}"],
                },
                "metrics": take_metrics,
                "thermalState": take_thermal,
                "warnings": [],
                **typed_identity,
            })
    overhead_hardware: dict[str, Any] = {}
    if isinstance(contexts, list) and contexts and isinstance(contexts[0], dict):
        before = contexts[0].get("before")
        if isinstance(before, dict):
            load = before.get("loadAverage")
            if isinstance(load, list) and load and (value := finite_number(load[0])) is not None:
                overhead_hardware["loadAverage1M"] = value
            if (value := finite_number(before.get("freeStorageBytes"))) is not None:
                overhead_hardware["freeStorageBytes"] = int(value)
            if (value := finite_number(before.get("uptimeSeconds"))) is not None:
                overhead_hardware["uptimeSeconds"] = value
    manifest = record_shell(
        kind="telemetry-overhead", platform="macos", run_id=str(verdict.get("runID")),
        label=str(verdict.get("runID")), started_at=str(verdict.get("startedAt")),
        finished_at=str(verdict.get("completedAt")), matrix_scope="focused",
        artifact_dir=args.artifact_dir, snapshot=args.snapshot, takes=takes,
        raw_digest=digest_file(args.verdict), telemetry_schema=telemetry_schema,
        qc_algorithm="not-applicable",
        inputs={"matrixHash": digest_bytes(canonical_bytes({
            "seed": summary.get("seed"),
            "modeOrderRotations": summary.get("modeOrderRotations"),
            "warmupTakesPerModePerRotation": summary.get("warmupTakesPerModePerRotation"),
            "measuredWarmTakesPerModePerRotation": summary.get("measuredWarmTakesPerModePerRotation"),
        }))},
        hardware=overhead_hardware,
        models=exact_models("macos", takes),
        crash_delta=crash_delta_from_snapshot(args.snapshot, expected_scope="macos"),
        executable_paths={"vocello": "build/vocello"},
        optimization="-Onone",
    )
    return write_and_record(args.artifact_dir, manifest)


def _xml_tag(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1].lower().replace("_", "-")


def _pid_from_text(value: str | None) -> int | None:
    if not value:
        return None
    token = value.strip()
    try:
        return int(token, 0)
    except ValueError:
        pass
    for pattern in (r"\bpid\s*[=:]\s*(\d+)\b", r"\((\d+)\)\s*$"):
        match = re.search(pattern, token, re.IGNORECASE)
        if match:
            return int(match.group(1))
    return None


def _element_pid(element: ET.Element) -> int | None:
    attributes = {
        key.rsplit("}", 1)[-1].lower().replace("_", "-"): value
        for key, value in element.attrib.items()
    }
    for key in ("pid", "process-id", "process-identifier"):
        if (pid := _pid_from_text(attributes.get(key))) is not None:
            return pid
    if _xml_tag(element) in {"pid", "process-id", "process-identifier", "process"}:
        for key in ("fmt", "formatted", "value", "name"):
            if (pid := _pid_from_text(attributes.get(key))) is not None:
                return pid
        return _pid_from_text(element.text)
    return None


def _process_reference_pids(root: ET.Element) -> dict[str, int]:
    references: dict[str, int] = {}
    for element in root.iter():
        if _xml_tag(element) != "process":
            continue
        pid = _element_pid(element)
        if pid is None:
            for child in element:
                if (pid := _element_pid(child)) is not None:
                    break
        identifier = element.get("id")
        if identifier and pid is not None:
            references[identifier] = pid
    return references


def _row_process_pid(row: ET.Element, references: dict[str, int]) -> int | None:
    if (direct := _element_pid(row)) is not None:
        return direct
    observed: set[int] = set()
    for element in row.iter():
        tag = _xml_tag(element)
        if tag not in {"pid", "process-id", "process-identifier", "process"}:
            continue
        if (pid := _element_pid(element)) is not None:
            observed.add(pid)
        reference = element.get("ref")
        if reference in references:
            observed.add(references[reference])
    return next(iter(observed)) if len(observed) == 1 else None


def extract_trace_data_summary(
    trace: Path,
    schemas: Iterable[str],
    *,
    run_id: str,
    target_pid: int,
    expected_correlations: set[tuple[str, int, str]],
) -> dict[str, Any]:
    relevant = sorted({
        schema for schema in schemas
        if re.fullmatch(r"[A-Za-z0-9._-]+", schema)
        and any(token in schema.lower() for token in (
            "cpu-profile", "time-profile", "signpost", "allocation", "energy", "gpu", "wakeup",
        ))
    })
    if not relevant:
        raise PublicationError("xctrace table-of-contents exposes no performance-data schema")

    rows_by_schema: dict[str, int] = {}
    cpu_weights_ns: list[float] = []
    cpu_cycle_weights: list[float] = []
    cpu_sample_times_ns: list[float] = []
    signpost_events = 0
    correlated_signposts = 0
    observed_correlations: set[tuple[str, int, str]] = set()
    for schema in relevant:
        descriptor, temporary = tempfile.mkstemp(prefix="vocello-xctrace-", suffix=".xml")
        os.close(descriptor)
        try:
            completed = subprocess.run(
                [
                    "xcrun", "xctrace", "export", "--input", str(trace),
                    "--xpath", f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
                    "--output", temporary,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            if completed.returncode:
                detail = completed.stderr.strip() or completed.stdout.strip() or "unknown export failure"
                raise PublicationError(f"could not export xctrace schema {schema}: {detail}")
            try:
                root = ET.parse(temporary).getroot()
            except (OSError, ET.ParseError) as error:
                raise PublicationError(f"xctrace schema {schema} exported invalid XML") from error
            all_rows = [element for element in root.iter() if _xml_tag(element) == "row"]
            process_references = _process_reference_pids(root)
            rows = [
                row for row in all_rows
                if _row_process_pid(row, process_references) == target_pid
            ]
            rows_by_schema[schema] = len(rows)
            if schema in {"cpu-profile", "time-profile"}:
                resolved: dict[tuple[str, str], float] = {}
                for element in root.iter():
                    tag = element.tag.rsplit("}", 1)[-1]
                    if tag not in {"cycle-weight", "weight", "sample-time"} or not element.get("id"):
                        continue
                    try:
                        resolved[(tag, element.get("id", ""))] = float((element.text or "").strip())
                    except ValueError:
                        continue
                for row in rows:
                    fields = [("sample-time", cpu_sample_times_ns)]
                    fields.append(
                        ("cycle-weight", cpu_cycle_weights)
                        if schema == "cpu-profile" else ("weight", cpu_weights_ns)
                    )
                    for tag, destination in fields:
                        element = next(
                            (child for child in row.iter() if child.tag.rsplit("}", 1)[-1] == tag),
                            None,
                        )
                        if element is None:
                            continue
                        value = resolved.get((tag, element.get("ref", "")))
                        if value is None:
                            try:
                                value = float((element.text or "").strip())
                            except ValueError:
                                continue
                        destination.append(value)
            if "signpost" in schema.lower():
                signpost_events += len(rows)
                elements_by_id = {
                    element.get("id"): element
                    for element in root.iter()
                    if element.get("id")
                }

                def resolved_text(element: ET.Element, seen: frozenset[str] = frozenset()) -> str:
                    reference = element.get("ref")
                    if reference and reference not in seen and reference in elements_by_id:
                        return resolved_text(elements_by_id[reference], seen | {reference})
                    rendered = element.get("fmt")
                    if rendered:
                        return rendered
                    pieces = [element.text.strip()] if element.text and element.text.strip() else []
                    pieces.extend(
                        value for child in element
                        if (value := resolved_text(child, seen))
                    )
                    return " ".join(pieces)

                for row in rows:
                    serialized = " ".join(
                        value for element in row.iter()
                        if (value := resolved_text(element))
                    )
                    generation = re.search(r"\bgenerationID=\s*([A-Za-z0-9._-]+)", serialized)
                    take_index = re.search(r"\btakeIndex=\s*([1-9][0-9]*)", serialized)
                    cell = re.search(r"\bcell=\s*([^\s<]+)", serialized)
                    run = re.search(r"\brunID=\s*([A-Za-z0-9._-]+)", serialized)
                    if run is None or run.group(1) != run_id or not all(
                        (generation, take_index, cell)
                    ):
                        continue
                    correlation = (
                        generation.group(1), int(take_index.group(1)), cell.group(1)
                    )
                    if correlation in expected_correlations:
                        correlated_signposts += 1
                        observed_correlations.add(correlation)
        finally:
            Path(temporary).unlink(missing_ok=True)

    captured_rows = sum(rows_by_schema.values())
    if captured_rows == 0:
        raise PublicationError("xctrace exported no performance data rows")
    if not ({"cpu-profile", "time-profile"} & set(relevant)):
        raise PublicationError("trace lacks an exportable CPU Profiler or Time Profiler table")
    if not cpu_sample_times_ns:
        raise PublicationError("CPU profile trace contains no target-process samples")
    correlation_fields_verified = correlated_signposts > 0
    if signpost_events == 0 or not correlation_fields_verified:
        raise PublicationError("trace lacks a run/generation/take/cell-correlated signpost")
    missing_correlations = expected_correlations - observed_correlations
    if missing_correlations:
        raise PublicationError(
            f"trace lacks exact signpost correlation for {len(missing_correlations)} profiled take(s)"
        )
    summary = {
        "capturedRowsBySchema": rows_by_schema,
        "capturedDataRowCount": captured_rows,
        "cpuSampleCount": len(cpu_sample_times_ns),
        "cpuSampleSpanMS": round(
            (max(cpu_sample_times_ns) - min(cpu_sample_times_ns)) / 1_000_000.0, 6
        ) if len(cpu_sample_times_ns) >= 2 else 0.0,
        "signpostEventCount": signpost_events,
        "correlatedSignpostEventCount": correlated_signposts,
        "correlationFieldsVerified": correlation_fields_verified,
    }
    if cpu_weights_ns:
        summary["cpuSampleWeightMS"] = round(sum(cpu_weights_ns) / 1_000_000.0, 6)
    if cpu_cycle_weights:
        summary["cpuCycleWeight"] = int(sum(cpu_cycle_weights))
    return summary


def trace_evidence(
    args: argparse.Namespace,
    *,
    expected_correlations: set[tuple[str, int, str]],
) -> dict[str, Any]:
    if not expected_correlations:
        raise PublicationError("profile publication has no expected take correlation")
    if not args.trace.is_dir():
        raise PublicationError(f"trace is missing: {args.trace}")
    if not args.toc.is_file() or args.toc.stat().st_size == 0:
        raise PublicationError("xctrace table-of-contents export is missing or empty")
    try:
        toc = ET.parse(args.toc)
    except (OSError, ET.ParseError) as error:
        raise PublicationError(f"xctrace table-of-contents is invalid XML: {error}") from error
    try:
        artifact_reference = args.trace.resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError as error:
        raise PublicationError("trace must remain under the repository's untracked build directory") from error
    table_count = sum(
        element.tag.rsplit("}", 1)[-1].lower() == "table"
        for element in toc.getroot().iter()
    )
    if table_count == 0:
        raise PublicationError("xctrace table-of-contents contains no captured data tables")
    process_entries: list[tuple[str, int | None]] = []
    for element in toc.getroot().iter():
        tag = element.tag.rsplit("}", 1)[-1].lower()
        if tag != "process":
            continue
        attributes = {
            key.rsplit("}", 1)[-1].lower().replace("_", "-"): value
            for key, value in element.attrib.items()
        }
        name = next(
            (attributes[key] for key in ("name", "process-name", "executable", "path") if attributes.get(key)),
            None,
        )
        pid_raw = next(
            (attributes[key] for key in ("pid", "process-id", "process-identifier") if attributes.get(key)),
            None,
        )
        if name is None:
            for child in element:
                child_tag = child.tag.rsplit("}", 1)[-1].lower().replace("_", "-")
                if child_tag in {"name", "process-name", "executable", "path"} and child.text:
                    name = child.text.strip()
                    break
        if pid_raw is None:
            for child in element:
                child_tag = child.tag.rsplit("}", 1)[-1].lower().replace("_", "-")
                if child_tag in {"pid", "process-id", "process-identifier"} and child.text:
                    pid_raw = child.text.strip()
                    break
        pid: int | None = None
        if pid_raw is not None:
            try:
                pid = int(pid_raw, 0)
            except ValueError:
                pid = None
        if name:
            process_entries.append((Path(name).name, pid))
    matching_processes = [entry for entry in process_entries if entry[0] == args.target_process]
    if not matching_processes:
        raise PublicationError(
            f"xctrace table-of-contents does not contain target process {args.target_process!r}"
        )
    requested_pid = getattr(args, "target_pid", None)
    if requested_pid is not None and not any(pid == requested_pid for _, pid in matching_processes):
        raise PublicationError(
            f"xctrace table-of-contents does not contain target PID {requested_pid}"
        )
    if requested_pid is None:
        matching_pids = {pid for _, pid in matching_processes if pid is not None}
        if len(matching_pids) != 1:
            raise PublicationError(
                "xctrace table-of-contents does not resolve the target process to one exact PID"
            )
        target_pid = next(iter(matching_pids))
    else:
        target_pid = requested_pid
    schemas: set[str] = set()
    signpost_schemas: set[str] = set()
    for element in toc.getroot().iter():
        tag = element.tag.rsplit("}", 1)[-1].lower()
        if tag not in {"table", "schema"}:
            continue
        name = next(
            (value for key, value in element.attrib.items() if key.rsplit("}", 1)[-1].lower() in {"schema", "name", "id"}),
            tag,
        )
        token = str(name).strip().lower()
        schemas.add(token)
        if "signpost" in token:
            signpost_schemas.add(token)
    extracted = extract_trace_data_summary(
        args.trace,
        schemas,
        run_id=str(args.run_id),
        target_pid=target_pid,
        expected_correlations=expected_correlations,
    )
    return {
        "digest": digest_bytes(canonical_bytes([
            [path.relative_to(args.trace).as_posix(), digest_file(path)]
            for path in sorted(args.trace.rglob("*")) if path.is_file()
        ])),
        "template": Path(args.template).name,
        "durationSeconds": float(args.duration),
        "validated": True,
        "summary": {
            "artifact": artifact_reference,
            "tocDigest": digest_file(args.toc),
            "tableCount": table_count,
            "schemaCount": len(schemas),
            "signpostSchemaCount": len(signpost_schemas),
            "processCount": len(set(process_entries)),
            "targetProcess": args.target_process,
            "targetPIDVerified": True,
            **extracted,
        },
    }


def _profile_correlations(args: argparse.Namespace, *, ios: bool) -> set[tuple[str, int, str]]:
    if ios:
        sentinel = load_json(args.sentinel)
        generation_id = sentinel.get("generationID")
        mode = sentinel.get("mode")
        variant = sentinel.get("variant", "speed")
        if (
            sentinel.get("runID") != args.run_id
            or not isinstance(generation_id, str) or not generation_id
            or not isinstance(mode, str) or not mode
            or not isinstance(variant, str) or not variant
        ):
            raise PublicationError("iOS profile sentinel lacks exact signpost identity")
        return {(generation_id, 1, f"{mode}/{variant}/device")}

    results = load_json(args.results)
    takes = results.get("takes")
    if results.get("runID") != args.run_id or not isinstance(takes, list) or not takes:
        raise PublicationError("profile bench results lack exact signpost identity")
    expected: set[tuple[str, int, str]] = set()
    for index, take in enumerate(takes, start=1):
        if not isinstance(take, dict) or take.get("takeIndex") != index:
            raise PublicationError("profile bench take indices are not exact")
        generation_id = take.get("generationID")
        cell = take.get("cell")
        if not isinstance(generation_id, str) or not generation_id or not isinstance(cell, str) or not cell:
            raise PublicationError("profile bench take lacks generation or cell identity")
        expected.add((generation_id, index, cell))
    if len(expected) != len(takes):
        raise PublicationError("profile bench correlations are not unique")
    return expected


def profile_command(args: argparse.Namespace) -> Path:
    trace = trace_evidence(
        args, expected_correlations=_profile_correlations(args, ios=False)
    )
    return engine_command(args, kind="instrument-profile", trace=trace)


def ios_profile_command(args: argparse.Namespace) -> Path:
    trace = trace_evidence(
        args, expected_correlations=_profile_correlations(args, ios=True)
    )
    return ios_engine_command(args, kind="instrument-profile", trace=trace)


def prosody_command(args: argparse.Namespace) -> Path:
    result = load_json(args.results)
    if result.get("status") != "pass" or result.get("analysisFailureCount") != 0:
        raise PublicationError("prosody calibration did not pass without analysis failures")
    if int(result.get("goodClipCount", 0)) < 2 or int(result.get("badClipCount", 0)) < 2:
        raise PublicationError("prosody calibration corpus lacks the required good/bad clips")
    profile = load_json(args.profile)
    profile_digest = digest_file(args.profile)
    if result.get("profileDigest") != profile_digest:
        raise PublicationError("prosody result does not identify the published profile")
    thresholds = profile.get("thresholds")
    flag_rates = result.get("flagRates")
    if not isinstance(thresholds, dict) or not isinstance(flag_rates, dict):
        raise PublicationError("prosody calibration lacks threshold or flag-rate evidence")
    metric_sources = {
        "goodClipCount": result.get("goodClipCount"),
        "badClipCount": result.get("badClipCount"),
        "targetFalsePositiveRate": result.get("targetFalsePositiveRate"),
        "observedFalsePositiveRate": flag_rates.get("false_positive_rate"),
        "observedTruePositiveRate": flag_rates.get("true_positive_rate"),
        "goodFlagRate": flag_rates.get("good_flag_rate"),
        "badFlagRate": flag_rates.get("bad_flag_rate"),
        "monotoneF0StdThresholdHz": thresholds.get("monotone_f0_std_hz"),
        "monotoneTurningPointsThresholdPerSecond": thresholds.get("monotone_turning_points_per_sec"),
        "rushedSyllableRateThresholdHz": thresholds.get("rushed_syllable_rate_hz"),
        "rushedMaximumPauseRatio": thresholds.get("rushed_max_pause_ratio"),
        "flatEnvelopeRoughnessThreshold": thresholds.get("flat_envelope_roughness"),
        "flatRateCVThreshold": thresholds.get("flat_rate_cv"),
        "maximumPauseThresholdSeconds": thresholds.get("pause_max_seconds"),
        "maximumPauseRatioThreshold": thresholds.get("pause_ratio_max"),
    }
    metrics = {key: finite_number(value) for key, value in metric_sources.items()}
    if any(value is None for value in metrics.values()):
        raise PublicationError("prosody calibration contains non-finite aggregate evidence")
    run_id = str(result.get("runID"))
    take = {
        "takeIndex": 1,
        "generationID": f"{run_id}-analysis",
        "cell": "prosody-calibration/corpus",
        "mode": "not-applicable",
        "modelID": "not-applicable",
        "variant": "not-applicable",
        "warmState": "not-applicable",
        "length": "not-applicable",
        "finishReason": "completed",
        "status": "passed",
        "metrics": metrics,
        "warnings": [],
    }
    combined_digest = digest_bytes(canonical_bytes({
        "results": result,
        "profileDigest": profile_digest,
    }))
    manifest = record_shell(
        kind="prosody-calibration", platform="macos", run_id=run_id,
        label=run_id, started_at=str(result.get("startedAt")),
        finished_at=str(result.get("finishedAt")), matrix_scope="focused",
        artifact_dir=args.artifact_dir, snapshot=args.snapshot, takes=[take],
        raw_digest=combined_digest, telemetry_schema="not-applicable", qc_algorithm="not-applicable",
        inputs={
            "corpusHash": str(result.get("corpusDigest")),
            "analysisProfileHash": profile_digest,
        },
        # Calibration analyzes an existing labeled corpus and launches no app or
        # engine process. Its crash delta is therefore explicitly not applicable;
        # the registry's boolean means that this benchmark introduced no target crash.
        crash_delta={"passed": True, "count": 0},
        executable_paths={},
        optimization="not-applicable",
    )
    return write_and_record(args.artifact_dir, manifest)


def add_snapshot(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)


def add_engine(parser: argparse.ArgumentParser) -> None:
    add_snapshot(parser)
    parser.add_argument("--platform", choices=("macos", "ios"), required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--diagnostics", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--label", default="")
    parser.add_argument(
        "--defer-record", action="store_true",
        help="write validated benchmark-evidence.json without updating tracked history",
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    snapshot = subparsers.add_parser("snapshot", help="capture pre-run Git provenance")
    snapshot.add_argument("--output", type=Path, required=True)
    snapshot.add_argument("--crash-scope", choices=("macos", "ios", "none"), required=True)
    snapshot.add_argument("--crash-diagnostics", type=Path)

    engine = subparsers.add_parser("engine", help="publish a vocello bench run")
    add_engine(engine)

    ios_engine = subparsers.add_parser("ios-engine", help="publish one physical-iPhone headless run")
    add_snapshot(ios_engine)
    ios_engine.add_argument("--run-id", required=True)
    ios_engine.add_argument("--sentinel", type=Path, required=True)
    ios_engine.add_argument("--diagnostics", type=Path, required=True)
    ios_engine.add_argument("--crash-diagnostics", type=Path)
    ios_engine.add_argument("--label", default="")
    ios_engine.add_argument("--defer-record", action="store_true")

    language = subparsers.add_parser("language", help="publish a gated language matrix")
    add_snapshot(language)
    language.add_argument("--platform", choices=("macos", "ios"), required=True)
    language.add_argument("--run-id", required=True)
    language.add_argument("--diagnostics", type=Path, required=True)
    language.add_argument("--crash-diagnostics", type=Path)
    language.add_argument("--matrix", type=Path, required=True)
    language.add_argument("--corpus", type=Path, required=True)
    language.add_argument("--subset", choices=("quick", "full"), required=True)
    language.add_argument("--output-gate", choices=("pass", "not-performed"), required=True)
    language.add_argument("--started-at", required=True)
    language.add_argument("--finished-at")
    language.add_argument("--label", default="")
    language.add_argument("--design-fixture-digest")
    language.add_argument("--defer-record", action="store_true")

    overhead = subparsers.add_parser("telemetry-overhead", help="publish the rotated parity lane")
    add_snapshot(overhead)
    overhead.add_argument("--verdict", type=Path, required=True)

    profile = subparsers.add_parser("profile", help="publish a validated Instruments capture")
    add_engine(profile)
    profile.add_argument("--trace", type=Path, required=True)
    profile.add_argument("--toc", type=Path, required=True)
    profile.add_argument("--template", required=True)
    profile.add_argument("--duration", type=float, required=True)
    profile.add_argument("--target-process", required=True)
    profile.add_argument("--target-pid", type=int)

    ios_profile = subparsers.add_parser("ios-profile", help="publish a validated physical-iPhone Instruments capture")
    add_snapshot(ios_profile)
    ios_profile.add_argument("--run-id", required=True)
    ios_profile.add_argument("--sentinel", type=Path, required=True)
    ios_profile.add_argument("--diagnostics", type=Path, required=True)
    ios_profile.add_argument("--crash-diagnostics", type=Path)
    ios_profile.add_argument("--label", default="")
    ios_profile.add_argument("--trace", type=Path, required=True)
    ios_profile.add_argument("--toc", type=Path, required=True)
    ios_profile.add_argument("--template", required=True)
    ios_profile.add_argument("--duration", type=float, required=True)
    ios_profile.add_argument("--target-process", required=True)
    ios_profile.add_argument("--target-pid", type=int)
    ios_profile.add_argument("--defer-record", action="store_true")

    prosody = subparsers.add_parser("prosody", help="publish a successful calibration corpus")
    add_snapshot(prosody)
    prosody.add_argument("--results", type=Path, required=True)
    prosody.add_argument("--profile", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    try:
        if args.command == "snapshot":
            capture_snapshot(args.output, args.crash_scope, args.crash_diagnostics)
            print(args.output)
        elif args.command == "engine":
            print(engine_command(args))
        elif args.command == "ios-engine":
            print(ios_engine_command(args))
        elif args.command == "language":
            print(language_command(args))
        elif args.command == "telemetry-overhead":
            print(telemetry_overhead_command(args))
        elif args.command == "profile":
            print(profile_command(args))
        elif args.command == "ios-profile":
            print(ios_profile_command(args))
        elif args.command == "prosody":
            print(prosody_command(args))
        return 0
    except (PublicationError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"benchmark publication: FAIL: {error}", file=sys.stderr)
        if args.command != "snapshot" and "repair:" not in str(error):
            print(f"repair: {shlex.join([sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
