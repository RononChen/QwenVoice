#!/usr/bin/env python3
"""Codex Computer Use lifecycle and evidence harness for Vocello on a physical iPhone."""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

LIB_DIR = Path(__file__).resolve().parent
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))
from computer_use_routing import new_service_crash_reports, routing_status, service_crash_reports


ROOT = Path(__file__).resolve().parents[2]
BUILD_ROOT = ROOT / "build" / "ios" / "agent-ui"
SCENARIOS = ROOT / "config" / "ios-ui-scenarios.json"
IMPACT = ROOT / "config" / "ios-test-impact.json"
ATTESTATION = ROOT / "qa" / "ios-ui-attestation.json"
CURRENT = BUILD_ROOT / "current-run.json"
APP_BUNDLE_ID = "com.patricedery.vocello"
MIRROR_BUNDLE_ID = "com.apple.ScreenContinuity"
SUITES = ("quick", "full", "benchmark")
SUITE_SATISFIERS = {"quick": {"quick", "full"}, "full": {"full"}, "benchmark": {"benchmark"}}


class HarnessError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise HarnessError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise HarnessError(f"invalid JSON in {path}: {exc}") from exc


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=ROOT, check=check, text=True, capture_output=True)


def sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def relative_files(*, build_inputs_only: bool = False) -> list[Path]:
    if build_inputs_only:
        candidates = [
            Path("project.yml"),
            Path("Package.resolved"),
            Path("Sources/Resources/qwenvoice_contract.json"),
            Path("Sources/Resources/qwenvoice_ios_model_catalog.json"),
            Path("third_party_patches/mlx-audio-swift/Package.swift"),
        ]
        return [path for path in candidates if (ROOT / path).is_file()]
    roots = (
        ".agents", ".github", "Sources", "config", "scripts",
        "third_party_patches/mlx-audio-swift/Sources",
    )
    values = run(["/usr/bin/git", "ls-files", "--cached", "--others", "--exclude-standard"]).stdout.splitlines()
    paths = {
        Path(value) for value in values
        if value and (ROOT / value).is_file()
        and any(value == root or value.startswith(root + "/") for root in roots)
    }
    for value in ("AGENTS.md", "project.yml", "Package.resolved"):
        if (ROOT / value).is_file():
            paths.add(Path(value))
    paths.discard(ATTESTATION.relative_to(ROOT))
    return sorted(paths, key=lambda path: path.as_posix())


