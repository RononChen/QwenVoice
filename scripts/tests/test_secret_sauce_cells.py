#!/usr/bin/env python3
from __future__ import annotations

import json
import unittest
from pathlib import Path

import scripts.check_secret_sauce_cells as CHECK

ROOT = Path(__file__).resolve().parents[2]


def _cell(mode: str, *, trim: int = 1) -> dict:
    return {
        "key": f"{mode}/short/warm",
        "mode": mode,
        "length": "short",
        "maximumTrimLevel": trim,
        "statistics": {
            "submitToFirstChunkMS": {"count": 1, "median": 800},
            "playbackScheduledMS": {"count": 1, "median": 2000},
            "peakPhysicalFootprintMB": {"count": 1, "median": 2800},
            "mlxPeakMB": {"count": 1, "median": 3000},
            "maximumTrimLevel": {"count": 1, "median": float(trim), "max": float(trim)},
            "memoryTrimCount": {"count": 1, "median": 1},
        },
    }


class SecretSauceCellTests(unittest.TestCase):
    def test_tracked_baseline_short_cells_pass(self) -> None:
        record = ROOT / "benchmarks/runs/ui-generation/macos-xcui-benchmark-20260719-215547-11f8f4cf.json"
        self.assertEqual(CHECK.main([str(record)]), 0)

    def test_hard_trim_fails_closed(self) -> None:
        fixtures = json.loads(
            (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8")
        )
        record = {
            "cells": [_cell("custom", trim=2), _cell("design"), _cell("clone")],
            "takes": [],
        }
        findings = CHECK.evaluate(record, fixtures)
        self.assertTrue(any("hardTrim" in item for item in findings))

    def test_critical_warning_fails_closed(self) -> None:
        fixtures = json.loads(
            (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8")
        )
        record = {
            "cells": [_cell("custom"), _cell("design"), _cell("clone")],
            "takes": [
                {
                    "mode": "custom",
                    "length": "short",
                    "cell": "custom/short/warm",
                    "warnings": ["memory.pressure.critical"],
                }
            ],
        }
        findings = CHECK.evaluate(record, fixtures)
        self.assertTrue(any("criticalPressure" in item for item in findings))

    def test_soft_trim_is_allowed(self) -> None:
        fixtures = json.loads(
            (ROOT / "config/characterization-fixtures.json").read_text(encoding="utf-8")
        )
        record = {
            "cells": [_cell("custom"), _cell("design"), _cell("clone")],
            "takes": [
                {
                    "mode": "custom",
                    "length": "short",
                    "cell": "custom/short/warm",
                    "warnings": ["memory.pressure.soft_trim"],
                }
            ],
        }
        self.assertEqual(CHECK.evaluate(record, fixtures), [])


if __name__ == "__main__":
    unittest.main()
