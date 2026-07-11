#!/usr/bin/env python3
"""Deterministic lifecycle, evidence, and probe verifier for Codex macOS UI QA.

Computer Use owns every UI action. This module owns everything that must be
repeatable: exact-bundle launch, isolated debug storage, fingerprints, report
updates, history/WAV verification, and cross-layer telemetry assertions.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
from urllib.parse import unquote, urlparse
import wave

LIB_DIR = Path(__file__).resolve().parent
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))
from computer_use_routing import new_service_crash_reports, routing_status, service_crash_reports


ROOT = Path(__file__).resolve().parents[2]
BUILD_ROOT = ROOT / "build" / "macos" / "agent-ui"
APP = ROOT / "build" / "Vocello.app"
APP_BINARY = APP / "Contents" / "MacOS" / "Vocello"
DEBUG_ROOT = Path.home() / "Library" / "Application Support" / "QwenVoice-Debug"
PRODUCTION_ROOT = Path.home() / "Library" / "Application Support" / "QwenVoice"
SCENARIOS = ROOT / "config" / "macos-ui-scenarios.json"
IMPACT = ROOT / "config" / "macos-test-impact.json"
RISK = ROOT / "config" / "backend-risk-spine.json"
ATTESTATION = ROOT / "qa" / "macos-ui-attestation.json"
CURRENT = BUILD_ROOT / "current-run.json"
WARM_DIAGNOSTIC = BUILD_ROOT / "warm-diagnostic.json"
BENCH_TAKE_FILE = Path("/tmp/vocello-bench-current-take.json")
BUNDLE_ID = "com.qwenvoice.app"
DEBUG_BUNDLE_ID = "com.qwenvoice.app.debug"
DEBUG_KEY = "QwenVoice.DebugModeEnabled"
APP_PROCESS = "Vocello"
SERVICE_PROCESS = "QwenVoiceEngineService"
LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)
SEVERITIES = ("blocker", "major", "minor", "note")
SUITES = ("quick", "full", "benchmark", "destructive")
ATTESTABLE_SUITES = ("quick", "full", "benchmark")
SUITE_SATISFIERS = {
    "quick": {"quick", "full"},
    "full": {"full"},
    "benchmark": {"benchmark"},
}
INITIAL_SIDEBAR_ITEMS = ("custom", "history", "settings")


class HarnessError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def local_timestamp() -> str:
    value = dt.datetime.now().astimezone()
    return value.strftime("%Y-%m-%d %H:%M:%S.") + value.strftime("%f")[:3]


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


def append_jsonl(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, sort_keys=True) + "\n")


def run(command: list[str], *, check: bool = True, capture: bool = True, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        cwd=ROOT,
        check=check,
        text=True,
        capture_output=capture,
        env=env,
    )


def process_ids(name: str) -> list[int]:
    result = run(["/usr/bin/pgrep", "-x", name], check=False)
    return [int(line) for line in result.stdout.splitlines() if line.strip().isdigit()]


def process_executable(pid: int) -> str | None:
    result = run(["/bin/ps", "-p", str(pid), "-o", "command="], check=False)
    command = result.stdout.strip()
    return command.split(maxsplit=1)[0] if command else None


def app_process_records() -> list[dict]:
    expected = APP_BINARY.resolve()
    records = []
    for pid in process_ids(APP_PROCESS):
        executable = process_executable(pid)
        try:
            exact = Path(executable).resolve() == expected if executable else False
        except OSError:
            exact = False
        records.append({"pid": pid, "executable": executable, "exactPath": exact})
    return records


def exact_single_app_running() -> bool:
    records = app_process_records()
    return len(records) == 1 and records[0]["exactPath"] is True


def parse_launch_services_app_records(output: str, bundle_id: str = BUNDLE_ID) -> list[dict]:
    records = []
    for block in output.split("\n--------------------------------------------------------------------------------\n"):
        identifier = re.search(r"^identifier:\s+(.+?)\s*$", block, re.MULTILINE)
        path_match = re.search(r"^path:\s+(.+?\.app)(?:\s+\(0x[0-9a-fA-F]+\))?\s*$", block, re.MULTILINE)
        if not identifier or not path_match or identifier.group(1).strip('"') != bundle_id:
            continue
        path = Path(path_match.group(1))
        try:
            exact = path.resolve() == APP.resolve()
        except OSError:
            exact = False
        records.append({"path": str(path), "exists": path.is_dir(), "exactPath": exact})
    return sorted(records, key=lambda item: item["path"])


def launch_services_app_records() -> list[dict]:
    if not LSREGISTER.is_file():
        return []
    result = run([str(LSREGISTER), "-dump"], check=False)
    if result.returncode != 0:
        return []
    return parse_launch_services_app_records(result.stdout)


def terminate_process(name: str) -> None:
    pids = process_ids(name)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while process_ids(name) and time.monotonic() < deadline:
        time.sleep(0.1)
    for pid in process_ids(name):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def clear_debug_flag() -> None:
    run(["/usr/bin/defaults", "delete", BUNDLE_ID, DEBUG_KEY], check=False)


def set_debug_flag() -> None:
    run(["/usr/bin/defaults", "write", BUNDLE_ID, DEBUG_KEY, "-bool", "true"])


def cleanup_processes(*, clear_persisted_debug_flag: bool = True) -> None:
    terminate_process(APP_PROCESS)
    terminate_process(SERVICE_PROCESS)
    if clear_persisted_debug_flag:
        clear_debug_flag()


def exact_launch_command(
    run_id: str,
    app_support_root: Path,
    *,
    force_cold: bool = False,
    initial_sidebar_item: str = "custom",
) -> list[str]:
    if initial_sidebar_item not in INITIAL_SIDEBAR_ITEMS:
        raise HarnessError(f"unsupported initial sidebar item: {initial_sidebar_item}")
    launch = [
        "/usr/bin/open", "-n", "--env", "QWENVOICE_DEBUG=1",
        "--env", f"QWENVOICE_INITIAL_SIDEBAR_ITEM={initial_sidebar_item}",
        "--env", "QWENVOICE_NATIVE_TELEMETRY_MODE=verbose",
        "--env", f"QWENVOICE_APP_SUPPORT_DIR={app_support_root}",
        "--env", f"QVOICE_MAC_BENCH_RUN_ID={run_id}",
        "--env", f"QVOICE_MAC_BENCH_LABEL={run_id}",
    ]
    if force_cold:
        launch.extend(["--env", "QWENVOICE_BENCH_FORCE_COLD=1"])
    launch.append(str(APP))
    return launch


def computer_use_service_identity(routing: dict) -> dict:
    processes = routing.get("computerUseServiceProcesses") or []
    if len(processes) != 1:
        raise HarnessError(f"expected one Computer Use service process, found {processes}")
    process = processes[0]
    return {
        "pid": process.get("pid"),
        "executable": process.get("executable"),
        "version": process.get("version") or process.get("helperVersion") or routing.get("helperVersion"),
        "build": process.get("build") or process.get("helperBuild") or routing.get("helperBuild"),
        "uuid": process.get("uuid") or process.get("helperUUID") or routing.get("helperUUID"),
        "sha256": process.get("sha256") or process.get("executableSHA256") or process.get("helperSHA256") or routing.get("helperSHA256"),
    }


def routing_ready(routing: dict, *, diagnostic: bool = False) -> bool:
    key = "readyForDiagnostic" if diagnostic else "readyForSuite"
    return bool(routing.get(key, routing.get("ready", False)))


def routing_failure_messages(routing: dict, *, diagnostic: bool = False) -> list[str]:
    base = routing.get("routingErrors") if diagnostic else routing.get("errors")
    messages = list(base or [])
    if not diagnostic and not routing.get("errors"):
        messages.extend(routing.get("suiteBlockers") or [])
    if not routing_ready(routing, diagnostic=diagnostic) and not messages:
        messages.append(
            "Computer Use is not ready for the bounded diagnostic"
            if diagnostic
            else "Computer Use is not ready for a normal UI suite"
        )
    return list(dict.fromkeys(messages))


def require_same_computer_use_service(expected: dict, routing: dict) -> dict:
    actual = computer_use_service_identity(routing)
    if actual != expected:
        raise HarnessError(
            "Computer Use service identity changed during the operation: "
            f"expected {expected}, found {actual}"
        )
    return actual


def report_computer_use_service_identity(report: dict) -> dict:
    evidence = ((report.get("environment") or {}).get("computerUse") or {})
    return {
        "pid": evidence.get("servicePID"),
        "executable": evidence.get("servicePath"),
        "version": evidence.get("serviceVersion"),
        "build": evidence.get("serviceBuild"),
        "uuid": evidence.get("serviceUUID"),
        "sha256": evidence.get("serviceSHA256"),
    }


def stable_exact_app_pid(
    *,
    timeout_seconds: float = 15.0,
    stable_seconds: float = 3.0,
    crash_baseline: list[dict] | None = None,
) -> int:
    deadline = time.monotonic() + timeout_seconds
    stable_pid: int | None = None
    stable_since: float | None = None
    while time.monotonic() < deadline:
        if crash_baseline is not None:
            delta = new_service_crash_reports(crash_baseline)
            if delta:
                raise HarnessError(
                    "Computer Use service crashed while Vocello was stabilizing: "
                    + ", ".join(item["path"] for item in delta)
                )
        records = app_process_records()
        if len(records) > 1 or any(not record["exactPath"] for record in records):
            raise HarnessError(f"unexpected Vocello process ownership during launch: {records}")
        if len(records) == 1:
            pid = int(records[0]["pid"])
            if pid != stable_pid:
                stable_pid = pid
                stable_since = time.monotonic()
            elif stable_since is not None and time.monotonic() - stable_since >= stable_seconds:
                return pid
        else:
            stable_pid = None
            stable_since = None
        time.sleep(0.1)
    raise HarnessError(
        f"expected one exact-path {APP_PROCESS} process stable for {stable_seconds:.1f}s; "
        f"found {app_process_records()}"
    )


def launch_exact_app(
    run_id: str,
    app_support_root: Path,
    *,
    force_cold: bool = False,
    initial_sidebar_item: str = "custom",
    crash_baseline: list[dict] | None = None,
    clear_persisted_debug_flag_on_failure: bool = True,
) -> int:
    launch = exact_launch_command(
        run_id,
        app_support_root,
        force_cold=force_cold,
        initial_sidebar_item=initial_sidebar_item,
    )
    run(launch)
    try:
        return stable_exact_app_pid(crash_baseline=crash_baseline)
    except HarnessError:
        cleanup_processes(clear_persisted_debug_flag=clear_persisted_debug_flag_on_failure)
        raise


def benchmark_scenario() -> dict:
    scenarios = read_json(SCENARIOS)
    for scenario in scenarios.get("scenarios", []):
        if scenario.get("id") == "generation-matrix":
            return scenario
    raise HarnessError("generation-matrix scenario is missing")


def benchmark_manifest() -> list[dict]:
    matrix = benchmark_scenario().get("matrix") or {}
    modes = matrix.get("modes") or []
    lengths = matrix.get("lengths") or []
    corpus = matrix.get("corpus") or {}
    warm_repetitions = max(1, int(matrix.get("warmRepetitions", 1)))
    cold_length = matrix.get("coldLength")
    cold_modes = set(matrix.get("coldModes") or [])
    takes: list[dict] = []
    for mode in modes:
        if mode in cold_modes and cold_length in lengths:
            text = corpus.get(cold_length)
            if not text:
                raise HarnessError(f"benchmark corpus is missing cold length {cold_length}")
            takes.append({
                "index": len(takes) + 1,
                "mode": mode,
                "length": cold_length,
                "warmState": "cold",
                "repetition": 0,
                "text": text,
            })
        for length in lengths:
            text = corpus.get(length)
            if not text:
                raise HarnessError(f"benchmark corpus is missing length {length}")
            for repetition in range(warm_repetitions):
                takes.append({
                    "index": len(takes) + 1,
                    "mode": mode,
                    "length": length,
                    "warmState": "warm",
                    "repetition": repetition,
                    "text": text,
                })
    return takes


def public_benchmark_take(take: dict) -> dict:
    return {key: value for key, value in take.items() if key != "text"} | {
        "textLength": len(take["text"]),
        "textDigest": hashlib.sha256(take["text"].encode()).hexdigest(),
    }


def relative_files(*, build_inputs_only: bool = False) -> list[Path]:
    if build_inputs_only:
        candidates = [
            Path("project.yml"),
            Path("Package.resolved"),
            Path("Sources/Resources/qwenvoice_contract.json"),
            Path("third_party_patches/mlx-audio-swift/Package.swift"),
        ]
        return [path for path in candidates if (ROOT / path).is_file()]

    include_roots = [
        ".agents",
        ".github",
        "Sources",
        "Tests",
        "config",
        "scripts",
        "third_party_patches/mlx-audio-swift/Sources",
        "third_party_patches/mlx-audio-swift/Tests",
    ]
    # Fingerprints must be reproducible in a clean checkout while still
    # covering newly created, uncommitted source files. Asking Git for cached
    # and non-ignored untracked files excludes local .DS_Store, __pycache__,
    # and other ignored machine state that previously made CI attestations
    # disagree with the same source tree.
    repository_files = {
        Path(value)
        for value in run(
            ["/usr/bin/git", "ls-files", "--cached", "--others", "--exclude-standard"]
        ).stdout.splitlines()
        if value
    }
    paths: set[Path] = set()
    for path in repository_files:
        value = path.as_posix()
        if (ROOT / path).is_file() and any(value == root or value.startswith(f"{root}/") for root in include_roots):
            paths.add(path)
    for name in ("project.yml", "Package.resolved", "AGENTS.md"):
        if (ROOT / name).is_file():
            paths.add(Path(name))
    paths.discard(ATTESTATION.relative_to(ROOT))
    return sorted(paths, key=lambda value: value.as_posix())


def fingerprint(*, build_inputs_only: bool = False) -> str:
    digest = hashlib.sha256()
    for relative in relative_files(build_inputs_only=build_inputs_only):
        absolute = ROOT / relative
        digest.update(relative.as_posix().encode())
        digest.update(b"\0")
        digest.update(absolute.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def toolchain_identity() -> dict:
    values = {
        "xcode": run(["/usr/bin/xcodebuild", "-version"]).stdout.strip(),
        "swift": run(["/usr/bin/xcrun", "swift", "--version"]).stdout.strip(),
    }
    values["digest"] = hashlib.sha256(
        json.dumps(values, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return values


def toolchain_identity_is_valid(identity: dict) -> bool:
    xcode = identity.get("xcode")
    swift = identity.get("swift")
    digest = identity.get("digest")
    if not all(isinstance(value, str) and value for value in (xcode, swift, digest)):
        return False
    expected = hashlib.sha256(
        json.dumps({"xcode": xcode, "swift": swift}, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return digest == expected


def toolchain_identity_matches(recorded: dict, current: dict, *, ci: bool) -> bool:
    if not toolchain_identity_is_valid(recorded):
        return False
    if not ci:
        return recorded == current

    # Local Computer Use and GitHub builds can use different point releases
    # of the same supported Xcode/Swift generation. CI verifies a genuine,
    # internally consistent identity and compatible majors; it does not make
    # local evidence impossible merely because the hosted image trails by a
    # point release (for example Xcode 26.5 versus 26.6).
    recorded_xcode = re.search(r"\bXcode\s+(\d+)", recorded["xcode"])
    current_xcode = re.search(r"\bXcode\s+(\d+)", current["xcode"])
    recorded_swift = re.search(r"\bSwift version\s+(\d+)", recorded["swift"])
    current_swift = re.search(r"\bSwift version\s+(\d+)", current["swift"])
    if not all((recorded_xcode, current_xcode, recorded_swift, current_swift)):
        return False
    return (
        recorded_xcode.group(1) == current_xcode.group(1)
        and recorded_swift.group(1) == current_swift.group(1)
    )


def executable_identity() -> dict:
    return {
        "path": str(APP),
        "binaryPath": str(APP_BINARY),
        "sha256": sha256(APP_BINARY),
    }


def report_support_root(report: dict) -> Path:
    return Path((report.get("environment") or {}).get("appSupportRoot", DEBUG_ROOT))


def report_db(report: dict) -> Path:
    return report_support_root(report) / "history.sqlite"


def report_diagnostics(report: dict) -> Path:
    return report_support_root(report) / "diagnostics"


def current_run_dir(explicit: str | None = None) -> Path:
    if explicit:
        candidate = Path(explicit)
        if not candidate.is_absolute():
            candidate = BUILD_ROOT / explicit
        if candidate.name == "run.json":
            candidate = candidate.parent
        return candidate
    value = read_json(CURRENT)
    return Path(value["runDirectory"])


def load_run(explicit: str | None = None) -> tuple[Path, dict]:
    directory = current_run_dir(explicit)
    return directory, read_json(directory / "run.json")


def store_run(directory: Path, report: dict) -> None:
    report["updatedAt"] = utc_now()
    write_json(directory / "run.json", report)


def test_reference_exists(reference: str) -> bool:
    parts = reference.split("/")
    if len(parts) != 3:
        return False
    target, suite, test = parts
    roots = {
        "VocelloCoreTests": ROOT / "Tests" / "VocelloCoreTests",
        "VocelloEngineIntegrationTests": ROOT / "Tests" / "VocelloEngineIntegrationTests",
        "Qwen3RuntimeTests": ROOT / "third_party_patches" / "mlx-audio-swift" / "Tests" / "Qwen3RuntimeTests",
        "HarnessTests": ROOT / "scripts",
    }
    root = roots.get(target)
    if root is None or not root.is_dir():
        return False
    suffix = "*.py" if target == "HarnessTests" else "*.swift"
    for path in root.rglob(suffix):
        text = path.read_text(errors="ignore")
        if suite in text and re.search(rf"\b(?:func\s+)?{re.escape(test)}\b", text):
            return True
    return False


def validate_config() -> list[str]:
    errors: list[str] = []
    scenarios = read_json(SCENARIOS)
    if scenarios.get("schemaVersion") != 2:
        errors.append("macos-ui-scenarios schemaVersion must be 2")
    scenario_ids = {item.get("id") for item in scenarios.get("scenarios", [])}
    if None in scenario_ids or len(scenario_ids) != len(scenarios.get("scenarios", [])):
        errors.append("scenario IDs must be present and unique")
    for name, suite in scenarios.get("suites", {}).items():
        missing = set(suite.get("includes", [])) - scenario_ids
        if missing:
            errors.append(f"suite {name} references missing scenarios: {sorted(missing)}")
        if name == "destructive" and not suite.get("requiresDisposableAppSupport"):
            errors.append("destructive suite must require disposable app support")
    impact = read_json(IMPACT)
    if impact.get("schemaVersion") != 2:
        errors.append("macos-test-impact schemaVersion must be 2")
    risk = read_json(RISK)
    if risk.get("schemaVersion") != 2:
        errors.append("backend-risk-spine schemaVersion must be 2")
    for item in risk.get("items", []):
        source = item.get("source")
        if not source or not (ROOT / source).exists():
            errors.append(f"risk item {item.get('id')} source missing: {source}")
        missing_tests = [reference for reference in item.get("tests", []) if not test_reference_exists(reference)]
        if missing_tests:
            errors.append(f"risk item {item.get('id')} has unresolved tests: {missing_tests}")
        if item.get("status") == "implemented" and item.get("remaining"):
            errors.append(f"risk item {item.get('id')} is implemented but remaining is non-empty")

    for scenario in scenarios.get("scenarios", []):
        if "restorationPolicy" not in scenario:
            errors.append(f"scenario {scenario.get('id')} is missing restorationPolicy")
        if "timeoutSeconds" not in scenario:
            errors.append(f"scenario {scenario.get('id')} is missing timeoutSeconds")
        if "requiresActionTimeConfirmation" not in scenario:
            errors.append(f"scenario {scenario.get('id')} is missing requiresActionTimeConfirmation")
        for step in scenario.get("steps", []):
            for required in ("semanticResult", "deterministicPostcondition", "restorationPolicy", "timeoutSeconds", "confirmation"):
                if required not in step:
                    errors.append(f"scenario {scenario.get('id')} step {step.get('id')} is missing {required}")
            if not step.get("id"):
                errors.append(f"scenario {scenario.get('id')} contains a step without an id")
    return errors


def cmd_doctor(args: argparse.Namespace) -> None:
    errors = validate_config()
    routing = routing_status()
    repository_ready = all(path.is_file() for path in (SCENARIOS, IMPACT, RISK)) and sys.version_info >= (3, 10) and shutil.which("sqlite3") is not None and not errors
    app_ready = APP.is_dir() and APP_BINARY.is_file()
    app_processes = app_process_records()
    process_ownership_ready = not app_processes or (
        len(app_processes) == 1 and app_processes[0]["exactPath"] is True
    )
    app_registrations = launch_services_app_records()
    duplicate_app_registration = len(app_registrations) > 1
    wrong_path_app_registration = any(not record["exactPath"] for record in app_registrations)
    # Launch Services and Computer Use may retain multiple records for installed
    # and build-product copies. Exact-path targeting plus live process ownership
    # is the gate; registration duplication remains diagnostic evidence.
    app_registration_ready = any(
        record["exactPath"] is True and record["exists"] is True
        for record in app_registrations
    )
    checks = {
        "appBundle": APP.is_dir(),
        "appBinary": APP_BINARY.is_file(),
        "scenarioContract": SCENARIOS.is_file(),
        "impactContract": IMPACT.is_file(),
        "riskContract": RISK.is_file(),
        "python": sys.version_info >= (3, 10),
        "sqlite": shutil.which("sqlite3") is not None,
        "configErrors": errors,
        "routingErrors": routing.get("routingErrors") or [],
        "suite": args.suite,
        "repositoryReady": repository_ready,
        "appReady": app_ready,
        "appProcesses": app_processes,
        "processOwnershipReady": process_ownership_ready,
        "vocelloLaunchServicesRegistrations": app_registrations,
        "duplicateVocelloRegistrationDetected": duplicate_app_registration,
        "wrongPathVocelloRegistrationDetected": wrong_path_app_registration,
        "appRegistrationReady": app_registration_ready,
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
    }
    common_ready = (
        repository_ready
        and app_ready
        and process_ownership_ready
        and app_registration_ready
    )
    checks["readyForDiagnostic"] = common_ready and routing_ready(routing, diagnostic=True)
    checks["readyForSuite"] = common_ready and routing_ready(routing)
    checks["readyForSession"] = checks["readyForSuite"]
    checks["ready"] = checks["readyForSuite"]
    if args.json:
        print(json.dumps(checks, indent=2, sort_keys=True))
    else:
        for key, value in checks.items():
            print(f"{key}: {value}")
    if not checks["ready"]:
        raise HarnessError("doctor found blocking problems")


def cmd_routing_audit(_: argparse.Namespace) -> None:
    result = routing_status()
    print(json.dumps(result, indent=2, sort_keys=True))
    if not result.get("routingReady", result.get("ready", False)):
        raise HarnessError("Computer Use routing audit failed")


def require_computer_use_session(report: dict | None = None, *, diagnostic: bool = False) -> dict:
    routing = routing_status()
    errors = routing_failure_messages(routing, diagnostic=diagnostic)
    if report is not None:
        delta = new_service_crash_reports(report.get("computerUseCrashReportsAtStart") or [])
        if delta:
            errors.append("new SkyComputerUseService crash report detected: " + ", ".join(item["path"] for item in delta))
    if errors:
        raise HarnessError("Computer Use session is not safe: " + "; ".join(errors))
    return routing


def reset_runtime_state(root: Path) -> None:
    database = root / "history.sqlite"
    diagnostics = root / "diagnostics"
    if database.is_file():
        try:
            connection = sqlite3.connect(database)
            connection.execute("DELETE FROM generations")
            connection.commit()
            connection.close()
        except sqlite3.Error as exc:
            raise HarnessError(f"could not clear debug history: {exc}") from exc
    outputs = root / "outputs"
    if outputs.is_dir():
        for path in outputs.rglob("*"):
            if path.is_file() or path.is_symlink():
                path.unlink(missing_ok=True)
    if diagnostics.is_dir():
        shutil.rmtree(diagnostics)
    for subdirectory in ("engine", "engine-service", "app"):
        (diagnostics / subdirectory).mkdir(parents=True, exist_ok=True)


def snapshot_state(directory: Path, root: Path) -> dict:
    state_dir = directory / "state-snapshot"
    state_dir.mkdir(parents=True, exist_ok=True)
    preferences = state_dir / "preferences.plist"
    debug_preferences = state_dir / "debug-preferences.plist"
    exported = run(["/usr/bin/defaults", "export", BUNDLE_ID, str(preferences)], check=False)
    if exported.returncode != 0:
        preferences.unlink(missing_ok=True)
    debug_exported = run(
        ["/usr/bin/defaults", "export", DEBUG_BUNDLE_ID, str(debug_preferences)],
        check=False,
    )
    if debug_exported.returncode != 0:
        debug_preferences.unlink(missing_ok=True)
    voices = root / "voices"
    voices_snapshot = state_dir / "voices"
    if voices.is_dir():
        shutil.copytree(voices, voices_snapshot, symlinks=True)
    return {
        "preferencesExisted": preferences.is_file(),
        "preferencesPath": str(preferences),
        "debugPreferencesExisted": debug_preferences.is_file(),
        "debugPreferencesPath": str(debug_preferences),
        "voicesExisted": voices.is_dir(),
        "voicesPath": str(voices_snapshot),
        "restored": False,
    }


def restore_state(report: dict) -> None:
    if "stateSnapshot" not in report:
        return
    snapshot = report.get("stateSnapshot") or {}
    if snapshot.get("restored"):
        return
    preferences = Path(snapshot.get("preferencesPath", ""))
    if snapshot.get("preferencesExisted") and preferences.is_file():
        run(["/usr/bin/defaults", "import", BUNDLE_ID, str(preferences)], check=False)
    else:
        run(["/usr/bin/defaults", "delete", BUNDLE_ID], check=False)
    if "debugPreferencesExisted" in snapshot:
        debug_preferences = Path(snapshot.get("debugPreferencesPath", ""))
        if snapshot.get("debugPreferencesExisted") and debug_preferences.is_file():
            run(["/usr/bin/defaults", "import", DEBUG_BUNDLE_ID, str(debug_preferences)], check=False)
        else:
            run(["/usr/bin/defaults", "delete", DEBUG_BUNDLE_ID], check=False)
    root = report_support_root(report)
    voices = root / "voices"
    voices_snapshot = Path(snapshot.get("voicesPath", ""))
    if voices.is_dir() or voices.is_symlink():
        if voices.is_symlink() or voices.is_file():
            voices.unlink(missing_ok=True)
        else:
            shutil.rmtree(voices)
    if snapshot.get("voicesExisted") and voices_snapshot.is_dir():
        shutil.copytree(voices_snapshot, voices, symlinks=True)
    snapshot["restored"] = True
    report["stateSnapshot"] = snapshot


def destructive_root(directory: Path) -> Path:
    root = (directory / "disposable-app-support").resolve()
    forbidden = {PRODUCTION_ROOT.resolve(), DEBUG_ROOT.resolve()}
    if root in forbidden or not root.is_relative_to(directory.resolve()):
        raise HarnessError(f"destructive app-support root is unsafe: {root}")
    root.mkdir(parents=True, exist_ok=False)
    for name in ("models", "voices"):
        candidate = root / name
        candidate.mkdir()
        if candidate.is_symlink() or candidate.resolve() in forbidden:
            raise HarnessError(f"destructive {name} root is not disposable: {candidate}")
    return root


def cmd_start(args: argparse.Namespace) -> None:
    if args.suite == "destructive" and not args.allow_destructive:
        raise HarnessError("destructive suite requires --allow-destructive and action-time Computer Use confirmations")
    if not APP_BINARY.is_file():
        raise HarnessError(f"app not built at {APP}; run scripts/build.sh build")
    routing = routing_status()
    if not routing_ready(routing):
        raise HarnessError(
            "Computer Use is not ready for a normal UI suite: "
            + "; ".join(routing_failure_messages(routing))
        )
    errors = validate_config()
    if errors:
        raise HarnessError("invalid QA contracts: " + "; ".join(errors))

    cleanup_processes(clear_persisted_debug_flag=False)
    run_id = f"mac-ui-{args.suite}-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    directory = BUILD_ROOT / run_id
    directory.mkdir(parents=True, exist_ok=False)
    (directory / "screenshots").mkdir()
    root = destructive_root(directory) if args.suite == "destructive" else DEBUG_ROOT
    state_snapshot = snapshot_state(directory, root)
    reset_runtime_state(root)
    set_debug_flag()
    started = utc_now()
    computer_use_identity = computer_use_service_identity(routing)
    crash_baseline = service_crash_reports()
    report = {
        "schemaVersion": 2,
        "runID": run_id,
        "suite": args.suite,
        "status": "running",
        "startedAt": started,
        "updatedAt": started,
        "completedAt": None,
        "sourceFingerprint": fingerprint(),
        "buildInputFingerprint": fingerprint(build_inputs_only=True),
        "appPath": str(APP),
        "appBinarySHA256": sha256(APP_BINARY),
        "executableIdentity": executable_identity(),
        "environment": {
            "os": run(["/usr/bin/sw_vers", "-productVersion"]).stdout.strip(),
            "architecture": run(["/usr/bin/uname", "-m"]).stdout.strip(),
            "appSupportRoot": str(root),
            "computerUse": {
                "pluginInstalled": routing.get("computerUsePluginInstalled"),
                "pluginEnabled": routing.get("computerUsePluginEnabled"),
                "pluginVersion": routing.get("computerUsePluginVersion") or routing.get("pluginVersion"),
                "serverDeclared": routing.get("computerUseServerDeclared"),
                "serverEnabled": routing.get("computerUseServerEnabled"),
                "skillInstalled": routing.get("computerUseSkillInstalled"),
                "skillExpectedAvailable": routing.get("computerUseSkillExpectedAvailable"),
                "skillPath": routing.get("computerUseSkillPath"),
                "wrapperAvailable": routing.get("computerUseWrapperAvailable"),
                "wrapperPath": routing.get("computerUseWrapperPath"),
                "wrapperSHA256": routing.get("computerUseWrapperSHA256"),
                "servicePath": computer_use_identity.get("executable"),
                "servicePID": computer_use_identity.get("pid"),
                "serviceVersion": computer_use_identity.get("version"),
                "serviceBuild": computer_use_identity.get("build"),
                "serviceUUID": computer_use_identity.get("uuid"),
                "serviceSHA256": computer_use_identity.get("sha256"),
                "verifiedAt": started,
            },
            "disposableAppSupport": args.suite == "destructive",
            "toolchain": toolchain_identity(),
        },
        "stateSnapshot": state_snapshot,
        "scenarios": {},
        "issues": [],
        "deterministicAssertions": [],
        "probeVerdict": "missing",
        "cleanupVerdict": "pending",
        "computerUseCrashReportsAtStart": crash_baseline,
        "computerUseCrashDelta": [],
    }
    if args.suite == "benchmark":
        manifest = benchmark_manifest()
        report["benchmark"] = {
            "expectedTakeCount": len(manifest),
            "activeTakeIndex": None,
            "takes": [{**public_benchmark_take(take), "status": "pending"} for take in manifest],
        }
    store_run(directory, report)
    write_json(directory / "issues.json", [])
    write_json(CURRENT, {"runID": run_id, "runDirectory": str(directory)})
    append_jsonl(directory / "events.jsonl", {"timestamp": started, "event": "run-started", "suite": args.suite})

    try:
        report["appPID"] = launch_exact_app(
            run_id,
            root,
            initial_sidebar_item="custom",
            crash_baseline=crash_baseline,
        )
        post_launch_routing = require_computer_use_session(report)
        require_same_computer_use_service(computer_use_identity, post_launch_routing)
    except HarnessError:
        restore_state(report)
        report["status"] = "blocked"
        report["cleanupVerdict"] = "pass"
        store_run(directory, report)
        raise
    store_run(directory, report)
    print(json.dumps({"runID": run_id, "runDirectory": str(directory), "appPath": str(APP), "appPID": report["appPID"]}, indent=2))


def diagnostic_plugin_evidence(routing: dict) -> dict:
    return {
        "installed": routing.get("computerUsePluginInstalled"),
        "enabled": routing.get("computerUsePluginEnabled"),
        "version": routing.get("computerUsePluginVersion") or routing.get("pluginVersion"),
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
    }


def prepare_warm_diagnostic(args: argparse.Namespace) -> None:
    if not APP_BINARY.is_file():
        raise HarnessError(f"app not built at {APP}; run scripts/build.sh build")
    if app_process_records():
        raise HarnessError(
            "warm diagnostic refuses a pre-existing Vocello process; switch Computer Use to Finder, "
            "then terminate the existing exact-path app before preparing"
        )
    if WARM_DIAGNOSTIC.is_file():
        previous = read_json(WARM_DIAGNOSTIC)
        if previous.get("status") in {"preparing", "prepared"}:
            raise HarnessError(
                f"warm diagnostic {previous.get('diagnosticID')} is still active; verify or abort it first"
            )

    routing = require_computer_use_session(diagnostic=True)
    if routing.get("knownBadHelperDetected") and not args.acknowledge_known_bad_helper:
        raise HarnessError(
            "this helper is blocked for normal suites; the bounded diagnostic requires "
            "--acknowledge-known-bad-helper"
        )

    diagnostic_id = f"mac-ui-warm-diagnostic-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    crash_baseline = service_crash_reports()
    helper = computer_use_service_identity(routing)
    report = {
        "schemaVersion": 1,
        "diagnosticOnly": True,
        "attestable": False,
        "diagnosticID": diagnostic_id,
        "status": "preparing",
        "createdAt": utc_now(),
        "updatedAt": utc_now(),
        "initialSidebarItem": args.initial_screen,
        "observationBudget": 1,
        "observationsConsumed": 0,
        "verificationVerdict": "pending",
        "cleanupVerdict": "pending",
        "appPath": str(APP),
        "appBinarySHA256": sha256(APP_BINARY),
        "sourceFingerprint": fingerprint(),
        "computerUsePlugin": diagnostic_plugin_evidence(routing),
        "computerUseService": helper,
        "knownBadHelperDetected": bool(routing.get("knownBadHelperDetected")),
        "knownBadHelperRule": routing.get("knownBadHelperRule"),
        "computerUseCrashReportsAtStart": crash_baseline,
        "computerUseCrashDelta": [],
    }
    write_json(WARM_DIAGNOSTIC, report)
    try:
        report["appPID"] = launch_exact_app(
            diagnostic_id,
            DEBUG_ROOT,
            initial_sidebar_item=args.initial_screen,
            crash_baseline=crash_baseline,
            clear_persisted_debug_flag_on_failure=False,
        )
        post_launch_routing = require_computer_use_session(report, diagnostic=True)
        require_same_computer_use_service(helper, post_launch_routing)
    except HarnessError as exc:
        report["status"] = "blocked"
        report["verificationVerdict"] = "blocked"
        report["updatedAt"] = utc_now()
        report["failure"] = str(exc)
        report["computerUseCrashDelta"] = new_service_crash_reports(crash_baseline)
        write_json(WARM_DIAGNOSTIC, report)
        raise

    report["status"] = "prepared"
    report["updatedAt"] = utc_now()
    write_json(WARM_DIAGNOSTIC, report)
    print(json.dumps({
        "diagnosticID": diagnostic_id,
        "status": "prepared",
        "diagnosticOnly": True,
        "attestable": False,
        "appPath": str(APP),
        "appPID": report["appPID"],
        "initialSidebarItem": args.initial_screen,
        "observationBudget": 1,
        "next": (
            "Perform exactly one Computer Use observation, record its non-sensitive metadata while "
            "the screenshot exists, then run warm-diagnostic --phase verify."
        ),
    }, indent=2))


def record_warm_diagnostic_observation(args: argparse.Namespace) -> None:
    report = read_json(WARM_DIAGNOSTIC)
    if report.get("status") != "prepared" or report.get("observationsConsumed") != 0:
        raise HarnessError(
            f"warm diagnostic cannot record an observation: status={report.get('status')}"
        )
    if report.get("observationEvidence"):
        raise HarnessError("warm diagnostic observation evidence has already been recorded")

    observed_app = Path(args.app_path).expanduser().resolve()
    if observed_app != APP.resolve():
        raise HarnessError(f"observation app must be the exact build path {APP}")
    if args.accessibility_length <= 0:
        raise HarnessError("observation accessibility length must be positive")
    if args.window_count <= 0:
        raise HarnessError("observation must report at least one visible window")

    if not args.screenshot_url:
        raise HarnessError("observation screenshot URL is required")
    parsed = urlparse(args.screenshot_url)
    if parsed.scheme != "file":
        raise HarnessError("observation screenshot must be a file URL returned by Computer Use")
    screenshot = Path(unquote(parsed.path))
    if not screenshot.is_file():
        raise HarnessError("Computer Use screenshot file is no longer available; record it before cleanup")
    screenshot_size = screenshot.stat().st_size
    if screenshot_size <= 0:
        raise HarnessError("Computer Use screenshot is empty")

    report["observationEvidence"] = {
        "observedAt": utc_now(),
        "appPath": str(APP),
        "accessibilityTextLength": args.accessibility_length,
        "visibleWindowCount": args.window_count,
        "screenshotAvailable": True,
        "screenshotByteCount": screenshot_size,
        "screenshotSHA256": sha256(screenshot),
    }
    report["updatedAt"] = utc_now()
    write_json(WARM_DIAGNOSTIC, report)
    print(json.dumps({
        "diagnosticID": report.get("diagnosticID"),
        "status": report.get("status"),
        "diagnosticOnly": True,
        "attestable": False,
        "observationEvidence": report["observationEvidence"],
        "next": "Run warm-diagnostic --phase verify exactly once.",
    }, indent=2))


def verify_warm_diagnostic() -> None:
    report = read_json(WARM_DIAGNOSTIC)
    if report.get("status") != "prepared" or report.get("observationsConsumed") != 0:
        raise HarnessError(
            f"warm diagnostic is not awaiting its single observation: status={report.get('status')}"
        )
    if not report.get("observationEvidence"):
        raise HarnessError(
            "warm diagnostic observation metadata is missing; run --phase record-observation "
            "immediately after the single Computer Use response"
        )
    try:
        routing = require_computer_use_session(report, diagnostic=True)
        require_same_computer_use_service(report.get("computerUseService") or {}, routing)
        records = app_process_records()
        if (
            len(records) != 1
            or records[0].get("pid") != report.get("appPID")
            or records[0].get("exactPath") is not True
        ):
            raise HarnessError(
                "Vocello process identity changed during the single observation: "
                f"expected PID {report.get('appPID')}, found {records}"
            )
    except HarnessError as exc:
        report["status"] = "failed"
        report["verificationVerdict"] = "fail"
        report["updatedAt"] = utc_now()
        report["failure"] = str(exc)
        report["computerUseCrashDelta"] = new_service_crash_reports(
            report.get("computerUseCrashReportsAtStart") or []
        )
        write_json(WARM_DIAGNOSTIC, report)
        raise

    report["status"] = "verified"
    report["verificationVerdict"] = "pass"
    report["updatedAt"] = utc_now()
    report["observationsConsumed"] = 1
    report["computerUseCrashDelta"] = []
    write_json(WARM_DIAGNOSTIC, report)
    print(json.dumps({
        "diagnosticID": report["diagnosticID"],
        "status": "verified",
        "diagnosticOnly": True,
        "attestable": False,
        "observationBudget": 1,
        "observationsConsumed": 1,
        "next": "Target Finder in Computer Use, then run warm-diagnostic --phase abort to close Vocello.",
    }, indent=2))


def abort_warm_diagnostic() -> None:
    report = read_json(WARM_DIAGNOSTIC)
    prior_status = report.get("status")
    verification_verdict = report.get("verificationVerdict")
    if verification_verdict is None:
        verification_verdict = (
            "pass"
            if prior_status in {"verified", "aborted"} and report.get("observationsConsumed") == 1
            else "fail" if prior_status in {"failed", "blocked"} else "pending"
        )
    cleanup_errors: list[str] = []
    expected_pid = report.get("appPID")
    records = app_process_records()
    for record in records:
        if not record.get("exactPath") or record.get("pid") != expected_pid:
            cleanup_errors.append(
                "refusing diagnostic cleanup because Vocello process identity changed: "
                f"expected PID {expected_pid}, found {records}"
            )
            break
    if records and not cleanup_errors:
        try:
            os.kill(int(expected_pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 5
        while process_ids(APP_PROCESS) and time.monotonic() < deadline:
            time.sleep(0.1)
        if process_ids(APP_PROCESS):
            cleanup_errors.append("exact-path Vocello did not terminate during diagnostic cleanup")
    terminate_process(SERVICE_PROCESS)

    crash_delta = new_service_crash_reports(report.get("computerUseCrashReportsAtStart") or [])
    report["computerUseCrashDelta"] = crash_delta
    try:
        final_routing = require_computer_use_session(report, diagnostic=True)
        report["computerUseServiceAtCleanup"] = computer_use_service_identity(final_routing)
        require_same_computer_use_service(report.get("computerUseService") or {}, final_routing)
    except HarnessError as exc:
        cleanup_errors.append(str(exc))

    report["priorStatus"] = prior_status
    report["verificationVerdict"] = verification_verdict
    report["cleanupVerdict"] = "fail" if cleanup_errors else "pass"
    report["cleanupErrors"] = cleanup_errors
    report["status"] = (
        "cleaned"
        if verification_verdict == "pass" and not cleanup_errors
        else "failed"
    )
    report["completedAt"] = utc_now()
    report["updatedAt"] = utc_now()
    write_json(WARM_DIAGNOSTIC, report)
    print(json.dumps({
        "diagnosticID": report.get("diagnosticID"),
        "status": report["status"],
        "diagnosticOnly": True,
        "attestable": False,
        "verificationVerdict": report["verificationVerdict"],
        "cleanupVerdict": report["cleanupVerdict"],
        "computerUseCrashDelta": crash_delta,
        "errors": cleanup_errors,
    }, indent=2))
    if cleanup_errors:
        raise HarnessError("warm diagnostic cleanup found blocking problems")


def cmd_warm_diagnostic(args: argparse.Namespace) -> None:
    if args.phase == "prepare":
        prepare_warm_diagnostic(args)
    elif args.phase == "record-observation":
        record_warm_diagnostic_observation(args)
    elif args.phase == "verify":
        verify_warm_diagnostic()
    else:
        abort_warm_diagnostic()


def cmd_benchmark_manifest(_: argparse.Namespace) -> None:
    manifest = benchmark_manifest()
    scenario = benchmark_scenario()
    matrix = scenario.get("matrix") or {}
    print(json.dumps({
        "schemaVersion": 1,
        "takeCount": len(manifest),
        "designBrief": matrix.get("designBrief"),
        "cloneVoice": matrix.get("cloneVoice"),
        "takes": manifest,
    }, indent=2))


def cmd_benchmark_take(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    routing = require_computer_use_session(report)
    require_same_computer_use_service(report_computer_use_service_identity(report), routing)
    if report.get("suite") != "benchmark":
        raise HarnessError("benchmark-take requires a benchmark run")
    manifest = benchmark_manifest()
    if args.index < 1 or args.index > len(manifest):
        raise HarnessError(f"benchmark take index must be 1...{len(manifest)}")
    take = manifest[args.index - 1]
    progress = report["benchmark"]["takes"][args.index - 1]

    if args.phase == "begin":
        expected_index = next(
            (item["index"] for item in report["benchmark"]["takes"] if item["status"] != "pass"),
            None,
        )
        if expected_index != args.index:
            raise HarnessError(f"benchmark takes must run in order; next index is {expected_index}")
        if report["benchmark"].get("activeTakeIndex") is not None:
            raise HarnessError("another benchmark take is already active")
        if take["warmState"] == "cold":
            terminate_process(APP_PROCESS)
            terminate_process(SERVICE_PROCESS)
            set_debug_flag()
            report["appPID"] = launch_exact_app(
                report["runID"],
                report_support_root(report),
                force_cold=True,
                initial_sidebar_item="custom",
                crash_baseline=report.get("computerUseCrashReportsAtStart") or [],
            )
            post_launch_routing = require_computer_use_session(report)
            require_same_computer_use_service(
                report_computer_use_service_identity(report),
                post_launch_routing,
            )
        elif not exact_single_app_running():
            raise HarnessError("warm benchmark take requires the existing exact-path app process")
        cell = f"{take['mode']}/{take['length']}/{take['warmState']}#{take['repetition']}"
        write_json(BENCH_TAKE_FILE, {
            "benchRunID": report["runID"],
            "benchTakeIndex": str(take["index"]),
            "benchCell": cell,
            "benchWarmState": take["warmState"],
        })
        since = local_timestamp()
        progress.update({
            "status": "running",
            "startedAt": utc_now(),
            "since": since,
            "cell": cell,
            "attempt": int(progress.get("attempt", 0)) + 1,
        })
        report["benchmark"]["activeTakeIndex"] = args.index
        store_run(directory, report)
        append_jsonl(directory / "events.jsonl", {
            "timestamp": utc_now(), "event": "benchmark-take-began", **public_benchmark_take(take), "cell": cell,
        })
        print(json.dumps({**take, "cell": cell, "since": since, "appPID": report["appPID"]}, indent=2))
        return

    if report["benchmark"].get("activeTakeIndex") != args.index:
        raise HarnessError(f"benchmark take {args.index} is not active")
    text_digest = hashlib.sha256(take["text"].encode()).hexdigest()
    verified = any(
        assertion.get("kind") == "generation"
        and assertion.get("pass") is True
        and assertion.get("benchmarkTakeIndex") == args.index
        and assertion.get("mode") == take["mode"]
        and assertion.get("textDigest") == text_digest
        for assertion in report.get("deterministicAssertions", [])
    )
    if args.phase == "complete" and not verified:
        raise HarnessError(f"benchmark take {args.index} lacks matching deterministic generation proof")
    progress["status"] = "pass" if args.phase == "complete" else "fail"
    progress["completedAt"] = utc_now()
    report["benchmark"]["activeTakeIndex"] = None
    completed = sum(item["status"] == "pass" for item in report["benchmark"]["takes"])
    if completed == len(manifest):
        report["scenarios"]["generation-matrix"] = {
            "status": "pass",
            "message": f"Completed and deterministically verified {completed}/{len(manifest)} UI-driven takes",
            "evidence": "benchmark.takes",
            "updatedAt": utc_now(),
        }
    store_run(directory, report)
    append_jsonl(directory / "events.jsonl", {
        "timestamp": utc_now(), "event": f"benchmark-take-{args.phase}", **public_benchmark_take(take),
    })
    print(json.dumps({"index": args.index, "status": progress["status"], "completed": completed, "expected": len(manifest)}, indent=2))


def cmd_now(_: argparse.Namespace) -> None:
    print(local_timestamp())


def cmd_checkpoint(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    require_computer_use_session(report)
    entry = {
        "status": args.status,
        "message": args.message,
        "evidence": args.evidence,
        "updatedAt": utc_now(),
    }
    report["scenarios"][args.scenario] = entry
    append_jsonl(directory / "events.jsonl", {"timestamp": utc_now(), "event": "checkpoint", "scenario": args.scenario, **entry})
    store_run(directory, report)


def cmd_issue(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    issue = {
        "id": f"issue-{len(report['issues']) + 1}",
        "scenario": args.scenario,
        "severity": args.severity,
        "category": args.category,
        "summary": args.summary,
        "expected": args.expected,
        "actual": args.actual,
        "evidence": args.evidence,
        "recordedAt": utc_now(),
    }
    report["issues"].append(issue)
    write_json(directory / "issues.json", report["issues"])
    append_jsonl(directory / "events.jsonl", {"timestamp": utc_now(), "event": "issue", **issue})
    store_run(directory, report)


def parse_since(value: str) -> dt.datetime:
    try:
        return dt.datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%f").astimezone()
    except ValueError as exc:
        raise HarnessError("--since must be YYYY-MM-DD HH:MM:SS.mmm from the now command") from exc


def latest_history(database: Path, since: dt.datetime, expected_mode: str | None = None, expected_text: str | None = None) -> dict | None:
    if not database.is_file():
        return None
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    rows = connection.execute(
        "SELECT id, text, mode, modelTier, voice, audioPath, duration, createdAt FROM generations ORDER BY createdAt DESC"
    ).fetchall()
    connection.close()
    for row in rows:
        created = dt.datetime.strptime(row["createdAt"], "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=dt.timezone.utc)
        if created <= since.astimezone(dt.timezone.utc):
            continue
        if expected_mode and row["mode"] != expected_mode:
            continue
        if expected_text and row["text"] != expected_text:
            continue
        return dict(row)
    return None


def wav_metadata(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size <= 44:
        raise HarnessError(f"missing or empty WAV: {path}")
    try:
        with wave.open(str(path), "rb") as stream:
            frames = stream.getnframes()
            rate = stream.getframerate()
            duration = frames / rate if rate else 0
            return {"frames": frames, "sampleRate": rate, "channels": stream.getnchannels(), "durationSeconds": duration, "bytes": path.stat().st_size}
    except (wave.Error, EOFError) as exc:
        raise HarnessError(f"unreadable WAV {path}: {exc}") from exc


def cmd_verify_history(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    require_computer_use_session(report)
    row = latest_history(report_db(report), parse_since(args.since), args.mode, args.text)
    if row is None:
        raise HarnessError("no matching history row after --since")
    assertion = {"kind": "history", "pass": True, "mode": row["mode"], "historyID": row["id"], "audioPathDigest": hashlib.sha256(row["audioPath"].encode()).hexdigest()}
    report["deterministicAssertions"].append(assertion)
    store_run(directory, report)
    print(json.dumps(assertion, indent=2))


def cmd_verify_generation(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    require_computer_use_session(report)
    since = parse_since(args.since)
    deadline = time.monotonic() + args.timeout
    row = None
    while time.monotonic() < deadline:
        row = latest_history(report_db(report), since, args.mode, args.text)
        if row is not None:
            break
        time.sleep(1)
    if row is None:
        raise HarnessError(f"no matching {args.mode} generation within {args.timeout}s")
    audio = Path(row["audioPath"])
    metadata = wav_metadata(audio)
    if not row["duration"] or row["duration"] <= 0 or metadata["durationSeconds"] <= 0:
        raise HarnessError("generation duration is non-positive")
    assertion = {
        "kind": "generation",
        "pass": True,
        "mode": row["mode"],
        "historyID": row["id"],
        "textDigest": hashlib.sha256(row["text"].encode()).hexdigest(),
        "audioPathDigest": hashlib.sha256(str(audio).encode()).hexdigest(),
        "wav": metadata,
    }
    active_take = (report.get("benchmark") or {}).get("activeTakeIndex")
    if active_take is not None:
        assertion["benchmarkTakeIndex"] = active_take
    report["deterministicAssertions"].append(assertion)
    store_run(directory, report)
    write_json(directory / f"generation-{row['id']}.json", assertion)
    print(json.dumps(assertion, indent=2))


def read_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    rows = []
    for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise HarnessError(f"invalid JSONL {path}:{number}: {exc}") from exc
    return rows


def recorded_after(row: dict, started: str) -> bool:
    return str(row.get("recordedAt", "")) >= started


def run_rows(report: dict, layer: str) -> list[dict]:
    path = report_diagnostics(report) / layer / "generations.jsonl"
    rows = read_jsonl(path)
    run_id = report["runID"]
    return [
        row for row in rows
        if (row.get("notes") or {}).get("benchRunID") == run_id
    ]


def terminal_reason(row: dict) -> str | None:
    backend = row.get("backendMetrics") or {}
    transport = row.get("transportMetrics") or {}
    return backend.get("finishReason") or transport.get("finishReason") or row.get("finishReason")


def validate_probe_rows(engine_rows: list[dict], transport_rows: list[dict]) -> tuple[list[dict], list[str]]:
    errors: list[str] = []
    if not engine_rows:
        errors.append("missing backend engine telemetry")
    if not transport_rows:
        errors.append("missing middle-layer engine-service telemetry")

    for layer, rows in (("backend", engine_rows), ("transport", transport_rows)):
        forbidden_keys = {"text", "transcript", "filepath", "audiopath", "voicedescription"}
        for row in rows:
            stack: list[object] = [row]
            while stack:
                value = stack.pop()
                if isinstance(value, dict):
                    for key, child in value.items():
                        if key.lower() in forbidden_keys:
                            errors.append(f"{layer} telemetry contains forbidden raw field: {key}")
                        stack.append(child)
                elif isinstance(value, list):
                    stack.extend(value)
                elif isinstance(value, str) and ("/Users/" in value or "file://" in value):
                    errors.append(f"{layer} telemetry contains a raw local path")
        identities = [row.get("generationID") for row in rows if row.get("generationID")]
        duplicates = sorted({identity for identity in identities if identities.count(identity) > 1})
        if duplicates:
            errors.append(f"{layer} emitted duplicate terminal rows for: {', '.join(duplicates)}")

    engine_by_id = {row.get("generationID"): row for row in engine_rows if row.get("generationID")}
    transport_by_id = {row.get("generationID"): row for row in transport_rows if row.get("generationID")}
    common = sorted(set(engine_by_id) & set(transport_by_id))
    if not common:
        errors.append("no generationID is present in both backend and transport telemetry")

    checked = []
    for generation_id in common:
        engine = engine_by_id[generation_id]
        transport = transport_by_id[generation_id]
        engine_reason = terminal_reason(engine)
        transport_reason = terminal_reason(transport)
        if engine_reason and transport_reason and engine_reason != transport_reason:
            completed_aliases = {"completed", "eos"}
            if {engine_reason, transport_reason} - completed_aliases:
                errors.append(f"{generation_id}: terminal mismatch engine={engine_reason} transport={transport_reason}")
        if int(engine.get("schemaVersion", 0)) < 6 or not engine.get("backendMetrics"):
            errors.append(f"{generation_id}: missing typed backend schema-v6 metrics")
        if int(transport.get("schemaVersion", 0)) < 6 or not transport.get("transportMetrics"):
            errors.append(f"{generation_id}: missing typed transport schema-v6 metrics")
        counters = transport.get("transportMetrics", {}).get("counters") or transport.get("counters") or {}
        gaps = counters.get("chunkGaps", 0)
        duplicates = counters.get("duplicateChunks", 0)
        reordered = counters.get("outOfOrderChunks", 0)
        if gaps:
            errors.append(f"{generation_id}: transport reported {gaps} chunk gaps")
        if duplicates:
            errors.append(f"{generation_id}: transport reported {duplicates} duplicate chunks")
        if reordered:
            errors.append(f"{generation_id}: transport reported {reordered} out-of-order chunks")
        if counters.get("chunksForwarded", 0) <= 0:
            errors.append(f"{generation_id}: transport forwarded no chunks")
        stages = engine.get("stageMarks") or []
        times = [mark.get("tNS", mark.get("tMS", 0)) for mark in stages]
        if times != sorted(times):
            errors.append(f"{generation_id}: backend stage marks are not monotonic")
        completed = engine_reason in {"completed", "eos"} and transport_reason in {"completed", "eos"}
        barrier = (engine.get("backendMetrics") or {}).get("finalChunkBarrierObserved")
        if completed and engine.get("usedStreaming") and barrier is not True:
            errors.append(f"{generation_id}: completed stream lacks final-chunk barrier evidence")
        engine_at = str(engine.get("recordedAt", ""))
        transport_at = str(transport.get("recordedAt", ""))
        if engine_at and transport_at and engine_at > transport_at:
            errors.append(f"{generation_id}: transport completed before backend telemetry terminal")
        checked.append({
            "generationID": generation_id,
            "engineFinish": engine_reason,
            "transportFinish": transport_reason,
            "chunkGaps": gaps,
            "duplicateChunks": duplicates,
            "outOfOrderChunks": reordered,
            "finalChunkBarrierObserved": barrier,
        })
    return checked, errors


def cmd_verify_probes(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    require_computer_use_session(report)
    deadline = time.monotonic() + args.timeout
    while True:
        engine_rows = run_rows(report, "engine")
        transport_rows = run_rows(report, "engine-service")
        checked, errors = validate_probe_rows(engine_rows, transport_rows)
        if checked or time.monotonic() >= deadline:
            break
        time.sleep(0.25)

    correlated = len(checked)
    verdict = {
        "schemaVersion": 1,
        "pass": not errors,
        "runID": report["runID"],
        "engineRows": len(engine_rows),
        "transportRows": len(transport_rows),
        "correlatedRows": correlated,
        "checked": checked,
        "errors": errors,
        "verifiedAt": utc_now(),
    }
    write_json(directory / "probe-verdict.json", verdict)
    report["probeVerdict"] = "pass" if verdict["pass"] else "fail"
    report["deterministicAssertions"].append({"kind": "cross-layer-probes", "pass": verdict["pass"], "correlatedRows": correlated})
    store_run(directory, report)
    print(json.dumps(verdict, indent=2))
    if errors:
        raise HarnessError("cross-layer probe verification failed")


def cmd_xpc_status(_: argparse.Namespace) -> None:
    print(json.dumps({"appPIDs": process_ids(APP_PROCESS), "servicePIDs": process_ids(SERVICE_PROCESS)}, indent=2))


def cmd_xpc_kill(_: argparse.Namespace) -> None:
    require_computer_use_session()
    pids = process_ids(SERVICE_PROCESS)
    if not pids:
        raise HarnessError("engine service is not running")
    for pid in pids:
        os.kill(pid, signal.SIGKILL)
    time.sleep(1)
    if not process_ids(APP_PROCESS):
        raise HarnessError("Vocello exited after engine-service kill")
    print(json.dumps({"killedServicePIDs": pids, "appSurvived": True}, indent=2))


def cmd_xpc_wait(args: argparse.Namespace) -> None:
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        present = bool(process_ids(SERVICE_PROCESS))
        if present == args.present:
            print(json.dumps({"present": present, "servicePIDs": process_ids(SERVICE_PROCESS)}, indent=2))
            return
        time.sleep(0.5)
    raise HarnessError(f"engine service did not reach present={args.present} within {args.timeout}s")


def issue_counts(report: dict) -> dict[str, int]:
    return {severity: sum(issue.get("severity") == severity for issue in report.get("issues", [])) for severity in SEVERITIES}


def cmd_cleanup(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    cleanup_processes()
    restore_state(report)
    passed = not process_ids(APP_PROCESS) and not process_ids(SERVICE_PROCESS)
    passed = passed and bool((report.get("stateSnapshot") or {}).get("restored"))
    report["cleanupVerdict"] = "pass" if passed else "fail"
    append_jsonl(directory / "events.jsonl", {"timestamp": utc_now(), "event": "cleanup", "pass": passed})
    store_run(directory, report)
    if not passed:
        raise HarnessError("cleanup left app or engine-service processes running")


def cmd_finish(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    cleanup_processes()
    restore_state(report)
    cleanup_ok = not process_ids(APP_PROCESS) and not process_ids(SERVICE_PROCESS)
    cleanup_ok = cleanup_ok and bool((report.get("stateSnapshot") or {}).get("restored"))
    counts = issue_counts(report)
    severe = counts["blocker"] + counts["major"]
    scenarios = read_json(SCENARIOS).get("suites", {}).get(report.get("suite"), {}).get("includes", [])
    scenarios_ok = all((report.get("scenarios", {}).get(scenario) or {}).get("status") == "pass" for scenario in scenarios)
    crash_delta = new_service_crash_reports(report.get("computerUseCrashReportsAtStart") or [])
    final_routing = routing_status()
    report["computerUseCrashDelta"] = crash_delta
    report["computerUseFinalRouting"] = final_routing
    computer_use_ok = not crash_delta and routing_ready(final_routing)
    requested = args.status
    final = requested
    if requested == "pass" and (severe or report.get("probeVerdict") != "pass" or not cleanup_ok or not scenarios_ok or not computer_use_ok):
        final = "fail"
    completed = utc_now()
    report["status"] = final
    report["completedAt"] = completed
    try:
        started_at = dt.datetime.fromisoformat(report["startedAt"].replace("Z", "+00:00"))
        completed_at = dt.datetime.fromisoformat(completed.replace("Z", "+00:00"))
        report["durationSeconds"] = max(0.0, (completed_at - started_at).total_seconds())
    except (KeyError, TypeError, ValueError):
        report["durationSeconds"] = None
    report["cleanupVerdict"] = "pass" if cleanup_ok else "fail"
    report["issueCounts"] = counts
    store_run(directory, report)
    append_jsonl(directory / "events.jsonl", {"timestamp": utc_now(), "event": "run-finished", "status": final})
    print(json.dumps({"runID": report["runID"], "status": final, "cleanupVerdict": report["cleanupVerdict"], "issueCounts": counts}, indent=2))
    if final != "pass":
        raise HarnessError(f"run finished with status={final}")


def validate_report(report: dict, *, required_suite: str | None = None, current_fingerprints: bool = True) -> list[str]:
    errors = []
    required = [
        "schemaVersion", "runID", "suite", "status", "sourceFingerprint",
        "buildInputFingerprint", "appBinarySHA256", "executableIdentity",
        "environment", "probeVerdict", "cleanupVerdict",
    ]
    for key in required:
        if key not in report:
            errors.append(f"missing report field: {key}")
    if report.get("schemaVersion") != 2:
        errors.append(f"report schemaVersion {report.get('schemaVersion')} is diagnostic-only; schemaVersion 2 is required")
    if report.get("status") != "pass":
        errors.append(f"report status is {report.get('status')}, not pass")
    if report.get("probeVerdict") != "pass":
        errors.append("probe verdict is not pass")
    if report.get("cleanupVerdict") != "pass":
        errors.append("cleanup verdict is not pass")
    if report.get("computerUseCrashDelta"):
        errors.append("Computer Use service crashed during the run")
    final_routing = report.get("computerUseFinalRouting") or {}
    if final_routing and not routing_ready(final_routing):
        errors.append("Computer Use routing was not healthy when the run finished")
    counts = issue_counts(report)
    if counts["blocker"] or counts["major"]:
        errors.append("report contains blocker or major issues")
    required_scenarios = read_json(SCENARIOS).get("suites", {}).get(report.get("suite"), {}).get("includes", [])
    incomplete = [
        scenario for scenario in required_scenarios
        if (report.get("scenarios", {}).get(scenario) or {}).get("status") != "pass"
    ]
    if incomplete:
        errors.append("required scenarios are not passing: " + ", ".join(incomplete))
    suite_contract = read_json(SCENARIOS).get("suites", {}).get(report.get("suite"), {})
    budget_minutes = suite_contract.get("budgetMinutes")
    if budget_minutes is not None:
        duration = report.get("durationSeconds")
        if not isinstance(duration, (int, float)):
            errors.append("report is missing a numeric durationSeconds")
        elif duration > float(budget_minutes) * 60:
            errors.append(
                f"suite duration {duration:.1f}s exceeds the {budget_minutes}-minute budget"
            )
    if report.get("suite") == "benchmark":
        benchmark = report.get("benchmark") or {}
        takes = benchmark.get("takes") or []
        expected = benchmark.get("expectedTakeCount")
        if expected != len(benchmark_manifest()) or len(takes) != expected:
            errors.append("benchmark take manifest is incomplete")
        elif any(take.get("status") != "pass" for take in takes):
            errors.append("benchmark contains an incomplete or failed take")
    if required_suite and report.get("suite") not in SUITE_SATISFIERS.get(required_suite, set()):
        errors.append(f"suite {report.get('suite')} is insufficient; require an actual {required_suite} report")
    if current_fingerprints:
        if report.get("sourceFingerprint") != fingerprint():
            errors.append("source fingerprint is stale")
        if report.get("buildInputFingerprint") != fingerprint(build_inputs_only=True):
            errors.append("build-input fingerprint is stale")
        if APP_BINARY.is_file() and report.get("appBinarySHA256") != sha256(APP_BINARY):
            errors.append("app binary SHA-256 is stale")
        if (report.get("environment") or {}).get("toolchain") != toolchain_identity():
            errors.append("toolchain identity is stale")
    return errors


def cmd_validate_report(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    errors = validate_report(report, required_suite=args.suite)
    result = {"pass": not errors, "runID": report.get("runID"), "requiredSuite": args.suite, "errors": errors}
    write_json(directory / "report-validation.json", result)
    print(json.dumps(result, indent=2))
    if errors:
        raise HarnessError("report validation failed")


def evidence_digest(directory: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted((item for item in directory.rglob("*") if item.is_file()), key=lambda item: item.as_posix()):
        if path.name == "report-validation.json":
            continue
        digest.update(path.relative_to(directory).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def cmd_attest(args: argparse.Namespace) -> None:
    directory, report = load_run(args.run)
    errors = validate_report(report, required_suite=args.suite)
    if errors:
        raise HarnessError("cannot attest invalid report: " + "; ".join(errors))
    counts = issue_counts(report)
    identity = {
        "sourceFingerprint": report["sourceFingerprint"],
        "buildInputFingerprint": report["buildInputFingerprint"],
        "toolchainIdentity": report["environment"]["toolchain"],
    }
    existing = read_json(ATTESTATION) if ATTESTATION.is_file() else {}
    preserve = (
        existing.get("schemaVersion") == 2
        and all(existing.get(key) == value for key, value in identity.items())
    )
    entries = dict(existing.get("entries") or {}) if preserve else {}
    runtime_checks = dict(existing.get("runtimeChecks") or {}) if preserve else {}
    entries[report["suite"]] = {
        "status": report["status"],
        "suite": report["suite"],
        "runID": report["runID"],
        "completedAt": report["completedAt"],
        "issues": counts,
        "probeVerdict": report["probeVerdict"],
        "evidenceDigest": evidence_digest(directory),
        "cleanupVerdict": report["cleanupVerdict"],
        "durationSeconds": report.get("durationSeconds"),
        "executableIdentity": report["executableIdentity"],
    }
    attestation = {
        "schemaVersion": 2,
        **identity,
        "entries": {suite: entries.get(suite) for suite in ATTESTABLE_SUITES},
        "runtimeChecks": runtime_checks,
        "updatedAt": utc_now(),
    }
    write_json(ATTESTATION, attestation)
    print(json.dumps(attestation, indent=2))


def cmd_attest_runtime(args: argparse.Namespace) -> None:
    verdict = read_json(Path(args.file))
    if verdict.get("schemaVersion") != 1 or verdict.get("status") != "pass":
        raise HarnessError("runtime-check verdict must be schemaVersion 1 with status=pass")
    identity = {
        "sourceFingerprint": fingerprint(),
        "buildInputFingerprint": fingerprint(build_inputs_only=True),
        "toolchainIdentity": toolchain_identity(),
    }
    existing = read_json(ATTESTATION) if ATTESTATION.is_file() else {}
    preserve = (
        existing.get("schemaVersion") == 2
        and all(existing.get(key) == value for key, value in identity.items())
    )
    entries = dict(existing.get("entries") or {}) if preserve else {}
    runtime_checks = dict(existing.get("runtimeChecks") or {}) if preserve else {}
    runtime_checks[args.name] = {
        "status": "pass",
        "completedAt": verdict.get("completedAt") or utc_now(),
        "evidenceDigest": sha256(Path(args.file)),
        "summary": verdict.get("attestationSummary") or verdict.get("summary") or {},
    }
    attestation = {
        "schemaVersion": 2,
        **identity,
        "entries": {suite: entries.get(suite) for suite in ATTESTABLE_SUITES},
        "runtimeChecks": runtime_checks,
        "updatedAt": utc_now(),
    }
    write_json(ATTESTATION, attestation)
    print(json.dumps(attestation, indent=2))


def changed_paths(base: str) -> list[str]:
    if run(["/usr/bin/git", "rev-parse", "--verify", base], check=False).returncode != 0:
        raise HarnessError(f"base ref not found: {base}; set QVOICE_BASE_REF explicitly")
    paths = set(run(["/usr/bin/git", "diff", "--name-only", f"{base}...HEAD"]).stdout.splitlines())
    paths.update(run(["/usr/bin/git", "diff", "--name-only"]).stdout.splitlines())
    untracked = run(["/usr/bin/git", "ls-files", "--others", "--exclude-standard"]).stdout.splitlines()
    paths.update(untracked)
    paths.discard(ATTESTATION.relative_to(ROOT).as_posix())
    paths = {path for path in paths if path and not path.startswith("QwenVoice_MLXAudio_Corrected_Report_Series_2026-07-10/")}
    return sorted(paths)


def classify_paths(paths: list[str], config: dict) -> tuple[list[str], list[str], list[dict]]:
    suites: set[str] = set(config.get("defaultRequiredSuites") or [])
    runtime_checks: set[str] = set(config.get("defaultRequiredRuntimeChecks") or [])
    matches: list[dict] = []
    for path in paths:
        for rule in config.get("rules", []):
            if any(fnmatch.fnmatch(path, pattern) for pattern in rule.get("patterns", [])):
                rule_suites = set(rule.get("requiredSuites") or [])
                rule_checks = set(rule.get("requiredRuntimeChecks") or [])
                suites.update(rule_suites)
                runtime_checks.update(rule_checks)
                matches.append({
                    "path": path,
                    "requiredSuites": sorted(rule_suites),
                    "requiredRuntimeChecks": sorted(rule_checks),
                })
    return sorted(suites), sorted(runtime_checks), matches


def validate_attestation(attestation: dict, required_suites: list[str], required_runtime_checks: list[str], *, ci: bool = False) -> list[str]:
    errors: list[str] = []
    if attestation.get("schemaVersion") != 2:
        return [f"attestation schemaVersion {attestation.get('schemaVersion')} is diagnostic-only; schemaVersion 2 is required"]
    if attestation.get("sourceFingerprint") != fingerprint():
        errors.append("attestation source fingerprint is stale")
    if attestation.get("buildInputFingerprint") != fingerprint(build_inputs_only=True):
        errors.append("attestation build-input fingerprint is stale")
    if not toolchain_identity_matches(
        attestation.get("toolchainIdentity") or {}, toolchain_identity(), ci=ci
    ):
        errors.append("attestation toolchain identity is stale")
    entries = attestation.get("entries") or {}
    for required in required_suites:
        satisfiers = SUITE_SATISFIERS[required]
        candidates = [entries.get(suite) for suite in satisfiers if entries.get(suite)]
        valid = []
        for entry in candidates:
            entry_errors = []
            if entry.get("status") != "pass":
                entry_errors.append("status")
            if entry.get("probeVerdict") != "pass":
                entry_errors.append("probe")
            if entry.get("cleanupVerdict") != "pass":
                entry_errors.append("cleanup")
            counts = entry.get("issues") or {}
            if counts.get("blocker", 0) or counts.get("major", 0):
                entry_errors.append("issues")
            executable = entry.get("executableIdentity") or {}
            if not ci and executable.get("sha256") != sha256(APP_BINARY):
                entry_errors.append("local executable")
            if not entry_errors:
                valid.append(entry)
        if not valid:
            errors.append(f"missing valid {required} evidence (accepted suites: {', '.join(sorted(satisfiers))})")
    runtime = attestation.get("runtimeChecks") or {}
    for check in required_runtime_checks:
        if (runtime.get(check) or {}).get("status") != "pass":
            errors.append(f"missing passing runtime check: {check}")
    if not APP_BINARY.is_file():
        errors.append(f"current exact-path app binary is missing: {APP_BINARY}")
    return errors


def cmd_impact(args: argparse.Namespace) -> None:
    config = read_json(IMPACT)
    base = args.base or os.environ.get("QVOICE_BASE_REF") or "origin/main"
    paths = changed_paths(base)
    suites, runtime_checks, matches = classify_paths(paths, config)
    result = {
        "schemaVersion": 2,
        "base": base,
        "requiredSuites": suites,
        "requiredRuntimeChecks": runtime_checks,
        "changedPaths": paths,
        "matches": matches,
    }
    print(json.dumps(result, indent=2))
    if args.check and (suites or runtime_checks):
        attestation = read_json(ATTESTATION)
        errors = validate_attestation(attestation, suites, runtime_checks, ci=args.ci)
        if errors:
            raise HarnessError("Computer Use attestation required: " + "; ".join(errors))


def cmd_release_check(args: argparse.Namespace) -> None:
    attestation = read_json(ATTESTATION)
    errors = validate_attestation(
        attestation,
        ["full", "benchmark"],
        ["telemetry-overhead"],
        ci=args.ci,
    )
    result = {
        "schemaVersion": 1,
        "status": "pass" if not errors else "fail",
        "requiredSuites": ["full", "benchmark"],
        "requiredRuntimeChecks": ["telemetry-overhead"],
        "review": "pass" if not errors and (attestation.get("entries") or {}).get("full") else "fail",
        "benchUI": "pass" if not errors and (attestation.get("entries") or {}).get("benchmark") else "fail",
        "errors": errors,
    }
    print(json.dumps(result, indent=2))
    if errors:
        raise HarnessError("release frontend readiness failed: " + "; ".join(errors))


def cmd_model_readiness_check(args: argparse.Namespace) -> None:
    """Require current full UI evidence before any non-UI generation lane."""
    attestation = read_json(ATTESTATION)
    errors = validate_attestation(attestation, ["full"], [], ci=args.ci)
    result = {
        "schemaVersion": 1,
        "status": "pass" if not errors else "fail",
        "requiredSuite": "full",
        "requiredScenario": "model-readiness",
        "evidencePolicy": "visible-computer-use-settings",
        "errors": errors,
    }
    print(json.dumps(result, indent=2))
    if errors:
        raise HarnessError(
            "visible model readiness is required before generation: " + "; ".join(errors)
        )


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    sub = root.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor")
    doctor.add_argument("--suite", choices=SUITES, default="quick")
    doctor.add_argument("--json", action="store_true")
    doctor.set_defaults(func=cmd_doctor)

    routing = sub.add_parser("routing-audit")
    routing.set_defaults(func=cmd_routing_audit)

    start = sub.add_parser("start")
    start.add_argument("--suite", choices=("quick", "full", "benchmark", "destructive"), required=True)
    start.add_argument("--allow-destructive", action="store_true")
    start.set_defaults(func=cmd_start)

    diagnostic = sub.add_parser("warm-diagnostic")
    diagnostic.add_argument(
        "--phase",
        choices=("prepare", "record-observation", "verify", "abort"),
        required=True,
    )
    diagnostic.add_argument("--initial-screen", choices=INITIAL_SIDEBAR_ITEMS, default="history")
    diagnostic.add_argument("--acknowledge-known-bad-helper", action="store_true")
    diagnostic.add_argument("--app-path", default=str(APP))
    diagnostic.add_argument("--accessibility-length", type=int, default=0)
    diagnostic.add_argument("--window-count", type=int, default=0)
    diagnostic.add_argument("--screenshot-url")
    diagnostic.set_defaults(func=cmd_warm_diagnostic)

    now = sub.add_parser("now")
    now.set_defaults(func=cmd_now)

    manifest = sub.add_parser("benchmark-manifest")
    manifest.set_defaults(func=cmd_benchmark_manifest)

    take = sub.add_parser("benchmark-take")
    take.add_argument("--run")
    take.add_argument("--index", type=int, required=True)
    take.add_argument("--phase", choices=("begin", "complete", "fail"), required=True)
    take.set_defaults(func=cmd_benchmark_take)

    checkpoint = sub.add_parser("checkpoint")
    checkpoint.add_argument("--run")
    checkpoint.add_argument("--scenario", required=True)
    checkpoint.add_argument("--status", choices=("running", "pass", "fail", "blocked", "skipped"), required=True)
    checkpoint.add_argument("--message", required=True)
    checkpoint.add_argument("--evidence")
    checkpoint.set_defaults(func=cmd_checkpoint)

    issue = sub.add_parser("issue")
    issue.add_argument("--run")
    issue.add_argument("--scenario", required=True)
    issue.add_argument("--severity", choices=SEVERITIES, required=True)
    issue.add_argument("--category", choices=("functional", "visual", "accessibility", "automation", "environment"), required=True)
    issue.add_argument("--summary", required=True)
    issue.add_argument("--expected", required=True)
    issue.add_argument("--actual", required=True)
    issue.add_argument("--evidence")
    issue.set_defaults(func=cmd_issue)

    for name, function in (("verify-generation", cmd_verify_generation), ("verify-history", cmd_verify_history)):
        command = sub.add_parser(name)
        command.add_argument("--run")
        command.add_argument("--since", required=True)
        command.add_argument("--mode", choices=("custom", "design", "clone"))
        command.add_argument("--text")
        if name == "verify-generation":
            command.add_argument("--timeout", type=int, default=300)
        command.set_defaults(func=function)

    probes = sub.add_parser("verify-probes")
    probes.add_argument("--run")
    probes.add_argument("--timeout", type=int, default=20)
    probes.set_defaults(func=cmd_verify_probes)

    status = sub.add_parser("xpc-status")
    status.set_defaults(func=cmd_xpc_status)
    kill = sub.add_parser("xpc-kill")
    kill.set_defaults(func=cmd_xpc_kill)
    wait = sub.add_parser("xpc-wait")
    group = wait.add_mutually_exclusive_group(required=True)
    group.add_argument("--present", action="store_true")
    group.add_argument("--absent", action="store_true")
    wait.add_argument("--timeout", type=int, default=60)
    wait.set_defaults(func=cmd_xpc_wait)

    cleanup = sub.add_parser("cleanup")
    cleanup.add_argument("--run")
    cleanup.set_defaults(func=cmd_cleanup)
    finish = sub.add_parser("finish")
    finish.add_argument("--run")
    finish.add_argument("--status", choices=("pass", "fail", "blocked"), required=True)
    finish.set_defaults(func=cmd_finish)

    validate = sub.add_parser("validate-report")
    validate.add_argument("--run")
    validate.add_argument("--suite", choices=("quick", "full", "benchmark"))
    validate.set_defaults(func=cmd_validate_report)
    attest = sub.add_parser("attest")
    attest.add_argument("--run")
    attest.add_argument("--suite", choices=("quick", "full", "benchmark"))
    attest.set_defaults(func=cmd_attest)

    attest_runtime = sub.add_parser("attest-runtime")
    attest_runtime.add_argument("--name", required=True)
    attest_runtime.add_argument("--file", required=True)
    attest_runtime.set_defaults(func=cmd_attest_runtime)

    impact = sub.add_parser("impact")
    impact.add_argument("--base")
    impact.add_argument("--check", action="store_true")
    impact.add_argument("--ci", action="store_true", help="skip local signed executable hash comparison")
    impact.set_defaults(func=cmd_impact)

    release_check = sub.add_parser("release-check")
    release_check.add_argument("--ci", action="store_true")
    release_check.set_defaults(func=cmd_release_check)

    model_readiness = sub.add_parser("model-readiness-check")
    model_readiness.add_argument("--ci", action="store_true")
    model_readiness.set_defaults(func=cmd_model_readiness_check)
    return root


def main() -> int:
    args = parser().parse_args()
    if getattr(args, "absent", False):
        args.present = False
    try:
        args.func(args)
        return 0
    except HarnessError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
