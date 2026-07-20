#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import uuid
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "scripts/codex_session_storage.py"
POLICY_PATH = REPO_ROOT / "config/codex-session-storage-policy.json"

SPEC = importlib.util.spec_from_file_location("codex_session_storage", HELPER)
assert SPEC and SPEC.loader
WORKFLOW = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = WORKFLOW
SPEC.loader.exec_module(WORKFLOW)


class CodexSessionStorageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.temporary_root = Path(self.temporary.name)
        self.codex_home = self.temporary_root / "codex-home"
        self.sessions = self.codex_home / "sessions/2026/07/19"
        self.archived = self.codex_home / "archived_sessions"
        self.sessions.mkdir(parents=True)
        self.archived.mkdir(parents=True)
        self.policy = WORKFLOW.load_policy(REPO_ROOT, POLICY_PATH)
        self.root_id = str(uuid.uuid4())
        self.child_id = str(uuid.uuid4())
        self.grandchild_id = str(uuid.uuid4())
        self.protected_root_id = str(uuid.uuid4())
        self.unrelated_root_id = str(uuid.uuid4())
        self.orphan_id = str(uuid.uuid4())
        self.paths: dict[str, Path] = {}
        self.fake_codex = self.temporary_root / "fake-codex"
        self.fake_map = self.temporary_root / "fake-codex-map.json"
        self.fake_log = self.temporary_root / "fake-codex-log.jsonl"
        self._write_fake_codex()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_fake_codex(self) -> None:
        self.fake_codex.write_text(
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
if arguments == ["--version"]:
    print("codex-cli 9.9.9-fixture")
    raise SystemExit(0)
if arguments == ["delete", "--help"]:
    print("Permanently delete a saved session by id")
    print("--force  Delete without prompting")
    raise SystemExit(0)
if len(arguments) == 3 and arguments[:2] == ["delete", "--force"]:
    session_id = arguments[2]
    mapping = json.loads(Path(os.environ["FAKE_CODEX_MAP"]).read_text(encoding="utf-8"))
    log_path = Path(os.environ["FAKE_CODEX_LOG"])
    first_invocation = not log_path.exists()
    targets = [session_id]
    if os.environ.get("FAKE_CODEX_DELETE_EXTRA") == "1" and session_id in mapping:
        extra = os.environ.get("FAKE_CODEX_EXTRA_ID")
        if extra:
            targets.append(extra)
    for target in targets:
        candidate = mapping.get(target)
        if candidate:
            Path(candidate).unlink(missing_ok=True)
    insert_path = os.environ.get("FAKE_CODEX_INSERT_PATH")
    if first_invocation and insert_path:
        Path(insert_path).write_text(
            os.environ["FAKE_CODEX_INSERT_CONTENT"], encoding="utf-8"
        )
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"sessionId": session_id, "codexHome": os.environ.get("CODEX_HOME")}) + "\\n")
    print(f"Deleted session {session_id}")
    raise SystemExit(0)
