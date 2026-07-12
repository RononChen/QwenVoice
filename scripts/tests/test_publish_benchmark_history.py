#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest import mock
import wave


SCRIPT = Path(__file__).resolve().parents[1] / "publish_benchmark_history.py"
SPEC = importlib.util.spec_from_file_location("publish_benchmark_history", SCRIPT)
assert SPEC and SPEC.loader
publisher = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = publisher
SPEC.loader.exec_module(publisher)


def source_fixture() -> dict:
    return {
        "commit": "a" * 40,
        "dirty": False,
        "changedPaths": [],
        "workspaceFingerprint": "b" * 64,
        "preFingerprint": "b" * 64,
        "postFingerprint": "b" * 64,
        "fingerprintsMatch": True,
    }


def engine_row(generation_id: str, *, run_id: str = "run-one", cell: str = "custom/speed/medium/warm#0", qc: str = "pass") -> dict:
    return {
        "schemaVersion": 7,
        "generationID": generation_id,
        "layer": "engine",
        "mode": "custom",
        "modelID": "pro_custom_speed",
        "modelRuntimeIdentity": {
            "resolvedModelID": "pro_custom_speed",
            "modelRepository": "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            "huggingFaceRevision": "f35faf19b0cc2160865af64ecf0f22f83d335135",
            "artifactVersion": "2026.04.05.2",
            "quantization": "4-bit",
            "integrityManifestDigest": "f" * 64,
            "runtimeProfileSignature": "pro_custom_speed:fixture-v1",
        },
        "warmState": "warm",
        "finishReason": "eos",
        "notes": {
            "benchRunID": run_id,
            "benchTakeIndex": "1",
            "benchCell": cell,
            "promptDigest": "1" * 64,
        },
        "derivedMetrics": {
            "audioSeconds": 2.0,
            "audioSecondsPerWallSecond": 1.5,
            "tokensPerSecond": 20.0,
            "generatedTokenCount": 42,
        },
        "backendMetrics": {
            "finishReason": "eos",
            "warmState": "warm",
            "usedStreaming": True,
            "stages": [],
            "timings": [{"key": "modelLoad", "milliseconds": 4.0}],
            "counters": [],
            "finalChunkBarrierObserved": True,
        },
        "summary": {"physFootprintPeakMB": 100.0},
        "timingsMS": {"native_model_load_ms": 4.0},
        "thermalState": {"worst": "nominal"},
        "outputMetrics": {
            "readableWAV": True,
            "atomicallyPublished": True,
            "durationSeconds": 2.0,
        },
        "audioQC": {
            "algorithmVersion": 2,
            "verdict": qc,
            "instabilityVerdict": "pass",
            "writtenOutputVerdict": qc,
            "flags": ["long-silence"] if qc == "warn" else [],
            "clickEvents": 0,
            "clippedSamples": 0,
            "nonFiniteSamples": 0,
            "longestSilenceMS": 10,
        },
    }


class PublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def capture_manifest(self):
        captured: dict = {}

        def fake_write(artifact_dir, manifest, **kwargs):
            captured["manifest"] = manifest
            captured["deferRecord"] = kwargs.get("defer_record", False)
            return artifact_dir / "benchmark-evidence.json"

        return captured, mock.patch.object(publisher, "write_and_record", side_effect=fake_write)

    def hardware_patch(self):
        return mock.patch.object(
            publisher,
            "verify_canonical_hardware",
            side_effect=lambda platform, **_kwargs: {
                "profileID": "mac-mini-m2-8gb" if platform == "macos" else "iphone-17-pro"
            },
        )

    def make_wave(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(path), "wb") as stream:
            stream.setnchannels(1)
            stream.setsampwidth(2)
            stream.setframerate(24_000)
            stream.writeframes(b"\0\0" * 240)

    def test_engine_uses_only_ordered_manifest_generations(self) -> None:
        diagnostics = self.root / "diagnostics"
        output_dir = self.root / "outputs"
        diagnostics.mkdir()
        self.make_wave(output_dir / "take.wav")
        results = diagnostics / "bench-results.json"
        results.write_text(json.dumps({
            "schemaVersion": 1,
            "runID": "run-one",
            "label": "fixture",
            "startedAt": "2026-07-12T12:00:00Z",
            "finishedAt": "2026-07-12T12:01:00Z",
            "telemetryMode": "lightweight",
            "seed": 42,
            "streaming": True,
            "fixtureDigests": {},
            "takes": [{
                "takeIndex": 1,
                "generationID": "selected",
                "cell": "custom/speed/medium/warm#0",
                "mode": "custom",
                "modelID": "pro_custom_speed",
                "variant": "speed",
                "length": "medium",
                "warmState": "warm",
                "wallSeconds": 1.0,
                "audioSeconds": 2.0,
                "firstChunkMS": 100,
                "outputFileName": "take.wav",
            }],
        }))
        unrelated = [engine_row(f"old-{index}", run_id="old") for index in range(300)]
        selected = engine_row("selected")
        args = SimpleNamespace(
            results=results, run_id="run-one", diagnostics=diagnostics,
            output_dir=output_dir, platform="macos", artifact_dir=diagnostics,
            snapshot=self.root / "snapshot.json", label="fixture",
        )
        captured, write_patch = self.capture_manifest()
        with (
            mock.patch.object(publisher, "load_engine_rows", return_value=unrelated + [selected]),
            mock.patch.object(publisher, "source_from_snapshot", return_value=source_fixture()),
            mock.patch.object(publisher, "crash_delta_from_snapshot", return_value={"passed": True, "count": 0}),
            self.hardware_patch(),
            write_patch,
        ):
            publisher.engine_command(args)
        record = captured["manifest"]["historyRecord"]
        self.assertEqual([take["generationID"] for take in record["takes"]], ["selected"])
        self.assertEqual(record["takes"][0]["metrics"]["ttfcMS"], 100.0)
        self.assertEqual(
            record["takes"][0]["runtimeProfileSignature"],
            "pro_custom_speed:fixture-v1",
        )
        self.assertEqual(record["toolchain"]["optimization"], "-Onone")
        self.assertEqual(record["evidence"]["actualTakeCount"], 1)

    def test_engine_take_requires_exact_run_take_and_cell_provenance(self) -> None:
        take = {
            "generationID": "selected",
            "cell": "custom/speed/medium/warm#0",
            "mode": "custom",
            "modelID": "pro_custom_speed",
            "variant": "speed",
            "warmState": "warm",
            "length": "medium",
            "wallSeconds": 1.0,
            "audioSeconds": 2.0,
        }
        for missing_key in ("benchRunID", "benchTakeIndex", "benchCell"):
            row = engine_row("selected")
            del row["notes"][missing_key]
            with self.subTest(missing_key=missing_key), self.assertRaises(
                publisher.PublicationError
            ):
                publisher.engine_take(1, take, row, None, run_id="run-one")
        wrong = engine_row("selected")
        wrong["notes"]["benchRunID"] = "another-run"
        with self.assertRaisesRegex(publisher.PublicationError, "benchRunID"):
            publisher.engine_take(1, take, wrong, None, run_id="run-one")

    def test_forced_memory_profile_is_exploratory(self) -> None:
        self.assertFalse(publisher.uses_forced_memory_profile([engine_row("native")]))
        forced = engine_row("forced")
        forced["notes"]["deviceClassForced"] = "true"
        self.assertTrue(publisher.uses_forced_memory_profile([forced]))
        simulated = engine_row("simulated")
        simulated["notes"]["memoryProfile"] = "iphone15pro"
        simulated["notes"]["simulatedProcessLimitMB"] = "5000"
        self.assertTrue(publisher.uses_forced_memory_profile([simulated]))

    def test_mac_hardware_profile_requires_exact_model_and_ram(self) -> None:
        values = {
            ("sysctl", "-n", "hw.model"): "Mac14,3\n",
            ("sysctl", "-n", "hw.memsize"): "8589934592\n",
        }

        def run(command, **_kwargs):
            return SimpleNamespace(returncode=0, stdout=values[tuple(command)], stderr="")

        with mock.patch.object(publisher.subprocess, "run", side_effect=run):
            self.assertEqual(
                publisher.verify_canonical_hardware("macos"),
                {"profileID": "mac-mini-m2-8gb"},
            )
        values[("sysctl", "-n", "hw.memsize")] = "17179869184\n"
        with (
            mock.patch.object(publisher.subprocess, "run", side_effect=run),
            self.assertRaisesRegex(publisher.PublicationError, "does not match"),
        ):
            publisher.verify_canonical_hardware("macos")

    def test_ios_hardware_profile_binds_sentinel_to_one_exact_coredevice(self) -> None:
        product_type = "iPhone18,1"

        def run(command, **_kwargs):
            output = Path(command[command.index("--json-output") + 1])
            output.write_text(json.dumps({"result": {"devices": [{
                "hardwareProperties": {"platform": "iOS", "productType": product_type},
                "deviceProperties": {"osVersionNumber": "26.5"},
                "connectionProperties": {"pairingState": "paired"},
            }]}}), encoding="utf-8")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        evidence = [{"deviceModel": "iPhone", "systemName": "iOS", "systemVersion": "26.5"}]
        with mock.patch.object(publisher.subprocess, "run", side_effect=run):
            self.assertEqual(
                publisher.verify_canonical_hardware("ios", ios_evidence=evidence),
                {"profileID": "iphone-17-pro"},
            )
        product_type = "iPhone17,1"
        with (
            mock.patch.object(publisher.subprocess, "run", side_effect=run),
            self.assertRaisesRegex(publisher.PublicationError, "does not match"),
        ):
            publisher.verify_canonical_hardware("ios", ios_evidence=evidence)

    def test_failed_qc_never_reaches_recording(self) -> None:
        row = engine_row("bad", qc="fail")
        with self.assertRaises(publisher.PublicationError):
            publisher.successful_row(row)

    def test_delayed_repair_records_frozen_manifest_directly(self) -> None:
        completed = SimpleNamespace(returncode=1, stderr="registry rejected", stdout="")
        with mock.patch.object(publisher.subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(
                publisher.PublicationError,
                r"scripts/benchmark_history\.py record --artifact-dir",
            ):
                publisher.write_and_record(self.root, {"schemaVersion": 1})
        self.assertEqual(
            json.loads((self.root / "benchmark-evidence.json").read_text()),
            {"schemaVersion": 1},
        )

    def test_deferred_record_writes_evidence_without_touching_registry(self) -> None:
        with mock.patch.object(publisher.subprocess, "run") as run:
            path = publisher.write_and_record(
                self.root, {"schemaVersion": 1}, defer_record=True
            )
        self.assertEqual(path, self.root / "benchmark-evidence.json")
        self.assertEqual(
            json.loads(path.read_text(encoding="utf-8")),
            {"schemaVersion": 1},
        )
        run.assert_not_called()

    def test_v7_sampler_resource_environment_and_dual_qc_are_distilled(self) -> None:
        row = engine_row("v7", qc="pass")
        row["summary"].update({
            "headroomMinMB": 512.0,
            "targetIntervalNS": 500_000_000,
            "effectiveIntervalNS": 510_000_000,
            "maximumLatenessNS": 12_000_000,
            "maximumDriftNS": 9_000_000,
            "boundarySampleCount": 4,
            "captureFailureCount": 1,
            "processResourceUsage": {
                "userCPUTimeMS": 2_500.0,
                "systemCPUTimeMS": 500.0,
                "minorPageFaults": 10,
                "majorPageFaults": 2,
                "voluntaryContextSwitches": 3,
                "involuntaryContextSwitches": 4,
                "blockInputOperations": 5,
                "blockOutputOperations": 6,
            },
            "stageMarks": [
                {"stage": "memory_trim", "metadata": {"level": "softTrim"}},
                {"stage": "memory_trim", "metadata": {"level": "hardTrim"}},
            ],
            "runEnvironment": {
                "loadAverage1Minute": 1.25,
                "freeStorageBytes": 123_456,
                "uptimeSeconds": 99.0,
                "lowPowerModeEnabled": True,
                "thermalState": "fair",
            },
        })
        row["audioQC"].update({
            "instabilityVerdict": "pass",
            "writtenOutputVerdict": "warn",
            "dcOffset": 0.06,
            "flags": ["dc_offset"],
        })
        metrics = publisher.row_metrics(row)
        self.assertEqual(metrics["samplerTargetIntervalMS"], 500.0)
        self.assertEqual(metrics["samplerEffectiveMedianIntervalMS"], 510.0)
        self.assertEqual(metrics["samplerMaximumLatenessMS"], 12.0)
        self.assertEqual(metrics["samplerMaximumDriftMS"], 9.0)
        self.assertEqual(metrics["cpuUserSeconds"], 2.5)
        self.assertEqual(metrics["pageFaults"], 12.0)
        self.assertEqual(metrics["contextSwitches"], 7.0)
        self.assertEqual(metrics["generatedTokens"], 42.0)
        self.assertEqual(metrics["memoryTrimCount"], 2.0)
        self.assertEqual(metrics["maximumTrimLevel"], 2.0)
        self.assertEqual(metrics["blockIOOperations"], 11.0)
        self.assertEqual(publisher.hardware_context([row]), {
            "loadAverage1M": 1.25,
            "freeStorageBytes": 123_456,
            "uptimeSeconds": 99.0,
            "lowPowerMode": True,
            "thermalState": "fair",
        })
        qc = publisher.qc_record(row)
        self.assertEqual(qc["verdict"], "warn")
        self.assertEqual(qc["metrics"]["dcOffset"], 0.06)
        self.assertIn("written-output-warn", qc["warningCodes"])

    def test_v7_runtime_and_fixture_identity_is_typed_and_cross_checked(self) -> None:
        row = engine_row("design-id")
        row["mode"] = "design"
        row["modelID"] = "pro_design_speed"
        row["modelRuntimeIdentity"] = {
            "resolvedModelID": "pro_design_speed",
            "modelRepository": "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit",
            "huggingFaceRevision": "5c390979e4b93af5f2932f90742ca99c7dd04687",
            "artifactVersion": "2026.04.05.2",
            "quantization": "4-bit",
            "integrityManifestDigest": "c" * 64,
            "runtimeProfileSignature": "pro_design_speed:profile-v2",
            "fixtureDigest": "d" * 64,
        }
        identity = publisher.runtime_identity(
            row, mode="design", model_id="pro_design_speed"
        )
        self.assertEqual(identity["runtimeProfileSignature"], "pro_design_speed:profile-v2")
        self.assertEqual(identity["fixtureDigest"], "d" * 64)
        self.assertEqual(identity["modelIntegrityDigest"], "c" * 64)
        takes = [{"mode": "design", "fixtureDigest": identity["fixtureDigest"]}]
        publisher.require_fixture_cross_check(
            takes, {"design": "d" * 64}, source="fixture"
        )
        with self.assertRaises(publisher.PublicationError):
            publisher.require_fixture_cross_check(
                takes, {"design": "e" * 64}, source="fixture"
            )
        row["modelRuntimeIdentity"]["resolvedModelID"] = "wrong-model"
        with self.assertRaises(publisher.PublicationError):
            publisher.runtime_identity(row, mode="design", model_id="pro_design_speed")
        row["modelRuntimeIdentity"]["resolvedModelID"] = "pro_design_speed"
        del row["modelRuntimeIdentity"]["runtimeProfileSignature"]
        with self.assertRaises(publisher.PublicationError):
            publisher.runtime_identity(row, mode="design", model_id="pro_design_speed")

    def test_crash_delta_uses_before_after_content_hashes(self) -> None:
        before = self.root / "before"
        after = self.root / "after"
        (before / "crashes").mkdir(parents=True)
        (after / "crashes").mkdir(parents=True)
        (before / "crashes" / "old.ips").write_bytes(b"old")
        (after / "crashes" / "renamed.ips").write_bytes(b"old")
        snapshot = self.root / "benchmark-source.json"
        publisher.capture_snapshot(snapshot, "ios", before)
        self.assertEqual(
            publisher.crash_delta_from_snapshot(snapshot, expected_scope="ios", diagnostics=after),
            {"passed": True, "count": 0},
        )
        (after / "crashes" / "new.ips").write_bytes(b"new")
        with self.assertRaises(publisher.PublicationError):
            publisher.crash_delta_from_snapshot(snapshot, expected_scope="ios", diagnostics=after)

    def test_language_hint_only_is_partial_and_ordered(self) -> None:
        matrix = self.root / "matrix.json"
        corpus = self.root / "corpus.json"
        matrix.write_text(json.dumps({"cells": [
            {"id": "fr", "quick": True, "expectedHint": "french"},
            {"id": "en", "quick": True, "expectedHint": "english"},
        ]}))
        corpus.write_text(json.dumps({"languages": []}))
        fr = engine_row("fr-id", run_id="lang-run", cell="fr")
        en = engine_row("en-id", run_id="lang-run", cell="en")
        fr["notes"]["languageHint"] = "french"
        en["notes"]["languageHint"] = "english"
        args = SimpleNamespace(
            matrix=matrix, corpus=corpus, subset="quick", diagnostics=self.root,
            run_id="lang-run", output_gate="not-performed", platform="macos",
            started_at="2026-07-12T12:00:00Z", finished_at="2026-07-12T12:01:00Z",
            label="fixture", artifact_dir=self.root, snapshot=self.root / "snapshot.json",
        )
        captured, write_patch = self.capture_manifest()
        with (
            mock.patch.object(publisher, "load_engine_rows", return_value=[en, fr]),
            mock.patch.object(publisher, "source_from_snapshot", return_value=source_fixture()),
            mock.patch.object(publisher, "crash_delta_from_snapshot", return_value={"passed": True, "count": 0}),
            self.hardware_patch(),
            write_patch,
        ):
            publisher.language_command(args)
        record = captured["manifest"]["historyRecord"]
        self.assertEqual(record["run"]["matrixScope"], "partial")
        self.assertEqual([take["cell"] for take in record["takes"]], ["fr", "en"])
        self.assertTrue(all(take["layerCompleteness"] == "complete" for take in record["takes"]))
        self.assertTrue(all(take["output"]["readableWAV"] for take in record["takes"]))
        self.assertTrue(all(take["audioQC"]["verdict"] == "pass" for take in record["takes"]))

    def test_ios_language_binds_sanitized_asr_evidence_and_per_take_scores(self) -> None:
        matrix = self.root / "matrix.json"
        corpus = self.root / "corpus.json"
        matrix.write_text(json.dumps({"cells": [
            {"id": "fr", "quick": True, "expectedHint": "french"},
        ]}))
        corpus.write_text(json.dumps({"languages": []}))
        row = engine_row("fr-generation", run_id="lang-ios", cell="fr")
        row["notes"]["languageHint"] = "french"
        sentinel = {
            "runID": "lang-ios--fr",
            "generationID": "fr-generation",
            "status": "ok",
            "deviceModel": "iPhone",
            "systemName": "iOS",
            "systemVersion": "26.5",
            "outputVerification": {
                "transcript": "private generated transcript must not be selected",
                "detectedLanguage": "french",
                "expectedLanguage": "french",
                "languageMatchScore": 0.875,
                "wordErrorRate": 0.125,
                "languagePass": True,
                "accuracyPass": True,
                "pass": True,
                "skipReason": None,
            },
        }
        sentinel_dir = self.root / "diagnostics" / "lang-ios--fr"
        sentinel_dir.mkdir(parents=True)
        (sentinel_dir / "device-diagnostics-done.json").write_text(json.dumps(sentinel))
        args = SimpleNamespace(
            matrix=matrix, corpus=corpus, subset="quick", diagnostics=self.root / "diagnostics",
            crash_diagnostics=None, run_id="lang-ios", output_gate="pass", platform="ios",
            started_at="2026-07-12T12:00:00Z", finished_at="2026-07-12T12:01:00Z",
            label="fixture", artifact_dir=self.root, snapshot=self.root / "snapshot.json",
            design_fixture_digest=None,
        )
        captured, write_patch = self.capture_manifest()
        with (
            mock.patch.object(publisher, "load_engine_rows", return_value=[row]),
            mock.patch.object(publisher, "source_from_snapshot", return_value=source_fixture()),
            mock.patch.object(publisher, "crash_delta_from_snapshot", return_value={"passed": True, "count": 0}),
            self.hardware_patch(),
            write_patch,
        ):
            publisher.language_command(args)
        manifest = captured["manifest"]
        take_metrics = manifest["historyRecord"]["takes"][0]["metrics"]
        self.assertEqual(take_metrics["wordErrorRate"], 0.125)
        self.assertEqual(take_metrics["languageMatchScore"], 0.875)
        self.assertEqual(take_metrics["outputLanguagePass"], 1.0)
        self.assertEqual(take_metrics["outputAccuracyPass"], 1.0)
        sanitized = publisher.sanitized_asr_evidence(
            cell={"id": "fr", "expectedHint": "french"},
            sentinel=sentinel,
            engine_row=row,
            parent_run_id="lang-ios",
        )
        self.assertNotIn("transcript", sanitized)
        self.assertEqual(
            manifest["rawTelemetryDigest"],
            publisher.digest_bytes(publisher.canonical_bytes({
                "telemetry": [row], "outputVerification": [sanitized],
            })),
        )
        mismatched = dict(sentinel)
        mismatched["generationID"] = "another-generation"
        with self.assertRaisesRegex(publisher.PublicationError, "another generation"):
            publisher.sanitized_asr_evidence(
                cell={"id": "fr", "expectedHint": "french"},
                sentinel=mismatched,
                engine_row=row,
                parent_run_id="lang-ios",
            )

    def test_telemetry_overhead_requires_and_records_eighteen_samples(self) -> None:
        rotations = [
            ("off", "lightweight", "verbose"),
            ("lightweight", "verbose", "off"),
            ("verbose", "off", "lightweight"),
        ]
        results = {}
        pcm = {
            f"r{rotation}-t{measured}": f"{rotation}{measured}" * 32
            for rotation in range(1, 4) for measured in range(1, 3)
        }
        for mode in ("off", "lightweight", "verbose"):
            results[mode] = {"pcmSHA256": dict(pcm), "samples": [
                {
                    "rotation": rotation,
                    "modeOrder": rotations[rotation - 1].index(mode) + 1,
                    "measuredTake": measured,
                    "generationID": f"{mode}-{rotation}-{measured}",
                    "rtf": 1.0,
                    "ttfcMS": 10.0,
                    "audioSeconds": 2.0,
                    "environment": {
                        "loadAverage1Minute": float(rotation) + measured / 10,
                        "freeStorageBytes": 900 - measured,
                        "uptimeSeconds": 100.0 + measured,
                        "lowPowerModeEnabled": rotation == 2,
                        "thermalState": "nominal",
                    },
                }
                for rotation in range(1, 4) for measured in range(1, 3)
            ]}
        contexts = []
        for rotation, order in enumerate(rotations, start=1):
            for mode_order, mode in enumerate(order, start=1):
                contexts.append({
                    "rotation": rotation,
                    "order": mode_order,
                    "mode": mode,
                    "before": {
                        "loadAverage": [float(rotation), 0.0, 0.0],
                        "freeStorageBytes": 1000 - rotation,
                        "uptimeSeconds": 50.0 + rotation,
                        "lowPowerMode": rotation == 2,
                        "thermalState": "nominal",
                    },
                    "after": {"thermalState": "fair" if rotation == 3 else "nominal"},
                })
        verdict = self.root / "verdict.json"
        verdict.write_text(json.dumps({
            "schemaVersion": 2,
            "runID": "telemetry-overhead-fixture",
            "startedAt": "2026-07-12T12:00:00Z",
            "completedAt": "2026-07-12T12:01:00Z",
            "status": "pass",
            "summary": {
                "telemetrySchemaVersion": 7,
                "modelID": "pro_custom_speed",
                "modelRuntimeIdentity": engine_row("identity")["modelRuntimeIdentity"],
                "pcmParity": True,
                "failures": [],
                "results": results,
                "machineContext": contexts,
            },
        }))
        args = SimpleNamespace(
            verdict=verdict, artifact_dir=self.root, snapshot=self.root / "snapshot.json",
        )
        captured, write_patch = self.capture_manifest()
        with (
            mock.patch.object(publisher, "source_from_snapshot", return_value=source_fixture()),
            mock.patch.object(publisher, "crash_delta_from_snapshot", return_value={"passed": True, "count": 0}),
            self.hardware_patch(),
            write_patch,
        ):
            publisher.telemetry_overhead_command(args)
        takes = captured["manifest"]["historyRecord"]["takes"]
        self.assertEqual(len(takes), 18)
        self.assertEqual(
            [take["cell"] for take in takes[:8]],
            [
                "rotation-1/order-1/off/take-1",
                "rotation-1/order-1/off/take-2",
                "rotation-1/order-2/lightweight/take-1",
                "rotation-1/order-2/lightweight/take-2",
                "rotation-1/order-3/verbose/take-1",
                "rotation-1/order-3/verbose/take-2",
                "rotation-2/order-1/lightweight/take-1",
                "rotation-2/order-1/lightweight/take-2",
            ],
        )
        self.assertEqual(takes[0]["metrics"]["loadAverage1M"], 1.1)
        self.assertEqual(takes[6]["metrics"]["lowPowerMode"], 1.0)
        self.assertEqual(takes[-1]["thermalState"], "fair")
        self.assertEqual(takes[0]["output"], {
            "readableWAV": True,
            "atomicPublish": True,
            "durationSeconds": 2.0,
            "fileDigest": pcm["r1-t1"],
        })
        self.assertEqual(
            [take["output"]["fileDigest"] for take in takes if "/off/" in take["cell"]],
            [pcm[f"r{rotation}-t{measured}"] for rotation in range(1, 4) for measured in range(1, 3)],
        )
        self.assertTrue(all(
            take["runtimeProfileSignature"] == "pro_custom_speed:fixture-v1"
            for take in takes
        ))
        self.assertTrue(all(take["modelIntegrityDigest"] == "f" * 64 for take in takes))
        models = captured["manifest"]["historyRecord"]["models"]
        self.assertEqual(len(models), 1)
        self.assertEqual(models[0]["mode"], "custom")
        self.assertEqual(
            models[0]["modelID"],
            "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
        )
        self.assertEqual(models[0]["revision"], "f35faf19b0cc2160865af64ecf0f22f83d335135")
        invalid = json.loads(verdict.read_text())
        invalid["summary"]["results"]["off"]["pcmSHA256"]["r1-t1"] = (
            publisher.hashlib.sha256(b"").hexdigest()
        )
        verdict.write_text(json.dumps(invalid))
        with self.assertRaisesRegex(publisher.PublicationError, "empty or invalid PCM"):
            publisher.telemetry_overhead_command(args)

    def test_telemetry_overhead_rejects_missing_typed_identity(self) -> None:
        verdict = self.root / "verdict.json"
        verdict.write_text(json.dumps({
            "schemaVersion": 2,
            "runID": "telemetry-overhead-fixture",
            "startedAt": "2026-07-12T12:00:00Z",
            "completedAt": "2026-07-12T12:01:00Z",
            "status": "pass",
            "summary": {"pcmParity": True, "failures": [], "results": {}},
        }))
        args = SimpleNamespace(
            verdict=verdict, artifact_dir=self.root, snapshot=self.root / "snapshot.json",
        )
        with self.assertRaisesRegex(
            publisher.PublicationError,
            "lacks exact schema-v7 Custom Speed identity",
        ):
            publisher.telemetry_overhead_command(args)

    def test_prosody_calibration_retains_aggregate_accuracy_and_thresholds(self) -> None:
        profile = self.root / "profile.json"
        thresholds = {
            "monotone_f0_std_hz": 10.0,
            "monotone_turning_points_per_sec": 1.0,
            "rushed_syllable_rate_hz": 7.0,
            "rushed_max_pause_ratio": 0.1,
            "flat_envelope_roughness": 0.02,
            "flat_rate_cv": 0.2,
            "pause_max_seconds": 1.5,
            "pause_ratio_max": 0.4,
        }
        profile.write_text(json.dumps({"thresholds": thresholds}))
        result = self.root / "calibration-results.json"
        result.write_text(json.dumps({
            "status": "pass",
            "analysisFailureCount": 0,
            "runID": "prosody-fixture",
            "label": "fixture",
            "startedAt": "2026-07-12T12:00:00Z",
            "finishedAt": "2026-07-12T12:01:00Z",
            "goodClipCount": 3,
            "badClipCount": 4,
            "targetFalsePositiveRate": 0.05,
            "corpusDigest": "c" * 64,
            "profileDigest": publisher.digest_file(profile),
            "flagRates": {
                "good_flag_rate": 0.0,
                "bad_flag_rate": 0.75,
                "false_positive_rate": 0.0,
                "true_positive_rate": 0.75,
            },
        }))
        args = SimpleNamespace(
            results=result,
            profile=profile,
            artifact_dir=self.root,
            snapshot=self.root / "snapshot.json",
        )
        captured, write_patch = self.capture_manifest()
        with (
            mock.patch.object(publisher, "source_from_snapshot", return_value=source_fixture()),
            self.hardware_patch(),
            write_patch,
        ):
            publisher.prosody_command(args)
        metrics = captured["manifest"]["historyRecord"]["takes"][0]["metrics"]
        self.assertEqual(metrics["goodClipCount"], 3.0)
        self.assertEqual(metrics["observedTruePositiveRate"], 0.75)
        self.assertEqual(metrics["maximumPauseThresholdSeconds"], 1.5)

    def test_profile_requires_a_nonempty_exported_trace_toc(self) -> None:
        trace = self.root / "build" / "profile.trace"
        trace.mkdir(parents=True)
        (trace / "data.bin").write_bytes(b"trace")
        toc = self.root / "trace-toc.xml"
        toc.write_text(
            "<trace-toc><run><processes><process name='Vocello' pid='4242'/>"
            "<process name='kernel' pid='0'/></processes><data>"
            "<table schema='time-profile'/><table schema='os-signpost'/></data></run></trace-toc>"
        )
        args = SimpleNamespace(
            trace=trace,
            toc=toc,
            template="Time Profiler",
            duration=10.0,
            target_process="Vocello",
            target_pid=4242,
            run_id="profile-fixture",
        )
        extracted = {
            "capturedRowsBySchema": {"time-profile": 12, "os-signpost": 8},
            "capturedDataRowCount": 20,
            "cpuSampleCount": 12,
            "cpuSampleWeightMS": 12.0,
            "cpuSampleSpanMS": 9.0,
            "signpostEventCount": 8,
            "correlatedSignpostEventCount": 4,
            "correlationFieldsVerified": True,
        }
        with (
            mock.patch.object(publisher, "ROOT", self.root),
            mock.patch.object(
                publisher, "extract_trace_data_summary", return_value=extracted
            ) as extract,
        ):
            evidence = publisher.trace_evidence(
                args,
                expected_correlations={
                    ("profile-generation", 1, "custom/speed/medium/warm#0")
                },
            )
            self.assertEqual(evidence["summary"]["tableCount"], 2)
            self.assertEqual(evidence["summary"]["schemaCount"], 2)
            self.assertEqual(evidence["summary"]["signpostSchemaCount"], 1)
            self.assertEqual(evidence["summary"]["processCount"], 2)
            self.assertTrue(evidence["summary"]["targetPIDVerified"])
            self.assertEqual(evidence["summary"]["cpuSampleCount"], 12)
            self.assertEqual(evidence["summary"]["correlatedSignpostEventCount"], 4)
            self.assertEqual(extract.call_args.kwargs["target_pid"], 4242)
            extract.reset_mock()
            args.target_pid = None
            derived = publisher.trace_evidence(
                args,
                expected_correlations={
                    ("profile-generation", 1, "custom/speed/medium/warm#0")
                },
            )
            self.assertTrue(derived["summary"]["targetPIDVerified"])
            self.assertEqual(extract.call_args.kwargs["target_pid"], 4242)
            args.target_pid = 4242
            args.target_pid = 9999
            with self.assertRaises(publisher.PublicationError):
                publisher.trace_evidence(
                    args,
                    expected_correlations={
                        ("profile-generation", 1, "custom/speed/medium/warm#0")
                    },
                )
            args.target_pid = 4242
            args.target_process = "WrongTarget"
            with self.assertRaises(publisher.PublicationError):
                publisher.trace_evidence(
                    args,
                    expected_correlations={
                        ("profile-generation", 1, "custom/speed/medium/warm#0")
                    },
                )

    def test_trace_summary_extracts_cpu_samples_and_correlated_signposts(self) -> None:
        trace = self.root / "profile.trace"
        trace.mkdir()

        def fake_export(command, **_kwargs):
            output = Path(command[command.index("--output") + 1])
            xpath = command[command.index("--xpath") + 1]
            if "time-profile" in xpath:
                xml = """<trace-query-result>
                <process id='target' pid='4242'/>
                <row><process pid='9999'/><sample-time>0</sample-time><weight>9000000</weight></row>
                <row><process ref='target'/><sample-time id='t1'>1000000</sample-time><weight id='w1'>1000000</weight></row>
                <row><process pid='4242'/><sample-time id='t2'>4000000</sample-time><weight ref='w1'/></row>
                </trace-query-result>"""
            else:
                xml = """<trace-query-result>
                <row><process pid='9999'/><string>runID=profile-run generationID=wrong takeIndex=1 cell=wrong</string></row>
                <row><process pid='4242'/><string>runID=profile-run generationID=gen-1 takeIndex=1 cell=custom/speed/medium/warm#0</string></row>
                </trace-query-result>"""
            output.write_text(xml, encoding="utf-8")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with mock.patch.object(publisher.subprocess, "run", side_effect=fake_export):
            summary = publisher.extract_trace_data_summary(
                trace, {"time-profile", "os-signpost"}, run_id="profile-run",
                target_pid=4242,
                expected_correlations={
                    ("gen-1", 1, "custom/speed/medium/warm#0")
                },
            )
        self.assertEqual(summary["cpuSampleCount"], 2)
        self.assertEqual(summary["cpuSampleWeightMS"], 2.0)
        self.assertEqual(summary["cpuSampleSpanMS"], 3.0)
        self.assertEqual(summary["correlatedSignpostEventCount"], 1)
        self.assertEqual(summary["capturedRowsBySchema"]["time-profile"], 2)
        self.assertEqual(summary["capturedRowsBySchema"]["os-signpost"], 1)

    def test_trace_summary_resolves_cpu_profiler_and_reused_signpost_values(self) -> None:
        trace = self.root / "profile.trace"
        trace.mkdir()

        def fake_export(command, **_kwargs):
            output = Path(command[command.index("--output") + 1])
            xpath = command[command.index("--xpath") + 1]
            if "cpu-profile" in xpath:
                xml = """<trace-query-result>
                <process id='target' pid='4242'/>
                <row><process ref='target'/><sample-time id='t1'>1000000</sample-time><cycle-weight id='w1'>100</cycle-weight></row>
                <row><process ref='target'/><sample-time>4000000</sample-time><cycle-weight>200</cycle-weight></row>
                </trace-query-result>"""
            else:
                xml = """<trace-query-result>
                <process id='target' pid='4242'/>
                <os-log-metadata id='cold' fmt='runID= profile-run generationID= gen-1 takeIndex= 1 cell= custom/speed/medium/cold#0'/>
                <os-log-metadata id='warm' fmt='runID= profile-run generationID= gen-2 takeIndex= 2 cell= custom/speed/medium/warm#0'/>
                <row><process ref='target'/><os-log-metadata ref='cold'/></row>
                <row><process ref='target'/><os-log-metadata ref='warm'/></row>
                </trace-query-result>"""
            output.write_text(xml, encoding="utf-8")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with mock.patch.object(publisher.subprocess, "run", side_effect=fake_export):
            summary = publisher.extract_trace_data_summary(
                trace, {"cpu-profile", "os-signpost"}, run_id="profile-run",
                target_pid=4242,
                expected_correlations={
                    ("gen-1", 1, "custom/speed/medium/cold#0"),
                    ("gen-2", 2, "custom/speed/medium/warm#0"),
                },
            )
        self.assertEqual(summary["cpuSampleCount"], 2)
        self.assertEqual(summary["cpuCycleWeight"], 300)
        self.assertEqual(summary["cpuSampleSpanMS"], 3.0)
        self.assertEqual(summary["correlatedSignpostEventCount"], 2)

    def test_trace_summary_rejects_signposts_without_cpu_profile(self) -> None:
        trace = self.root / "profile.trace"
        trace.mkdir()

        def fake_export(command, **_kwargs):
            output = Path(command[command.index("--output") + 1])
            output.write_text(
                """<trace-query-result><process id='target' pid='4242'/>
                <row><process ref='target'/><string>runID=profile-run generationID=gen-1 takeIndex=1 cell=custom/speed/medium/warm#0</string></row>
                </trace-query-result>""",
                encoding="utf-8",
            )
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with (
            mock.patch.object(publisher.subprocess, "run", side_effect=fake_export),
            self.assertRaisesRegex(publisher.PublicationError, "CPU Profiler or Time Profiler"),
        ):
            publisher.extract_trace_data_summary(
                trace, {"os-signpost"}, run_id="profile-run", target_pid=4242,
                expected_correlations={
                    ("gen-1", 1, "custom/speed/medium/warm#0")
                },
            )

    def test_trace_rejects_wrong_or_split_correlation_rows(self) -> None:
        trace = self.root / "profile.trace"
        trace.mkdir()

        def fake_export(command, **_kwargs):
            output = Path(command[command.index("--output") + 1])
            xpath = command[command.index("--xpath") + 1]
            if "time-profile" in xpath:
                xml = """<trace-query-result><row><process pid='4242'/><sample-time>1</sample-time><weight>1</weight></row></trace-query-result>"""
            else:
                xml = """<trace-query-result>
                <row><process pid='4242'/><string>runID=profile-run generationID=wrong takeIndex=1 cell=custom/speed/medium/warm#0</string></row>
                <row><process pid='4242'/><string>runID=profile-run generationID=gen-1</string></row>
                <row><process pid='4242'/><string>takeIndex=1 cell=custom/speed/medium/warm#0</string></row>
                </trace-query-result>"""
            output.write_text(xml, encoding="utf-8")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with (
            mock.patch.object(publisher.subprocess, "run", side_effect=fake_export),
            self.assertRaisesRegex(publisher.PublicationError, "correlated signpost"),
        ):
            publisher.extract_trace_data_summary(
                trace, {"time-profile", "os-signpost"}, run_id="profile-run",
                target_pid=4242,
                expected_correlations={
                    ("gen-1", 1, "custom/speed/medium/warm#0")
                },
            )


if __name__ == "__main__":
    unittest.main()
