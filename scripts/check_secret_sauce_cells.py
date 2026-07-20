#!/usr/bin/env python3
"""Evaluate a UI-generation benchmark record against secretSauceCells.

Fail closed on hardTrim / fullUnload / criticalPressure / appMemoryWarning.
softTrim may warn. Required metrics must be present for each mode's short cell.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "config/characterization-fixtures.json"

FAIL_CLOSED_ALIASES = {
    "hardTrim": ("hardTrim", "memory.pressure.hard_trim", "hard_trim"),
    "fullUnload": ("fullUnload", "memory.pressure.full_unload", "full_unload"),
    "criticalPressure": ("criticalPressure", "memory.pressure.critical", "critical"),
    "appMemoryWarning": ("appMemoryWarning", "memory.warning", "app_memory_warning"),
}


def _load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _metric_present(statistics: dict[str, Any], name: str) -> bool:
    value = statistics.get(name)
    if value is None:
        return False
    if isinstance(value, dict):
        return value.get("count", 0) > 0 and value.get("median") is not None
    return True


def _trim_level(cell: dict[str, Any]) -> int:
    level = cell.get("maximumTrimLevel")
    if isinstance(level, int):
        return level
    stats = cell.get("statistics") or {}
    nested = stats.get("maximumTrimLevel")
    if isinstance(nested, dict) and nested.get("max") is not None:
        return int(nested["max"])
    if isinstance(nested, (int, float)):
        return int(nested)
    return 0


def _coerce_warnings(source: Any) -> list[str]:
    found: list[str] = []
    if not isinstance(source, list):
        return found
    for item in source:
        if isinstance(item, str):
            found.append(item)
        elif isinstance(item, dict):
            code = item.get("code") or item.get("id") or item.get("warning")
            if isinstance(code, str):
                found.append(code)
    return found


def _warnings(record: dict[str, Any], cell: dict[str, Any]) -> list[str]:
    found = _coerce_warnings(record.get("warnings"))
    found.extend(_coerce_warnings(cell.get("warnings")))
    mode = cell.get("mode")
    length = cell.get("length")
    for take in record.get("takes") or []:
        if not isinstance(take, dict):
            continue
        if mode and take.get("mode") not in {mode, None}:
            # mode may only live on cell key; keep take if length matches.
            pass
        take_length = take.get("length")
        take_mode = take.get("mode")
        if length and take_length not in {None, length}:
            continue
        if mode and take_mode not in {None, mode}:
            continue
        # Prefer takes that clearly belong to this cell key.
        key = str(take.get("cell") or take.get("key") or "")
        if mode and length and key and f"{mode}/" in key and length not in key:
            continue
        found.extend(_coerce_warnings(take.get("warnings")))
    return found


def _matches_fail_closed(warning: str, token: str) -> bool:
    aliases = FAIL_CLOSED_ALIASES.get(token, (token,))
    lowered = warning.lower()
    return any(alias.lower() in lowered for alias in aliases)


def evaluate(record: dict[str, Any], fixtures: dict[str, Any]) -> list[str]:
    cells = fixtures.get("secretSauceCells") or []
    if not cells:
        return ["characterization fixtures missing secretSauceCells"]

    by_mode = {
        f"{c.get('mode')}/{c.get('length')}": c
        for c in record.get("cells") or []
        if isinstance(c, dict)
    }
    # Also index by mode/variant/length key fragments used in UI records.
    for cell in record.get("cells") or []:
        if not isinstance(cell, dict):
            continue
        key = str(cell.get("key") or "")
        mode = cell.get("mode")
        length = cell.get("length")
        if mode and length:
            by_mode.setdefault(f"{mode}/{length}", cell)
        if mode and "short" in key:
            by_mode.setdefault(f"{mode}/short", cell)

    findings: list[str] = []
    for expected in cells:
        mode = expected["mode"]
        length = expected["length"]
        cell_id = expected["id"]
        matched = by_mode.get(f"{mode}/{length}")
        if matched is None:
            # Prefer warm short cells when both cold and warm exist.
            candidates = [
                c
                for c in record.get("cells") or []
                if isinstance(c, dict)
                and c.get("mode") == mode
                and c.get("length") == length
            ]
            if not candidates:
                findings.append(f"{cell_id}: missing {mode}/{length} cell in record")
                continue
            warm = [c for c in candidates if "warm" in str(c.get("key") or "")]
            matched = warm[0] if warm else candidates[0]

        stats = matched.get("statistics") or {}
        for metric in expected.get("requiredMetrics") or []:
            if not _metric_present(stats, metric):
                # playbackScheduledMS may live on takes or alternate names.
                if metric == "playbackScheduledMS" and _metric_present(
                    stats, "firstChunkToPlaybackScheduledMS"
                ):
                    continue
                if metric == "submitToFirstChunkMS" and (
                    _metric_present(stats, "requestToFirstChunkMS")
                    or _metric_present(stats, "appTTFCMS")
                ):
                    continue
                findings.append(f"{cell_id}: missing required metric {metric}")

        trim = _trim_level(matched)
        # Convention: 0 none, 1 soft, 2 hard, 3 unload (see telemetry docs).
        if trim >= 2 and "hardTrim" in (expected.get("failClosed") or []):
            findings.append(f"{cell_id}: fail-closed hardTrim (maximumTrimLevel={trim})")
        if trim >= 3 and "fullUnload" in (expected.get("failClosed") or []):
            findings.append(f"{cell_id}: fail-closed fullUnload (maximumTrimLevel={trim})")

        warns = _warnings(record, matched)
        for token in expected.get("failClosed") or []:
            if token in {"hardTrim", "fullUnload"}:
                continue  # covered by trim level
            for warning in warns:
                if _matches_fail_closed(warning, token):
                    findings.append(f"{cell_id}: fail-closed {token} via warning {warning!r}")
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", type=Path, help="UI-generation benchmark JSON record")
    parser.add_argument(
        "--fixtures",
        type=Path,
        default=FIXTURES,
        help="characterization fixtures path",
    )
    args = parser.parse_args(argv)
    record = _load_json(args.record)
    fixtures = _load_json(args.fixtures)
    findings = evaluate(record, fixtures)
    if findings:
        print("secret-sauce cells: FAIL")
        for item in findings:
            print(f"  - {item}")
        return 1
    print("secret-sauce cells: PASS")
    print(f"  record={args.record}")
    print(f"  cells={len(fixtures.get('secretSauceCells') or [])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
