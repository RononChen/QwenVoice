import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).parent / "lib" / "macos_agent_ui.py"
SPEC = importlib.util.spec_from_file_location("macos_agent_ui", MODULE_PATH)
assert SPEC and SPEC.loader
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)

OVERHEAD_PATH = Path(__file__).parent / "telemetry_overhead.py"
OVERHEAD_SPEC = importlib.util.spec_from_file_location("telemetry_overhead", OVERHEAD_PATH)
assert OVERHEAD_SPEC and OVERHEAD_SPEC.loader
OVERHEAD = importlib.util.module_from_spec(OVERHEAD_SPEC)
OVERHEAD_SPEC.loader.exec_module(OVERHEAD)


def engine_row(generation_id="generation-1", finish="eos"):
    return {
        "schemaVersion": 6,
        "generationID": generation_id,
        "recordedAt": "2026-07-10T00:00:00Z",
        "finishReason": finish,
        "usedStreaming": True,
        "stageMarks": [{"tNS": 1}, {"tNS": 2}],
        "backendMetrics": {
            "finishReason": finish,
            "finalChunkBarrierObserved": True,
        },
    }


def transport_row(generation_id="generation-1", finish="eos", **counters):
    values = {
        "chunksForwarded": 2,
        "chunkGaps": 0,
        "duplicateChunks": 0,
        "outOfOrderChunks": 0,
    }
    values.update(counters)
    return {
        "schemaVersion": 6,
        "generationID": generation_id,
        "recordedAt": "2026-07-10T00:00:01Z",
        "finishReason": finish,
        "transportMetrics": {"finishReason": finish, "counters": values},
    }


