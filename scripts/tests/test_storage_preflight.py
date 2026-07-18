#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "scripts/lib/storage_preflight.py"


class StoragePreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "repo"
        (self.root / "config").mkdir(parents=True)
        (self.root / "config/build-output-policy.json").write_text(
            json.dumps(
                {
                    "heavyLanePreflight": {
                        "schemaVersion": 1,
                        "lanes": {
                            "fixture": {
                                "requiredFreeBytes": 5 * 1024**3,
                                "cleanupHint": "scripts/clean_build_caches.sh --routine",
                            }
                        },
                    }
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_helper(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(HELPER),
                "check",
                "--root",
                str(self.root),
                "--lane",
                "fixture",
                *arguments,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_passes_at_exact_threshold(self) -> None:
        result = self.run_helper("--available-bytes", str(5 * 1024**3), "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ready"])
        self.assertEqual(payload["lane"], "fixture")

    def test_fails_before_work_and_prints_bounded_repair(self) -> None:
        result = self.run_helper("--available-bytes", str(4 * 1024**3))
        self.assertEqual(result.returncode, 2)
        self.assertIn("4.00 GiB available; 5 GiB required", result.stderr)
        self.assertIn("python3 scripts/build_output_policy.py status", result.stderr)
        self.assertIn("scripts/clean_build_caches.sh --routine", result.stderr)

    def test_rejects_unknown_lane(self) -> None:
        result = subprocess.run(
            [
                "python3",
                str(HELPER),
                "check",
                "--root",
                str(self.root),
                "--lane",
                "unknown",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown heavy-lane", result.stderr)


if __name__ == "__main__":
    unittest.main()
