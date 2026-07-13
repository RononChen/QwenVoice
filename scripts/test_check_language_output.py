#!/usr/bin/env python3
"""Offline fixture tests for scripts/check_language_output.py (no device)."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from language_bench_evidence import build_plan, write_json_atomic
from check_language_output import recomputed_accuracy, validate_structured_verification

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CHECK = os.path.join(ROOT, "scripts", "check_language_output.py")
MATRIX = os.path.join(ROOT, "config", "language-bench-matrix.json")
CORPUS = os.path.join(ROOT, "config", "language-bench-corpus.json")

QUICK_CELLS = (
    ("custom-en-pinned", "english"),
    ("custom-en-auto", "english"),
    ("design-en-auto", "english"),
    ("custom-fr-pinned", "french"),
    ("custom-fr-auto", "french"),
    ("design-fr-auto", "french"),
)


def verification(
    expected_language: str,
    *,
    script: str | None = None,
    transcript_override: str | None = None,
    inconsistent: bool = False,
    missing_metrics: bool = False,
) -> dict:
    locale = "en-US" if expected_language == "english" else "fr-FR"
    if script is None:
        script = (
            "The train left the station at dawn."
            if expected_language == "english"
            else "Le train a quitté la gare à l'aube."
        )
    transcript = transcript_override or script
    word, character = recomputed_accuracy(script, transcript, expected_language)
    accuracy_metric = (
        "characterErrorRate" if expected_language in {"chinese", "japanese"}
        else "wordErrorRate"
    )
    repetitions = []
    for index in (1, 2, 3):
        pass_transcript = transcript
        if inconsistent and index == 3:
            pass_transcript = "Different transcript"
        repetitions.append(
            {
                "passIndex": index,
                "localeIdentifier": locale,
                "authorizationStatus": "authorized",
                "recognizerAvailable": True,
                "supportsOnDeviceRecognition": True,
                "finalResultStatus": "finalResult",
                "recognitionDurationSeconds": 0.25,
                "transcript": pass_transcript,
                "segmentCount": 7,
                "segmentStartSeconds": 0.0,
                "segmentEndSeconds": 1.5,
                "timingCoverageSeconds": 1.5,
                "averageConfidence": 0.9,
                "minimumConfidence": 0.8,
            }
        )
    value = {
        "schemaVersion": 3,
        "algorithmVersion": "language-output-verifier-v3",
        "expectedLanguage": expected_language,
        "detectedLanguage": expected_language,
        "transcript": transcript,
        "languagePass": True,
        "accuracyPass": True,
        "languageMatchScore": 1.0,
        "wordErrorRate": word["errorRate"],
        "characterErrorRate": character["errorRate"],
        "referenceTokenCount": word["referenceCount"],
        "hypothesisTokenCount": word["hypothesisCount"],
        "referenceCharacterCount": character["referenceCount"],
        "hypothesisCharacterCount": character["hypothesisCount"],
        "substitutions": word["substitutions"],
        "insertions": word["insertions"],
        "deletions": word["deletions"],
        "characterSubstitutions": character["substitutions"],
        "characterInsertions": character["insertions"],
        "characterDeletions": character["deletions"],
        "accuracyMetricVersion": "normalized-edit-rate-v1",
        "accuracyMetric": accuracy_metric,
        "accuracyThreshold": 0.15,
        "accuracyValue": character["errorRate"] if accuracy_metric == "characterErrorRate" else word["errorRate"],
        "pass": True,
        "recognition": {
            "schemaVersion": 2,
            "algorithmVersion": "apple-speech-file-consensus-v2",
            "expectedLanguage": expected_language,
            "selectedLocaleIdentifier": locale,
            "authorizationStatus": "authorized",
            "recognizerAvailable": True,
            "supportsOnDeviceRecognition": True,
            "requiredPassCount": 3,
            "recognitionDurationSeconds": 0.75,
            "repetitions": repetitions,
            "evidenceConsistency": not inconsistent,
            "consensusStatus": "inconsistent" if inconsistent else "consistent",
            "transcript": None if inconsistent else transcript,
        },
    }
    if missing_metrics:
        value.pop("wordErrorRate")
        value.pop("substitutions")
    return value


def write_fixture(
    diag: str,
    run_id: str,
    *,
    mismatch: bool = False,
    inconsistent: bool = False,
    missing_metrics: bool = False,
) -> None:
    for index, (cell_id, expected_language) in enumerate(QUICK_CELLS):
        directory = os.path.join(diag, cell_id)
        os.makedirs(directory, exist_ok=True)
        if mismatch and index == 0:
            expected_language = "french"
        record = {
            "runID": f"{run_id}--{cell_id}",
            "status": "ok",
            "outputVerification": verification(
                expected_language,
                inconsistent=inconsistent and index == 0,
                missing_metrics=missing_metrics and index == 0,
            ),
        }
        with open(os.path.join(directory, "device-diagnostics-done.json"), "w", encoding="utf-8") as fh:
            json.dump(record, fh)


def write_planned_fixture(diag: str, run_id: str, plan_path: str) -> dict:
    plan = build_plan(
        run_id=run_id,
        matrix_path=Path(MATRIX),
        corpus_path=Path(CORPUS),
        subset="quick",
        cohort_path=None,
    )
    write_json_atomic(Path(plan_path), plan)
    group_digests = {
        "custom-english-v1": "a" * 64,
        "custom-french-v1": "b" * 64,
    }
    with open(CORPUS, encoding="utf-8") as handle:
        scripts = {entry["id"]: entry["script"] for entry in json.load(handle)["languages"]}
    for take in plan["takes"]:
        directory = os.path.join(diag, "runs", take["childRunID"])
        os.makedirs(directory, exist_ok=True)
        expected = take["expectedHint"]
        record = {
            "runID": take["childRunID"],
            "generationID": f"generation-{take['takeIndex']}",
            "mode": take["mode"],
            "variant": take["variant"],
            "status": "ok",
            "seed": take["seed"],
            "samplingVariation": take["samplingVariation"],
            "requestedLanguageHint": take["uiHint"],
            "languageHintSource": "auto" if take["uiHint"] == "auto" else "explicit",
            "promptDigestScope": "resolved",
            "resolvedPromptAssemblyDigest": group_digests.get(
                take.get("promptEquivalenceGroup"), "c" * 64
            ),
        }
        if not take.get("skipOutputVerification"):
            record["outputVerification"] = verification(
                expected, script=scripts[take["scriptLang"]]
            )
        with open(os.path.join(directory, "device-diagnostics-done.json"), "w", encoding="utf-8") as handle:
            json.dump(record, handle)
    return plan


class CheckLanguageOutputTests(unittest.TestCase):
    def run_checker(self, diag: str, run_id: str, plan_path: str | None = None) -> subprocess.CompletedProcess[str]:
        command = [
                sys.executable,
                CHECK,
                diag,
                "--run-id",
                run_id,
                "--matrix",
                MATRIX,
                "--subset",
                "quick",
            ]
        if plan_path:
            command.extend(["--plan", plan_path])
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_quick_subset_passes_fixture(self) -> None:
        run_id = "fixture-output"
        with tempfile.TemporaryDirectory() as diag:
            write_fixture(diag, run_id)
            result = self.run_checker(diag, run_id)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_expected_language_mismatch_fails(self) -> None:
        run_id = "fixture-output-mismatch"
        with tempfile.TemporaryDirectory() as diag:
            write_fixture(diag, run_id, mismatch=True)
            result = self.run_checker(diag, run_id)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expectedLanguage", result.stdout + result.stderr)

    def test_inconsistent_repeated_asr_fails_conservatively(self) -> None:
        run_id = "fixture-output-inconsistent"
        with tempfile.TemporaryDirectory() as diag:
            write_fixture(diag, run_id, inconsistent=True)
            result = self.run_checker(diag, run_id)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("inconsistent", (result.stdout + result.stderr).lower())

    def test_missing_structured_metrics_fails(self) -> None:
        run_id = "fixture-output-missing-metrics"
        with tempfile.TemporaryDirectory() as diag:
            write_fixture(diag, run_id, missing_metrics=True)
            result = self.run_checker(diag, run_id)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("wordErrorRate", result.stdout + result.stderr)

    def test_duplicate_sentinel_fails_instead_of_overwriting(self) -> None:
        run_id = "fixture-output-duplicate"
        with tempfile.TemporaryDirectory() as diag:
            write_fixture(diag, run_id)
            source = os.path.join(diag, QUICK_CELLS[0][0], "device-diagnostics-done.json")
            duplicate_dir = os.path.join(diag, "duplicate", QUICK_CELLS[0][0])
            os.makedirs(duplicate_dir)
            with open(source, encoding="utf-8") as handle:
                record = json.load(handle)
            with open(os.path.join(duplicate_dir, "device-diagnostics-done.json"), "w", encoding="utf-8") as handle:
                json.dump(record, handle)
            result = self.run_checker(diag, run_id)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate", (result.stdout + result.stderr).lower())

    def test_planned_output_evidence_passes(self) -> None:
        run_id = "fixture-output-plan"
        with tempfile.TemporaryDirectory() as diag:
            plan_path = os.path.join(diag, "plan.json")
            write_planned_fixture(diag, run_id, plan_path)
            result = self.run_checker(diag, run_id, plan_path)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_planned_prompt_equivalence_mismatch_fails(self) -> None:
        run_id = "fixture-output-prompt-mismatch"
        with tempfile.TemporaryDirectory() as diag:
            plan_path = os.path.join(diag, "plan.json")
            plan = write_planned_fixture(diag, run_id, plan_path)
            target = next(take for take in plan["takes"] if take["cellID"] == "custom-fr-auto")
            sentinel = os.path.join(diag, "runs", target["childRunID"], "device-diagnostics-done.json")
            with open(sentinel, encoding="utf-8") as handle:
                record = json.load(handle)
            record["resolvedPromptAssemblyDigest"] = "f" * 64
            with open(sentinel, "w", encoding="utf-8") as handle:
                json.dump(record, handle)
            result = self.run_checker(diag, run_id, plan_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("prompt equivalence", (result.stdout + result.stderr).lower())

    def test_planned_requested_language_hint_tamper_fails(self) -> None:
        run_id = "fixture-output-requested-hint"
        with tempfile.TemporaryDirectory() as diag:
            plan_path = os.path.join(diag, "plan.json")
            plan = write_planned_fixture(diag, run_id, plan_path)
            target = next(
                take
                for take in plan["takes"]
                if take["uiHint"] == "auto" and not take.get("skipOutputVerification")
            )
            sentinel = os.path.join(
                diag, "runs", target["childRunID"], "device-diagnostics-done.json"
            )
            with open(sentinel, encoding="utf-8") as handle:
                record = json.load(handle)
            record["requestedLanguageHint"] = target["expectedHint"]
            record["languageHintSource"] = "explicit"
            with open(sentinel, "w", encoding="utf-8") as handle:
                json.dump(record, handle)
            result = self.run_checker(diag, run_id, plan_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requestedLanguageHint", result.stdout + result.stderr)

    def test_tampered_scores_fail_independent_recomputation(self) -> None:
        value = verification("french")
        value["wordErrorRate"] = 0.1
        failures = validate_structured_verification(
            value,
            "french",
            "Le train a quitté la gare à l'aube.",
            "tampered",
        )
        self.assertTrue(any("WER does not match" in failure for failure in failures), failures)

    def test_cjk_uses_recomputed_character_error_rate(self) -> None:
        script = "火车在黎明时分离开了车站。"
        # One character differs: WER is 1.0 because the unspaced sentence is one
        # word token, while CER remains below 0.15 and is the locked CJK metric.
        value = verification("chinese", script=script, transcript_override="火車在黎明时分离开了车站。")
        failures = validate_structured_verification(value, "chinese", script, "cjk")
        self.assertEqual(failures, [])
        self.assertEqual(value["accuracyMetric"], "characterErrorRate")
        self.assertEqual(value["wordErrorRate"], 1.0)
        self.assertLess(value["characterErrorRate"], 0.15)

    def test_japanese_dakuten_is_preserved_by_cer(self) -> None:
        word, character = recomputed_accuracy("かきくけこ", "がきくけこ", "japanese")
        # Compatibility WER folds diacritics, but the primary Japanese CER
        # must retain the audible dakuten distinction.
        self.assertEqual(word["errorRate"], 0.0)
        self.assertEqual(character["errorRate"], 0.2)


if __name__ == "__main__":
    unittest.main()