class ProbeValidationTests(unittest.TestCase):
    def test_accepts_correlated_monotonic_terminal_rows(self):
        checked, errors = HARNESS.validate_probe_rows([engine_row()], [transport_row()])
        self.assertEqual(len(checked), 1)
        self.assertEqual(errors, [])

    def test_rejects_missing_duplicate_reordered_and_mismatched_rows(self):
        _, missing = HARNESS.validate_probe_rows([engine_row()], [])
        self.assertTrue(any("missing middle-layer" in error for error in missing))
        _, duplicate = HARNESS.validate_probe_rows(
            [engine_row(), engine_row()],
            [transport_row(), transport_row()],
        )
        self.assertTrue(any("duplicate terminal rows" in error for error in duplicate))
        _, reordered = HARNESS.validate_probe_rows(
            [engine_row()],
            [transport_row(outOfOrderChunks=1)],
        )
        self.assertTrue(any("out-of-order" in error for error in reordered))
        _, mismatch = HARNESS.validate_probe_rows(
            [engine_row(finish="cancelled")],
            [transport_row(finish="failed")],
        )
        self.assertTrue(any("terminal mismatch" in error for error in mismatch))

    def test_rejects_corrupted_jsonl(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rows.jsonl"
            path.write_text("{not-json}\n")
            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.read_jsonl(path)

    def test_rejects_cross_layer_privacy_leaks(self):
        engine = engine_row()
        engine["notes"] = {"audioPath": "/Users/example/private.wav"}
        _, errors = HARNESS.validate_probe_rows([engine], [transport_row()])
        self.assertTrue(any("forbidden raw field" in error for error in errors))
        self.assertTrue(any("raw local path" in error for error in errors))


class ContractTests(unittest.TestCase):
    def test_launch_services_records_identify_duplicate_wrong_path_bundles(self):
        output = f"""
--------------------------------------------------------------------------------
bundle id:                  Vocello
path:                       /Applications/Vocello.app (0x123)
identifier:                 com.qwenvoice.app
--------------------------------------------------------------------------------
bundle id:                  Vocello
path:                       {HARNESS.APP} (0x456)
identifier:                 com.qwenvoice.app
--------------------------------------------------------------------------------
bundle id:                  Unrelated
path:                       /Applications/Other.app (0x789)
identifier:                 com.example.other
"""
        records = HARNESS.parse_launch_services_app_records(output)
        self.assertEqual(len(records), 2)
        self.assertEqual(sum(record["exactPath"] for record in records), 1)
        self.assertTrue(any(record["path"] == "/Applications/Vocello.app" for record in records))

    def test_source_fingerprint_excludes_ignored_machine_state(self):
        paths = [path.as_posix() for path in HARNESS.relative_files()]
        self.assertFalse(any("__pycache__" in path for path in paths))
        self.assertFalse(any(path.endswith(".DS_Store") for path in paths))

    def test_benchmark_manifest_matches_the_29_take_contract(self):
        manifest = HARNESS.benchmark_manifest()
        self.assertEqual(len(manifest), 29)
        self.assertEqual(
            [(take["mode"], take["warmState"]) for take in manifest if take["warmState"] == "cold"],
            [("custom", "cold"), ("design", "cold")],
        )
        self.assertEqual([take["index"] for take in manifest], list(range(1, 30)))

    def test_impact_rules_union_independent_requirements(self):
        config = HARNESS.read_json(HARNESS.IMPACT)
        self.assertEqual(HARNESS.classify_paths(["README.md"], config)[:2], ([], []))
        self.assertEqual(HARNESS.classify_paths(["Sources/Views/HistoryView.swift"], config)[0], ["quick"])
        self.assertEqual(HARNESS.classify_paths(["Sources/QwenVoiceNative/XPCNativeEngineClient.swift"], config)[0], ["full"])
        suites, checks, _ = HARNESS.classify_paths(
            ["Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift"], config
        )
        self.assertEqual(suites, ["benchmark", "full"])
        self.assertEqual(checks, ["telemetry-overhead"])

    def test_stale_source_fingerprint_invalidates_report(self):
        report = {
            "schemaVersion": 2,
            "runID": "fixture",
            "suite": "full",
            "status": "pass",
            "sourceFingerprint": "stale",
            "buildInputFingerprint": HARNESS.fingerprint(build_inputs_only=True),
            "appBinarySHA256": HARNESS.sha256(HARNESS.APP_BINARY),
            "executableIdentity": HARNESS.executable_identity(),
            "environment": {"toolchain": HARNESS.toolchain_identity()},
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
        }
        errors = HARNESS.validate_report(report)
        self.assertIn("source fingerprint is stale", errors)

    def test_report_requires_every_suite_scenario_to_pass(self):
        report = {
            "schemaVersion": 2,
            "runID": "fixture",
            "suite": "quick",
            "status": "pass",
            "sourceFingerprint": "fixture",
            "buildInputFingerprint": "fixture",
            "appBinarySHA256": "fixture",
            "executableIdentity": {"sha256": "fixture"},
            "environment": {"toolchain": HARNESS.toolchain_identity()},
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
            "scenarios": {},
        }
        errors = HARNESS.validate_report(report, current_fingerprints=False)
        self.assertTrue(any("required scenarios" in error for error in errors))

    def test_quick_and_full_reports_enforce_declared_time_budgets(self):
        base = {
            "schemaVersion": 2,
            "runID": "fixture",
            "status": "pass",
            "sourceFingerprint": "fixture",
            "buildInputFingerprint": "fixture",
            "appBinarySHA256": "fixture",
            "executableIdentity": {"sha256": "fixture"},
            "environment": {"toolchain": HARNESS.toolchain_identity()},
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
        }
        quick = dict(base, suite="quick", durationSeconds=601, scenarios={})
        full = dict(base, suite="full", durationSeconds=2_401, scenarios={})
        quick_errors = HARNESS.validate_report(quick, current_fingerprints=False)
        full_errors = HARNESS.validate_report(full, current_fingerprints=False)
        self.assertTrue(any("10-minute budget" in error for error in quick_errors))
        self.assertTrue(any("40-minute budget" in error for error in full_errors))

    def test_destructive_start_requires_explicit_authorization(self):
        args = argparse.Namespace(suite="destructive", allow_destructive=False)
        with self.assertRaises(HARNESS.HarnessError):
            HARNESS.cmd_start(args)

    def test_full_can_satisfy_quick_but_benchmark_cannot_satisfy_full(self):
        base = {
            "schemaVersion": 2,
            "runID": "fixture",
            "status": "pass",
            "sourceFingerprint": "fixture",
            "buildInputFingerprint": "fixture",
            "appBinarySHA256": "fixture",
            "executableIdentity": {"sha256": "fixture"},
            "environment": {"toolchain": HARNESS.toolchain_identity()},
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": [],
            "scenarios": {},
        }
        full = dict(base, suite="full")
        benchmark = dict(base, suite="benchmark")
        full_errors = HARNESS.validate_report(full, required_suite="quick", current_fingerprints=False)
        benchmark_errors = HARNESS.validate_report(benchmark, required_suite="full", current_fingerprints=False)
        self.assertFalse(any("insufficient" in error for error in full_errors))
        self.assertTrue(any("actual full" in error for error in benchmark_errors))

    def test_ci_attestation_skips_local_signed_binary_hash_only(self):
        identity = {
            "sourceFingerprint": HARNESS.fingerprint(),
            "buildInputFingerprint": HARNESS.fingerprint(build_inputs_only=True),
            "toolchainIdentity": HARNESS.toolchain_identity(),
        }
        entry = {
            "status": "pass",
            "suite": "full",
            "probeVerdict": "pass",
            "cleanupVerdict": "pass",
            "issues": {"blocker": 0, "major": 0},
            "executableIdentity": {"sha256": "different-signature"},
        }
        attestation = {"schemaVersion": 2, **identity, "entries": {"full": entry}, "runtimeChecks": {}}
        local = HARNESS.validate_attestation(attestation, ["full"], [], ci=False)
        ci = HARNESS.validate_attestation(attestation, ["full"], [], ci=True)
        self.assertTrue(any("full evidence" in error for error in local))
        self.assertFalse(any("full evidence" in error for error in ci))

    def test_schema_v1_attestation_is_diagnostic_only(self):
        errors = HARNESS.validate_attestation({"schemaVersion": 1}, ["quick"], [], ci=True)
        self.assertTrue(any("diagnostic-only" in error for error in errors))

    def test_contracts_are_schema_v2_and_all_risk_references_resolve(self):
        self.assertEqual(HARNESS.validate_config(), [])

    def test_exact_launch_targets_path_and_never_bundle_identifier(self):
        command = HARNESS.exact_launch_command("fixture", Path("/tmp/disposable"))
        self.assertEqual(command[-1], str(HARNESS.APP))
        self.assertNotIn(HARNESS.BUNDLE_ID, command)
        self.assertIn("QWENVOICE_APP_SUPPORT_DIR=/tmp/disposable", command)
        self.assertIn("QWENVOICE_INITIAL_SIDEBAR_ITEM=custom", command)

        diagnostic = HARNESS.exact_launch_command(
            "fixture",
            Path("/tmp/disposable"),
            initial_sidebar_item="history",
        )
        self.assertIn("QWENVOICE_INITIAL_SIDEBAR_ITEM=history", diagnostic)

    def test_exact_launch_rejects_arbitrary_initial_screen(self):
        with self.assertRaises(HARNESS.HarnessError):
            HARNESS.exact_launch_command(
                "fixture",
                Path("/tmp/disposable"),
                initial_sidebar_item="voiceDesign",
            )

    def test_normal_start_rejects_known_bad_helper(self):
        routing = {
            "readyForSuite": False,
            "ready": False,
            "errors": [],
            "suiteBlockers": ["helper fingerprint is blocked for normal UI suites"],
        }
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "Vocello"
            binary.write_bytes(b"fixture")
            args = argparse.Namespace(suite="quick", allow_destructive=False)
            with mock.patch.object(HARNESS, "APP_BINARY", binary), mock.patch.object(
                HARNESS, "routing_status", return_value=routing
            ):
                with self.assertRaisesRegex(HARNESS.HarnessError, "blocked for normal UI suites"):
                    HARNESS.cmd_start(args)

    def test_known_bad_warm_diagnostic_requires_explicit_acknowledgement(self):
        routing = {
            "readyForDiagnostic": True,
            "ready": False,
            "errors": [],
            "knownBadHelperDetected": True,
        }
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "Vocello"
            binary.write_bytes(b"fixture")
            state = Path(directory) / "warm.json"
            args = argparse.Namespace(
                initial_screen="history",
                acknowledge_known_bad_helper=False,
            )
            with mock.patch.object(HARNESS, "APP_BINARY", binary), mock.patch.object(
                HARNESS, "WARM_DIAGNOSTIC", state
            ), mock.patch.object(HARNESS, "app_process_records", return_value=[]), mock.patch.object(
                HARNESS, "routing_status", return_value=routing
            ):
                with self.assertRaisesRegex(HARNESS.HarnessError, "acknowledge-known-bad-helper"):
                    HARNESS.prepare_warm_diagnostic(args)

    def test_stable_app_poll_requires_one_unchanged_exact_pid(self):
        record = {"pid": 42, "executable": str(HARNESS.APP_BINARY), "exactPath": True}
        with mock.patch.object(HARNESS, "app_process_records", return_value=[record]), mock.patch.object(
            HARNESS, "new_service_crash_reports", return_value=[]
        ), mock.patch.object(HARNESS.time, "sleep"):
            self.assertEqual(
                HARNESS.stable_exact_app_pid(
                    timeout_seconds=1,
                    stable_seconds=0,
                    crash_baseline=[],
                ),
                42,
            )

    def test_stable_app_poll_fails_immediately_for_duplicate_or_crash(self):
        exact = {"pid": 42, "executable": str(HARNESS.APP_BINARY), "exactPath": True}
        duplicate = {"pid": 43, "executable": "/Applications/Vocello.app", "exactPath": False}
        with mock.patch.object(HARNESS, "app_process_records", return_value=[exact, duplicate]):
            with self.assertRaisesRegex(HARNESS.HarnessError, "unexpected Vocello process ownership"):
                HARNESS.stable_exact_app_pid(timeout_seconds=1, stable_seconds=0)
        with mock.patch.object(HARNESS, "new_service_crash_reports", return_value=[{"path": "new.ips"}]):
            with self.assertRaisesRegex(HARNESS.HarnessError, "crashed while Vocello was stabilizing"):
                HARNESS.stable_exact_app_pid(
                    timeout_seconds=1,
                    stable_seconds=0,
                    crash_baseline=[],
                )

    def test_warm_diagnostic_verify_never_relaunches_and_is_not_attestable(self):
        helper = {
            "pid": 7,
            "executable": "/managed/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService",
            "version": "26.708.1000366",
            "build": "1000366",
            "uuid": "61C0",
            "sha256": "helper-hash",
        }
        routing = {
            "readyForDiagnostic": True,
            "errors": [],
            "computerUseServiceProcesses": [{
                "pid": 7,
                "executable": helper["executable"],
                "version": helper["version"],
                "build": helper["build"],
                "uuid": helper["uuid"],
                "sha256": helper["sha256"],
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "warm.json"
            binary = Path(directory) / "Vocello"
            binary.write_bytes(b"fixture")
            HARNESS.write_json(state, {
                "schemaVersion": 1,
                "diagnosticOnly": True,
                "attestable": False,
                "diagnosticID": "fixture",
                "status": "prepared",
                "observationsConsumed": 0,
                "observationEvidence": {
                    "accessibilityTextLength": 100,
                    "visibleWindowCount": 1,
                    "screenshotAvailable": True,
                },
                "appPID": 42,
                "computerUseService": helper,
                "computerUseCrashReportsAtStart": [],
            })
            app_record = {"pid": 42, "executable": str(binary.resolve()), "exactPath": True}
            with mock.patch.object(HARNESS, "WARM_DIAGNOSTIC", state), mock.patch.object(
                HARNESS, "APP_BINARY", binary
            ), mock.patch.object(HARNESS, "routing_status", return_value=routing), mock.patch.object(
                HARNESS, "app_process_records", return_value=[app_record]
            ), mock.patch.object(HARNESS, "new_service_crash_reports", return_value=[]), mock.patch.object(
                HARNESS, "run"
            ) as run_mock:
                HARNESS.verify_warm_diagnostic()
                run_mock.assert_not_called()
            verified = HARNESS.read_json(state)
            self.assertEqual(verified["status"], "verified")
            self.assertTrue(verified["diagnosticOnly"])
            self.assertFalse(verified["attestable"])
            self.assertEqual(verified["observationsConsumed"], 1)

    def test_warm_diagnostic_records_non_sensitive_observation_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "warm.json"
            screenshot = Path(directory) / "capture.jpeg"
            screenshot.write_bytes(b"diagnostic-image")
            HARNESS.write_json(state, {
                "diagnosticID": "fixture",
                "diagnosticOnly": True,
                "attestable": False,
                "status": "prepared",
                "observationsConsumed": 0,
            })
            args = argparse.Namespace(
                app_path=str(HARNESS.APP),
                accessibility_length=1815,
                window_count=1,
                screenshot_url=screenshot.as_uri(),
            )
            with mock.patch.object(HARNESS, "WARM_DIAGNOSTIC", state):
                HARNESS.record_warm_diagnostic_observation(args)
            evidence = HARNESS.read_json(state)["observationEvidence"]
            self.assertEqual(evidence["accessibilityTextLength"], 1815)
            self.assertEqual(evidence["visibleWindowCount"], 1)
            self.assertEqual(evidence["screenshotByteCount"], len(b"diagnostic-image"))
            self.assertEqual(evidence["screenshotSHA256"], hashlib.sha256(b"diagnostic-image").hexdigest())
            self.assertNotIn(str(screenshot), json.dumps(evidence))

    def test_warm_diagnostic_cleanup_preserves_verification_and_debug_preference(self):
        helper = {
            "pid": 7,
            "executable": "/managed/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService",
            "version": "26.708.1000366",
            "build": "1000366",
            "uuid": "61C0",
            "sha256": "helper-hash",
        }
        routing = {"computerUseServiceProcesses": [helper]}
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "warm.json"
            HARNESS.write_json(state, {
                "diagnosticID": "fixture",
                "diagnosticOnly": True,
                "attestable": False,
                "status": "verified",
                "verificationVerdict": "pass",
                "observationsConsumed": 1,
                "appPID": 42,
                "computerUseService": helper,
                "computerUseCrashReportsAtStart": [],
            })
            with mock.patch.object(HARNESS, "WARM_DIAGNOSTIC", state), mock.patch.object(
                HARNESS, "app_process_records", return_value=[]
            ), mock.patch.object(HARNESS, "terminate_process"), mock.patch.object(
                HARNESS, "clear_debug_flag"
            ) as clear_debug, mock.patch.object(
                HARNESS, "require_computer_use_session", return_value=routing
            ), mock.patch.object(HARNESS, "new_service_crash_reports", return_value=[]):
                HARNESS.abort_warm_diagnostic()
                clear_debug.assert_not_called()
            cleaned = HARNESS.read_json(state)
            self.assertEqual(cleaned["status"], "cleaned")
            self.assertEqual(cleaned["verificationVerdict"], "pass")
            self.assertEqual(cleaned["cleanupVerdict"], "pass")

    def test_warm_diagnostic_cleanup_records_late_helper_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "warm.json"
            HARNESS.write_json(state, {
                "diagnosticID": "fixture",
                "diagnosticOnly": True,
                "attestable": False,
                "status": "verified",
                "verificationVerdict": "pass",
                "observationsConsumed": 1,
                "appPID": 42,
                "computerUseService": {"pid": 7},
                "computerUseCrashReportsAtStart": [],
            })
            crash = {"path": "/tmp/SkyComputerUseService-new.ips"}
            with mock.patch.object(HARNESS, "WARM_DIAGNOSTIC", state), mock.patch.object(
                HARNESS, "app_process_records", return_value=[]
            ), mock.patch.object(HARNESS, "terminate_process"), mock.patch.object(
                HARNESS, "new_service_crash_reports", return_value=[crash]
            ), mock.patch.object(
                HARNESS,
                "require_computer_use_session",
                side_effect=HARNESS.HarnessError("new helper crash"),
            ):
                with self.assertRaisesRegex(HARNESS.HarnessError, "cleanup found blocking problems"):
                    HARNESS.abort_warm_diagnostic()
            failed = HARNESS.read_json(state)
            self.assertEqual(failed["status"], "failed")
            self.assertEqual(failed["verificationVerdict"], "pass")
            self.assertEqual(failed["cleanupVerdict"], "fail")
            self.assertEqual(failed["computerUseCrashDelta"], [crash])

    def test_computer_use_skill_prohibits_ambiguous_vocello_selectors(self):
        skill = (HARNESS.ROOT / ".agents" / "skills" / "vocello-macos-ui-qa" / "SKILL.md").read_text()
        self.assertIn("Do not retry by display name or bundle identifier", skill)
        self.assertNotIn("use the display name `Vocello` as the selector", skill)

    def test_diagnostic_evidence_distinguishes_node_repl_from_manifest_mirror(self):
        evidence = HARNESS.diagnostic_plugin_evidence({
            "computerUsePluginInstalled": True,
            "computerUsePluginEnabled": True,
            "computerUsePluginVersion": "1.0.1000366",
            "computerUseBundledContentVariant": "node-repl",
            "computerUseUsesNodeRepl": True,
            "nodeReplServerDeclared": True,
            "nodeReplServerEnabled": True,
            "nodeReplServerCommand": "/Applications/ChatGPT.app/node_repl",
            "nodeReplServerArgs": [],
            "computerUseManifestServerDeclared": True,
            "computerUseManifestMirrorEntryPresent": True,
            "computerUseManifestMirrorEnabled": False,
            "computerUseManifestMirrorConflicting": False,
            "computerUseServerAvailable": True,
        })
        self.assertEqual(evidence["bundledContentVariant"], "node-repl")
        self.assertTrue(evidence["usesNodeRepl"])
        self.assertTrue(evidence["nodeReplServerEnabled"])
        self.assertFalse(evidence["manifestMirrorEnabled"])
        self.assertFalse(evidence["manifestMirrorConflicting"])
        self.assertTrue(evidence["serverAvailable"])

    def test_model_readiness_check_requires_current_full_ui_evidence(self):
        args = argparse.Namespace(ci=False)
        with mock.patch.object(HARNESS, "read_json", return_value={}), mock.patch.object(
            HARNESS,
            "validate_attestation",
            return_value=["missing valid full Computer Use evidence"],
        ) as validate:
            with self.assertRaisesRegex(HARNESS.HarnessError, "visible model readiness"):
                HARNESS.cmd_model_readiness_check(args)
        validate.assert_called_once_with({}, ["full"], [], ci=False)

    def test_model_readiness_check_accepts_valid_full_ui_evidence(self):
        args = argparse.Namespace(ci=False)
        attestation = {"schemaVersion": 2, "entries": {"full": {"status": "pass"}}}
        with mock.patch.object(HARNESS, "read_json", return_value=attestation), mock.patch.object(
            HARNESS, "validate_attestation", return_value=[]
        ) as validate:
            HARNESS.cmd_model_readiness_check(args)
        validate.assert_called_once_with(attestation, ["full"], [], ci=False)

    def test_destructive_root_is_disposable_and_not_shared(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            run.mkdir()
            root = HARNESS.destructive_root(run)
            self.assertTrue(root.is_relative_to(run.resolve()))
            self.assertNotEqual(root, HARNESS.DEBUG_ROOT.resolve())
            self.assertNotEqual(root, HARNESS.PRODUCTION_ROOT.resolve())
            self.assertFalse((root / "models").is_symlink())
            self.assertFalse((root / "voices").is_symlink())

    def test_state_snapshot_restores_production_and_debug_preferences(self):
        commands = []

        def fake_run(command, **_kwargs):
            commands.append(command)
            if len(command) >= 4 and command[1] == "export":
                Path(command[3]).write_bytes(b"plist")
            return argparse.Namespace(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as directory:
            run_directory = Path(directory) / "run"
            support_root = Path(directory) / "support"
            run_directory.mkdir()
            support_root.mkdir()
            with mock.patch.object(HARNESS, "run", side_effect=fake_run):
                snapshot = HARNESS.snapshot_state(run_directory, support_root)
                self.assertTrue(snapshot["preferencesExisted"])
                self.assertTrue(snapshot["debugPreferencesExisted"])
                report = {
                    "environment": {"appSupportRoot": str(support_root)},
                    "stateSnapshot": snapshot,
                }
                HARNESS.restore_state(report)

        self.assertIn(
            ["/usr/bin/defaults", "import", HARNESS.BUNDLE_ID, snapshot["preferencesPath"]],
            commands,
        )
        self.assertIn(
            [
                "/usr/bin/defaults",
                "import",
                HARNESS.DEBUG_BUNDLE_ID,
                snapshot["debugPreferencesPath"],
            ],
            commands,
        )

    def test_stale_toolchain_identity_invalidates_attestation(self):
        attestation = {
            "schemaVersion": 2,
            "sourceFingerprint": HARNESS.fingerprint(),
            "buildInputFingerprint": HARNESS.fingerprint(build_inputs_only=True),
            "toolchainIdentity": {"digest": "stale"},
            "entries": {},
            "runtimeChecks": {},
        }
        errors = HARNESS.validate_attestation(attestation, [], [], ci=True)
        self.assertIn("attestation toolchain identity is stale", errors)

    def test_ci_accepts_compatible_toolchain_point_release(self):
        current = HARNESS.toolchain_identity()
        recorded = {
            "xcode": re.sub(
                r"(Xcode\s+\d+)(?:\.\d+)*", r"\1.999", current["xcode"], count=1
            ),
            "swift": current["swift"],
        }
        recorded["digest"] = hashlib.sha256(
            json.dumps(recorded, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        self.assertTrue(HARNESS.toolchain_identity_matches(recorded, current, ci=True))
        self.assertFalse(HARNESS.toolchain_identity_matches(recorded, current, ci=False))


class TelemetryOverheadMathTests(unittest.TestCase):
    def test_rtf_is_audio_per_wall_second_and_lower_throughput_is_regression(self):
        self.assertAlmostEqual(OVERHEAD.throughput_regression(0.9, 1.0), 10.0)
        self.assertAlmostEqual(OVERHEAD.throughput_regression(1.1, 1.0), -10.0)

    def test_higher_ttfc_is_regression(self):
        self.assertAlmostEqual(OVERHEAD.latency_regression(110.0, 100.0), 10.0)
        self.assertAlmostEqual(OVERHEAD.latency_regression(90.0, 100.0), -10.0)


if __name__ == "__main__":
    unittest.main()
