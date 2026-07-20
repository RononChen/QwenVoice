#!/usr/bin/env python3
"""Inventory and explicitly manage persisted Codex task/session storage.

The repository owns this workflow, not the user's Codex state.  ``validate`` is
the only command intended for CI.  Live commands read exactly the first,
bounded ``session_meta`` JSONL record from each rollout and never inspect a
prompt, transcript event, tool result, image, SQLite database, or other Codex
state.  Deletion is possible only from an unexpired, checksummed plan and uses
the installed, supported ``codex delete --force UUID`` command one UUID at a
time in deepest-first order.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Sequence


SCRIPT_PATH = Path(__file__).resolve()
DEFAULT_REPO_ROOT = SCRIPT_PATH.parent.parent
DEFAULT_POLICY_RELATIVE = Path("config/codex-session-storage-policy.json")
PLAN_FILENAME = "deletion-plan.json"
CHECKSUM_FILENAME = "deletion-plan.sha256"
JOURNAL_FILENAME = "execution-journal.json"
MAX_OPERATOR_RECORD_BYTES = 16 * 1024 * 1024
PLAN_KIND = "codex-session-deletion-plan"
JOURNAL_KIND = "codex-session-deletion-journal"
PARSER_CONTRACT_VERSION = 1
UUID_PATTERN = re.compile(
    r"(?<![0-9A-Fa-f])"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    r"(?![0-9A-Fa-f])"
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SAFE_TIMESTAMP_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)
EXPECTED_COMMAND_TEMPLATE = ["codex", "delete", "--force", "{sessionId}"]
EXPECTED_STORES = {"active": "sessions", "archived": "archived_sessions"}
EXPECTED_ROLLOUT_PATTERNS = ["rollout-*.jsonl", "rollout-*.jsonl.zst"]


class PolicyError(ValueError):
    """The tracked operator policy is malformed or unsafe."""


class WorkflowError(RuntimeError):
    """Live state cannot safely satisfy the requested operation."""


@dataclass(frozen=True)
class LoadedPolicy:
    repo_root: Path
    path: Path
    document: dict[str, Any]
    sha256: str

    @property
    def stores(self) -> dict[str, str]:
        return dict(self.document["scope"]["coveredStores"])

    @property
    def filename_patterns(self) -> tuple[str, ...]:
        return tuple(self.document["scope"]["rolloutFilenamePatterns"])

    @property
    def maximum_first_line_bytes(self) -> int:
        return self.document["metadata"]["maximumFirstLineBytes"]

    @property
    def plan_validity_seconds(self) -> int:
        return self.document["execution"]["planValiditySeconds"]

    @property
    def command_timeout_seconds(self) -> int:
        return self.document["execution"]["commandTimeoutSeconds"]


@dataclass(frozen=True)
class SessionRecord:
    path: Path
    record_key: str
    store: str
    session_id: str | None
    root_id: str | None
    parent_id: str | None
    spawn_parent_id: str | None
    created_at: str | None
    modified_at: str
    cwd_classification: str
    logical_bytes: int
    allocated_bytes: int
    device: int
    inode: int
    mtime_ns: int
    changed_during_read: bool
    errors: tuple[str, ...]


@dataclass(frozen=True)
class Lineage:
    valid: bool
    root_id: str | None
    depth: int | None
    reason: str


@dataclass(frozen=True)
class GraphAnalysis:
    records: tuple[SessionRecord, ...]
    lineages: dict[str, Lineage]
    classifications: dict[str, tuple[str, str]]
    deletion_order: tuple[str, ...]

    @property
    def target_ids(self) -> set[str]:
        return {
            record.session_id
            for record in self.records
            if record.session_id is not None
            and self.classifications[record.record_key][0] == "delete"
        }


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _format_timestamp(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def _parse_timestamp(value: Any, label: str) -> dt.datetime:
    if not isinstance(value, str) or not SAFE_TIMESTAMP_PATTERN.fullmatch(value):
        raise WorkflowError(f"{label} is not a supported UTC timestamp")
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise WorkflowError(f"{label} is not a valid timestamp") from error


def _safe_metadata_timestamp(value: Any) -> str | None:
    if isinstance(value, str) and SAFE_TIMESTAMP_PATTERN.fullmatch(value):
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        return _format_timestamp(parsed)
    return None


def _canonical_uuid(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        return None


def _require_uuid(value: str, label: str) -> str:
    canonical = _canonical_uuid(value)
    if canonical is None:
        raise WorkflowError(f"{label} must be a UUID")
    return canonical


def _require_canonical_uuid(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise WorkflowError(f"{label} must be a canonical UUID")
    canonical = _canonical_uuid(value)
    if canonical is None or canonical != value:
        raise WorkflowError(f"{label} must be a canonical UUID")
    return value


def _relative_policy_path(value: Any, label: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value:
        raise PolicyError(f"{label} must be a non-empty relative POSIX path")
    path = PurePosixPath(value)
    if path.is_absolute() or value.startswith("~"):
        raise PolicyError(f"{label} must be relative")
    if len(path.parts) != 1 or path.parts[0] in {"", ".", ".."}:
        raise PolicyError(f"{label} must be one normalized path component")
    return path


def _require_string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item for item in value
    ):
        raise PolicyError(f"{label} must be a list of non-empty strings")
    if len(set(value)) != len(value):
        raise PolicyError(f"{label} cannot contain duplicates")
    return list(value)


def validate_policy_document(document: Any) -> None:
    if not isinstance(document, dict):
        raise PolicyError("policy root must be an object")
    expected_section_keys = {
        "scope": {
            "repositoryOwnsUserState",
            "ciMayInspectUserState",
            "coveredStores",
            "rolloutFilenamePatterns",
            "rejectUnexpectedJsonlFilenames",
            "requireFilenameSessionIdMatch",
            "rejectSymlinkedStoreDirectories",
            "requireUniqueRegularRolloutFiles",
            "excludedState",
        },
        "metadata": {
            "recordType",
            "maximumFirstLineBytes",
            "allowedRecordFields",
            "allowedPayloadFields",
            "readLaterJsonlLines",
            "requireTerminatingNewline",
            "compressedRolloutReader",
            "compressedReaderUnavailable",
            "includeTaskNames",
        },
        "privacy": {
            "trackedRuntimeRecordsAllowed",
            "operatorRecordsLocation",
            "operatorRecordsMode",
            "operatorRecordsDirectoryMode",
            "forbiddenTrackedData",
        },
        "classification": {
            "defaultDisposition",
            "deleteOnlyProvenDescendants",
            "ambiguousDisposition",
            "requireExplicitProtectedRoot",
            "blockTargetAdjacentAmbiguity",
            "deriveDepthFromParentChain",
        },
        "execution": {
            "automaticDeletion",
            "commandTemplate",
            "assumeCommandCascades",
            "order",
            "requireManifestSha256",
            "requireApprovedRoot",
            "planValiditySeconds",
            "requireCurrentValidityWindow",
            "revalidateBeforeMutation",
            "preMutationScans",
            "verifyAfterEachDeletion",
            "requireLeafBeforeEachDeletion",
            "preserveBaselineNonTargets",
            "rejectReferencesToAnyApprovedId",
            "sameDepthTieBreak",
            "commandTimeoutSeconds",
            "persistCommandOutput",
            "shell",
        },
        "measurement": {
            "fileLogicalBytes",
            "fileAllocatedBytes",
            "filesystemAvailableBytes",
            "directoryCrossChecks",
            "mole",
        },
        "continuity": {
            "recommendNewTopLevelTaskAtMajorCheckpoint",
            "requireExplicitOperatorRequestForTaskCreation",
            "subagentContext",
            "fullHistoryForkDefault",
            "preferEphemeralExecForDisposableWork",
            "repositoryTruth",
        },
        "integration": {
            "manualOnly",
            "developmentGate",
            "publicationGate",
            "releaseEvidenceInput",
            "scheduledAutomation",
            "ciPolicyCommand",
            "ciSyntheticTestCommand",
        },
    }
    expected_root_keys = {
        "schemaVersion",
        "id",
        "owner",
        "status",
        *expected_section_keys,
    }
    if set(document) != expected_root_keys:
        raise PolicyError("policy root schema must remain exact")
    for section_name, expected_keys in expected_section_keys.items():
        section = document.get(section_name)
        if not isinstance(section, dict) or set(section) != expected_keys:
            raise PolicyError(f"{section_name} schema must remain exact")
    if document.get("schemaVersion") != 1:
        raise PolicyError("unsupported Codex session-storage policy schemaVersion")
    if document.get("id") != "codex-session-storage":
        raise PolicyError("policy id must remain codex-session-storage")
    if document.get("owner") != "release-qa":
        raise PolicyError("policy owner must remain release-qa")
    if document.get("status") != "optional-local-operator-workflow":
        raise PolicyError("policy status must remain optional-local-operator-workflow")

    scope = document.get("scope")
    if not isinstance(scope, dict):
        raise PolicyError("scope must be an object")
    if scope.get("repositoryOwnsUserState") is not False:
        raise PolicyError("the repository cannot own user-scoped Codex state")
    if scope.get("ciMayInspectUserState") is not False:
        raise PolicyError("CI cannot inspect user-scoped Codex state")
    stores = scope.get("coveredStores")
    if stores != EXPECTED_STORES:
        raise PolicyError("coveredStores must be the active and archived session roots")
    for name, value in stores.items():
        _relative_policy_path(value, f"coveredStores.{name}")
    if scope.get("rolloutFilenamePatterns") != EXPECTED_ROLLOUT_PATTERNS:
        raise PolicyError("rolloutFilenamePatterns must cover plain and compressed rollouts")
    for key in (
        "rejectUnexpectedJsonlFilenames",
        "requireFilenameSessionIdMatch",
        "rejectSymlinkedStoreDirectories",
        "requireUniqueRegularRolloutFiles",
    ):
        if scope.get(key) is not True:
            raise PolicyError(f"scope.{key} must remain true")
    excluded = _require_string_list(scope.get("excludedState"), "excludedState")
    required_exclusions = {
        "config",
        "databases",
        "memories",
        "plugins",
        "skills",
        "packages",
        "logs",
        "attachments",
        "generated-images",
        "repository-build-output",
        "models",
        "benchmark-history",
    }
    if set(excluded) != required_exclusions:
        raise PolicyError("excludedState changed the protected state boundary")

    metadata = document.get("metadata")
    if not isinstance(metadata, dict) or metadata.get("recordType") != "session_meta":
        raise PolicyError("metadata.recordType must remain session_meta")
    limit = metadata.get("maximumFirstLineBytes")
    if not isinstance(limit, int) or not 64 * 1024 <= limit <= 16 * 1024 * 1024:
        raise PolicyError("maximumFirstLineBytes must be between 64 KiB and 16 MiB")
    expected_fields = {
        "id",
        "session_id",
        "parent_thread_id",
        "timestamp",
        "cwd",
        "source.subagent.thread_spawn.parent_thread_id",
    }
    if set(_require_string_list(metadata.get("allowedPayloadFields"), "allowedPayloadFields")) != expected_fields:
        raise PolicyError("allowedPayloadFields changed the metadata-only read boundary")
    if metadata.get("allowedRecordFields") != ["type", "timestamp", "payload"]:
        raise PolicyError("allowedRecordFields changed the session-meta envelope boundary")
    if metadata.get("readLaterJsonlLines") is not False:
        raise PolicyError("later JSONL lines must never be read")
    if metadata.get("requireTerminatingNewline") is not True:
        raise PolicyError("the session-meta line must remain physically bounded")
    if metadata.get("compressedRolloutReader") != "python-stdlib-compression.zstd":
        raise PolicyError("compressed rollouts must use the bounded standard-library reader")
    if metadata.get("compressedReaderUnavailable") != "fail-closed":
        raise PolicyError("compressed rollouts must fail closed without a reader")
    if metadata.get("includeTaskNames") is not False:
        raise PolicyError("task names must remain excluded")

    privacy = document.get("privacy")
    if not isinstance(privacy, dict):
        raise PolicyError("privacy must be an object")
    if privacy.get("trackedRuntimeRecordsAllowed") is not False:
        raise PolicyError("live session records cannot be tracked")
    if privacy.get("operatorRecordsLocation") != "system-temporary-directory":
        raise PolicyError("operator records must remain outside the repository")
    if privacy.get("operatorRecordsMode") != "0600":
        raise PolicyError("operator records must use mode 0600")
    if privacy.get("operatorRecordsDirectoryMode") != "0700":
        raise PolicyError("operator-record directories must use mode 0700")
    forbidden = set(
        _require_string_list(privacy.get("forbiddenTrackedData"), "forbiddenTrackedData")
    )
    expected_forbidden = {
        "session-identifiers",
        "rollout-filenames",
        "absolute-paths",
        "usernames",
        "task-titles",
        "prompts",
        "transcripts",
        "tool-output",
        "images",
        "secrets",
        "private-metadata",
    }
    if forbidden != expected_forbidden:
        raise PolicyError("forbiddenTrackedData changed the privacy boundary")

    classification = document.get("classification")
    if not isinstance(classification, dict):
        raise PolicyError("classification must be an object")
    expected_classification = {
        "defaultDisposition": "protect",
        "deleteOnlyProvenDescendants": True,
        "ambiguousDisposition": "protect",
        "requireExplicitProtectedRoot": True,
        "blockTargetAdjacentAmbiguity": True,
        "deriveDepthFromParentChain": True,
    }
    if classification != expected_classification:
        raise PolicyError("classification invariants changed")

    execution = document.get("execution")
    if not isinstance(execution, dict):
        raise PolicyError("execution must be an object")
    required_execution = {
        "automaticDeletion": False,
        "commandTemplate": EXPECTED_COMMAND_TEMPLATE,
        "assumeCommandCascades": False,
        "order": "deepest-first-root-last",
        "requireManifestSha256": True,
        "requireApprovedRoot": True,
        "requireCurrentValidityWindow": True,
        "revalidateBeforeMutation": True,
        "preMutationScans": 2,
        "verifyAfterEachDeletion": True,
        "requireLeafBeforeEachDeletion": True,
        "preserveBaselineNonTargets": True,
        "rejectReferencesToAnyApprovedId": True,
        "sameDepthTieBreak": "session-id-ascending",
        "commandTimeoutSeconds": 120,
        "persistCommandOutput": False,
        "shell": False,
    }
    for key, expected in required_execution.items():
        if execution.get(key) != expected:
            raise PolicyError(f"execution.{key} changed an operator safety invariant")
    validity = execution.get("planValiditySeconds")
    if not isinstance(validity, int) or not 300 <= validity <= 7 * 24 * 60 * 60:
        raise PolicyError("planValiditySeconds must be between 5 minutes and 7 days")

    measurement = document.get("measurement")
    if not isinstance(measurement, dict):
        raise PolicyError("measurement must be an object")
    if measurement.get("fileLogicalBytes") != "stat.st_size":
        raise PolicyError("logical-byte authority must remain stat.st_size")
    if measurement.get("fileAllocatedBytes") != "stat.st_blocks*512":
        raise PolicyError("allocated-byte authority must remain stat.st_blocks*512")
    if measurement.get("filesystemAvailableBytes") != "statvfs":
        raise PolicyError("filesystem availability authority must remain statvfs")
    if measurement.get("directoryCrossChecks") != [
        "du-apparent",
        "du-allocated",
        "df-available",
    ]:
        raise PolicyError("directory cross-checks changed")
    mole = measurement.get("mole")
    if not isinstance(mole, dict) or set(mole) != {
        "required",
        "allowedMode",
        "authority",
        "mayAuthorizeDeletion",
    } or mole.get("required") is not False:
        raise PolicyError("Mole must remain optional")
    if (
        mole.get("allowedMode") != "analyze-only"
        or mole.get("authority") != "supplemental-only"
        or mole.get("mayAuthorizeDeletion") is not False
    ):
        raise PolicyError("Mole cannot clean state or authorize deletion")

    continuity = document.get("continuity")
    expected_continuity = {
        "recommendNewTopLevelTaskAtMajorCheckpoint": True,
        "requireExplicitOperatorRequestForTaskCreation": True,
        "subagentContext": "smallest-bounded-self-contained-brief",
        "fullHistoryForkDefault": False,
        "preferEphemeralExecForDisposableWork": True,
        "repositoryTruth": [
            "committed-code",
            "machine-readable-contracts",
            "docs/development-progress.md",
        ],
    }
    if continuity != expected_continuity:
        raise PolicyError("continuity guidance changed")

    integration = document.get("integration")
    if not isinstance(integration, dict):
        raise PolicyError("integration must be an object")
    for key in (
        "developmentGate",
        "publicationGate",
        "releaseEvidenceInput",
        "scheduledAutomation",
    ):
        if integration.get(key) is not False:
            raise PolicyError(f"integration.{key} must remain false")
    if integration.get("manualOnly") is not True:
        raise PolicyError("live storage management must remain manual-only")
    if integration.get("ciPolicyCommand") != "python3 scripts/codex_session_storage.py validate":
        raise PolicyError("the CI policy command changed")
    if integration.get("ciSyntheticTestCommand") != (
        "python3 -m unittest scripts.tests.test_codex_session_storage"
    ):
        raise PolicyError("the hermetic CI fixture command changed")


def load_policy(
    repo_root: Path = DEFAULT_REPO_ROOT,
    policy_path: Path | None = None,
) -> LoadedPolicy:
    root = repo_root.resolve()
    path = (policy_path or root / DEFAULT_POLICY_RELATIVE).resolve()
    try:
        raw = path.read_bytes()
        document = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        raise PolicyError("unable to load the tracked Codex session-storage policy") from error
    validate_policy_document(document)
    return LoadedPolicy(
        repo_root=root,
        path=path,
        document=document,
        sha256=hashlib.sha256(raw).hexdigest(),
    )


def _is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _system_temporary_roots() -> tuple[Path, ...]:
    candidates = [Path(tempfile.gettempdir()), Path("/tmp"), Path("/private/tmp")]
    roots: list[Path] = []
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if resolved.is_dir() and resolved not in roots:
            roots.append(resolved)
    if not roots:
        raise WorkflowError("no supported system temporary directory is available")
    return tuple(roots)


def _is_in_system_temporary_directory(path: Path) -> bool:
    return any(_is_relative_to(path, root) for root in _system_temporary_roots())


def _codex_home(value: Path | None) -> Path:
    if value is not None:
        path = value.expanduser().resolve()
    else:
        configured = os.environ.get("CODEX_HOME")
        path = Path(configured).expanduser().resolve() if configured else (Path.home() / ".codex").resolve()
    if not path.is_absolute() or not path.is_dir():
        raise WorkflowError("the selected Codex home does not exist")
    return path


def _codex_home_fingerprint(codex_home: Path) -> dict[str, int]:
    try:
        home_stat = codex_home.stat()
    except OSError as error:
        raise WorkflowError("unable to fingerprint the selected Codex home") from error
    if not stat.S_ISDIR(home_stat.st_mode):
        raise WorkflowError("the selected Codex home is not a directory")
    return {"device": int(home_stat.st_dev), "inode": int(home_stat.st_ino)}


def _record_key(path: Path, codex_home: Path) -> str:
    relative = path.relative_to(codex_home).as_posix()
    return hashlib.sha256(relative.encode("utf-8")).hexdigest()


def _allocated_bytes(file_stat: os.stat_result) -> int:
    blocks = getattr(file_stat, "st_blocks", None)
    return int(blocks) * 512 if isinstance(blocks, int) else int(file_stat.st_size)


def _modified_at(file_stat: os.stat_result) -> str:
    return _format_timestamp(dt.datetime.fromtimestamp(file_stat.st_mtime, dt.timezone.utc))


def _classify_cwd(value: Any, repo_root: Path) -> str:
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        return "missing"
    try:
        candidate = Path(value).expanduser().resolve(strict=False)
    except (OSError, RuntimeError, ValueError):
        return "other"
    return "repository" if _is_relative_to(candidate, repo_root) else "other"


def _error_record(
    path: Path,
    codex_home: Path,
    store: str,
    file_stat: os.stat_result,
    error: str,
) -> SessionRecord:
    return SessionRecord(
        path=path,
        record_key=_record_key(path, codex_home),
        store=store,
        session_id=None,
        root_id=None,
        parent_id=None,
        spawn_parent_id=None,
        created_at=None,
        modified_at=_modified_at(file_stat),
        cwd_classification="missing",
        logical_bytes=int(file_stat.st_size),
        allocated_bytes=_allocated_bytes(file_stat),
        device=int(file_stat.st_dev),
        inode=int(file_stat.st_ino),
        mtime_ns=int(file_stat.st_mtime_ns),
        changed_during_read=False,
        errors=(error,),
    )


def read_session_record(
    path: Path,
    *,
    codex_home: Path,
    store: str,
    repo_root: Path,
    maximum_first_line_bytes: int,
) -> SessionRecord:
    try:
        initial = path.lstat()
    except OSError as error:
        raise WorkflowError("a rollout changed while inventory was opening it") from error
    if stat.S_ISLNK(initial.st_mode):
        return _error_record(path, codex_home, store, initial, "symlink-rollout")
    if not stat.S_ISREG(initial.st_mode):
        return _error_record(path, codex_home, store, initial, "non-regular-rollout")
    if initial.st_nlink != 1:
        return _error_record(path, codex_home, store, initial, "non-unique-rollout-link")

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return _error_record(path, codex_home, store, initial, "rollout-open-failed")

    line = b""
    read_error: str | None = None
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (initial.st_dev, initial.st_ino):
            return _error_record(path, codex_home, store, opened, "rollout-open-race")
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            descriptor = -1
            if path.name.endswith(".jsonl.zst"):
                try:
                    from compression import zstd
                except ImportError:
                    read_error = "compressed-rollout-reader-unavailable"
                else:
                    try:
                        with zstd.open(handle, "rb") as decompressed:
                            line = decompressed.readline(maximum_first_line_bytes + 1)
                    except (OSError, EOFError, ValueError, zstd.ZstdError):
                        read_error = "compressed-rollout-read-failed"
            else:
                line = handle.readline(maximum_first_line_bytes + 1)
            final = os.fstat(handle.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    errors: list[str] = [read_error] if read_error is not None else []
    if len(line) > maximum_first_line_bytes:
        errors.append("session-meta-line-too-large")
    if line and not line.endswith(b"\n"):
        errors.append("session-meta-line-incomplete")

    document: Any = None
    if not errors:
        try:
            document = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            errors.append("invalid-session-meta-json")
    if not isinstance(document, dict):
        if not errors:
            errors.append("invalid-session-meta-record")
        document = {}
    if document.get("type") != "session_meta":
        errors.append("first-record-not-session-meta")
    payload = document.get("payload")
    if not isinstance(payload, dict):
        errors.append("missing-session-meta-payload")
        payload = {}

    session_id = _canonical_uuid(payload.get("id"))
    root_id = _canonical_uuid(payload.get("session_id"))
    raw_parent = payload.get("parent_thread_id")
    parent_id = _canonical_uuid(raw_parent) if raw_parent is not None else None
    if session_id is None:
        errors.append("invalid-session-id")
    if root_id is None:
        errors.append("invalid-session-root-id")
    if raw_parent is not None and parent_id is None:
        errors.append("invalid-session-parent-id")
    filename_ids = {
        str(uuid.UUID(value)) for value in UUID_PATTERN.findall(path.name)
    }
    if session_id is not None and filename_ids != {session_id}:
        errors.append("filename-session-id-mismatch")

    spawn_parent_raw: Any = None
    source = payload.get("source")
    if isinstance(source, dict):
        subagent = source.get("subagent")
        if isinstance(subagent, dict):
            thread_spawn = subagent.get("thread_spawn")
            if isinstance(thread_spawn, dict):
                spawn_parent_raw = thread_spawn.get("parent_thread_id")
    spawn_parent_id = (
        _canonical_uuid(spawn_parent_raw) if spawn_parent_raw is not None else None
    )
    if spawn_parent_raw is not None and spawn_parent_id is None:
        errors.append("invalid-spawn-parent-id")

    changed = (
        final.st_size != initial.st_size
        or final.st_mtime_ns != initial.st_mtime_ns
        or final.st_ino != initial.st_ino
        or final.st_dev != initial.st_dev
    )
    return SessionRecord(
        path=path,
        record_key=_record_key(path, codex_home),
        store=store,
        session_id=session_id,
        root_id=root_id,
        parent_id=parent_id,
        spawn_parent_id=spawn_parent_id,
        created_at=_safe_metadata_timestamp(payload.get("timestamp") or document.get("timestamp")),
        modified_at=_modified_at(final),
        cwd_classification=_classify_cwd(payload.get("cwd"), repo_root),
        logical_bytes=int(final.st_size),
        allocated_bytes=_allocated_bytes(final),
        device=int(final.st_dev),
        inode=int(final.st_ino),
        mtime_ns=int(final.st_mtime_ns),
        changed_during_read=changed,
        errors=tuple(sorted(set(errors))),
    )


def _rollout_paths(root: Path, patterns: Sequence[str]) -> Iterable[Path]:
    if not root.exists():
        return ()
    paths: list[Path] = []
    def raise_walk_error(error: OSError) -> None:
        raise WorkflowError("unable to enumerate a Codex session store") from error

    for directory, directory_names, filenames in os.walk(
        root, followlinks=False, onerror=raise_walk_error
    ):
        for name in directory_names:
            if (Path(directory) / name).is_symlink():
                raise WorkflowError("a Codex session store contains a symlinked directory")
        directory_names[:] = sorted(directory_names)
        for filename in sorted(filenames):
            matches = any(
                fnmatch.fnmatchcase(filename, pattern) for pattern in patterns
            )
            if (
                filename.endswith(".jsonl") or filename.endswith(".jsonl.zst")
            ) and not matches:
                raise WorkflowError(
                    "a Codex session store contains an unexpected JSONL filename"
                )
            if matches:
                paths.append(Path(directory) / filename)
    return tuple(sorted(paths))


def scan_records(
    policy: LoadedPolicy,
    *,
    codex_home: Path,
) -> tuple[SessionRecord, ...]:
    records: list[SessionRecord] = []
    for store, relative in sorted(policy.stores.items()):
        store_root = codex_home / relative
        if store_root.exists() and (store_root.is_symlink() or not store_root.is_dir()):
            raise WorkflowError(f"the {store} session store is not a regular directory")
        for path in _rollout_paths(store_root, policy.filename_patterns):
            records.append(
                read_session_record(
                    path,
                    codex_home=codex_home,
                    store=store,
                    repo_root=policy.repo_root,
                    maximum_first_line_bytes=policy.maximum_first_line_bytes,
                )
            )
    return tuple(sorted(records, key=lambda record: record.record_key))


def derive_lineages(records: Sequence[SessionRecord]) -> dict[str, Lineage]:
    by_id: dict[str, list[SessionRecord]] = {}
    for record in records:
        if record.session_id is not None:
            by_id.setdefault(record.session_id, []).append(record)

    results: dict[str, Lineage] = {}
    for record in records:
        if record.errors:
            results[record.record_key] = Lineage(
                False, record.root_id, None, record.errors[0]
            )
            continue
        if record.session_id is None or record.root_id is None:
            results[record.record_key] = Lineage(False, record.root_id, None, "missing-identity")
            continue
        if len(by_id.get(record.session_id, [])) != 1:
            results[record.record_key] = Lineage(False, record.root_id, None, "duplicate-session-id")
            continue

        seen: set[str] = set()
        current = record
        depth = 0
        reason: str | None = None
        while True:
            assert current.session_id is not None
            if current.session_id in seen:
                reason = "lineage-cycle"
                break
            seen.add(current.session_id)
            if current.errors:
                reason = current.errors[0]
                break
            if current.root_id != record.root_id:
                reason = "lineage-root-changed"
                break
            if current.spawn_parent_id is not None and current.spawn_parent_id != current.parent_id:
                reason = "spawn-parent-disagrees"
                break
            if current.session_id == record.root_id:
                if current.parent_id is not None:
                    reason = "root-has-parent"
                    break
                results[record.record_key] = Lineage(
                    True, record.root_id, depth, "proven-lineage"
                )
                break
            if current.parent_id is None:
                reason = "lineage-ended-before-root"
                break
            parent_candidates = by_id.get(current.parent_id, [])
            if len(parent_candidates) != 1:
                reason = "missing-or-duplicate-parent"
                break
            current = parent_candidates[0]
            depth += 1
            if depth > len(records):
                reason = "lineage-depth-overflow"
                break
        if reason is not None:
            results[record.record_key] = Lineage(False, record.root_id, None, reason)
    return results


def _ambiguous_target_references(
    records: Sequence[SessionRecord],
    lineages: dict[str, Lineage],
    *,
    delete_root: str,
    target_ids: set[str],
) -> set[str]:
    tainted = set(target_ids)
    ambiguous_keys: set[str] = set()
    changed = True
    while changed:
        changed = False
        for record in records:
            lineage = lineages[record.record_key]
            if lineage.valid or record.record_key in ambiguous_keys:
                continue
            touches = (
                record.root_id == delete_root
                or record.parent_id in tainted
                or record.spawn_parent_id in tainted
            )
            if touches:
                ambiguous_keys.add(record.record_key)
                if record.session_id is not None:
                    tainted.add(record.session_id)
                changed = True
    return ambiguous_keys


def analyze_graph(
    records: Sequence[SessionRecord],
    *,
    delete_root: str,
    protected_roots: Sequence[str],
) -> GraphAnalysis:
    unreadable = [record for record in records if record.errors and record.session_id is None]
    if unreadable:
        raise WorkflowError(
            "one or more rollout metadata records are unreadable; no deletion plan can prove completeness"
        )

    lineages = derive_lineages(records)
    by_id: dict[str, list[SessionRecord]] = {}
    for record in records:
        if record.session_id is not None:
            by_id.setdefault(record.session_id, []).append(record)
    if any(len(candidates) != 1 for candidates in by_id.values()):
        raise WorkflowError(
            "duplicate session IDs prevent a complete deletion-graph proof"
        )

    root_candidates = by_id.get(delete_root, [])
    if len(root_candidates) != 1:
        raise WorkflowError("the proposed deletion root is missing or duplicated")
    root_record = root_candidates[0]
    root_lineage = lineages[root_record.record_key]
    if not root_lineage.valid or root_lineage.root_id != delete_root or root_lineage.depth != 0:
        raise WorkflowError("the proposed deletion root is not a proven top-level task")

    protected = set(protected_roots)
    if not protected:
        raise WorkflowError("at least one current top-level task must be explicitly protected")
    if delete_root in protected:
        raise WorkflowError("the deletion root cannot also be protected")
    for protected_root in sorted(protected):
        candidates = by_id.get(protected_root, [])
        if len(candidates) != 1:
            raise WorkflowError("an explicit protected root is missing or duplicated")
        lineage = lineages[candidates[0].record_key]
        if not lineage.valid or lineage.root_id != protected_root or lineage.depth != 0:
            raise WorkflowError("an explicit protected root is not a proven top-level task")

    target_records = [
        record
        for record in records
        if lineages[record.record_key].valid
        and lineages[record.record_key].root_id == delete_root
    ]
    target_ids = {
        record.session_id for record in target_records if record.session_id is not None
    }
    target_adjacent = _ambiguous_target_references(
        records,
        lineages,
        delete_root=delete_root,
        target_ids=target_ids,
    )
    if target_adjacent:
        raise WorkflowError(
            "ambiguous metadata touches the proposed deletion tree; preserve it and resolve the graph first"
        )
    if any(record.changed_during_read for record in target_records):
        raise WorkflowError("a proposed deletion target changed during inventory")

    classifications: dict[str, tuple[str, str]] = {}
    for record in records:
        lineage = lineages[record.record_key]
        if lineage.valid and lineage.root_id == delete_root:
            classifications[record.record_key] = ("delete", "proven-old-root-descendant")
        elif lineage.valid and lineage.root_id in protected:
            classifications[record.record_key] = ("protect", "explicit-protected-tree")
        elif lineage.valid:
            classifications[record.record_key] = ("protect", "unrelated-proven-tree")
        else:
            classifications[record.record_key] = ("ambiguous", lineage.reason)

    ordered_records = sorted(
        target_records,
        key=lambda record: (
            -int(lineages[record.record_key].depth or 0),
            str(record.session_id),
        ),
    )
    if not ordered_records or ordered_records[-1].session_id != delete_root:
        raise WorkflowError("the deletion order does not end with the old root")
    for record in ordered_records[:-1]:
        if record.parent_id not in target_ids:
            raise WorkflowError("a proposed descendant has a parent outside the deletion tree")
    return GraphAnalysis(
        records=tuple(records),
        lineages=lineages,
        classifications=classifications,
        deletion_order=tuple(str(record.session_id) for record in ordered_records),
    )


def _filesystem_status(path: Path) -> dict[str, int]:
    usage = shutil.disk_usage(path)
    return {
        "totalBytes": int(usage.total),
        "usedBytes": int(usage.used),
        "availableBytes": int(usage.free),
    }


def _aggregate_records(records: Sequence[SessionRecord]) -> dict[str, Any]:
    stores: dict[str, dict[str, int]] = {}
    for record in records:
        bucket = stores.setdefault(
            record.store,
            {"records": 0, "logicalBytes": 0, "allocatedBytes": 0},
        )
        bucket["records"] += 1
        bucket["logicalBytes"] += record.logical_bytes
        bucket["allocatedBytes"] += record.allocated_bytes
    lineages = derive_lineages(records)
    return {
        "records": len(records),
        "logicalBytes": sum(record.logical_bytes for record in records),
        "allocatedBytes": sum(record.allocated_bytes for record in records),
        "metadataErrors": sum(bool(record.errors) for record in records),
        "ambiguousLineages": sum(
            not lineage.valid for lineage in lineages.values()
        ),
        "stores": stores,
    }


def status_payload(policy: LoadedPolicy, codex_home: Path) -> dict[str, Any]:
    records = scan_records(policy, codex_home=codex_home)
    return {
        "schemaVersion": 1,
        "kind": "codex-session-storage-status",
        "measuredAt": _format_timestamp(_utc_now()),
        "scope": "user-scoped-codex-session-stores",
        "inventory": _aggregate_records(records),
        "filesystem": _filesystem_status(codex_home),
        "privacy": "aggregate-only-first-session-meta-record",
    }


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_executor(codex_bin: str) -> dict[str, str]:
    candidate = Path(codex_bin)
    resolved_value = str(candidate.resolve()) if candidate.is_absolute() else shutil.which(codex_bin)
    if not resolved_value:
        raise WorkflowError("the Codex executable is unavailable")
    resolved = Path(resolved_value).resolve()
    if not resolved.is_file():
        raise WorkflowError("the Codex executable is not a regular file")

    try:
        version = subprocess.run(
            [str(resolved), "--version"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=15,
        )
        help_result = subprocess.run(
            [str(resolved), "delete", "--help"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise WorkflowError("unable to inspect the installed Codex deletion command") from error
    version_text = version.stdout.strip()
    if version.returncode != 0 or not re.fullmatch(r"codex-cli [0-9A-Za-z.+-]+", version_text):
        raise WorkflowError("the installed Codex version response is unsupported")
    if help_result.returncode != 0:
        raise WorkflowError("codex delete --help failed")
    if "Permanently delete a saved session" not in help_result.stdout or "--force" not in help_result.stdout:
        raise WorkflowError("the installed Codex CLI does not expose the required delete contract")
    return {
        "version": version_text,
        "binarySha256": _hash_file(resolved),
        "deleteHelpSha256": hashlib.sha256(help_result.stdout.encode("utf-8")).hexdigest(),
    }


def _entry_for_manifest(
    record: SessionRecord,
    analysis: GraphAnalysis,
) -> dict[str, Any]:
    lineage = analysis.lineages[record.record_key]
    classification, reason = analysis.classifications[record.record_key]
    return {
        "recordKey": record.record_key,
        "sessionId": record.session_id,
        "rootId": record.root_id,
        "parentId": record.parent_id,
        "spawnParentId": record.spawn_parent_id,
        "store": record.store,
        "createdAt": record.created_at,
        "modifiedAt": record.modified_at,
        "cwdClassification": record.cwd_classification,
        "logicalBytes": record.logical_bytes,
        "allocatedBytes": record.allocated_bytes,
        "depth": lineage.depth,
        "classification": classification,
        "reason": reason,
        "targetFingerprint": (
            {
                "device": record.device,
                "inode": record.inode,
                "size": record.logical_bytes,
                "mtimeNs": record.mtime_ns,
            }
            if classification == "delete"
            else None
        ),
    }


def build_plan_document(
    policy: LoadedPolicy,
    *,
    codex_home: Path,
    delete_root: str,
    protected_roots: Sequence[str],
    executor: dict[str, str],
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    records = scan_records(policy, codex_home=codex_home)
    analysis = analyze_graph(
        records,
        delete_root=delete_root,
        protected_roots=protected_roots,
    )
    created = now or _utc_now()
    expires = created + dt.timedelta(seconds=policy.plan_validity_seconds)
    entries = [
        _entry_for_manifest(record, analysis)
        for record in sorted(records, key=lambda item: item.record_key)
    ]
    targets = [entry for entry in entries if entry["classification"] == "delete"]
    protected = [entry for entry in entries if entry["classification"] == "protect"]
    ambiguous = [entry for entry in entries if entry["classification"] == "ambiguous"]
    return {
        "schemaVersion": 1,
        "kind": PLAN_KIND,
        "parserContractVersion": PARSER_CONTRACT_VERSION,
        "createdAt": _format_timestamp(created),
        "expiresAt": _format_timestamp(expires),
        "policySha256": policy.sha256,
        "codexHomeFingerprint": _codex_home_fingerprint(codex_home),
        "deleteRoot": delete_root,
        "protectedRoots": sorted(set(protected_roots)),
        "executor": {
            "commandTemplate": EXPECTED_COMMAND_TEMPLATE,
            **executor,
        },
        "inventory": {
            "records": len(entries),
            "logicalBytes": sum(entry["logicalBytes"] for entry in entries),
            "allocatedBytes": sum(entry["allocatedBytes"] for entry in entries),
            "deleteRecords": len(targets),
            "deleteLogicalBytes": sum(entry["logicalBytes"] for entry in targets),
            "deleteAllocatedBytes": sum(entry["allocatedBytes"] for entry in targets),
            "protectedRecords": len(protected),
            "protectedAllocatedBytes": sum(entry["allocatedBytes"] for entry in protected),
            "ambiguousRecords": len(ambiguous),
            "ambiguousAllocatedBytes": sum(entry["allocatedBytes"] for entry in ambiguous),
            "filesystem": _filesystem_status(codex_home),
        },
        "deletionOrder": list(analysis.deletion_order),
        "entries": entries,
    }


def _json_bytes(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _exclusive_write(path: Path, payload: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _replace_json(path: Path, document: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4()}.tmp")
    try:
        _exclusive_write(temporary, _json_bytes(document))
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _read_private_operator_record(
    path: Path,
    *,
    expected_name: str,
    repo_root: Path,
    codex_home: Path,
) -> tuple[Path, bytes]:
    candidate = path.expanduser()
    if not candidate.is_absolute():
        raise WorkflowError("operator records must use an absolute path")
    try:
        candidate_lstat = candidate.lstat()
    except OSError as error:
        raise WorkflowError("the operator record is unavailable") from error
    if stat.S_ISLNK(candidate_lstat.st_mode):
        raise WorkflowError("the operator record cannot be a symlink")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise WorkflowError("the operator record cannot be resolved") from error
    if resolved.name != expected_name:
        raise WorkflowError(f"the operator record must be named {expected_name}")
    resolved_repo = repo_root.resolve()
    resolved_home = codex_home.resolve()
    if (
        not _is_in_system_temporary_directory(resolved)
        or _is_relative_to(resolved, resolved_repo)
        or _is_relative_to(resolved, resolved_home)
    ):
        raise WorkflowError(
            "operator records must stay in a private system-temporary directory"
        )

    parent_stat = resolved.parent.stat()
    if not stat.S_ISDIR(parent_stat.st_mode) or stat.S_IMODE(parent_stat.st_mode) != 0o700:
        raise WorkflowError("the operator-record directory must use private permissions")
    if hasattr(os, "geteuid") and parent_stat.st_uid != os.geteuid():
        raise WorkflowError("the operator-record directory has a different owner")

    file_stat = resolved.lstat()
    if (
        not stat.S_ISREG(file_stat.st_mode)
        or file_stat.st_nlink != 1
        or stat.S_IMODE(file_stat.st_mode) != 0o600
    ):
        raise WorkflowError("the operator record must be a private unique regular file")
    if hasattr(os, "geteuid") and file_stat.st_uid != os.geteuid():
        raise WorkflowError("the operator record has a different owner")
    if file_stat.st_size > MAX_OPERATOR_RECORD_BYTES:
        raise WorkflowError("the operator record exceeds the bounded size limit")

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(resolved, flags)
    except OSError as error:
        raise WorkflowError("unable to open the operator record safely") from error
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (file_stat.st_dev, file_stat.st_ino):
            raise WorkflowError("the operator record changed while opening")
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            descriptor = -1
            raw = handle.read(MAX_OPERATOR_RECORD_BYTES + 1)
            final = os.fstat(handle.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(raw) > MAX_OPERATOR_RECORD_BYTES:
        raise WorkflowError("the operator record exceeds the bounded size limit")
    if (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns) != (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_size,
        file_stat.st_mtime_ns,
    ):
        raise WorkflowError("the operator record changed while reading")
    return resolved, raw


def write_plan(
    document: dict[str, Any],
    *,
    output_dir: Path | None,
    repo_root: Path,
    codex_home: Path,
) -> tuple[Path, str]:
    repo_root = repo_root.resolve()
    codex_home = codex_home.resolve()
    if output_dir is None:
        temporary_root = _system_temporary_roots()[0]
        if _is_relative_to(temporary_root, repo_root) or _is_relative_to(
            temporary_root, codex_home
        ):
            raise WorkflowError("the system temporary directory overlaps protected state")
        directory = Path(
            tempfile.mkdtemp(prefix="codex-session-cleanup-", dir=temporary_root)
        )
        os.chmod(directory, 0o700)
    else:
        directory = output_dir.expanduser()
        if not directory.is_absolute():
            raise WorkflowError("the plan output directory must be absolute")
        directory = directory.resolve()
        if (
            not _is_in_system_temporary_directory(directory)
            or _is_relative_to(directory, repo_root)
            or _is_relative_to(directory, codex_home)
        ):
            raise WorkflowError(
                "the plan must stay outside the repository and Codex state root in system temporary storage"
            )
        if directory.exists():
            raise WorkflowError("the plan output directory already exists; use a new directory")
        directory.mkdir(mode=0o700, parents=True)
        os.chmod(directory, 0o700)

    payload = _json_bytes(document)
    digest = hashlib.sha256(payload).hexdigest()
    manifest_path = directory / PLAN_FILENAME
    checksum_path = directory / CHECKSUM_FILENAME
    _exclusive_write(manifest_path, payload)
    _exclusive_write(checksum_path, f"{digest}  {PLAN_FILENAME}\n".encode("ascii"))
    return manifest_path, digest


PLAN_KEYS = {
    "schemaVersion",
    "kind",
    "parserContractVersion",
    "createdAt",
    "expiresAt",
    "policySha256",
    "codexHomeFingerprint",
    "deleteRoot",
    "protectedRoots",
    "executor",
    "inventory",
    "deletionOrder",
    "entries",
}
ENTRY_KEYS = {
    "recordKey",
    "sessionId",
    "rootId",
    "parentId",
    "spawnParentId",
    "store",
    "createdAt",
    "modifiedAt",
    "cwdClassification",
    "logicalBytes",
    "allocatedBytes",
    "depth",
    "classification",
    "reason",
    "targetFingerprint",
}
INVENTORY_KEYS = {
    "records",
    "logicalBytes",
    "allocatedBytes",
    "deleteRecords",
    "deleteLogicalBytes",
    "deleteAllocatedBytes",
    "protectedRecords",
    "protectedAllocatedBytes",
    "ambiguousRecords",
    "ambiguousAllocatedBytes",
    "filesystem",
}


def _load_and_validate_plan(
    policy: LoadedPolicy,
    codex_home: Path,
    manifest_path: Path,
    approved_sha256: str,
    *,
    approved_root: str | None,
    require_unexpired: bool,
) -> tuple[dict[str, Any], str]:
    if not SHA256_PATTERN.fullmatch(approved_sha256):
        raise WorkflowError("the approved manifest SHA-256 is malformed")
    _, raw = _read_private_operator_record(
        manifest_path,
        expected_name=PLAN_FILENAME,
        repo_root=policy.repo_root,
        codex_home=codex_home,
    )
    actual_sha256 = hashlib.sha256(raw).hexdigest()
    if actual_sha256 != approved_sha256:
        raise WorkflowError("the deletion plan does not match the approved SHA-256")
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as error:
        raise WorkflowError("the deletion plan is not valid JSON") from error
    if not isinstance(document, dict) or set(document) != PLAN_KEYS:
        raise WorkflowError("the deletion plan schema is not exact")
    if document.get("schemaVersion") != 1 or document.get("kind") != PLAN_KIND:
        raise WorkflowError("the deletion plan kind or schema is unsupported")
    if document.get("parserContractVersion") != PARSER_CONTRACT_VERSION:
        raise WorkflowError("the deletion plan parser contract changed")
    if document.get("policySha256") != policy.sha256:
        raise WorkflowError("the tracked policy changed after planning")
    home_fingerprint = document.get("codexHomeFingerprint")
    if (
        not isinstance(home_fingerprint, dict)
        or set(home_fingerprint) != {"device", "inode"}
        or not all(isinstance(value, int) and value >= 0 for value in home_fingerprint.values())
        or home_fingerprint != _codex_home_fingerprint(codex_home)
    ):
        raise WorkflowError("the plan does not match the selected Codex home")
    delete_root = _require_canonical_uuid(document.get("deleteRoot"), "plan deleteRoot")
    if approved_root is not None and delete_root != approved_root:
        raise WorkflowError("the plan root does not match the separately approved root")
    protected_roots_raw = document.get("protectedRoots")
    if not isinstance(protected_roots_raw, list) or not protected_roots_raw:
        raise WorkflowError("the plan has no explicit protected root")
    protected_roots = [
        _require_canonical_uuid(value, "protected root")
        for value in protected_roots_raw
    ]
    if protected_roots != sorted(set(protected_roots)) or delete_root in protected_roots:
        raise WorkflowError("the protected-root set is invalid")

    created = _parse_timestamp(document.get("createdAt"), "plan createdAt")
    expires = _parse_timestamp(document.get("expiresAt"), "plan expiresAt")
    if int((expires - created).total_seconds()) != policy.plan_validity_seconds:
        raise WorkflowError("the plan expiration no longer matches the tracked policy")
    if require_unexpired:
        current_time = _utc_now()
        if current_time < created:
            raise WorkflowError("the deletion plan is not active yet; create a current plan")
        if current_time > expires:
            raise WorkflowError("the deletion plan expired; create and review a new plan")

    executor = document.get("executor")
    if not isinstance(executor, dict) or set(executor) != {
        "commandTemplate",
        "version",
        "binarySha256",
        "deleteHelpSha256",
    }:
        raise WorkflowError("the plan executor binding is malformed")
    if executor.get("commandTemplate") != EXPECTED_COMMAND_TEMPLATE:
        raise WorkflowError("the plan executor command changed")
    for key in ("binarySha256", "deleteHelpSha256"):
        if not isinstance(executor.get(key), str) or not SHA256_PATTERN.fullmatch(executor[key]):
            raise WorkflowError("the plan executor digest is malformed")
    if not isinstance(executor.get("version"), str) or not re.fullmatch(
        r"codex-cli [0-9A-Za-z.+-]+", executor["version"]
    ):
        raise WorkflowError("the plan executor version is malformed")

    entries = document.get("entries")
    if not isinstance(entries, list) or not entries:
        raise WorkflowError("the deletion plan contains no entries")
    record_keys: set[str] = set()
    session_ids: set[str] = set()
    target_entries: list[dict[str, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != ENTRY_KEYS:
            raise WorkflowError("a deletion-plan entry schema is not exact")
        record_key = entry.get("recordKey")
        if not isinstance(record_key, str) or not SHA256_PATTERN.fullmatch(record_key):
            raise WorkflowError("a deletion-plan record key is malformed")
        if record_key in record_keys:
            raise WorkflowError("the deletion plan contains duplicate records")
        record_keys.add(record_key)
        session_id = _require_canonical_uuid(
            entry.get("sessionId"), "entry sessionId"
        )
        if session_id in session_ids:
            raise WorkflowError("the deletion plan contains duplicate session IDs")
        session_ids.add(session_id)
        classification = entry.get("classification")
        if classification not in {"delete", "protect", "ambiguous"}:
            raise WorkflowError("a deletion-plan classification is invalid")
        if entry.get("rootId") is None:
            if classification != "ambiguous":
                raise WorkflowError("a proven deletion-plan entry has no root ID")
        else:
            _require_canonical_uuid(entry["rootId"], "entry rootId")
        if entry.get("parentId") is not None:
            _require_canonical_uuid(entry["parentId"], "entry parentId")
        if entry.get("spawnParentId") is not None:
            _require_canonical_uuid(entry["spawnParentId"], "entry spawnParentId")
        if entry.get("store") not in EXPECTED_STORES:
            raise WorkflowError("a deletion-plan store is invalid")
        created_at = entry.get("createdAt")
        if created_at is not None:
            _parse_timestamp(created_at, "entry createdAt")
        _parse_timestamp(entry.get("modifiedAt"), "entry modifiedAt")
        if entry.get("cwdClassification") not in {"repository", "other", "missing"}:
            raise WorkflowError("a cwd classification is invalid")
        for key in ("logicalBytes", "allocatedBytes"):
            if not isinstance(entry.get(key), int) or entry[key] < 0:
                raise WorkflowError("a deletion-plan byte count is invalid")
        if not isinstance(entry.get("reason"), str) or not re.fullmatch(
            r"[a-z0-9-]+", entry["reason"]
        ):
            raise WorkflowError("a deletion-plan reason is invalid")
        if entry["classification"] == "delete":
            if not isinstance(entry.get("depth"), int) or entry["depth"] < 0:
                raise WorkflowError("a deletion target depth is invalid")
            fingerprint = entry.get("targetFingerprint")
            if not isinstance(fingerprint, dict) or set(fingerprint) != {
                "device",
                "inode",
                "size",
                "mtimeNs",
            }:
                raise WorkflowError("a deletion target fingerprint is malformed")
            if not all(isinstance(value, int) and value >= 0 for value in fingerprint.values()):
                raise WorkflowError("a deletion target fingerprint is invalid")
            target_entries.append(entry)
        elif entry.get("targetFingerprint") is not None:
            raise WorkflowError("a protected entry cannot carry a deletion fingerprint")
        elif entry.get("classification") == "protect" and (
            not isinstance(entry.get("depth"), int) or entry["depth"] < 0
        ):
            raise WorkflowError("a protected entry depth is invalid")
        elif entry.get("classification") == "ambiguous" and entry.get("depth") is not None:
            raise WorkflowError("an ambiguous entry cannot claim a proven depth")

    expected_order = [
        entry["sessionId"]
        for entry in sorted(
            target_entries,
            key=lambda item: (-item["depth"], item["sessionId"]),
        )
    ]
    if document.get("deletionOrder") != expected_order or not expected_order:
        raise WorkflowError("the deletion order is stale or malformed")
    if expected_order[-1] != delete_root:
        raise WorkflowError("the deletion root is not last")

    inventory = document.get("inventory")
    if not isinstance(inventory, dict) or set(inventory) != INVENTORY_KEYS:
        raise WorkflowError("the deletion-plan inventory is malformed")
    expected_counts = {
        "records": len(entries),
        "logicalBytes": sum(entry["logicalBytes"] for entry in entries),
        "allocatedBytes": sum(entry["allocatedBytes"] for entry in entries),
        "deleteRecords": len(target_entries),
        "deleteLogicalBytes": sum(entry["logicalBytes"] for entry in target_entries),
        "deleteAllocatedBytes": sum(entry["allocatedBytes"] for entry in target_entries),
        "protectedRecords": sum(entry["classification"] == "protect" for entry in entries),
        "protectedAllocatedBytes": sum(
            entry["allocatedBytes"] for entry in entries if entry["classification"] == "protect"
        ),
        "ambiguousRecords": sum(entry["classification"] == "ambiguous" for entry in entries),
        "ambiguousAllocatedBytes": sum(
            entry["allocatedBytes"] for entry in entries if entry["classification"] == "ambiguous"
        ),
    }
    for key, expected in expected_counts.items():
        if inventory.get(key) != expected:
            raise WorkflowError(f"the deletion-plan inventory field {key} is inconsistent")
    filesystem = inventory.get("filesystem")
    if not isinstance(filesystem, dict) or set(filesystem) != {
        "totalBytes",
        "usedBytes",
        "availableBytes",
    }:
        raise WorkflowError("the deletion-plan filesystem snapshot is malformed")
    if not all(isinstance(value, int) and value >= 0 for value in filesystem.values()):
        raise WorkflowError("the deletion-plan filesystem snapshot is invalid")
    return document, actual_sha256


def _target_fingerprints(document: dict[str, Any]) -> dict[str, dict[str, int]]:
    return {
        entry["sessionId"]: entry["targetFingerprint"]
        for entry in document["entries"]
        if entry["classification"] == "delete"
    }


def _validate_non_target_baseline(
    records: Sequence[SessionRecord],
    document: dict[str, Any],
    preserved_additions: dict[str, dict[str, Any]] | None = None,
) -> tuple[dict[str, Lineage], dict[str, list[SessionRecord]]]:
    current_by_key = {record.record_key: record for record in records}
    lineages = derive_lineages(records)
    by_id: dict[str, list[SessionRecord]] = {}
    for record in records:
        if record.session_id is not None:
            by_id.setdefault(record.session_id, []).append(record)

    baseline_entries = list(document["entries"])
    if preserved_additions:
        baseline_entries.extend(preserved_additions.values())
    for entry in baseline_entries:
        if entry["classification"] == "delete":
            continue
        record = current_by_key.get(entry["recordKey"])
        if record is None:
            raise WorkflowError("a protected or ambiguous baseline task disappeared after approval")
        expected_identity = {
            "sessionId": entry["sessionId"],
            "rootId": entry["rootId"],
            "parentId": entry["parentId"],
            "spawnParentId": entry["spawnParentId"],
            "store": entry["store"],
            "createdAt": entry["createdAt"],
            "cwdClassification": entry["cwdClassification"],
        }
        current_identity = {
            "sessionId": record.session_id,
            "rootId": record.root_id,
            "parentId": record.parent_id,
            "spawnParentId": record.spawn_parent_id,
            "store": record.store,
            "createdAt": record.created_at,
            "cwdClassification": record.cwd_classification,
        }
        if current_identity != expected_identity:
            raise WorkflowError("protected or ambiguous task metadata changed after approval")
        if len(by_id.get(entry["sessionId"], [])) != 1:
            raise WorkflowError("a protected or ambiguous baseline task disappeared or duplicated")
        lineage = lineages[record.record_key]
        if entry["classification"] == "protect":
            if not lineage.valid or lineage.root_id != entry["rootId"]:
                raise WorkflowError("a protected task lineage changed after approval")
        elif lineage.valid or lineage.reason != entry["reason"]:
            raise WorkflowError("an ambiguous task classification changed after approval")

    for protected_root in document["protectedRoots"]:
        candidates = by_id.get(protected_root, [])
        if len(candidates) != 1:
            raise WorkflowError("an explicit protected root disappeared or duplicated")
        lineage = lineages[candidates[0].record_key]
        if not lineage.valid or lineage.root_id != protected_root or lineage.depth != 0:
            raise WorkflowError("an explicit protected root lineage changed")
    return lineages, by_id


def _extend_preservation_baseline(
    records: Sequence[SessionRecord],
    lineages: dict[str, Lineage],
    document: dict[str, Any],
    preserved_additions: dict[str, dict[str, Any]] | None,
) -> None:
    if preserved_additions is None:
        return
    target_ids = set(document["deletionOrder"])
    planned_non_target_keys = {
        entry["recordKey"]
        for entry in document["entries"]
        if entry["classification"] != "delete"
    }
    for record in records:
        if (
            record.session_id is None
            or record.session_id in target_ids
            or record.record_key in planned_non_target_keys
            or record.record_key in preserved_additions
        ):
            continue
        lineage = lineages[record.record_key]
        preserved_additions[record.record_key] = {
            "recordKey": record.record_key,
            "sessionId": record.session_id,
            "rootId": record.root_id,
            "parentId": record.parent_id,
            "spawnParentId": record.spawn_parent_id,
            "store": record.store,
            "createdAt": record.created_at,
            "cwdClassification": record.cwd_classification,
            "classification": "protect" if lineage.valid else "ambiguous",
            "reason": "new-unrelated-proven-tree" if lineage.valid else lineage.reason,
        }


def validate_live_state(
    policy: LoadedPolicy,
    *,
    codex_home: Path,
    document: dict[str, Any],
    pending_target_ids: set[str],
    preserved_additions: dict[str, dict[str, Any]] | None = None,
) -> tuple[tuple[SessionRecord, ...], GraphAnalysis | None]:
    records = scan_records(policy, codex_home=codex_home)
    all_target_ids = set(document["deletionOrder"])
    delete_root = document["deleteRoot"]
    protected_roots = document["protectedRoots"]
    lineages, by_id = _validate_non_target_baseline(
        records, document, preserved_additions
    )

    for record in records:
        if record.session_id in pending_target_ids:
            continue
        if (
            record.session_id in all_target_ids
            or record.root_id == delete_root
            or record.parent_id in all_target_ids
            or record.spawn_parent_id in all_target_ids
        ):
            raise WorkflowError(
                "a new or surviving task references the approved deletion tree"
            )

    if pending_target_ids:
        analysis = analyze_graph(
            records,
            delete_root=delete_root,
            protected_roots=protected_roots,
        )
        if analysis.target_ids != pending_target_ids:
            raise WorkflowError("the approved deletion set changed; create a new plan")
        fingerprints = _target_fingerprints(document)
        planned_targets = {
            entry["sessionId"]: entry
            for entry in document["entries"]
            if entry["classification"] == "delete"
        }
        for session_id in pending_target_ids:
            candidates = by_id.get(session_id, [])
            if len(candidates) != 1:
                raise WorkflowError("an approved target is missing or duplicated")
            record = candidates[0]
            expected = fingerprints[session_id]
            current = {
                "device": record.device,
                "inode": record.inode,
                "size": record.logical_bytes,
                "mtimeNs": record.mtime_ns,
            }
            if current != expected:
                raise WorkflowError("an approved target changed after planning")
            planned = planned_targets[session_id]
            planned_identity = {
                "recordKey": planned["recordKey"],
                "rootId": planned["rootId"],
                "parentId": planned["parentId"],
                "spawnParentId": planned["spawnParentId"],
                "store": planned["store"],
                "createdAt": planned["createdAt"],
                "cwdClassification": planned["cwdClassification"],
                "depth": planned["depth"],
            }
            current_identity = {
                "recordKey": record.record_key,
                "rootId": record.root_id,
                "parentId": record.parent_id,
                "spawnParentId": record.spawn_parent_id,
                "store": record.store,
                "createdAt": record.created_at,
                "cwdClassification": record.cwd_classification,
                "depth": analysis.lineages[record.record_key].depth,
            }
            if current_identity != planned_identity:
                raise WorkflowError("an approved target relationship changed after planning")
        _extend_preservation_baseline(
            records,
            analysis.lineages,
            document,
            preserved_additions,
        )
        return records, analysis

    if any(record.errors and record.session_id is None for record in records):
        raise WorkflowError("unreadable rollout metadata prevents complete post-verification")
    for record in records:
        if record.session_id in all_target_ids or record.root_id == delete_root:
            raise WorkflowError("an approved deletion target or descendant remains")
        if record.parent_id in all_target_ids or record.spawn_parent_id in all_target_ids:
            raise WorkflowError("a surviving task still references the deleted tree")
    _extend_preservation_baseline(
        records,
        lineages,
        document,
        preserved_additions,
    )
    return records, None


def _executor_matches(document: dict[str, Any], codex_bin: str) -> str:
    current = inspect_executor(codex_bin)
    expected = document["executor"]
    for key in ("version", "binarySha256", "deleteHelpSha256"):
        if current[key] != expected[key]:
            raise WorkflowError("the Codex executable changed after planning")
    candidate = Path(codex_bin)
    resolved_value = str(candidate.resolve()) if candidate.is_absolute() else shutil.which(codex_bin)
    if not resolved_value:
        raise WorkflowError("the Codex executable is unavailable")
    return str(Path(resolved_value).resolve())


def _initial_journal(document: dict[str, Any], manifest_sha256: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "kind": JOURNAL_KIND,
        "manifestSha256": manifest_sha256,
        "deleteRoot": document["deleteRoot"],
        "startedAt": _format_timestamp(_utc_now()),
        "finishedAt": None,
        "status": "running",
        "results": [],
    }


def _load_and_validate_journal(
    policy: LoadedPolicy,
    *,
    codex_home: Path,
    manifest_path: Path,
    document: dict[str, Any],
    manifest_sha256: str,
) -> dict[str, Any]:
    journal_path = manifest_path.expanduser().resolve().parent / JOURNAL_FILENAME
    _, raw = _read_private_operator_record(
        journal_path,
        expected_name=JOURNAL_FILENAME,
        repo_root=policy.repo_root,
        codex_home=codex_home,
    )
    try:
        journal = json.loads(raw)
    except json.JSONDecodeError as error:
        raise WorkflowError("the execution journal is not valid JSON") from error
    expected_keys = {
        "schemaVersion",
        "kind",
        "manifestSha256",
        "deleteRoot",
        "startedAt",
        "finishedAt",
        "status",
        "results",
    }
    if not isinstance(journal, dict) or set(journal) != expected_keys:
        raise WorkflowError("the execution journal schema is not exact")
    if journal.get("schemaVersion") != 1 or journal.get("kind") != JOURNAL_KIND:
        raise WorkflowError("the execution journal kind or schema is unsupported")
    if journal.get("manifestSha256") != manifest_sha256:
        raise WorkflowError("the execution journal belongs to a different plan")
    if journal.get("deleteRoot") != document["deleteRoot"]:
        raise WorkflowError("the execution journal root does not match the plan")
    _parse_timestamp(journal.get("startedAt"), "journal startedAt")
    _parse_timestamp(journal.get("finishedAt"), "journal finishedAt")
    if journal.get("status") != "passed":
        raise WorkflowError("the execution journal did not finish with PASS")
    results = journal.get("results")
    if not isinstance(results, list) or len(results) != len(document["deletionOrder"]):
        raise WorkflowError("the execution journal result count is incomplete")
    result_ids: list[str] = []
    for result in results:
        if not isinstance(result, dict) or set(result) != {
            "sessionId",
            "status",
            "exitCode",
            "completedAt",
        }:
            raise WorkflowError("an execution journal result schema is not exact")
        result_ids.append(
            _require_canonical_uuid(result.get("sessionId"), "journal sessionId")
        )
        if result.get("status") != "deleted" or result.get("exitCode") != 0:
            raise WorkflowError("an execution journal result is not successful")
        _parse_timestamp(result.get("completedAt"), "journal completedAt")
    if result_ids != document["deletionOrder"]:
        raise WorkflowError("the execution journal order does not match the plan")
    return journal


def execute_plan(
    policy: LoadedPolicy,
    *,
    codex_home: Path,
    manifest_path: Path,
    approved_sha256: str,
    approved_root: str,
    codex_bin: str,
) -> dict[str, Any]:
    document, manifest_sha256 = _load_and_validate_plan(
        policy,
        codex_home,
        manifest_path,
        approved_sha256,
        approved_root=approved_root,
        require_unexpired=True,
    )
    resolved_codex = _executor_matches(document, codex_bin)
    codex_environment = os.environ.copy()
    codex_environment["CODEX_HOME"] = str(codex_home.resolve())
    journal_path = manifest_path.expanduser().resolve().parent / JOURNAL_FILENAME
    if journal_path.exists():
        raise WorkflowError(
            "this plan already has an execution journal; verify it and create a fresh plan before retrying"
        )
    pending = set(document["deletionOrder"])
    preserved_additions: dict[str, dict[str, Any]] = {}
    # Two matching scans separate approval validation from the first mutation.
    # The second scan is journaled and starts the per-command revalidation chain.
    _, analysis = validate_live_state(
        policy,
        codex_home=codex_home,
        document=document,
        pending_target_ids=pending,
        preserved_additions=preserved_additions,
    )
    journal = _initial_journal(document, manifest_sha256)
    _exclusive_write(journal_path, _json_bytes(journal))
    try:
        _, analysis = validate_live_state(
            policy,
            codex_home=codex_home,
            document=document,
            pending_target_ids=pending,
            preserved_additions=preserved_additions,
        )
        for session_id in document["deletionOrder"]:
            if analysis is None:
                raise WorkflowError("the live deletion graph disappeared unexpectedly")
            record_by_id = {
                record.session_id: record
                for record in analysis.records
                if record.session_id is not None
            }
            if any(
                other_id in pending and record_by_id[other_id].parent_id == session_id
                for other_id in pending
                if other_id != session_id and other_id in record_by_id
            ):
                raise WorkflowError("the next approved target is not currently a leaf")
            if _hash_file(Path(resolved_codex)) != document["executor"]["binarySha256"]:
                raise WorkflowError("the Codex executable changed during execution")
            try:
                result = subprocess.run(
                    [resolved_codex, "delete", "--force", session_id],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    stdin=subprocess.DEVNULL,
                    check=False,
                    env=codex_environment,
                    shell=False,
                    timeout=policy.command_timeout_seconds,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                raise WorkflowError("the supported Codex deletion command failed to complete") from error
            combined = f"{result.stdout}\n{result.stderr}"
            reported_ids = {str(uuid.UUID(value)) for value in UUID_PATTERN.findall(combined)}
            if reported_ids.difference({session_id}):
                raise WorkflowError("Codex reported a task other than the requested UUID")
            lowered = combined.lower()
            if result.returncode != 0 or (
                ("database" in lowered or "sqlite" in lowered) and "error" in lowered
            ):
                raise WorkflowError("Codex reported a deletion or state-database failure")

            pending.remove(session_id)
            _, analysis = validate_live_state(
                policy,
                codex_home=codex_home,
                document=document,
                pending_target_ids=pending,
                preserved_additions=preserved_additions,
            )
            journal["results"].append(
                {
                    "sessionId": session_id,
                    "status": "deleted",
                    "exitCode": result.returncode,
                    "completedAt": _format_timestamp(_utc_now()),
                }
            )
            _replace_json(journal_path, journal)
    except Exception:
        journal["status"] = "stopped"
        journal["finishedAt"] = _format_timestamp(_utc_now())
        try:
            _replace_json(journal_path, journal)
        except OSError:
            pass
        raise

    journal["status"] = "passed"
    journal["finishedAt"] = _format_timestamp(_utc_now())
    _replace_json(journal_path, journal)
    return journal


def verify_plan(
    policy: LoadedPolicy,
    *,
    codex_home: Path,
    manifest_path: Path,
    approved_sha256: str,
) -> dict[str, Any]:
    document, manifest_sha256 = _load_and_validate_plan(
        policy,
        codex_home,
        manifest_path,
        approved_sha256,
        approved_root=None,
        require_unexpired=False,
    )
    _load_and_validate_journal(
        policy,
        codex_home=codex_home,
        manifest_path=manifest_path,
        document=document,
        manifest_sha256=manifest_sha256,
    )
    records, _ = validate_live_state(
        policy,
        codex_home=codex_home,
        document=document,
        pending_target_ids=set(),
    )
    return {
        "schemaVersion": 1,
        "kind": "codex-session-deletion-verification",
        "verifiedAt": _format_timestamp(_utc_now()),
        "status": "passed",
        "manifestSha256": manifest_sha256,
        "deletedRecords": len(document["deletionOrder"]),
        "remaining": _aggregate_records(records),
        "filesystem": _filesystem_status(codex_home),
    }


def _format_bytes(value: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    amount = float(value)
    for unit in units:
        if abs(amount) < 1024.0 or unit == units[-1]:
            return f"{amount:.2f} {unit}"
        amount /= 1024.0
    return f"{value} B"


def _print_status(payload: dict[str, Any]) -> None:
    inventory = payload["inventory"]
    print("Codex task/session storage (read-only, metadata-only)")
    print(f"  records: {inventory['records']}")
    print(f"  logical: {_format_bytes(inventory['logicalBytes'])}")
    print(f"  allocated: {_format_bytes(inventory['allocatedBytes'])}")
    print(f"  metadata errors: {inventory['metadataErrors']}")
    print(f"  ambiguous lineages: {inventory['ambiguousLineages']}")
    print(f"  filesystem available: {_format_bytes(payload['filesystem']['availableBytes'])}")


def _print_plan(path: Path, digest: str, document: dict[str, Any]) -> None:
    inventory = document["inventory"]
    print("Codex deletion plan created; no task was modified.")
    print(f"  manifest: {path}")
    print(f"  sha256: {digest}")
    print(f"  old root: {document['deleteRoot']}")
    print(f"  delete: {inventory['deleteRecords']} records / {_format_bytes(inventory['deleteAllocatedBytes'])}")
    print(f"  protect: {inventory['protectedRecords']} records / {_format_bytes(inventory['protectedAllocatedBytes'])}")
    print(f"  ambiguous: {inventory['ambiguousRecords']} records / {_format_bytes(inventory['ambiguousAllocatedBytes'])}")
    print(f"  filesystem available: {_format_bytes(inventory['filesystem']['availableBytes'])}")
    print("  method: explicit deepest-first codex delete --force UUID; root last")
    print("Review the manifest, then obtain explicit approval for this exact root and SHA-256 before execute.")


def _add_policy_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repo-root", type=Path, default=DEFAULT_REPO_ROOT)
    parser.add_argument("--policy", type=Path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate and operate the optional Codex task/session storage workflow."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser(
        "validate", help="validate tracked policy only; never inspect user state"
    )
    _add_policy_arguments(validate_parser)

    status_parser = subparsers.add_parser(
        "status", help="read a privacy-safe aggregate inventory"
    )
    _add_policy_arguments(status_parser)
    status_parser.add_argument("--codex-home", type=Path)
    status_parser.add_argument("--json", action="store_true")

    plan_parser = subparsers.add_parser(
        "plan", help="create a checksummed, non-mutating deletion proposal"
    )
    _add_policy_arguments(plan_parser)
    plan_parser.add_argument("--codex-home", type=Path)
    plan_parser.add_argument("--delete-root", required=True)
    plan_parser.add_argument("--protect-root", action="append", required=True)
    plan_parser.add_argument("--output-dir", type=Path)
    plan_parser.add_argument("--codex-bin", default="codex")

    execute_parser = subparsers.add_parser(
        "execute", help="execute only an explicitly approved, checksummed plan"
    )
    _add_policy_arguments(execute_parser)
    execute_parser.add_argument("--codex-home", type=Path)
    execute_parser.add_argument("--manifest", type=Path, required=True)
    execute_parser.add_argument("--approved-sha256", required=True)
    execute_parser.add_argument("--approved-root", required=True)
    execute_parser.add_argument("--codex-bin", default="codex")

    verify_parser = subparsers.add_parser(
        "verify", help="verify deletion and protected-state preservation"
    )
    _add_policy_arguments(verify_parser)
    verify_parser.add_argument("--codex-home", type=Path)
    verify_parser.add_argument("--manifest", type=Path, required=True)
    verify_parser.add_argument("--approved-sha256", required=True)
    verify_parser.add_argument("--json", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        policy = load_policy(arguments.repo_root, arguments.policy)
        if arguments.command == "validate":
            print("Codex session-storage policy: PASS")
            return 0

        codex_home = _codex_home(arguments.codex_home)
        if arguments.command == "status":
            payload = status_payload(policy, codex_home)
            if arguments.json:
                print(json.dumps(payload, indent=2, sort_keys=True))
            else:
                _print_status(payload)
            return 0

        if arguments.command == "plan":
            delete_root = _require_uuid(arguments.delete_root, "delete root")
            protected_roots = sorted(
                {
                    _require_uuid(value, "protected root")
                    for value in arguments.protect_root
                }
            )
            executor = inspect_executor(arguments.codex_bin)
            document = build_plan_document(
                policy,
                codex_home=codex_home,
                delete_root=delete_root,
                protected_roots=protected_roots,
                executor=executor,
            )
            path, digest = write_plan(
                document,
                output_dir=arguments.output_dir,
                repo_root=policy.repo_root,
                codex_home=codex_home,
            )
            _print_plan(path, digest, document)
            return 0

        if arguments.command == "execute":
            approved_root = _require_uuid(arguments.approved_root, "approved root")
            journal = execute_plan(
                policy,
                codex_home=codex_home,
                manifest_path=arguments.manifest,
                approved_sha256=arguments.approved_sha256,
                approved_root=approved_root,
                codex_bin=arguments.codex_bin,
            )
            print(
                f"Codex deletion execution: PASS ({len(journal['results'])} exact UUIDs deleted)"
            )
            return 0

        if arguments.command == "verify":
            payload = verify_plan(
                policy,
                codex_home=codex_home,
                manifest_path=arguments.manifest,
                approved_sha256=arguments.approved_sha256,
            )
            if arguments.json:
                print(json.dumps(payload, indent=2, sort_keys=True))
            else:
                print(
                    "Codex deletion verification: PASS "
                    f"({payload['deletedRecords']} approved records absent; "
                    f"{payload['remaining']['records']} records remain)"
                )
            return 0
        raise AssertionError(f"unhandled command: {arguments.command}")
    except (PolicyError, WorkflowError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
