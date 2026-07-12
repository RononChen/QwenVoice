#!/usr/bin/env python3
"""Focused fixtures for check_macos_xpc_bench.py ordering and output gates."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts" / "check_macos_xpc_bench.py"
RUN_ID = "mac-ui-order-fixture"


def make_engine_row(index: int, cell: str) -> dict:
    mode, _, state_and_repetition = cell.split("/")
    warm_state, _ = state_and_repetition.split("#")
    generation_id = f"fixture-{index}"
    return {
        "generationID": generation_id,
        "mode": mode,
        "warmState": warm_state,
        "finishReason": "completed",
        "derivedMetrics": {"generatedTokenCount": 100 + index},
        "stageMarks": [
            {"stage": "memory_trim", "metadata": {"level": "hardTrim"}},
        ] if index == 1 else [],
        "notes": {
            "benchRunID": RUN_ID,
            "benchTakeIndex": str(index),
            "benchCell": cell,
        },
        "outputMetrics": {
            "readableWAV": True,
            "atomicallyPublished": True,
            "durationSeconds": 1.0,
        },
        "audioQC": {"verdict": "pass", "flags": []},
    }


def v7_summary() -> dict:
    return {
        "targetIntervalNS": 500_000_000,
        "effectiveIntervalNS": 505_000_000,
        "maximumDriftNS": 5_000_000,
        "maximumLatenessNS": 5_000_000,
        "boundarySampleCount": 4,
        "captureFailureCount": 0,
        "processResourceUsage": {
            "userCPUTimeMS": 100.0, "systemCPUTimeMS": 20.0,
            "minorPageFaults": 1, "majorPageFaults": 0,
            "voluntaryContextSwitches": 2, "involuntaryContextSwitches": 1,
            "blockInputOperations": 0, "blockOutputOperations": 0,
        },
        "runEnvironment": {
            "loadAverage1Minute": 1.0, "freeStorageBytes": 1_000_000,
            "uptimeSeconds": 10.0, "lowPowerModeEnabled": False,
            "thermalState": "nominal",
        },
    }


def v7_frontend() -> dict:
    return {
        "submitToFirstChunkMS": 10, "submitToPlaybackScheduledMS": 30,
        "submitToCompletedMS": 100, "firstChunkToPlaybackScheduledMS": 20,
        "delayedHeartbeatCount50": 0, "scheduledHeartbeatCount": 10,
        "completedHeartbeatCount": 10, "heartbeatCoveragePPM": 1_000_000,
        "playbackChunksReceived": 4, "playbackContinuityFailures": 0,
        "playbackUnderruns": 0, "playbackStartBufferedChunks": 2,
        "playbackStartBufferedAudioMS": 120, "playbackMinimumQueuedAudioMS": 80,
    }


def upgrade_layers_to_v7(layers: dict[str, list[dict]]) -> None:
    for row in layers["engine"]:
        mode = row["mode"]
        model_id = f"pro_{mode}_speed"
        row["schemaVersion"] = 7
        row["summary"] = v7_summary()
        row["backendMetrics"] = {"timings": [], "stages": []}
        row["modelID"] = model_id
        row["modelRuntimeIdentity"] = {
            "resolvedModelID": model_id, "modelVariant": "speed",
            "runtimeProfileSignature": f"{model_id}:fixture-v1",
            "modelRepository": "mlx-community/Qwen3-TTS-fixture",
            "huggingFaceRevision": "a" * 40, "artifactVersion": "fixture-v1",
            "quantization": "4-bit", "integrityManifestDigest": "b" * 64,
        }
        if mode in {"design", "clone"}:
            row["modelRuntimeIdentity"]["fixtureDigest"] = "d" * 64
        row["notes"]["promptDigest"] = "c" * 64
    for row in layers["engine-service"]:
        row["schemaVersion"] = 7
        row["transportMetrics"] = {
            "requestAccepted": True, "requestToFirstChunkMS": 9,
            "counters": {"chunkGaps": 0},
        }
    for row in layers["app"]:
        row["schemaVersion"] = 7
        row["frontendMetrics"] = v7_frontend()


class CheckMacOSXPCBenchmarkTests(unittest.TestCase):
    expected_order = [
        "custom/medium/cold#0",
        "custom/short/warm#0",
        "custom/medium/warm#0",
        "clone/short/warm#0",
        "clone/medium/warm#0",
    ]

    def run_checker(
        self,
        cells: list[str],
        mutate_engine_rows=None,
        mutate_layers=None,
        malformed_layer: str | None = None,
        evidence: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        self.last_manifest = None
        with tempfile.TemporaryDirectory() as temp:
            diagnostics = Path(temp)
            engine_rows = [
                make_engine_row(index, cell)
                for index, cell in enumerate(cells, start=1)
            ]
            if mutate_engine_rows is not None:
                mutate_engine_rows(engine_rows)

            correlated_rows = [
                {
                    "generationID": row["generationID"],
                    "finishReason": "completed",
                    "notes": {"benchRunID": RUN_ID},
                }
                for row in engine_rows
            ]
            layers = {
                "engine": engine_rows,
                "engine-service": [dict(row) for row in correlated_rows],
                "app": [dict(row) for row in correlated_rows],
                "merged": [
                    {
                        "generationID": row["generationID"],
                        "requiredLayers": ["app", "engine-service", "engine"],
                        "missingLayers": [],
                        "complete": True,
                        "engine": {"generationID": row["generationID"]},
                        "engineService": {"generationID": row["generationID"]},
                        "app": {"generationID": row["generationID"]},
                    }
                    for row in engine_rows
                ],
            }
            if mutate_layers is not None:
                mutate_layers(layers)
            for layer, rows in (
                ("engine", layers["engine"]),
                ("engine-service", layers["engine-service"]),
                ("app", layers["app"]),
            ):
                directory = diagnostics / layer
                directory.mkdir()
                path = directory / "generations.jsonl"
                path.write_text(
                    "".join(json.dumps(row) + "\n" for row in rows)
                    + ("{not-json\n" if malformed_layer == layer else ""),
                    encoding="utf-8",
                )
            (diagnostics / "generations-merged.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in layers["merged"])
                + ("{not-json\n" if malformed_layer == "merged" else ""),
                encoding="utf-8",
            )
            command = [
                sys.executable,
                str(CHECK),
                str(diagnostics),
                "--run-id",
                RUN_ID,
                "--modes",
                "custom,clone",
                "--lengths",
                "short,medium",
                "--warm",
                "1",
            ]
            manifest_path = diagnostics / "benchmark-evidence.json"
            if evidence:
                command.extend([
                    "--evidence-manifest",
                    str(manifest_path),
                    "--crash-delta-passed",
                    "--label",
                    "fixture",
                ])
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
            )
            if manifest_path.is_file():
                self.last_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            return result

    def test_exact_order_and_pass_qc_pass(self) -> None:
        result = self.run_checker(self.expected_order)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_same_distribution_with_sequential_indices_in_wrong_order_fails(self) -> None:
        reordered = self.expected_order.copy()
        reordered[1], reordered[2] = reordered[2], reordered[1]
        result = self.run_checker(reordered)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("benchmark cell order differs", result.stdout + result.stderr)

    def test_missing_audio_qc_fails(self) -> None:
        def remove_audio_qc(rows: list[dict]) -> None:
            rows[0].pop("audioQC")

        result = self.run_checker(self.expected_order, remove_audio_qc)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("audioQC verdict is missing", result.stdout + result.stderr)

    def test_failed_audio_qc_fails(self) -> None:
        def fail_audio_qc(rows: list[dict]) -> None:
            rows[0]["audioQC"] = {"verdict": "fail", "flags": ["fixture"]}

        result = self.run_checker(self.expected_order, fail_audio_qc)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("audioQC failed", result.stdout + result.stderr)

    def test_audio_qc_warning_is_accepted(self) -> None:
        def warn_audio_qc(rows: list[dict]) -> None:
            rows[0]["audioQC"] = {"verdict": "warn", "flags": ["fixture"]}

        result = self.run_checker(self.expected_order, warn_audio_qc)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_evidence_manifest_contains_exact_order_and_complete_layers(self) -> None:
        result = self.run_checker(self.expected_order, evidence=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = self.last_manifest
        self.assertIsNotNone(manifest)
        self.assertEqual(manifest["runID"], RUN_ID)
        self.assertEqual(manifest["matrix"]["orderedCells"], self.expected_order)
        self.assertEqual(
            [take["generationID"] for take in manifest["takes"]],
            [f"fixture-{index}" for index in range(1, 6)],
        )
        self.assertTrue(all(manifest["layers"][key]["complete"] for key in manifest["layers"]))
        self.assertTrue(manifest["historyRecord"]["evidence"]["crashDeltaPassed"])
        first_metrics = manifest["historyRecord"]["takes"][0]["metrics"]
        self.assertEqual(first_metrics["generatedTokens"], 101)
        self.assertEqual(first_metrics["memoryTrimCount"], 1)
        self.assertEqual(first_metrics["maximumTrimLevel"], 2)

    def test_missing_correlated_layer_row_fails_without_evidence(self) -> None:
        def remove_app_row(layers: dict[str, list[dict]]) -> None:
            layers["app"].pop()

        result = self.run_checker(
            self.expected_order,
            mutate_layers=remove_app_row,
            evidence=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("app rows 4 != expected 5", result.stdout + result.stderr)
        self.assertIsNone(self.last_manifest)

    def test_incomplete_merged_row_fails(self) -> None:
        def remove_nested_app(layers: dict[str, list[dict]]) -> None:
            layers["merged"][0].pop("app")

        result = self.run_checker(self.expected_order, mutate_layers=remove_nested_app)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing complete layer payloads: app", result.stdout + result.stderr)

    def test_duplicate_layer_generation_id_fails(self) -> None:
        def duplicate_service_id(layers: dict[str, list[dict]]) -> None:
            layers["engine-service"][1]["generationID"] = "fixture-1"

        result = self.run_checker(self.expected_order, mutate_layers=duplicate_service_id)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("engine-service generationIDs are not unique", result.stdout + result.stderr)

    def test_malformed_jsonl_fails(self) -> None:
        result = self.run_checker(self.expected_order, malformed_layer="engine")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("malformed JSON", result.stdout + result.stderr)

    def test_schema_v7_complete_accuracy_evidence_passes(self) -> None:
        result = self.run_checker(self.expected_order, mutate_layers=upgrade_layers_to_v7)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_schema_v7_missing_sampler_resource_or_environment_fails(self) -> None:
        for field, message in (
            ("maximumDriftNS", "invalid sampler maximumDriftNS"),
            ("processResourceUsage", "incomplete process resource deltas"),
            ("runEnvironment", "has no run environment"),
        ):
            def mutate(layers, field=field):
                upgrade_layers_to_v7(layers)
                layers["engine"][0]["summary"].pop(field)
            with self.subTest(field=field):
                result = self.run_checker(self.expected_order, mutate_layers=mutate)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)

    def test_schema_v7_transport_acceptance_and_latency_are_required(self) -> None:
        for field, value, message in (
            ("requestAccepted", False, "was not accepted by XPC transport"),
            ("requestToFirstChunkMS", None, "has no request-to-first-chunk"),
        ):
            def mutate(layers, field=field, value=value):
                upgrade_layers_to_v7(layers)
                layers["engine-service"][0]["transportMetrics"][field] = value
            with self.subTest(field=field):
                result = self.run_checker(self.expected_order, mutate_layers=mutate)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)

    def test_schema_v7_frontend_lifecycle_and_playback_health_are_required(self) -> None:
        def mutate(layers):
            upgrade_layers_to_v7(layers)
            layers["app"][0]["frontendMetrics"].pop("playbackMinimumQueuedAudioMS")
        result = self.run_checker(self.expected_order, mutate_layers=mutate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete typed frontend lifecycle/playback", result.stdout + result.stderr)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