raise SystemExit(2)
""",
            encoding="utf-8",
        )
        self.fake_codex.chmod(0o755)

    def _write_session(
        self,
        session_id: str,
        root_id: str,
        *,
        parent_id: str | None = None,
        spawn_parent_id: str | None = None,
        store: str = "active",
        secret_second_line: str = "SECRET_TRANSCRIPT_BODY",
    ) -> Path:
        directory = self.sessions if store == "active" else self.archived
        path = directory / f"rollout-2026-07-19T00-00-00-{session_id}.jsonl"
        payload: dict[str, object] = {
            "id": session_id,
            "session_id": root_id,
            "timestamp": "2026-07-19T00:00:00Z",
            "cwd": str(REPO_ROOT),
            "task_title": "SECRET_TASK_TITLE",
            "private_prompt": "SECRET_PROMPT",
        }
        if parent_id is not None:
            payload["parent_thread_id"] = parent_id
        if spawn_parent_id is not None:
            payload["source"] = {
                "subagent": {
                    "thread_spawn": {"parent_thread_id": spawn_parent_id}
                }
            }
        first = json.dumps(
            {
                "timestamp": "2026-07-19T00:00:00Z",
                "type": "session_meta",
                "payload": payload,
            },
            sort_keys=True,
        )
        path.write_text(
            first + "\n" + secret_second_line + "\n",
            encoding="utf-8",
        )
        self.paths[session_id] = path
        return path

    def _write_standard_tree(self, *, include_grandchild: bool = False) -> None:
        self._write_session(self.root_id, self.root_id)
        self._write_session(
            self.child_id,
            self.root_id,
            parent_id=self.root_id,
            spawn_parent_id=self.root_id,
        )
        if include_grandchild:
            self._write_session(
                self.grandchild_id,
                self.root_id,
                parent_id=self.child_id,
                spawn_parent_id=self.child_id,
            )
        self._write_session(self.protected_root_id, self.protected_root_id)
        self._write_session(self.unrelated_root_id, self.unrelated_root_id, store="archived")

    def _executor(self) -> dict[str, str]:
        return WORKFLOW.inspect_executor(str(self.fake_codex))

    def _plan(self, *, include_grandchild: bool = False) -> tuple[Path, str, dict]:
        self._write_standard_tree(include_grandchild=include_grandchild)
        document = WORKFLOW.build_plan_document(
            self.policy,
            codex_home=self.codex_home,
            delete_root=self.root_id,
            protected_roots=[self.protected_root_id],
            executor=self._executor(),
        )
        path, digest = WORKFLOW.write_plan(
            document,
            output_dir=self.temporary_root / "plan",
            repo_root=REPO_ROOT,
            codex_home=self.codex_home,
        )
        self.fake_map.write_text(
            json.dumps({key: str(value) for key, value in self.paths.items()}),
            encoding="utf-8",
        )
        return path, digest, document

    def _fake_environment(self, **extra: str):
        values = {
            "FAKE_CODEX_MAP": str(self.fake_map),
            "FAKE_CODEX_LOG": str(self.fake_log),
            **extra,
        }
        return mock.patch.dict(os.environ, values)

    def test_policy_validate_is_hermetic_and_rejects_unsafe_mutations(self) -> None:
        WORKFLOW.validate_policy_document(self.policy.document)
        mutations = (
            ("execution", "automaticDeletion", True),
            ("execution", "assumeCommandCascades", True),
            ("execution", "requireCurrentValidityWindow", False),
            ("execution", "rejectReferencesToAnyApprovedId", False),
            ("execution", "shell", True),
            ("metadata", "readLaterJsonlLines", True),
            ("classification", "defaultDisposition", "delete"),
            ("integration", "manualOnly", False),
        )
        for section, key, value in mutations:
            with self.subTest(section=section, key=key):
                mutated = json.loads(json.dumps(self.policy.document))
                mutated[section][key] = value
                with self.assertRaises(WORKFLOW.PolicyError):
                    WORKFLOW.validate_policy_document(mutated)
        mutated = json.loads(json.dumps(self.policy.document))
        mutated["unexpected"] = True
        with self.assertRaisesRegex(WORKFLOW.PolicyError, "schema must remain exact"):
            WORKFLOW.validate_policy_document(mutated)

    def test_status_reads_only_first_metadata_line_and_reports_aggregates(self) -> None:
        self._write_standard_tree()
        payload = WORKFLOW.status_payload(self.policy, self.codex_home)
        rendered = json.dumps(payload, sort_keys=True)
        self.assertEqual(payload["inventory"]["records"], 4)
        self.assertEqual(payload["inventory"]["metadataErrors"], 0)
        self.assertNotIn("SECRET_TRANSCRIPT_BODY", rendered)
        self.assertNotIn("SECRET_TASK_TITLE", rendered)
        self.assertNotIn("SECRET_PROMPT", rendered)
        self.assertNotIn(str(self.temporary_root), rendered)
        self.assertNotIn(self.root_id, rendered)

    def test_plan_is_bottom_up_private_checksummed_and_mode_0600(self) -> None:
        self._write_standard_tree(include_grandchild=True)
        self._write_session(
            self.orphan_id,
            str(uuid.uuid4()),
            parent_id=str(uuid.uuid4()),
        )
        document = WORKFLOW.build_plan_document(
            self.policy,
            codex_home=self.codex_home,
            delete_root=self.root_id,
            protected_roots=[self.protected_root_id],
            executor=self._executor(),
        )
        path, digest = WORKFLOW.write_plan(
            document,
            output_dir=self.temporary_root / "review",
            repo_root=REPO_ROOT,
            codex_home=self.codex_home,
        )
        self.assertEqual(
            document["deletionOrder"],
            [self.grandchild_id, self.child_id, self.root_id],
        )
        self.assertEqual(document["inventory"]["ambiguousRecords"], 1)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(WORKFLOW._hash_file(path), digest)
        rendered = path.read_text(encoding="utf-8")
        self.assertNotIn("SECRET_TRANSCRIPT_BODY", rendered)
        self.assertNotIn("SECRET_TASK_TITLE", rendered)
        self.assertNotIn("SECRET_PROMPT", rendered)
        self.assertNotIn(str(self.temporary_root), rendered)
        self.assertNotIn(str(REPO_ROOT), rendered)
        self.assertNotIn("taskName", rendered)
        self.assertIn('"cwdClassification": "repository"', rendered)

    def test_plan_blocks_ambiguity_that_touches_target_tree(self) -> None:
        self._write_session(self.root_id, self.root_id)
        self._write_session(
            self.child_id,
            self.root_id,
            parent_id=self.root_id,
            spawn_parent_id=str(uuid.uuid4()),
        )
        self._write_session(self.protected_root_id, self.protected_root_id)
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "ambiguous metadata touches"):
            WORKFLOW.build_plan_document(
                self.policy,
                codex_home=self.codex_home,
                delete_root=self.root_id,
                protected_roots=[self.protected_root_id],
                executor=self._executor(),
            )

    def test_plan_blocks_unreadable_metadata_even_when_unrelated(self) -> None:
        self._write_standard_tree()
        (self.sessions / f"rollout-2026-07-19T00-00-00-{uuid.uuid4()}.jsonl").write_text(
            "not-json\nSECRET_TRANSCRIPT_BODY\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "prove completeness"):
            WORKFLOW.build_plan_document(
                self.policy,
                codex_home=self.codex_home,
                delete_root=self.root_id,
                protected_roots=[self.protected_root_id],
                executor=self._executor(),
            )

    def test_plan_preserves_unrelated_ambiguous_record_with_missing_root(self) -> None:
        self._write_standard_tree()
        ambiguous_id = str(uuid.uuid4())
        self._write_session(ambiguous_id, "not-a-uuid")
        document = WORKFLOW.build_plan_document(
            self.policy,
            codex_home=self.codex_home,
            delete_root=self.root_id,
            protected_roots=[self.protected_root_id],
            executor=self._executor(),
        )
        self.assertEqual(document["inventory"]["ambiguousRecords"], 1)
        ambiguous_entry = next(
            entry for entry in document["entries"] if entry["sessionId"] == ambiguous_id
        )
        self.assertEqual(ambiguous_entry["classification"], "ambiguous")
        self.assertIsNone(ambiguous_entry["rootId"])
        path, digest = WORKFLOW.write_plan(
            document,
            output_dir=self.temporary_root / "ambiguous-plan",
            repo_root=REPO_ROOT,
            codex_home=self.codex_home,
        )
        loaded, _ = WORKFLOW._load_and_validate_plan(
            self.policy,
            self.codex_home,
            path,
            digest,
            approved_root=self.root_id,
            require_unexpired=True,
        )
        self.assertEqual(loaded["inventory"]["ambiguousRecords"], 1)

    def test_plan_blocks_duplicate_ids_and_filename_payload_mismatch(self) -> None:
        self._write_standard_tree()
        self._write_session(
            self.protected_root_id,
            self.protected_root_id,
            store="archived",
        )
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "duplicate session IDs"):
            WORKFLOW.build_plan_document(
                self.policy,
                codex_home=self.codex_home,
                delete_root=self.root_id,
                protected_roots=[self.protected_root_id],
                executor=self._executor(),
            )

        mismatch_id = str(uuid.uuid4())
        mismatch_path = self._write_session(mismatch_id, mismatch_id)
        renamed_path = mismatch_path.with_name(
            f"rollout-2026-07-19T00-00-00-{uuid.uuid4()}.jsonl"
        )
        mismatch_path.rename(renamed_path)
        record = WORKFLOW.read_session_record(
            renamed_path,
            codex_home=self.codex_home,
            store="active",
            repo_root=REPO_ROOT,
            maximum_first_line_bytes=self.policy.maximum_first_line_bytes,
        )
        self.assertIn("filename-session-id-mismatch", record.errors)

    def test_plan_orders_branching_tree_by_depth_then_uuid(self) -> None:
        self._write_standard_tree(include_grandchild=True)
        sibling_id = str(uuid.uuid4())
        self._write_session(
            sibling_id,
            self.root_id,
            parent_id=self.root_id,
            spawn_parent_id=self.root_id,
        )
        document = WORKFLOW.build_plan_document(
            self.policy,
            codex_home=self.codex_home,
            delete_root=self.root_id,
            protected_roots=[self.protected_root_id],
            executor=self._executor(),
        )
        self.assertEqual(
            document["deletionOrder"],
            [self.grandchild_id, *sorted([self.child_id, sibling_id]), self.root_id],
        )

    def test_plan_includes_compressed_cold_rollout(self) -> None:
        try:
            from compression import zstd
        except ImportError:
            self.skipTest("standard-library zstd reader is unavailable")
        self._write_standard_tree()
        plain_path = self.paths[self.child_id]
        compressed_path = plain_path.with_name(plain_path.name + ".zst")
        with zstd.open(compressed_path, "wb") as handle:
            handle.write(plain_path.read_bytes())
        plain_path.unlink()
        self.paths[self.child_id] = compressed_path

        document = WORKFLOW.build_plan_document(
            self.policy,
            codex_home=self.codex_home,
            delete_root=self.root_id,
            protected_roots=[self.protected_root_id],
            executor=self._executor(),
        )
        self.assertEqual(document["deletionOrder"], [self.child_id, self.root_id])
        self.assertNotIn("SECRET_TRANSCRIPT_BODY", json.dumps(document))
        path, digest = WORKFLOW.write_plan(
            document,
            output_dir=self.temporary_root / "compressed-plan",
            repo_root=REPO_ROOT,
            codex_home=self.codex_home,
        )
        self.fake_map.write_text(
            json.dumps({key: str(value) for key, value in self.paths.items()}),
            encoding="utf-8",
        )
        with self._fake_environment():
            journal = WORKFLOW.execute_plan(
                self.policy,
                codex_home=self.codex_home,
                manifest_path=path,
                approved_sha256=digest,
                approved_root=self.root_id,
                codex_bin=str(self.fake_codex),
            )
        self.assertEqual(journal["status"], "passed")

    def test_compressed_rollout_without_reader_fails_closed(self) -> None:
        self._write_standard_tree()
        plain_path = self.paths[self.child_id]
        compressed_path = plain_path.with_name(plain_path.name + ".zst")
        plain_path.rename(compressed_path)
        self.paths[self.child_id] = compressed_path
        original_import = __import__

        def guarded_import(name, *arguments, **keywords):
            if name == "compression":
                raise ImportError("fixture blocks the zstd reader")
            return original_import(name, *arguments, **keywords)

        with mock.patch("builtins.__import__", side_effect=guarded_import):
            payload = WORKFLOW.status_payload(self.policy, self.codex_home)
            self.assertEqual(payload["inventory"]["metadataErrors"], 1)
            with self.assertRaisesRegex(WORKFLOW.WorkflowError, "prove completeness"):
                WORKFLOW.build_plan_document(
                    self.policy,
                    codex_home=self.codex_home,
                    delete_root=self.root_id,
                    protected_roots=[self.protected_root_id],
                    executor=self._executor(),
                )

    def test_inventory_rejects_symlinked_store_subdirectory(self) -> None:
        linked = self.sessions / "linked"
        linked.symlink_to(self.archived, target_is_directory=True)
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "symlinked directory"):
            WORKFLOW.status_payload(self.policy, self.codex_home)

    def test_inventory_rejects_unexpected_jsonl_filename(self) -> None:
        (self.sessions / "unexpected.jsonl").write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "unexpected JSONL"):
            WORKFLOW.status_payload(self.policy, self.codex_home)

    def test_reader_uses_one_bounded_readline(self) -> None:
        path = self._write_session(self.root_id, self.root_id)
        original_fdopen = WORKFLOW.os.fdopen
        calls: list[int] = []

        class GuardedFile:
            def __init__(self, wrapped):
                self.wrapped = wrapped

            def __enter__(self):
                return self

            def __exit__(self, exception_type, exception, traceback):
                self.wrapped.close()

            def readline(self, limit: int):
                calls.append(limit)
                return self.wrapped.readline(limit)

            def fileno(self):
                return self.wrapped.fileno()

            def read(self, *arguments, **keywords):
                raise AssertionError("session reader crossed the first-line boundary")

        def guarded_fdopen(*arguments, **keywords):
            return GuardedFile(original_fdopen(*arguments, **keywords))

        with mock.patch.object(WORKFLOW.os, "fdopen", side_effect=guarded_fdopen):
            record = WORKFLOW.read_session_record(
                path,
                codex_home=self.codex_home,
                store="active",
                repo_root=REPO_ROOT,
                maximum_first_line_bytes=self.policy.maximum_first_line_bytes,
            )
        self.assertEqual(record.session_id, self.root_id)
        self.assertEqual(calls, [self.policy.maximum_first_line_bytes + 1])

    def test_plan_output_cannot_enter_repository_or_codex_state(self) -> None:
        self._write_standard_tree()
        document = WORKFLOW.build_plan_document(
            self.policy,
            codex_home=self.codex_home,
            delete_root=self.root_id,
            protected_roots=[self.protected_root_id],
            executor=self._executor(),
        )
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "outside the repository"):
            WORKFLOW.write_plan(
                document,
                output_dir=self.codex_home / "unsafe-plan",
                repo_root=REPO_ROOT,
                codex_home=self.codex_home,
            )
        synthetic_repo = self.temporary_root / "synthetic-repo"
        synthetic_repo.mkdir()
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "outside the repository"):
            WORKFLOW.write_plan(
                document,
                output_dir=synthetic_repo / "unsafe-plan",
                repo_root=synthetic_repo,
                codex_home=self.codex_home,
            )

    def test_live_validation_rejects_same_path_protected_identity_replacement(self) -> None:
        path, _, document = self._plan()
        protected_path = self.paths[self.protected_root_id]
        first, second = protected_path.read_text(encoding="utf-8").splitlines()[:2]
        metadata = json.loads(first)
        replacement_id = str(uuid.uuid4())
        metadata["payload"]["id"] = replacement_id
        metadata["payload"]["session_id"] = replacement_id
        protected_path.write_text(
            json.dumps(metadata, sort_keys=True) + "\n" + second + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "metadata changed"):
            WORKFLOW.validate_live_state(
                self.policy,
                codex_home=self.codex_home,
                document=document,
                pending_target_ids=set(document["deletionOrder"]),
            )
        self.assertTrue(path.exists())

    def test_live_validation_rejects_same_id_protected_reparenting(self) -> None:
        _, _, document = self._plan()
        protected_path = self.paths[self.protected_root_id]
        lines = protected_path.read_text(encoding="utf-8").splitlines()
        metadata = json.loads(lines[0])
        metadata["payload"]["session_id"] = self.unrelated_root_id
        metadata["payload"]["parent_thread_id"] = self.unrelated_root_id
        protected_path.write_text(
            json.dumps(metadata, sort_keys=True) + "\n" + "\n".join(lines[1:]) + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "metadata changed"):
            WORKFLOW.validate_live_state(
                self.policy,
                codex_home=self.codex_home,
                document=document,
                pending_target_ids=set(document["deletionOrder"]),
            )

    def test_live_validation_allows_unrelated_growth_but_rejects_target_drift(self) -> None:
        _, _, document = self._plan()
        with self.paths[self.protected_root_id].open("a", encoding="utf-8") as handle:
            handle.write("ACTIVE_TASK_APPEND\n")
        new_root_id = str(uuid.uuid4())
        self._write_session(new_root_id, new_root_id)
        _, analysis = WORKFLOW.validate_live_state(
            self.policy,
            codex_home=self.codex_home,
            document=document,
            pending_target_ids=set(document["deletionOrder"]),
        )
        self.assertIsNotNone(analysis)

        with self.paths[self.child_id].open("a", encoding="utf-8") as handle:
            handle.write("TARGET_APPEND\n")
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "target changed"):
            WORKFLOW.validate_live_state(
                self.policy,
                codex_home=self.codex_home,
                document=document,
                pending_target_ids=set(document["deletionOrder"]),
            )

    def test_execute_rejects_symlinked_or_relocated_manifest(self) -> None:
        path, digest, _ = self._plan()
        link_directory = self.temporary_root / "linked-plan"
        link_directory.mkdir(mode=0o700)
        linked_manifest = link_directory / WORKFLOW.PLAN_FILENAME
        linked_manifest.symlink_to(path)
        with self._fake_environment():
            with self.assertRaisesRegex(WORKFLOW.WorkflowError, "cannot be a symlink"):
                WORKFLOW.execute_plan(
                    self.policy,
                    codex_home=self.codex_home,
                    manifest_path=linked_manifest,
                    approved_sha256=digest,
                    approved_root=self.root_id,
                    codex_bin=str(self.fake_codex),
                )

        relocated = self.codex_home / WORKFLOW.PLAN_FILENAME
        relocated.write_bytes(path.read_bytes())
        relocated.chmod(0o600)
        with self._fake_environment():
            with self.assertRaisesRegex(WORKFLOW.WorkflowError, "system-temporary"):
                WORKFLOW.execute_plan(
                    self.policy,
                    codex_home=self.codex_home,
                    manifest_path=relocated,
                    approved_sha256=digest,
                    approved_root=self.root_id,
                    codex_bin=str(self.fake_codex),
                )

    def test_execute_rejects_manifest_mutation_before_subprocess(self) -> None:
        path, digest, _ = self._plan()
        path.write_bytes(path.read_bytes() + b" ")
        with self._fake_environment():
            with self.assertRaisesRegex(WORKFLOW.WorkflowError, "approved SHA-256"):
                WORKFLOW.execute_plan(
                    self.policy,
                    codex_home=self.codex_home,
                    manifest_path=path,
                    approved_sha256=digest,
                    approved_root=self.root_id,
                    codex_bin=str(self.fake_codex),
                )
        self.assertFalse(self.fake_log.exists())

    def test_execute_rejects_new_descendant_before_subprocess(self) -> None:
        new_id = str(uuid.uuid4())
        path, digest, _ = self._plan()
        self._write_session(
            new_id,
            self.root_id,
            parent_id=self.child_id,
            spawn_parent_id=self.child_id,
        )
        self.fake_map.write_text(
            json.dumps({key: str(value) for key, value in self.paths.items()}),
            encoding="utf-8",
        )
        with self._fake_environment():
            with self.assertRaisesRegex(
                WORKFLOW.WorkflowError, "references the approved deletion tree"
            ):
                WORKFLOW.execute_plan(
                    self.policy,
                    codex_home=self.codex_home,
                    manifest_path=path,
                    approved_sha256=digest,
                    approved_root=self.root_id,
                    codex_bin=str(self.fake_codex),
                )
        self.assertFalse(self.fake_log.exists())

    def test_execute_rejects_future_dated_plan_before_subprocess(self) -> None:
        self._write_standard_tree()
        document = WORKFLOW.build_plan_document(
            self.policy,
            codex_home=self.codex_home,
            delete_root=self.root_id,
            protected_roots=[self.protected_root_id],
            executor=self._executor(),
            now=WORKFLOW._utc_now() + dt.timedelta(days=2),
        )
        path, digest = WORKFLOW.write_plan(
            document,
            output_dir=self.temporary_root / "future-plan",
            repo_root=REPO_ROOT,
            codex_home=self.codex_home,
        )
        with self._fake_environment():
            with self.assertRaisesRegex(WORKFLOW.WorkflowError, "not active yet"):
                WORKFLOW.execute_plan(
                    self.policy,
                    codex_home=self.codex_home,
                    manifest_path=path,
                    approved_sha256=digest,
                    approved_root=self.root_id,
                    codex_bin=str(self.fake_codex),
                )
        self.assertFalse(self.fake_log.exists())

    def test_execute_deletes_only_approved_tree_and_verify_passes(self) -> None:
        path, digest, document = self._plan(include_grandchild=True)
        with self._fake_environment():
            journal = WORKFLOW.execute_plan(
                self.policy,
                codex_home=self.codex_home,
                manifest_path=path,
                approved_sha256=digest,
                approved_root=self.root_id,
                codex_bin=str(self.fake_codex),
            )
        deleted = [
            json.loads(line)["sessionId"]
            for line in self.fake_log.read_text(encoding="utf-8").splitlines()
        ]
        logged = [
            json.loads(line)
            for line in self.fake_log.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(deleted, document["deletionOrder"])
        self.assertTrue(
            all(item["codexHome"] == str(self.codex_home.resolve()) for item in logged)
        )
        self.assertEqual(journal["status"], "passed")
        self.assertTrue(self.paths[self.protected_root_id].exists())
        self.assertTrue(self.paths[self.unrelated_root_id].exists())
        verification = WORKFLOW.verify_plan(
            self.policy,
            codex_home=self.codex_home,
            manifest_path=path,
            approved_sha256=digest,
        )
        self.assertEqual(verification["status"], "passed")
        self.assertEqual(verification["deletedRecords"], 3)

    def test_extra_deletion_stops_and_never_reaches_root_command(self) -> None:
        path, digest, document = self._plan(include_grandchild=True)
        with self._fake_environment(
            FAKE_CODEX_DELETE_EXTRA="1",
            FAKE_CODEX_EXTRA_ID=self.child_id,
        ):
            with self.assertRaisesRegex(WORKFLOW.WorkflowError, "deletion set changed"):
                WORKFLOW.execute_plan(
                    self.policy,
                    codex_home=self.codex_home,
                    manifest_path=path,
                    approved_sha256=digest,
                    approved_root=self.root_id,
                    codex_bin=str(self.fake_codex),
                )
        invoked = [
            json.loads(line)["sessionId"]
            for line in self.fake_log.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(invoked, [document["deletionOrder"][0]])
        journal = json.loads(
            (path.parent / WORKFLOW.JOURNAL_FILENAME).read_text(encoding="utf-8")
        )
        self.assertEqual(journal["status"], "stopped")
        self.assertTrue(self.paths[self.root_id].exists())
        with self.assertRaisesRegex(WORKFLOW.WorkflowError, "journal did not finish"):
            WORKFLOW.verify_plan(
                self.policy,
                codex_home=self.codex_home,
                manifest_path=path,
                approved_sha256=digest,
            )

    def test_protected_extra_deletion_stops_after_first_command(self) -> None:
        path, digest, document = self._plan(include_grandchild=True)
        with self._fake_environment(
            FAKE_CODEX_DELETE_EXTRA="1",
            FAKE_CODEX_EXTRA_ID=self.protected_root_id,
        ):
            with self.assertRaisesRegex(WORKFLOW.WorkflowError, "baseline task disappeared"):
                WORKFLOW.execute_plan(
                    self.policy,
                    codex_home=self.codex_home,
                    manifest_path=path,
                    approved_sha256=digest,
                    approved_root=self.root_id,
                    codex_bin=str(self.fake_codex),
                )
        invoked = [
            json.loads(line)["sessionId"]
            for line in self.fake_log.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(invoked, [document["deletionOrder"][0]])
        self.assertTrue(self.paths[self.root_id].exists())
        self.assertTrue(self.paths[self.child_id].exists())

    def test_new_unrelated_collateral_deletion_stops_after_first_command(self) -> None:
        path, digest, document = self._plan(include_grandchild=True)
        new_root_id = str(uuid.uuid4())
        self._write_session(new_root_id, new_root_id)
        self.fake_map.write_text(
            json.dumps({key: str(value) for key, value in self.paths.items()}),
            encoding="utf-8",
        )
        with self._fake_environment(
            FAKE_CODEX_DELETE_EXTRA="1",
            FAKE_CODEX_EXTRA_ID=new_root_id,
        ):
            with self.assertRaisesRegex(WORKFLOW.WorkflowError, "baseline task disappeared"):
                WORKFLOW.execute_plan(
                    self.policy,
                    codex_home=self.codex_home,
                    manifest_path=path,
                    approved_sha256=digest,
                    approved_root=self.root_id,
                    codex_bin=str(self.fake_codex),
                )
        invoked = [
            json.loads(line)["sessionId"]
            for line in self.fake_log.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(invoked, [document["deletionOrder"][0]])
        self.assertTrue(self.paths[self.root_id].exists())
        self.assertTrue(self.paths[self.child_id].exists())

    def test_new_reference_to_deleted_leaf_stops_before_second_command(self) -> None:
        path, digest, document = self._plan(include_grandchild=True)
        new_id = str(uuid.uuid4())
        insert_path = self.sessions / (
            f"rollout-2026-07-19T00-00-01-{new_id}.jsonl"
        )
        insert_payload = {
            "timestamp": "2026-07-19T00:00:01Z",
            "type": "session_meta",
            "payload": {
                "id": new_id,
                "session_id": new_id,
                "parent_thread_id": self.grandchild_id,
                "timestamp": "2026-07-19T00:00:01Z",
                "cwd": str(REPO_ROOT),
                "source": {
                    "subagent": {
                        "thread_spawn": {"parent_thread_id": self.grandchild_id}
                    }
                },
            },
        }
        insert_content = json.dumps(insert_payload, sort_keys=True) + "\nSECRET\n"
        with self._fake_environment(
            FAKE_CODEX_INSERT_PATH=str(insert_path),
            FAKE_CODEX_INSERT_CONTENT=insert_content,
        ):
            with self.assertRaisesRegex(
                WORKFLOW.WorkflowError, "references the approved deletion tree"
            ):
                WORKFLOW.execute_plan(
                    self.policy,
                    codex_home=self.codex_home,
                    manifest_path=path,
                    approved_sha256=digest,
                    approved_root=self.root_id,
                    codex_bin=str(self.fake_codex),
                )
        invoked = [
            json.loads(line)["sessionId"]
            for line in self.fake_log.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(invoked, [document["deletionOrder"][0]])


if __name__ == "__main__":
    unittest.main()
