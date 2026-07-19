#!/usr/bin/env python3
"""Fail fast when a governed heavy lane lacks safe working disk space."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys
from typing import Any


GIB = 1024**3


class PreflightError(ValueError):
    pass


def load_contract(root: Path) -> dict[str, dict[str, Any]]:
    manifest = root / "config" / "build-output-policy.json"
    try:
        document = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PreflightError(f"cannot read build-output policy: {error}") from error
    contract = document.get("heavyLanePreflight")
    if not isinstance(contract, dict) or contract.get("schemaVersion") != 1:
        raise PreflightError("heavyLanePreflight must be a schema-v1 object")
    lanes = contract.get("lanes")
    if not isinstance(lanes, dict) or not lanes:
        raise PreflightError("heavyLanePreflight.lanes must be a non-empty object")
    return lanes


def check_lane(
    *, root: Path, lane: str, available_bytes: int | None = None
) -> dict[str, Any]:
    root = root.expanduser().resolve()
    if not root.is_dir():
        raise PreflightError(f"repository root does not exist: {root}")
    lanes = load_contract(root)
    lane_contract = lanes.get(lane)
    if not isinstance(lane_contract, dict):
        raise PreflightError(f"unknown heavy-lane storage contract: {lane}")
    required = lane_contract.get("requiredFreeBytes")
    cleanup_hint = lane_contract.get("cleanupHint")
    if (
        not isinstance(required, int)
        or isinstance(required, bool)
        or required < GIB
        or not isinstance(cleanup_hint, str)
        or not cleanup_hint.startswith("scripts/clean_build_caches.sh ")
    ):
        raise PreflightError(f"invalid heavy-lane storage contract: {lane}")
    available = shutil.disk_usage(root).free if available_bytes is None else available_bytes
    if not isinstance(available, int) or isinstance(available, bool) or available < 0:
        raise PreflightError("available bytes must be a non-negative integer")
    return {
        "schemaVersion": 1,
        "lane": lane,
        "availableBytes": available,
        "requiredBytes": required,
        "ready": available >= required,
        "cleanupHint": cleanup_hint,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("check",))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--lane", required=True)
    parser.add_argument("--available-bytes", type=int)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = check_lane(
            root=args.root, lane=args.lane, available_bytes=args.available_bytes
        )
    except PreflightError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.json or result["ready"]:
        print(json.dumps(result, sort_keys=True))
    if result["ready"]:
        return 0
    print(
        f"error: insufficient free disk space for {result['lane']}: "
        f"{result['availableBytes'] / GIB:.2f} GiB available; "
        f"{result['requiredBytes'] / GIB:.0f} GiB required.\n"
        "Inspect governed storage first:\n"
        "  python3 scripts/build_output_policy.py status\n"
        "Then run the bounded suggested cleanup:\n"
        f"  {result['cleanupHint']}",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
