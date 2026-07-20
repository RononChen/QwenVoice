#!/usr/bin/env python3
from __future__ import annotations

import json
import unittest
from pathlib import Path

import scripts.check_characterization_controls as CHECK

ROOT = Path(__file__).resolve().parents[2]


def _take(mode: str, *, state: str = "warm", trim: int = 1, warning: str | None = None) -> dict:
    warnings = [warning] if warning else []
    return {
        "mode": mode,
        "length": "short",
        "cell": f"{mode}/short/{state}",
        "maximumTrimLevel": trim,
        "warnings": warnings,
    }


class CharacterizationControlTests(unittest.TestCase):
    def test_requires_warm_and_cold_minima(self) -> None:
        fixtures = json.loads(
            (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8")
        )
        # Three sessions, but only one warm each → fail warm minima.
        records = [
            {"takes": [_take("custom"), _take("design"), _take("clone")]}
            for _ in range(3)
        ]
        findings = CHECK.evaluate(records, fixtures)
        self.assertTrue(any("warm takes" in item for item in findings))

    def test_passes_when_minima_met(self) -> None:
        fixtures = json.loads(
            (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8")
        )
        takes = []
        for mode in ("custom", "design"):
            takes.extend(_take(mode, state="cold") for _ in range(3))
            takes.extend(_take(mode, state="warm") for _ in range(10))
        takes.extend(_take("clone", state="warm") for _ in range(10))
        # Split across three session records.
        records = [
            {"takes": takes[0:12]},
            {"takes": takes[12:24]},
            {"takes": takes[24:]},
        ]
        self.assertEqual(CHECK.evaluate(records, fixtures), [])

    def test_hard_trim_fails_closed(self) -> None:
        fixtures = json.loads(
            (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8")
        )
        takes = []
        for mode in ("custom", "design"):
            takes.extend(_take(mode, state="cold") for _ in range(3))
            takes.extend(_take(mode, state="warm") for _ in range(10))
        takes.extend(_take("clone", state="warm") for _ in range(9))
        takes.append(
            _take("clone", state="warm", warning="memory.pressure.hard_trim")
        )
        records = [{"takes": takes}]
        findings = CHECK.evaluate(records, fixtures)
        self.assertTrue(any("fail-closed" in item for item in findings))


if __name__ == "__main__":
    unittest.main()