def fingerprint(*, build_inputs_only: bool = False) -> str:
    digest = hashlib.sha256()
    for relative in relative_files(build_inputs_only=build_inputs_only):
        digest.update(relative.as_posix().encode())
        digest.update(b"\0")
        digest.update((ROOT / relative).read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def toolchain_identity() -> dict:
    xcode = run(["/usr/bin/xcodebuild", "-version"]).stdout.strip()
    swift = run(["/usr/bin/xcrun", "swift", "--version"]).stdout.strip()
    digest = hashlib.sha256((xcode + "\n" + swift).encode()).hexdigest()
    return {"xcode": xcode, "swift": swift, "digest": digest}


def _device_records() -> list[dict]:
    with tempfile.NamedTemporaryFile(suffix=".json") as handle:
        result = run(["/usr/bin/xcrun", "devicectl", "list", "devices", "--json-output", handle.name], check=False)
        if result.returncode != 0:
            return []
        try:
            payload = json.loads(Path(handle.name).read_text())
        except (json.JSONDecodeError, OSError):
            return []
    return (payload.get("result") or {}).get("devices") or []


def resolve_device() -> tuple[str | None, dict]:
    requested = os.environ.get("QVOICE_IOS_DEVICE_ID")
    devices = _device_records()
    candidates = []
    for device in devices:
        identifier = str(device.get("identifier") or "")
        name = str((device.get("deviceProperties") or {}).get("name") or device.get("name") or "")
        if requested and requested not in (identifier, name):
            continue
        connection = device.get("connectionProperties") or {}
        pairing = connection.get("pairingState")
        tunnel = connection.get("tunnelState")
        if pairing == "paired" or tunnel in ("connected", "available"):
            candidates.append(device)
    if not candidates:
        return None, {}
    device = candidates[0]
    properties = device.get("deviceProperties") or {}
    hardware = device.get("hardwareProperties") or {}
    identity = {
        "model": properties.get("marketingName") or hardware.get("marketingName") or properties.get("modelCode") or "iPhone",
        "platform": properties.get("platform") or "iOS",
        "osVersion": properties.get("osVersionNumber") or properties.get("osVersion") or None,
    }
    return str(device.get("identifier")), identity


def validate_config() -> list[str]:
    errors: list[str] = []
    scenarios = read_json(SCENARIOS)
    impact = read_json(IMPACT)
    if scenarios.get("schemaVersion") != 1:
        errors.append("ios-ui-scenarios schemaVersion must be 1")
    if scenarios.get("driver") != "bundled-computer-use":
        errors.append("iOS UI driver must be bundled-computer-use")
    if scenarios.get("surface") != MIRROR_BUNDLE_ID:
        errors.append("iOS UI surface must be iPhone Mirroring")
    ids = {item.get("id") for item in scenarios.get("scenarios", [])}
    for name, suite in (scenarios.get("suites") or {}).items():
        missing = set(suite.get("includes") or []) - ids
        if missing:
            errors.append(f"suite {name} references missing scenarios: {sorted(missing)}")
    if impact.get("schemaVersion") != 1:
        errors.append("ios-test-impact schemaVersion must be 1")
    return errors


def load_run(reference: str | None = None) -> tuple[Path, dict]:
    if reference:
        path = Path(reference)
        if not path.is_absolute():
            candidate = BUILD_ROOT / reference
            path = candidate if candidate.exists() else ROOT / reference
        directory = path if path.is_dir() else path.parent
    else:
        pointer = read_json(CURRENT)
        directory = Path(pointer["runDirectory"])
    report = read_json(directory / "report.json")
    return directory, report


def store_run(directory: Path, report: dict) -> None:
    report["updatedAt"] = utc_now()
    write_json(directory / "report.json", report)


def routing_ready_for_suite(routing: dict) -> bool:
    return bool(routing.get("readyForSuite", routing.get("ready", False)))


def cmd_doctor(args: argparse.Namespace) -> None:
    config_errors = validate_config()
    routing = routing_status()
    device_id, identity = resolve_device()
    checks = {
        "suite": args.suite,
        "repositoryReady": not config_errors and SCENARIOS.is_file() and IMPACT.is_file(),
        "deviceReady": device_id is not None,
        "deviceIdentity": identity,
        "computerUseRequired": True,
        "computerUseServiceProcesses": routing["computerUseServiceProcesses"],
        "computerUseServiceRunning": routing["computerUseServiceRunning"],
        "computerUseServicePathVerified": routing["computerUseServicePathVerified"],
        "appBundledSourceApp": routing["appBundledSourceApp"],
        "installedPluginCacheSourceApp": routing["installedPluginCacheSourceApp"],
        "desktopManagedRuntimeApp": routing["desktopManagedRuntimeApp"],
        "sourceRuntimeIdentityMatch": routing["sourceRuntimeIdentityMatch"],
        "desktopManagedRuntimeRunning": routing["desktopManagedRuntimeRunning"],
        "pluginFallbackRunning": routing["pluginFallbackRunning"],
        "duplicateRuntimeDetected": routing["duplicateRuntimeDetected"],
        "routingStatus": routing["routingStatus"],
        "routingExpectationSource": routing["routingExpectationSource"],
        "macOSVersion": routing["macOSVersion"],
        "desktopVersion": routing["desktopVersion"],
        "pluginVersion": routing["pluginVersion"],
        "helperVersion": routing["helperVersion"],
        "dyldCompatibilityFailure": routing["dyldCompatibilityFailure"],
        "crashClassification": routing["crashClassification"],
        "computerUseConfigEntries": routing["computerUseConfigEntries"],
        "pluginManagedEntryPresent": routing["pluginManagedEntryPresent"],
        "commandConfiguredEntryPresent": routing["commandConfiguredEntryPresent"],
        "staleCommandPathPresent": routing["staleCommandPathPresent"],
        "duplicateTransportDefinitionPresent": routing["duplicateTransportDefinitionPresent"],
        "mcpClientProcessCount": routing["mcpClientProcessCount"],
        "turnEndedClientCount": routing["turnEndedClientCount"],
        "nodeReplProcessCount": routing["nodeReplProcessCount"],
        "stdioAppServerCount": routing["stdioAppServerCount"],
        "zombieChildCount": routing["zombieChildCount"],
        "staleClientSetDetected": routing["staleClientSetDetected"],
        "computerUsePluginInstalled": routing.get("computerUsePluginInstalled"),
        "computerUsePluginEnabled": routing.get("computerUsePluginEnabled"),
        "computerUsePluginVersion": routing.get("computerUsePluginVersion"),
        "computerUsePluginInventoryCachePath": routing.get("computerUsePluginInventoryCachePath"),
        "installedPluginInventoryCacheRoot": routing.get("installedPluginInventoryCacheRoot"),
        "installedPluginInventoryCacheApp": routing.get("installedPluginInventoryCacheApp"),
        "pluginInventoryCachePathConsistent": routing.get("pluginInventoryCachePathConsistent"),
        "computerUseBundledContentVariant": routing.get("computerUseBundledContentVariant"),
        "computerUseUsesNodeRepl": routing.get("computerUseUsesNodeRepl"),
        "nodeReplServerDeclared": routing.get("nodeReplServerDeclared"),
        "nodeReplServerEnabled": routing.get("nodeReplServerEnabled"),
        "nodeReplServerCommand": routing.get("nodeReplServerCommand"),
        "nodeReplServerArgs": routing.get("nodeReplServerArgs"),
        "expectedNodeReplCommand": routing.get("expectedNodeReplCommand"),
        "nodeReplServerCommandMatchesDesktop": routing.get("nodeReplServerCommandMatchesDesktop"),
        "nodeReplConfiguredSourceMatchesInventoryCache": routing.get("nodeReplConfiguredSourceMatchesInventoryCache"),
        "computerUseManifestServerDeclared": routing.get("computerUseManifestServerDeclared"),
        "computerUseManifestMirrorEntryPresent": routing.get("computerUseManifestMirrorEntryPresent"),
        "computerUseManifestMirrorEnabled": routing.get("computerUseManifestMirrorEnabled"),
        "computerUseManifestMirrorConflicting": routing.get("computerUseManifestMirrorConflicting"),
        "computerUseServerAvailable": routing.get("computerUseServerAvailable"),
        "computerUseServerDeclared": routing.get("computerUseServerDeclared"),
        "computerUseServerEnabled": routing.get("computerUseServerEnabled"),
        "computerUseSkillPath": routing.get("computerUseSkillPath"),
        "computerUseSkillInstalled": routing.get("computerUseSkillInstalled"),
        "computerUseSkillExpectedAvailable": routing.get("computerUseSkillExpectedAvailable"),
        "computerUseWrapperPath": routing.get("computerUseWrapperPath"),
        "computerUseWrapperAvailable": routing.get("computerUseWrapperAvailable"),
        "computerUseWrapperSHA256": routing.get("computerUseWrapperSHA256"),
        "computerUseProcessFamilies": routing.get("computerUseProcessFamilies"),
        "notificationClientProcessCount": routing.get("notificationClientProcessCount"),
        "helperBuild": routing.get("helperBuild"),
        "helperUUID": routing.get("helperUUID"),
        "helperSHA256": routing.get("helperSHA256"),
        "knownBadHelperDetected": routing.get("knownBadHelperDetected"),
        "knownBadHelperRule": routing.get("knownBadHelperRule"),
        "latestCurrentHelperCrash": routing.get("latestCurrentHelperCrash"),
        "routingReady": routing.get("routingReady"),
        "routingReadyForDiagnostic": routing.get("readyForDiagnostic"),
        "routingReadyForSuite": routing.get("readyForSuite"),
        "suiteBlockers": routing.get("suiteBlockers") or [],
        "configErrors": config_errors,
        "routingErrors": routing.get("routingErrors") or [],
    }
    checks["readyForSession"] = (
        checks["repositoryReady"]
        and checks["deviceReady"]
        and routing_ready_for_suite(routing)
    )
    checks["ready"] = checks["readyForSession"]
    print(json.dumps(checks, indent=2, sort_keys=True) if args.json else "\n".join(f"{key}: {value}" for key, value in checks.items()))
    if not checks["readyForSession"]:
        raise HarnessError("iOS Computer Use doctor found blocking problems")


def cmd_routing_audit(_: argparse.Namespace) -> None:
    result = routing_status()
    print(json.dumps(result, indent=2, sort_keys=True))
    if not result.get("routingReady", result.get("ready", False)):
        raise HarnessError("Computer Use routing audit failed")


def require_computer_use_session(report: dict | None = None) -> dict:
    routing = routing_status()
    errors = list(routing["errors"])
    if report is not None:
        delta = new_service_crash_reports(report.get("computerUseCrashReportsAtStart") or [])
        if delta:
            errors.append("new SkyComputerUseService crash report detected: " + ", ".join(item["path"] for item in delta))
    if errors:
        raise HarnessError("Computer Use session is not safe: " + "; ".join(errors))
    return routing


def cmd_start(args: argparse.Namespace) -> None:
    errors = validate_config()
    routing = routing_status()
    device_id, identity = resolve_device()
    if errors or not routing_ready_for_suite(routing) or not device_id:
        raise HarnessError("doctor prerequisites are not satisfied; run doctor --json")
    launch = run([str(ROOT / "scripts" / "ios_device.sh"), "launch"], check=False)
    if launch.returncode != 0:
        raise HarnessError("could not launch Vocello on the paired iPhone: " + launch.stderr.strip())
    run_id = f"ios-ui-{args.suite}-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    directory = BUILD_ROOT / run_id
    directory.mkdir(parents=True, exist_ok=False)
    (directory / "screenshots").mkdir()
    started = utc_now()
    computer_use_service = routing["computerUseServiceProcesses"][0]
    contract = read_json(SCENARIOS)
    includes = contract["suites"][args.suite]["includes"]
    report = {
        "schemaVersion": 1,
        "runID": run_id,
        "suite": args.suite,
        "status": "running",
        "startedAt": started,
        "updatedAt": started,
        "completedAt": None,
        "sourceFingerprint": fingerprint(),
        "buildInputFingerprint": fingerprint(build_inputs_only=True),
        "toolchainIdentity": toolchain_identity(),
        "deviceIdentity": identity,
        "driver": "bundled-computer-use",
        "surface": MIRROR_BUNDLE_ID,
        "computerUse": {
            "pluginInstalled": routing.get("computerUsePluginInstalled"),
            "pluginEnabled": routing.get("computerUsePluginEnabled"),
            "pluginVersion": routing.get("computerUsePluginVersion") or routing.get("pluginVersion"),
            "inventoryCachePath": routing.get("computerUsePluginInventoryCachePath"),
            "installedInventoryCacheRoot": routing.get("installedPluginInventoryCacheRoot"),
            "installedInventoryCacheApp": routing.get("installedPluginInventoryCacheApp"),
            "inventoryCachePathConsistent": routing.get("pluginInventoryCachePathConsistent"),
            "bundledContentVariant": routing.get("computerUseBundledContentVariant"),
            "usesNodeRepl": routing.get("computerUseUsesNodeRepl"),
            "nodeReplServerDeclared": routing.get("nodeReplServerDeclared"),
            "nodeReplServerEnabled": routing.get("nodeReplServerEnabled"),
            "nodeReplServerCommand": routing.get("nodeReplServerCommand"),
            "nodeReplServerArgs": routing.get("nodeReplServerArgs"),
            "expectedNodeReplCommand": routing.get("expectedNodeReplCommand"),
            "nodeReplServerCommandMatchesDesktop": routing.get("nodeReplServerCommandMatchesDesktop"),
            "nodeReplSourceMatchesInventoryCache": routing.get("nodeReplConfiguredSourceMatchesInventoryCache"),
            "manifestServerDeclared": routing.get("computerUseManifestServerDeclared"),
            "manifestMirrorEntryPresent": routing.get("computerUseManifestMirrorEntryPresent"),
            "manifestMirrorEnabled": routing.get("computerUseManifestMirrorEnabled"),
            "manifestMirrorConflicting": routing.get("computerUseManifestMirrorConflicting"),
            "serverAvailable": routing.get("computerUseServerAvailable"),
            "serverDeclared": routing.get("computerUseServerDeclared"),
            "serverEnabled": routing.get("computerUseServerEnabled"),
            "skillInstalled": routing.get("computerUseSkillInstalled"),
            "skillExpectedAvailable": routing.get("computerUseSkillExpectedAvailable"),
            "skillPath": routing.get("computerUseSkillPath"),
            "wrapperAvailable": routing.get("computerUseWrapperAvailable"),
            "wrapperPath": routing.get("computerUseWrapperPath"),
            "wrapperSHA256": routing.get("computerUseWrapperSHA256"),
            "servicePath": computer_use_service.get("executable"),
            "serviceVersion": computer_use_service.get("version"),
            "serviceBuild": computer_use_service.get("build") or routing.get("helperBuild"),
            "serviceUUID": computer_use_service.get("uuid") or routing.get("helperUUID"),
            "serviceSHA256": computer_use_service.get("executableSHA256") or routing.get("helperSHA256"),
            "servicePID": computer_use_service.get("pid"),
            "verifiedAt": started,
        },
        "requiredScenarios": includes,
        "scenarios": {},
        "issues": [],
        "generationVerifications": [],
        "computerUseCrashReportsAtStart": service_crash_reports(),
        "computerUseCrashDelta": [],
    }
    if args.suite == "benchmark":
        report["benchmark"] = {"expectedTakeCount": 29, "takes": benchmark_manifest()}
    store_run(directory, report)
    write_json(CURRENT, {"runID": run_id, "runDirectory": str(directory)})
    print(json.dumps({"runID": run_id, "runDirectory": str(directory), "surface": MIRROR_BUNDLE_ID, "deviceIdentity": identity}, indent=2))


def cmd_now(_: argparse.Namespace) -> None:
    print(utc_now())


def cmd_checkpoint(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    require_computer_use_session(report)
    if args.scenario not in report.get("requiredScenarios", []):
        raise HarnessError(f"scenario is not required by this suite: {args.scenario}")
    value = {"status": args.status, "message": args.message, "updatedAt": utc_now()}
    if args.evidence:
        evidence = Path(args.evidence).resolve()
        if not evidence.is_file() or not evidence.is_relative_to(directory.resolve()):
            raise HarnessError("checkpoint evidence must be a file beneath the run directory")
        value["evidence"] = str(evidence)
    report.setdefault("scenarios", {})[args.scenario] = value
    store_run(directory, report)
    print(json.dumps(value, indent=2))


def cmd_issue(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    issue = {
        "timestamp": utc_now(), "scenario": args.scenario, "severity": args.severity,
        "category": args.category, "summary": args.summary,
        "expected": args.expected, "actual": args.actual,
    }
    if args.evidence:
        issue["evidence"] = args.evidence
    report.setdefault("issues", []).append(issue)
    store_run(directory, report)
    print(json.dumps(issue, indent=2))


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def cmd_verify_generation(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    require_computer_use_session(report)
    destination = directory / "diagnostics"
    if destination.exists():
        shutil.rmtree(destination)
    pulled = run([str(ROOT / "scripts" / "ios_device.sh"), "pull", str(destination)], check=False)
    if pulled.returncode != 0:
        raise HarnessError("could not pull iOS diagnostics: " + pulled.stderr.strip())
    paths = list(destination.rglob("engine/generations.jsonl"))
    if not paths:
        raise HarnessError("pulled diagnostics contain no engine/generations.jsonl")
    since = parse_time(args.since)
    matches = []
    for path in paths:
        for line in path.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
                recorded = parse_time(str(row.get("recordedAt")))
            except (json.JSONDecodeError, TypeError, ValueError):
                continue
            if recorded < since:
                continue
            if args.mode and row.get("mode") != args.mode:
                continue
            prompt_chars = (row.get("notes") or {}).get("promptChars")
            if args.text and prompt_chars is not None and int(prompt_chars) != len(args.text):
                continue
            finish = row.get("finishReason") or (row.get("backendMetrics") or {}).get("finishReason")
            qc = row.get("audioQC") or {}
            verdict = qc.get("verdict")
            if finish in ("eos", "completed", "success") and not (isinstance(verdict, str) and verdict.startswith("fail")):
                matches.append(row)
    if not matches:
        raise HarnessError("no passing terminal engine row matched the Computer Use generation")
    row = matches[-1]
    verification = {
        "verifiedAt": utc_now(), "since": args.since, "mode": row.get("mode"),
        "generationID": row.get("generationID"), "finishReason": row.get("finishReason"),
        "audioQCVerdict": (row.get("audioQC") or {}).get("verdict"),
    }
    report.setdefault("generationVerifications", []).append(verification)
    report["lastGenerationVerification"] = verification
    store_run(directory, report)
    print(json.dumps(verification, indent=2))


def benchmark_manifest() -> list[dict]:
    matrix = next(item["matrix"] for item in read_json(SCENARIOS)["scenarios"] if item["id"] == "generation-matrix")
    takes: list[dict] = []
    index = 1
    for mode in matrix["coldModes"]:
        takes.append({"index": index, "mode": mode, "length": matrix["coldLength"], "warmState": "cold", "text": matrix["corpus"][matrix["coldLength"]], "status": "pending"})
        index += 1
    for mode in matrix["modes"]:
        for length in matrix["lengths"]:
            for repetition in range(1, matrix["warmRepetitions"] + 1):
                takes.append({"index": index, "mode": mode, "length": length, "warmState": "warm", "repetition": repetition, "text": matrix["corpus"][length], "status": "pending"})
                index += 1
    return takes


def cmd_benchmark_manifest(_: argparse.Namespace) -> None:
    print(json.dumps(benchmark_manifest(), indent=2))


def cmd_benchmark_take(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    require_computer_use_session(report)
    if report.get("suite") != "benchmark":
        raise HarnessError("benchmark-take requires a benchmark run")
    takes = report["benchmark"]["takes"]
    if not 1 <= args.index <= len(takes):
        raise HarnessError("benchmark index out of range")
    take = takes[args.index - 1]
    if args.phase == "begin":
        previous = takes[: args.index - 1]
        if any(item.get("status") != "pass" for item in previous):
            raise HarnessError("earlier benchmark takes must pass first")
        take.update({"status": "running", "since": utc_now(), "generationVerificationCount": len(report.get("generationVerifications", []))})
    elif args.phase == "complete":
        if take.get("status") != "running":
            raise HarnessError("take must be running before completion")
        if len(report.get("generationVerifications", [])) <= int(take.get("generationVerificationCount", 0)):
            raise HarnessError("take has no new passing generation verification")
        take.update({"status": "pass", "completedAt": utc_now()})
    else:
        take.update({"status": "fail", "completedAt": utc_now()})
    store_run(directory, report)
    print(json.dumps(take, indent=2))


def validate_report(report: dict, *, required_suite: str | None = None, current: bool = True) -> list[str]:
    errors: list[str] = []
    if report.get("schemaVersion") != 1:
        errors.append("report schemaVersion must be 1")
    if report.get("status") != "pass":
        errors.append("report status is not pass")
    if report.get("computerUseCrashDelta"):
        errors.append("Computer Use service crashed during the run")
    final_routing = report.get("computerUseFinalRouting") or {}
    if final_routing and not routing_ready_for_suite(final_routing):
        errors.append("Computer Use routing was not healthy when the run finished")
    if report.get("driver") != "bundled-computer-use" or report.get("surface") != MIRROR_BUNDLE_ID:
        errors.append("report did not use bundled Computer Use on iPhone Mirroring")
    incomplete = [item for item in report.get("requiredScenarios", []) if (report.get("scenarios", {}).get(item) or {}).get("status") != "pass"]
    if incomplete:
        errors.append("required scenarios are not passing: " + ", ".join(incomplete))
    counts = {severity: 0 for severity in ("blocker", "major", "minor", "note")}
    for issue in report.get("issues", []):
        counts[issue.get("severity")] = counts.get(issue.get("severity"), 0) + 1
    if counts.get("blocker") or counts.get("major"):
        errors.append("report contains blocker or major issues")
    if report.get("suite") == "benchmark":
        takes = (report.get("benchmark") or {}).get("takes") or []
        if len(takes) != 29 or any(take.get("status") != "pass" for take in takes):
            errors.append("benchmark matrix is incomplete")
    if required_suite and report.get("suite") not in SUITE_SATISFIERS[required_suite]:
        errors.append(f"suite {report.get('suite')} cannot satisfy {required_suite}")
    if current:
        if report.get("sourceFingerprint") != fingerprint():
            errors.append("source fingerprint is stale")
        if report.get("buildInputFingerprint") != fingerprint(build_inputs_only=True):
            errors.append("build-input fingerprint is stale")
        if report.get("toolchainIdentity") != toolchain_identity():
            errors.append("toolchain identity is stale")
    return errors


def cmd_finish(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    report["computerUseCrashDelta"] = new_service_crash_reports(report.get("computerUseCrashReportsAtStart") or [])
    report["computerUseFinalRouting"] = routing_status()
    report["status"] = args.status
    report["completedAt"] = utc_now()
    store_run(directory, report)
    errors = validate_report(report) if args.status == "pass" else []
    if errors:
        report["status"] = "fail"
        report["validationErrors"] = errors
        store_run(directory, report)
    print(json.dumps({"runID": report["runID"], "status": report["status"], "errors": errors}, indent=2))
    if report["status"] != "pass":
        raise HarnessError("iOS UI run did not pass")


def cmd_validate_report(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    errors = validate_report(report, required_suite=args.suite)
    result = {"pass": not errors, "runID": report.get("runID"), "errors": errors}
    write_json(directory / "report-validation.json", result)
    print(json.dumps(result, indent=2))
    if errors:
        raise HarnessError("report validation failed")


def cmd_attest(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    errors = validate_report(report, required_suite=args.suite)
    if errors:
        raise HarnessError("cannot attest invalid report: " + "; ".join(errors))
    existing = read_json(ATTESTATION) if ATTESTATION.is_file() else {}
    identity = {
        "sourceFingerprint": report["sourceFingerprint"],
        "buildInputFingerprint": report["buildInputFingerprint"],
        "deviceIdentity": report["deviceIdentity"],
    }
    preserve = existing.get("schemaVersion") == 1 and all(existing.get(key) == value for key, value in identity.items())
    entries = dict(existing.get("entries") or {}) if preserve else {}
    issues = report.get("issues", [])
    entries[report["suite"]] = {
        "status": "pass", "suite": report["suite"], "runID": report["runID"],
        "completedAt": report["completedAt"],
        "issues": {severity: sum(1 for issue in issues if issue.get("severity") == severity) for severity in ("blocker", "major", "minor", "note")},
        "driver": report["driver"], "surface": report["surface"],
        "generationVerificationCount": len(report.get("generationVerifications", [])),
        "evidenceDigest": hashlib.sha256((directory / "report.json").read_bytes()).hexdigest(),
    }
    attestation = {
        "schemaVersion": 1, **identity,
        "entries": {suite: entries.get(suite) for suite in SUITES},
        "updatedAt": utc_now(),
    }
    write_json(ATTESTATION, attestation)
    print(json.dumps(attestation, indent=2))


def changed_paths(base: str) -> list[str]:
    if run(["/usr/bin/git", "rev-parse", "--verify", base], check=False).returncode != 0:
        raise HarnessError(f"base ref not found: {base}")
    paths = set(run(["/usr/bin/git", "diff", "--name-only", f"{base}...HEAD"]).stdout.splitlines())
    paths.update(run(["/usr/bin/git", "diff", "--name-only"]).stdout.splitlines())
    paths.update(run(["/usr/bin/git", "ls-files", "--others", "--exclude-standard"]).stdout.splitlines())
    paths.discard(ATTESTATION.relative_to(ROOT).as_posix())
    return sorted(path for path in paths if path)


def classify_paths(paths: list[str]) -> tuple[list[str], list[dict]]:
    config = read_json(IMPACT)
    suites = set(config.get("defaultRequiredSuites") or [])
    matches = []
    for path in paths:
        for rule in config.get("rules", []):
            if any(fnmatch.fnmatch(path, pattern) for pattern in rule.get("patterns", [])):
                required = set(rule.get("requiredSuites") or [])
                suites.update(required)
                matches.append({"path": path, "requiredSuites": sorted(required)})
    return sorted(suites), matches


def validate_attestation(required: list[str]) -> list[str]:
    attestation = read_json(ATTESTATION)
    errors: list[str] = []
    if attestation.get("schemaVersion") != 1:
        errors.append("attestation schemaVersion must be 1")
    if attestation.get("sourceFingerprint") != fingerprint():
        errors.append("attestation source fingerprint is stale")
    if attestation.get("buildInputFingerprint") != fingerprint(build_inputs_only=True):
        errors.append("attestation build-input fingerprint is stale")
    entries = attestation.get("entries") or {}
    for suite in required:
        candidates = [entries.get(name) for name in SUITE_SATISFIERS[suite] if entries.get(name)]
        if not any(entry.get("status") == "pass" and entry.get("driver") == "bundled-computer-use" and entry.get("surface") == MIRROR_BUNDLE_ID for entry in candidates):
            errors.append(f"missing valid {suite} Computer Use evidence")
    return errors


def cmd_impact(args: argparse.Namespace) -> None:
    base = args.base or os.environ.get("QVOICE_BASE_REF") or "origin/main"
    paths = changed_paths(base)
    suites, matches = classify_paths(paths)
    result = {"schemaVersion": 1, "base": base, "requiredSuites": suites, "changedPaths": paths, "matches": matches}
    print(json.dumps(result, indent=2))
    if args.check and suites:
        errors = validate_attestation(suites)
        if errors:
            raise HarnessError("iOS Computer Use attestation required: " + "; ".join(errors))


def cmd_release_check(_: argparse.Namespace) -> None:
    errors = validate_attestation(["full", "benchmark"])
    result = {"schemaVersion": 1, "status": "pass" if not errors else "fail", "requiredSuites": ["full", "benchmark"], "errors": errors}
    print(json.dumps(result, indent=2))
    if errors:
        raise HarnessError("iOS release UI readiness failed")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    sub = root.add_subparsers(dest="command", required=True)
    routing = sub.add_parser("routing-audit")
    routing.set_defaults(func=cmd_routing_audit)
    doctor = sub.add_parser("doctor")
    doctor.add_argument("--suite", choices=SUITES, default="quick")
    doctor.add_argument("--json", action="store_true")
    doctor.set_defaults(func=cmd_doctor)
    start = sub.add_parser("start")
    start.add_argument("--suite", choices=SUITES, required=True)
    start.set_defaults(func=cmd_start)
    now = sub.add_parser("now")
    now.set_defaults(func=cmd_now)
    checkpoint = sub.add_parser("checkpoint")
    checkpoint.add_argument("--run")
    checkpoint.add_argument("--scenario", required=True)
    checkpoint.add_argument("--status", choices=("running", "pass", "fail", "blocked"), required=True)
    checkpoint.add_argument("--message", required=True)
    checkpoint.add_argument("--evidence")
    checkpoint.set_defaults(func=cmd_checkpoint)
    issue = sub.add_parser("issue")
    issue.add_argument("--run")
    issue.add_argument("--scenario", required=True)
    issue.add_argument("--severity", choices=("blocker", "major", "minor", "note"), required=True)
    issue.add_argument("--category", choices=("functional", "visual", "accessibility", "automation", "environment"), required=True)
    issue.add_argument("--summary", required=True)
    issue.add_argument("--expected", required=True)
    issue.add_argument("--actual", required=True)
    issue.add_argument("--evidence")
    issue.set_defaults(func=cmd_issue)
    verify = sub.add_parser("verify-generation")
    verify.add_argument("--run")
    verify.add_argument("--since", required=True)
    verify.add_argument("--mode", choices=("custom", "design", "clone"))
    verify.add_argument("--text")
    verify.set_defaults(func=cmd_verify_generation)
    manifest = sub.add_parser("benchmark-manifest")
    manifest.set_defaults(func=cmd_benchmark_manifest)
    take = sub.add_parser("benchmark-take")
    take.add_argument("--run")
    take.add_argument("--index", type=int, required=True)
    take.add_argument("--phase", choices=("begin", "complete", "fail"), required=True)
    take.set_defaults(func=cmd_benchmark_take)
    finish = sub.add_parser("finish")
    finish.add_argument("--run")
    finish.add_argument("--status", choices=("pass", "fail", "blocked"), required=True)
    finish.set_defaults(func=cmd_finish)
    validate = sub.add_parser("validate-report")
    validate.add_argument("--run")
    validate.add_argument("--suite", choices=SUITES)
    validate.set_defaults(func=cmd_validate_report)
    attest = sub.add_parser("attest")
    attest.add_argument("--run")
    attest.add_argument("--suite", choices=SUITES)
    attest.set_defaults(func=cmd_attest)
    impact = sub.add_parser("impact")
    impact.add_argument("--base")
    impact.add_argument("--check", action="store_true")
    impact.set_defaults(func=cmd_impact)
    release = sub.add_parser("release-check")
    release.set_defaults(func=cmd_release_check)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.func(args)
        return 0
    except HarnessError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
