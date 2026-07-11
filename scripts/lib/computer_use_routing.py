#!/usr/bin/env python3
"""Read-only compatibility, provenance, identity, process, and crash checks for Computer Use."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess


PROCESS_NAME = "SkyComputerUseService"
PLUGIN_FRAGMENT = "/.codex/plugins/cache/openai-bundled/computer-use/"
DESKTOP_RUNTIME_RELATIVE_APP = Path("computer-use") / "Codex Computer Use.app"
SERVICE_RELATIVE_EXECUTABLE = Path("Contents") / "MacOS" / PROCESS_NAME
CLIENT_RELATIVE_EXECUTABLE = Path("Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")
SERVICE_SUFFIX = "/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"
DESKTOP_APP = Path("/Applications/ChatGPT.app")
APP_BUNDLED_RELATIVE_APP = Path("Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app")
DESKTOP_NODE_REPL_RELATIVE_EXECUTABLE = Path("Contents/Resources/cua_node/bin/node_repl")
OBSERVED_DESKTOP_RUNTIME_VERSIONS = {"26.707.41301"}
DYLD_MISSING_SYMBOL = "_swift_task_addPriorityEscalationHandler"
COMPUTER_USE_PLUGIN_ID = "computer-use@openai-bundled"
PLUGIN_SKILL_RELATIVE_PATH = Path("skills/computer-use/SKILL.md")
PLUGIN_WRAPPER_RELATIVE_PATH = Path("scripts/computer-use-client.mjs")
KNOWN_BAD_AX_BOUNDS_UUID = "61C0B615-7F27-3A07-8D97-77ABC7139236"
KNOWN_BAD_AX_BOUNDS_BUILD = "1000366"
KNOWN_BAD_AX_BOUNDS_OFFSETS = (6740000, 7072780, 6972084, 6971180)
KNOWN_BAD_HELPER_RULE = {
    "id": "computer-use-1000366-ax-tree-bounds-trap",
    "bundleVersion": KNOWN_BAD_AX_BOUNDS_BUILD,
    "executableUUID": KNOWN_BAD_AX_BOUNDS_UUID,
    "classification": "ax-tree-bounds-trap-1000366",
}


def _run(command: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=False, text=True, capture_output=True)


def _sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    except OSError:
        return None
    return digest.hexdigest()


def _plist(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return {}


def _json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def _codex_cli(desktop_app: Path = DESKTOP_APP) -> Path | None:
    bundled = desktop_app / "Contents" / "Resources" / "codex"
    if bundled.is_file():
        return bundled
    discovered = shutil.which("codex")
    return Path(discovered) if discovered else None


def plugin_inventory(desktop_app: Path = DESKTOP_APP) -> dict:
    """Return the read-only Codex plugin-list view for bundled Computer Use."""
    cli = _codex_cli(desktop_app)
    base = {
        "pluginInventoryAvailable": False,
        "pluginInventoryError": None,
        "pluginInventoryCLI": str(cli) if cli else None,
        "computerUsePluginInstalled": False,
        "computerUsePluginEnabled": False,
        "computerUsePluginVersion": None,
        "computerUsePluginInventoryPath": None,
        "computerUsePluginInventoryCachePath": None,
    }
    if cli is None:
        return {**base, "pluginInventoryError": "Codex CLI was not found"}
    result = _run([str(cli), "plugin", "list", "--available", "--json"])
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        return {**base, "pluginInventoryError": f"Codex plugin inventory failed: {detail}"}
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return {**base, "pluginInventoryError": f"Codex plugin inventory returned invalid JSON: {exc}"}
    if not isinstance(payload, dict):
        return {**base, "pluginInventoryError": "Codex plugin inventory was not an object"}
    records = [
        item
        for section in ("installed", "available")
        for item in (payload.get(section) or [])
        if isinstance(item, dict) and item.get("pluginId") == COMPUTER_USE_PLUGIN_ID
    ]
    if not records:
        return {
            **base,
            "pluginInventoryAvailable": True,
            "pluginInventoryError": f"{COMPUTER_USE_PLUGIN_ID} is absent from the plugin inventory",
        }
    record = next((item for item in records if item.get("installed") is True), records[0])
    source = record.get("source") if isinstance(record.get("source"), dict) else {}
    return {
        **base,
        "pluginInventoryAvailable": True,
        "computerUsePluginInstalled": record.get("installed") is True,
        "computerUsePluginEnabled": record.get("enabled") is True,
        "computerUsePluginVersion": record.get("version"),
        "computerUsePluginInventoryPath": source.get("path"),
        "computerUsePluginInventoryCachePath": record.get("cachePath") or source.get("cachePath"),
    }


def _executable_uuids(path: Path) -> list[str]:
    if not path.is_file():
        return []
    result = _run(["/usr/bin/dwarfdump", "--uuid", str(path)])
    if result.returncode != 0:
        return []
    values = []
    for match in re.finditer(r"^UUID:\s*([0-9A-Fa-f-]+)\s+\([^)]+\)", result.stdout, re.MULTILINE):
        value = match.group(1).upper()
        if value not in values:
            values.append(value)
    return values


def _section(config_text: str, names: tuple[str, ...]) -> str | None:
    alternatives = "|".join(re.escape(name) for name in names)
    match = re.search(
        rf"^\[(?:{alternatives})\]\s*$\n(?P<body>.*?)(?=^\[|\Z)",
        config_text,
        re.MULTILINE | re.DOTALL,
    )
    return match.group("body") if match else None


def _string_value(text: str | None, key: str) -> str | None:
    if text is None:
        return None
    match = re.search(rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"\s*$', text, re.MULTILINE)
    return match.group(1) if match else None


def _bool_value(text: str | None, key: str) -> bool | None:
    if text is None:
        return None
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*(true|false)\s*$", text, re.MULTILINE)
    return match.group(1) == "true" if match else None


def _array_value(text: str | None, key: str) -> list[str] | None:
    if text is None:
        return None
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*(\[[^\n]*\])\s*$", text, re.MULTILINE)
    if not match:
        return None
    try:
        value = json.loads(match.group(1))
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, list) and all(isinstance(item, str) for item in value) else None


def configured_service_app(config_text: str) -> str | None:
    node_repl_env = _section(
        config_text,
        (
            "mcp_servers.node_repl.env",
            'mcp_servers."node_repl".env',
            'mcp_servers.node_repl."env"',
            'mcp_servers."node_repl"."env"',
        ),
    )
    return _string_value(node_repl_env, "SKY_CUA_SERVICE_PATH")


def _desktop_identity(desktop_app: Path = DESKTOP_APP) -> dict:
    payload = _plist(desktop_app / "Contents" / "Info.plist")
    return {
        "appPath": str(desktop_app),
        "version": payload.get("CFBundleShortVersionString"),
        "build": payload.get("CFBundleVersion"),
        "bundleIdentifier": payload.get("CFBundleIdentifier"),
    }


def _macos_version() -> str | None:
    result = _run(["/usr/bin/sw_vers", "-productVersion"])
    return result.stdout.strip() or None


def _codesign_details(app: Path) -> tuple[str | None, str | None, str | None, bool]:
    details = _run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)])
    output = details.stdout + details.stderr
    identifier = re.search(r"^Identifier=(.+)$", output, re.MULTILINE)
    team = re.search(r"^TeamIdentifier=(.+)$", output, re.MULTILINE)
    requirement_result = _run(["/usr/bin/codesign", "-dr", "-", str(app)])
    requirement_output = (requirement_result.stdout + requirement_result.stderr).strip()
    requirement_line = next((line for line in requirement_output.splitlines() if "designated =>" in line), None)
    requirement = requirement_line.split("designated =>", 1)[-1].strip() if requirement_line else None
    verification = _run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    return (
        identifier.group(1).strip() if identifier else None,
        team.group(1).strip() if team else None,
        requirement,
        verification.returncode == 0,
    )


def bundle_identity(app: Path) -> dict:
    executable = app / SERVICE_RELATIVE_EXECUTABLE
    payload = _plist(app / "Contents" / "Info.plist")
    identifier, team, requirement, valid = _codesign_details(app) if app.is_dir() else (None, None, None, False)
    executable_uuids = _executable_uuids(executable)
    return {
        "appPath": str(app),
        "exists": app.is_dir(),
        "executablePath": str(executable),
        "bundleIdentifier": identifier or payload.get("CFBundleIdentifier"),
        "shortVersion": payload.get("CFBundleShortVersionString"),
        "bundleVersion": payload.get("CFBundleVersion"),
        "teamIdentifier": team,
        "designatedRequirement": requirement,
        "executableSHA256": _sha256(executable),
        "executableUUIDs": executable_uuids,
        "executableUUID": executable_uuids[0] if executable_uuids else None,
        "codesignValid": valid,
    }


IDENTITY_FIELDS = (
    "bundleIdentifier",
    "shortVersion",
    "bundleVersion",
    "teamIdentifier",
    "designatedRequirement",
    "executableSHA256",
    "executableUUIDs",
)


def identity_comparison(source: dict, runtime: dict) -> dict:
    comparisons = {
        "sourceRuntimeBundleIDMatch": source.get("bundleIdentifier") is not None and source.get("bundleIdentifier") == runtime.get("bundleIdentifier"),
        "sourceRuntimeVersionMatch": source.get("shortVersion") is not None and source.get("shortVersion") == runtime.get("shortVersion"),
        "sourceRuntimeBuildMatch": source.get("bundleVersion") is not None and source.get("bundleVersion") == runtime.get("bundleVersion"),
        "sourceRuntimeTeamIDMatch": source.get("teamIdentifier") is not None and source.get("teamIdentifier") == runtime.get("teamIdentifier"),
        "sourceRuntimeDesignatedRequirementMatch": source.get("designatedRequirement") is not None and source.get("designatedRequirement") == runtime.get("designatedRequirement"),
        "sourceRuntimeExecutableHashMatch": source.get("executableSHA256") is not None and source.get("executableSHA256") == runtime.get("executableSHA256"),
        "sourceRuntimeExecutableUUIDMatch": bool(source.get("executableUUIDs")) and source.get("executableUUIDs") == runtime.get("executableUUIDs"),
        "sourceRuntimeCodesignValid": source.get("codesignValid") is True and runtime.get("codesignValid") is True,
    }
    comparisons["sourceRuntimeIdentityMatch"] = bool(source.get("exists") and runtime.get("exists")) and all(comparisons.values())
    return comparisons


def process_ids() -> list[int]:
    result = _run(["/usr/bin/pgrep", "-x", PROCESS_NAME])
    return [int(line) for line in result.stdout.splitlines() if line.strip().isdigit()]


def process_command(pid: int) -> str | None:
    result = _run(["/bin/ps", "-p", str(pid), "-o", "command="])
    value = result.stdout.strip()
    return value or None


def _service_executable_from_command(command: str | None) -> str | None:
    if not command or SERVICE_SUFFIX not in command:
        return command
    end = command.index(SERVICE_SUFFIX) + len(SERVICE_SUFFIX)
    return command[:end]


def service_version(executable: str | None) -> str | None:
    if not executable:
        return None
    try:
        app = Path(executable).parents[2]
    except IndexError:
        return None
    payload = _plist(app / "Contents" / "Info.plist")
    return str(payload.get("CFBundleShortVersionString") or payload.get("CFBundleVersion") or "") or None


def service_records(
    *,
    plugin_source_app: Path,
    desktop_runtime_app: Path,
    plugin_identity: dict | None = None,
    runtime_identity: dict | None = None,
) -> list[dict]:
    plugin_executable = plugin_source_app / SERVICE_RELATIVE_EXECUTABLE
    runtime_executable = desktop_runtime_app / SERVICE_RELATIVE_EXECUTABLE
    records = []
    for pid in process_ids():
        command = process_command(pid)
        executable = _service_executable_from_command(command)
        path = Path(executable) if executable else None
        expected = bool(path and path == runtime_executable)
        fallback = bool(path and path == plugin_executable)
        identity = runtime_identity if expected else plugin_identity if fallback else {}
        records.append({
            "pid": pid,
            "command": command,
            "executable": executable,
            "route": "expected" if expected else "plugin-fallback" if fallback else "unknown",
            "desktopManagedRuntimePath": expected,
            "pluginFallbackPath": fallback,
            "unknownPath": not expected and not fallback,
            "version": identity.get("shortVersion") or service_version(executable),
            "build": identity.get("bundleVersion"),
            "uuid": identity.get("executableUUID"),
            "executableUUIDs": identity.get("executableUUIDs") or [],
            "executableSHA256": identity.get("executableSHA256"),
        })
    return records


def related_process_counts() -> dict:
    result = _run(["/bin/ps", "-axo", "pid=,ppid=,stat=,command="])
    rows = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(maxsplit=3)
        if len(parts) != 4 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        rows.append({"pid": int(parts[0]), "ppid": int(parts[1]), "stat": parts[2], "command": parts[3]})
    desktop_pids = {
        row["pid"] for row in rows
        if row["command"].startswith(str(DESKTOP_APP / "Contents" / "MacOS" / "ChatGPT"))
    }
    mcp_clients = [row for row in rows if "SkyComputerUseClient" in row["command"] and re.search(r"(?:^|\s)mcp(?:\s|$)", row["command"])]
    turn_ended = [row for row in rows if "SkyComputerUseClient" in row["command"] and "turn-ended" in row["command"]]
    node_repls = [row for row in rows if re.search(r"(?:^|/)node_repl(?:\s|$)", row["command"])]
    stdio_servers = [row for row in rows if "codex" in row["command"] and "app-server" in row["command"] and "stdio://" in row["command"]]
    zombies = [row for row in rows if row["stat"].startswith("Z") and row["ppid"] in desktop_pids]
    live_pids = {row["pid"] for row in rows}
    client_rows = mcp_clients + turn_ended
    orphaned_clients = [
        row for row in client_rows
        if row["ppid"] > 1 and row["ppid"] not in live_pids
    ]
    duplicate_client_keys = {
        (row["ppid"], "mcp" if row in mcp_clients else "turn-ended", row["command"])
        for row in client_rows
        if sum(
            other["ppid"] == row["ppid"]
            and other["command"] == row["command"]
            and ((other in mcp_clients) == (row in mcp_clients))
            for other in client_rows
        ) > 1
    }
    stale = bool(orphaned_clients or duplicate_client_keys or zombies)
    return {
        "mcpClientProcessCount": len(mcp_clients),
        "turnEndedClientCount": len(turn_ended),
        "notificationClientProcessCount": len(turn_ended),
        "nodeReplProcessCount": len(node_repls),
        "stdioAppServerCount": len(stdio_servers),
        "zombieChildCount": len(zombies),
        "orphanedComputerUseClientCount": len(orphaned_clients),
        "duplicateComputerUseClientSetCount": len(duplicate_client_keys),
        "computerUseProcessFamilies": {
            "mcpClients": mcp_clients,
            "notificationClients": turn_ended,
            "nodeRepls": node_repls,
            "stdioAppServers": stdio_servers,
            "zombies": zombies,
        },
        "staleClientSetDetected": stale,
    }


def _ips_documents(text: str) -> tuple[dict, dict]:
    decoder = json.JSONDecoder()
    documents: list[dict] = []
    offset = 0
    while len(documents) < 2:
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset >= len(text):
            break
        try:
            value, offset = decoder.raw_decode(text, offset)
        except json.JSONDecodeError:
            break
        documents.append(value if isinstance(value, dict) else {})
    if len(documents) == 1 and any(key in documents[0] for key in ("threads", "exception", "termination")):
        return {}, documents[0]
    return (
        documents[0] if documents else {},
        documents[1] if len(documents) > 1 else {},
    )


def _crash_metadata(text: str) -> dict:
    header, body = _ips_documents(text)
    exception = body.get("exception") if isinstance(body.get("exception"), dict) else {}
    termination = body.get("termination") if isinstance(body.get("termination"), dict) else {}
    threads = body.get("threads") if isinstance(body.get("threads"), list) else []
    triggered = next(
        (thread for thread in threads if isinstance(thread, dict) and thread.get("triggered") is True),
        {},
    )
    frames = triggered.get("frames") if isinstance(triggered.get("frames"), list) else []
    offsets = [
        frame.get("imageOffset")
        for frame in frames
        if isinstance(frame, dict) and isinstance(frame.get("imageOffset"), int)
    ]
    state = triggered.get("threadState") if isinstance(triggered.get("threadState"), dict) else {}
    registers = state.get("x") if isinstance(state.get("x"), list) else []

    def register(index: int) -> int | None:
        if index >= len(registers) or not isinstance(registers[index], dict):
            return None
        value = registers[index].get("value")
        return value if isinstance(value, int) else None

    bundle = body.get("bundleInfo") if isinstance(body.get("bundleInfo"), dict) else {}
    helper_uuid = header.get("slice_uuid") or body.get("slice_uuid")
    helper_uuid = str(helper_uuid).upper() if helper_uuid else None
    helper_build = header.get("build_version") or bundle.get("CFBundleVersion")
    helper_build = str(helper_build) if helper_build is not None else None
    exception_type = exception.get("type")
    signal = exception.get("signal")
    queue = triggered.get("queue")
    esr = state.get("esr") if isinstance(state.get("esr"), dict) else {}
    esr_description = esr.get("description")
    dyld = (
        DYLD_MISSING_SYMBOL in text
        and (
            "OS_REASON_DYLD" in text
            or str(termination.get("namespace", "")).upper() == "DYLD"
        )
    )
    bounds_trap = all((
        helper_build == KNOWN_BAD_AX_BOUNDS_BUILD,
        helper_uuid == KNOWN_BAD_AX_BOUNDS_UUID,
        exception_type == "EXC_BREAKPOINT",
        signal == "SIGTRAP",
        queue == "com.apple.root.user-initiated-qos.cooperative",
        tuple(offsets[:len(KNOWN_BAD_AX_BOUNDS_OFFSETS)]) == KNOWN_BAD_AX_BOUNDS_OFFSETS,
        register(8) == 4,
        register(21) == 5,
        isinstance(esr_description, str) and "brk 1" in esr_description,
    ))
    signatures = [
        value for value in (
            "OS_REASON_DYLD",
            DYLD_MISSING_SYMBOL,
            "SIGTRAP",
            "EXC_BREAKPOINT",
            "EXC_BAD_ACCESS",
            "AXNotificationObserver",
            "UIElementTree",
            "SkyshotOperation",
        )
        if value in text
    ]
    accessibility_evidence = any(
        marker in text
        for marker in ("AXNotificationObserver", "UIElementTree", "SkyshotOperation", "AccessibilitySupport")
    )
    stack_evidence = (
        "stack overflow" in text.lower()
        or "stack exhaustion" in text.lower()
        or text.count("UIElementTree") > 1
        or text.count("AccessibilitySupport") > 2
    )
    if dyld:
        classification = "dyld-compatibility"
    elif bounds_trap:
        classification = "ax-tree-bounds-trap-1000366"
    elif exception_type == "EXC_BAD_ACCESS" or "EXC_BAD_ACCESS" in text:
        classification = "ax-stack-exhaustion" if accessibility_evidence and stack_evidence else "bad-access"
    elif (exception_type == "EXC_BREAKPOINT" or signal == "SIGTRAP" or "EXC_BREAKPOINT" in text or "SIGTRAP" in text) and accessibility_evidence:
        classification = "breakpoint-with-accessibility-observers"
    elif exception_type == "EXC_BREAKPOINT" or signal == "SIGTRAP" or "EXC_BREAKPOINT" in text or "SIGTRAP" in text:
        classification = "breakpoint-sigtrap"
    else:
        classification = "other"
    return {
        "classification": classification,
        "dyldCompatibilityFailure": dyld,
        "knownBadBoundsTrap": bounds_trap,
        "signatures": signatures,
        "helperUUID": helper_uuid,
        "helperBuild": helper_build,
        "exceptionType": exception_type,
        "signal": signal,
        "faultQueue": queue,
        "faultFrameOffsets": offsets,
        "faultRegisters": {"x8": register(8), "x21": register(21)},
    }


def classify_crash(text: str) -> tuple[str, bool, list[str]]:
    metadata = _crash_metadata(text)
    return (
        metadata["classification"],
        metadata["dyldCompatibilityFailure"],
        metadata["signatures"],
    )


def known_bad_helper_rule(identity: dict) -> dict | None:
    uuids = {str(value).upper() for value in identity.get("executableUUIDs") or []}
    if identity.get("executableUUID"):
        uuids.add(str(identity["executableUUID"]).upper())
    if identity.get("bundleVersion") == KNOWN_BAD_AX_BOUNDS_BUILD and KNOWN_BAD_AX_BOUNDS_UUID in uuids:
        return dict(KNOWN_BAD_HELPER_RULE)
    return None


def service_crash_reports(root: Path | None = None) -> list[dict]:
    reports_root = root or Path.home() / "Library" / "Logs" / "DiagnosticReports"
    reports = []
    for path in reports_root.glob(f"{PROCESS_NAME}-*.ips"):
        try:
            text = path.read_text(errors="replace")
            modified_at = path.stat().st_mtime
        except OSError:
            continue
        metadata = _crash_metadata(text)
        reports.append({
            "path": str(path),
            "modifiedAt": dt.datetime.fromtimestamp(modified_at, dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            **metadata,
            "_mtime": modified_at,
        })
    reports.sort(key=lambda item: item["_mtime"])
    for item in reports:
        item.pop("_mtime", None)
    return reports


def new_service_crash_reports(baseline: list[dict] | list[str], root: Path | None = None) -> list[dict]:
    known = {item if isinstance(item, str) else item.get("path") for item in baseline}
    return [item for item in service_crash_reports(root) if item["path"] not in known]


def _transport_configuration(
    config_text: str,
    plugin_root: Path,
    desktop_runtime_app: Path,
    bundled_content_variant: str | None = None,
) -> dict:
    node_repl = _section(config_text, ("mcp_servers.node_repl", 'mcp_servers."node_repl"'))
    top_level = _section(config_text, ("mcp_servers.computer-use", 'mcp_servers."computer-use"'))
    plugin_override = _section(
        config_text,
        (
            'plugins."computer-use@openai-bundled".mcp_servers.computer-use',
            'plugins."computer-use@openai-bundled".mcp_servers."computer-use"',
        ),
    )
    manifest = _json(plugin_root / ".mcp.json")
    manifest_transport = ((manifest.get("mcpServers") or {}).get("computer-use") or {})
    node_repl_configured = {
        "command": _string_value(node_repl, "command"),
        "args": _array_value(node_repl, "args"),
        "enabled": _bool_value(node_repl, "enabled"),
    }
    node_repl_declared = node_repl is not None
    node_repl_enabled = node_repl_declared and node_repl_configured["enabled"] is not False
    configured = {
        "command": _string_value(top_level, "command"),
        "args": _array_value(top_level, "args"),
        "cwd": _string_value(top_level, "cwd"),
        "enabled": _bool_value(top_level, "enabled"),
    }
    command_present = configured["command"] is not None
    manifest_match = command_present and all(
        configured.get(key) == manifest_transport.get(key) for key in ("command", "args", "cwd")
    )
    stale_command = command_present and not manifest_match
    top_level_count = sum(
        len(re.findall(rf"^\[{re.escape(name)}\]\s*$", config_text, re.MULTILINE))
        for name in ("mcp_servers.computer-use", 'mcp_servers."computer-use"')
    )
    duplicate_mirror_entries = top_level_count > 1

    notify_match = re.search(r"^notify\s*=\s*(\[[^\n]*\])\s*$", config_text, re.MULTILINE)
    notify = None
    if notify_match:
        try:
            candidate = json.loads(notify_match.group(1))
            notify = candidate if isinstance(candidate, list) else None
        except json.JSONDecodeError:
            notify = None
    expected_notify_paths = {
        str(desktop_runtime_app / CLIENT_RELATIVE_EXECUTABLE),
        str(plugin_root / "Codex Computer Use.app" / CLIENT_RELATIVE_EXECUTABLE),
    }
    current_notify = bool(
        notify and len(notify) == 2 and notify[0] in expected_notify_paths and notify[1] == "turn-ended"
    )
    stale_notify = notify is not None and not current_notify

    entries = []
    if top_level is not None:
        entries.append({
            "scope": "top-level-mcp-server",
            "provenance": "installed-plugin-manifest-mirror" if manifest_match else "command-configured",
            **configured,
        })
    if plugin_override is not None:
        entries.append({
            "scope": "plugin-override",
            "provenance": "plugin-managed-user-policy",
            "enabled": _bool_value(plugin_override, "enabled"),
            "command": _string_value(plugin_override, "command"),
        })
    override_enabled = _bool_value(plugin_override, "enabled")
    if override_enabled is not None:
        manifest_mirror_enabled = override_enabled
    elif configured["enabled"] is not None:
        manifest_mirror_enabled = configured["enabled"]
    else:
        # A materialized top-level entry without an explicit policy is active by
        # default.  Merely declaring a transport in the plugin manifest does not
        # activate that transport when the plugin selects the Node REPL variant.
        manifest_mirror_enabled = top_level is not None

    uses_node_repl = bundled_content_variant == "node-repl"
    manifest_mirror_conflicting = uses_node_repl and manifest_mirror_enabled
    duplicate_transport = duplicate_mirror_entries or manifest_mirror_conflicting
    if uses_node_repl:
        server_declared = node_repl_declared
        server_enabled = node_repl_enabled
    else:
        server_declared = bool(manifest_transport)
        # Preserve the pre-variant behavior for plugins that expose their MCP
        # server directly and do not declare ``bundledContentVariant=node-repl``.
        server_enabled = bool(manifest_transport) and (
            manifest_mirror_enabled if top_level is not None or plugin_override is not None else True
        )
    return {
        "computerUseConfigEntries": entries,
        "computerUseBundledContentVariant": bundled_content_variant,
        "computerUseUsesNodeRepl": uses_node_repl,
        "computerUseServerDeclared": server_declared,
        "computerUseServerEnabled": server_enabled,
        "nodeReplServerDeclared": node_repl_declared,
        "nodeReplServerEnabled": node_repl_enabled,
        "nodeReplServerCommand": node_repl_configured["command"],
        "nodeReplServerArgs": node_repl_configured["args"],
        "computerUseManifestServerDeclared": bool(manifest_transport),
        "computerUseManifestMirrorEntryPresent": manifest_match,
        "computerUseManifestMirrorEnabled": manifest_mirror_enabled,
        "computerUseManifestMirrorConflicting": manifest_mirror_conflicting,
        "pluginManagedEntryPresent": manifest_match or plugin_override is not None,
        "commandConfiguredEntryPresent": command_present,
        "pluginManifestMirrorEntryPresent": manifest_match,
        "staleCommandPathPresent": stale_command,
        "duplicateTransportDefinitionPresent": duplicate_transport,
        "desktopManagedNotifyPresent": current_notify,
        "staleNotifyPathPresent": stale_notify,
    }


def routing_status(
    *,
    config_path: Path | None = None,
    codex_home: Path | None = None,
    desktop_app: Path = DESKTOP_APP,
) -> dict:
    home = codex_home or Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    config = config_path or home / "config.toml"
    text = config.read_text(errors="replace") if config.is_file() else ""
    configured_app_value = configured_service_app(text)
    plugin_source_app = Path(configured_app_value) if configured_app_value else Path("/__missing_plugin_source__")
    plugin_root = plugin_source_app.parent if configured_app_value else Path("/__missing_plugin_root__")
    desktop_runtime_app = home / DESKTOP_RUNTIME_RELATIVE_APP
    app_bundled_source_app = desktop_app / APP_BUNDLED_RELATIVE_APP

    desktop = _desktop_identity(desktop_app)
    plugin_state = plugin_inventory(desktop_app)
    inventory_version = plugin_state.get("computerUsePluginVersion")
    derived_inventory_cache_root = (
        home
        / "plugins"
        / "cache"
        / "openai-bundled"
        / "computer-use"
        / (str(inventory_version) if inventory_version else "__missing_inventory_version__")
    )
    reported_inventory_cache_path = plugin_state.get("computerUsePluginInventoryCachePath")
    inventory_cache_root = (
        Path(str(reported_inventory_cache_path)).expanduser()
        if reported_inventory_cache_path
        else derived_inventory_cache_root
    )
    normalized_derived_cache_root = Path(os.path.abspath(derived_inventory_cache_root))
    normalized_inventory_cache_root = Path(os.path.abspath(inventory_cache_root))
    normalized_plugin_root = Path(os.path.abspath(plugin_root))
    inventory_cache_path_consistent = normalized_inventory_cache_root == normalized_derived_cache_root
    configured_source_matches_inventory_cache = bool(
        configured_app_value
        and normalized_plugin_root == normalized_inventory_cache_root
        and Path(os.path.abspath(plugin_source_app))
        == normalized_inventory_cache_root / "Codex Computer Use.app"
    )
    plugin_metadata = _json(plugin_root / ".codex-plugin" / "plugin.json")
    skill_path = plugin_root / PLUGIN_SKILL_RELATIVE_PATH
    wrapper_path = plugin_root / PLUGIN_WRAPPER_RELATIVE_PATH
    skill_installed = skill_path.is_file()
    wrapper_installed = wrapper_path.is_file()
    plugin_installed = plugin_state["computerUsePluginInstalled"]
    plugin_enabled = plugin_state["computerUsePluginEnabled"]
    skill_available = plugin_installed and plugin_enabled and skill_installed
    wrapper_available = plugin_installed and plugin_enabled and wrapper_installed
    macos_version = _macos_version()
    app_source_identity = bundle_identity(app_bundled_source_app)
    plugin_identity = bundle_identity(plugin_source_app)
    runtime_identity = bundle_identity(desktop_runtime_app)
    identity = identity_comparison(plugin_identity, runtime_identity)
    app_source_match = identity_comparison(app_source_identity, plugin_identity)["sourceRuntimeIdentityMatch"]
    bundled_content_variant = plugin_metadata.get("bundledContentVariant")
    transport = _transport_configuration(
        text,
        plugin_root,
        desktop_runtime_app,
        bundled_content_variant=bundled_content_variant,
    )
    expected_node_repl_command = desktop_app / DESKTOP_NODE_REPL_RELATIVE_EXECUTABLE
    configured_node_repl_command = transport.get("nodeReplServerCommand")
    node_repl_command_matches_desktop = bool(
        configured_node_repl_command
        and Path(os.path.abspath(Path(configured_node_repl_command).expanduser()))
        == Path(os.path.abspath(expected_node_repl_command))
    )
    server_available = (
        plugin_installed
        and plugin_enabled
        and transport["computerUseServerDeclared"]
        and transport["computerUseServerEnabled"]
    )
    records = service_records(
        plugin_source_app=plugin_source_app,
        desktop_runtime_app=desktop_runtime_app,
        plugin_identity=plugin_identity,
        runtime_identity=runtime_identity,
    )
    process_counts = related_process_counts()
    crashes = service_crash_reports()
    latest_crash = crashes[-1] if crashes else None
    active_helper_identity = runtime_identity if runtime_identity.get("exists") else plugin_identity
    active_helper_uuid = active_helper_identity.get("executableUUID")
    active_helper_build = active_helper_identity.get("bundleVersion")
    current_helper_crashes = [
        item for item in crashes
        if (
            active_helper_uuid
            and item.get("helperUUID") == str(active_helper_uuid).upper()
        ) or (
            not active_helper_uuid
            and active_helper_build
            and item.get("helperBuild") == str(active_helper_build)
        )
    ]
    latest_current_crash = current_helper_crashes[-1] if current_helper_crashes else None
    macos_major = int(macos_version.split(".", 1)[0]) if macos_version and macos_version.split(".", 1)[0].isdigit() else None
    dyld_failure = bool(
        macos_major == 15
        and any(item["dyldCompatibilityFailure"] for item in current_helper_crashes)
    )
    known_bad_rule = known_bad_helper_rule(active_helper_identity)

    expected_records = [record for record in records if record["desktopManagedRuntimePath"]]
    fallback_records = [record for record in records if record["pluginFallbackPath"]]
    unknown_records = [record for record in records if record["unknownPath"]]
    service_count = len(records)
    duplicate = service_count > 1
    expected_running = len(expected_records) == 1 and service_count == 1
    fallback_running = bool(fallback_records)
    if not records:
        route_status = "missing"
    elif duplicate:
        route_status = "duplicate"
    elif fallback_running:
        route_status = "fallback"
    elif unknown_records:
        route_status = "unknown"
    else:
        route_status = "expected"

    desktop_version = desktop.get("version")
    expectation_verified = desktop_version in OBSERVED_DESKTOP_RUNTIME_VERSIONS
    source_valid = bool(
        configured_source_matches_inventory_cache
        and inventory_cache_path_consistent
        and plugin_source_app.is_dir()
    )
    path_verified = expectation_verified and expected_running and identity["sourceRuntimeIdentityMatch"]

    routing_errors = []
    if not config.is_file():
        routing_errors.append(f"Codex config is missing: {config}")
    if plugin_state.get("pluginInventoryError"):
        routing_errors.append(str(plugin_state["pluginInventoryError"]))
    if not plugin_installed:
        routing_errors.append("bundled Computer Use plugin is not installed")
    if not plugin_enabled:
        routing_errors.append("bundled Computer Use plugin is not enabled")
    if not skill_installed:
        routing_errors.append("installed Computer Use skill is missing")
    if not wrapper_installed:
        routing_errors.append("installed Computer Use Node wrapper is missing")
    if transport["computerUseUsesNodeRepl"]:
        if not transport["nodeReplServerDeclared"]:
            routing_errors.append("Node REPL MCP server is missing for the Computer Use node-repl variant")
        elif not transport["nodeReplServerEnabled"]:
            routing_errors.append("Node REPL MCP server is disabled for the Computer Use node-repl variant")
        if transport["computerUseManifestMirrorConflicting"]:
            routing_errors.append(
                "enabled standalone Computer Use manifest mirror conflicts with node-repl plugin routing"
            )
        if transport["nodeReplServerDeclared"] and not node_repl_command_matches_desktop:
            routing_errors.append("Node REPL MCP command is not the current ChatGPT Desktop-bundled executable")
    elif not transport["computerUseServerDeclared"]:
        routing_errors.append("installed Computer Use plugin does not declare its MCP server")
    elif not transport["computerUseServerEnabled"]:
        routing_errors.append("Computer Use MCP server is disabled")
    metadata_version = plugin_metadata.get("version")
    if inventory_version and metadata_version and inventory_version != metadata_version:
        routing_errors.append("Computer Use plugin inventory version does not match the installed plugin cache")
    if dyld_failure:
        routing_errors.append(f"Computer Use helper is incompatible with this macOS runtime: missing {DYLD_MISSING_SYMBOL}")
    if not configured_app_value:
        routing_errors.append(
            "SKY_CUA_SERVICE_PATH is missing from [mcp_servers.node_repl.env]"
        )
    elif not inventory_cache_path_consistent:
        routing_errors.append("Computer Use plugin inventory cache path does not match its installed version cache root")
    elif not configured_source_matches_inventory_cache:
        routing_errors.append("Node REPL Computer Use source does not match the installed plugin inventory cache app")
    elif not source_valid:
        routing_errors.append("installed plugin inventory cache app is missing")
    if not app_source_identity.get("exists") or not app_source_match:
        routing_errors.append("ChatGPT-bundled Computer Use source does not match the installed plugin source")
    if not desktop_runtime_app.is_dir():
        routing_errors.append("ChatGPT desktop-managed Computer Use runtime is missing")
    elif not identity["sourceRuntimeIdentityMatch"]:
        routing_errors.append("desktop-managed Computer Use runtime identity does not match the installed plugin source")
    if not expectation_verified:
        routing_errors.append(f"Computer Use runtime path has not been audited for ChatGPT Desktop {desktop_version or 'unknown'}")
    if service_count != 1:
        routing_errors.append(f"expected one live {PROCESS_NAME} service, found {service_count}")
    if fallback_running:
        routing_errors.append("build-specific fallback routing observed: service is running from the plugin cache")
    if unknown_records:
        routing_errors.append("Computer Use is running from an unknown service path")
    if transport["staleCommandPathPresent"]:
        routing_errors.append("stale command-configured Computer Use MCP transport is present")
    if (
        transport["duplicateTransportDefinitionPresent"]
        and not transport["computerUseManifestMirrorConflicting"]
    ):
        routing_errors.append("duplicate active Computer Use transport definition is present")
    if transport["staleNotifyPathPresent"]:
        routing_errors.append("stale Computer Use notification client path is configured")
    if process_counts["staleClientSetDetected"]:
        routing_errors.append("stale Computer Use client process set or unreaped Desktop child detected")

    suite_blockers = []
    if known_bad_rule:
        suite_blockers.append(
            "Computer Use helper build 1000366 is blocked for frontend suites by the known AX tree bounds trap"
        )
    routing_ready = not routing_errors
    ready_for_diagnostic = routing_ready
    ready_for_suite = routing_ready and not suite_blockers
    errors = routing_errors + suite_blockers
    return {
        "schemaVersion": 4,
        "configPath": str(config),
        "macOSVersion": macos_version,
        "desktopVersion": desktop_version,
        "desktopBuild": desktop.get("build"),
        **plugin_state,
        "pluginVersion": metadata_version or inventory_version,
        "computerUseSkillPath": str(skill_path) if configured_app_value else None,
        "computerUseSkillInstalled": skill_installed,
        "computerUseSkillExpectedAvailable": skill_available,
        "computerUseWrapperPath": str(wrapper_path) if configured_app_value else None,
        "computerUseWrapperInstalled": wrapper_installed,
        "computerUseWrapperAvailable": wrapper_available,
        "computerUseWrapperSHA256": _sha256(wrapper_path),
        "computerUseServerAvailable": server_available,
        "helperVersion": runtime_identity.get("shortVersion") or plugin_identity.get("shortVersion"),
        "helperBuild": active_helper_build,
        "helperUUID": active_helper_uuid,
        "helperSHA256": active_helper_identity.get("executableSHA256"),
        "knownBadHelperDetected": known_bad_rule is not None,
        "knownBadHelperRule": known_bad_rule,
        "dyldCompatibilityFailure": dyld_failure,
        "crashClassification": (latest_current_crash or latest_crash or {}).get("classification"),
        "latestSkyComputerUseCrash": latest_crash,
        "latestCurrentHelperCrash": latest_current_crash,
        "appBundledSourceApp": str(app_bundled_source_app),
        "installedPluginCacheSourceApp": str(plugin_source_app) if configured_app_value else None,
        "installedPluginInventoryCacheRoot": str(inventory_cache_root),
        "installedPluginInventoryCacheApp": str(inventory_cache_root / "Codex Computer Use.app"),
        "pluginInventoryCachePathConsistent": inventory_cache_path_consistent,
        "nodeReplConfiguredSourceMatchesInventoryCache": configured_source_matches_inventory_cache,
        "desktopManagedRuntimeApp": str(desktop_runtime_app),
        "nodeReplConfiguredServicePath": configured_app_value,
        "expectedNodeReplCommand": str(expected_node_repl_command),
        "nodeReplServerCommandMatchesDesktop": node_repl_command_matches_desktop,
        "appBundledPluginIdentityMatch": app_source_match,
        "installedPluginSourceIdentity": plugin_identity,
        "desktopManagedRuntimeIdentity": runtime_identity,
        **identity,
        **transport,
        "routingExpectationSource": "observed-desktop-build" if expectation_verified else "unverified-desktop-build",
        "routingExpectationDesktopVersion": desktop_version if expectation_verified else None,
        "expectedRuntimePath": str(desktop_runtime_app) if expectation_verified else None,
        "routingStatus": route_status,
        "unexpectedPluginCacheFallbackForThisBuild": expectation_verified and fallback_running,
        "liveServiceExecutablePaths": [record.get("executable") for record in records],
        "serviceProcessCount": service_count,
        "computerUseServiceProcesses": records,
        "computerUseServiceRunning": service_count == 1,
        "desktopManagedRuntimeRunning": expected_running,
        "pluginFallbackRunning": fallback_running,
        "duplicateRuntimeDetected": duplicate,
        "unknownLiveServicePath": bool(unknown_records),
        **process_counts,
        "computerUseServicePathVerified": path_verified,
        "routingErrors": routing_errors,
        "suiteBlockers": suite_blockers,
        "errors": errors,
        "routingReady": routing_ready,
        "readyForDiagnostic": ready_for_diagnostic,
        "readyForSuite": ready_for_suite,
        "readyForSession": ready_for_suite,
        "ready": ready_for_suite,
    }


def main() -> int:
    status = routing_status()
    print(json.dumps(status, indent=2, sort_keys=True))
    return 0 if status["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
