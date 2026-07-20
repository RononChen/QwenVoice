#!/usr/bin/env python3
"""Evaluate UI/engine benchmark records against Phase 0 control minima.

For each promoted short Speed cell (Custom/Design/Clone), require at least the
configured warm and cold take counts across the supplied records. Clone has no
separate cold cell. Soft trim may warn; hardTrim/fullUnload fail closed.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "config/characterization-fixtures.json"

PROMOTED_SHORT = (
    "custom-speed-short-control",
    "design-speed-short-control",
    "clone-speed-short-control",
)


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _take_mode_length_state(take: dict[str, Any]) -> tuple[str | None, str | None, str]:
    mode = take.get("mode")
    length = take.get("length")
    key = str(take.get("cell") or take.get("key") or "")
    state = "warm"
    if "cold" in key or take.get("warmState") == "cold" or take.get("intendedWarmState") == "cold":
        state = "cold"
    if mode is None and "/" in key:
        parts = key.split("/")
        if parts:
            mode = parts[0]
        if len(parts) > 1 and parts[1] in {"short", "medium", "long"}:
            length = parts[1]
        elif length is None and "short" in key:
            length = "short"
    return mode if isinstance(mode, str) else None, length if isinstance(length, str) else None, state


def _fail_closed_warnings(takes: list[dict[str, Any]]) -> list[str]:
    bad: list[str] = []
    for take in takes:
        for warning in take.get("warnings") or []:
            text = warning if isinstance(warning, str) else str(warning)
            lowered = text.lower()
            if any(
                token in lowered
                for token in (
                    "hard_trim",
                    "hardtrim",
                    "full_unload",
                    "fullunload",
                    "critical",
                    "memory.warning",
                    "app_memory_warning",
                )
            ) and "soft_trim" not in lowered:
                bad.append(text)
        trim = take.get("maximumTrimLevel")
        if isinstance(trim, int) and trim >= 2:
            bad.append(f"maximumTrimLevel={trim}")
    return bad


def evaluate(records: list[dict[str, Any]], fixtures: dict[str, Any]) -> list[str]:
    min_warm = int(fixtures.get("minimumWarmTakesPerPromotedCell") or 10)
    min_cold = int(fixtures.get("minimumColdTakesPerPromotedCell") or 3)
    min_sessions = int(fixtures.get("minimumCleanControlRuns") or 3)
    findings: list[str] = []

    if len(records) < min_sessions:
        findings.append(
            f"need at least {min_sessions} control session records (got {len(records)})"
        )

    counts: dict[tuple[str, str], dict[str, int]] = defaultdict(
        lambda: {"warm": 0, "cold": 0}
    )
    all_takes: list[dict[str, Any]] = []
    for record in records:
        for take in record.get("takes") or []:
            if not isinstance(take, dict):
                continue
            all_takes.append(take)
            mode, length, state = _take_mode_length_state(take)
            if mode is None or length != "short":
                continue
            counts[(mode, "short")][state] += 1
        for cell in record.get("cells") or []:
            if not isinstance(cell, dict):
                continue
            mode = cell.get("mode")
            length = cell.get("length")
            if mode not in {"custom", "design", "clone"} or length != "short":
                continue
            key = str(cell.get("key") or "")
            stats = cell.get("statistics") or {}
            # Prefer take-level counts; fall back to cell statistics count.
            if (mode, "short") not in counts or (
                counts[(mode, "short")]["warm"] == 0 and counts[(mode, "short")]["cold"] == 0
            ):
                n = 0
                for metric in ("submitToFirstChunkMS", "requestToFirstChunkMS", "audioSeconds"):
                    value = stats.get(metric)
                    if isinstance(value, dict) and isinstance(value.get("count"), int):
                        n = max(n, value["count"])
                if n:
                    state = "cold" if "cold" in key else "warm"
                    counts[(mode, "short")][state] += n

    for fixture in fixtures.get("fixtures") or []:
        if fixture.get("id") not in PROMOTED_SHORT:
            continue
        mode = fixture["mode"]
        warm = counts[(mode, "short")]["warm"]
        cold = counts[(mode, "short")]["cold"]
        if warm < min_warm:
            findings.append(
                f"{fixture['id']}: warm takes {warm} < required {min_warm}"
            )
        if mode != "clone" and cold < min_cold:
            findings.append(
                f"{fixture['id']}: cold takes {cold} < required {min_cold}"
            )

    for warning in _fail_closed_warnings(all_takes):
        findings.append(f"fail-closed pressure/warning: {warning}")
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "records",
        nargs="+",
        type=Path,
        help="One or more UI/engine generation benchmark JSON records",
    )
    parser.add_argument("--fixtures", type=Path, default=FIXTURES)
    args = parser.parse_args(argv)
    fixtures = _load(args.fixtures)
    records = [_load(path) for path in args.records]
    findings = evaluate(records, fixtures)
    if findings:
        print("characterization controls: FAIL")
        for item in findings:
            print(f"  - {item}")
        return 1
    print("characterization controls: PASS")
    print(f"  sessions={len(records)}")
    print(f"  fixtures={args.fixtures}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
