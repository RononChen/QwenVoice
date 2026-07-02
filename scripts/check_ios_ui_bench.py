#!/usr/bin/env python3
"""Gate the iOS UI-driven bench (scripts/ios_device.sh bench-ui).

Validates the pulled engine telemetry for one bench-ui run:
  - at least --expected rows stamped with notes.benchRunID == --run-id
    (the expected count comes from the test's VOCELLO-BENCH-UI-MANIFEST line,
    so clone cells skipped for a missing saved voice are accounted for);
  - no row's audioQC verdict is a hard fail;
  - prints a per-cell summary (mode x length-bucket x recorded warm state).

iOS runs the engine in-process, so unlike the macOS XPC gate there is exactly
one telemetry layer (engine) — no service/app row reconciliation.
"""

import argparse
import json
import os
import sys


def len_bucket(chars: int) -> str:
    # Mirrors BenchMatrixSpec.lenBucket / summarize_generation_telemetry.py.
    if chars == 0:
        return "n/a"
    return "short" if chars < 70 else ("long" if chars > 220 else "medium")


def qc_verdict(row: dict) -> str:
    qc = row.get("audioQC")
    if not isinstance(qc, dict):
        return "-"
    verdict = qc.get("verdict")
    if isinstance(verdict, str):
        return verdict
    flags = qc.get("flags")
    if isinstance(flags, list) and flags:
        return "fail:" + ",".join(str(f) for f in flags)
    return "pass"


def main() -> int:
    parser = argparse.ArgumentParser(description="Gate iOS UI-driven bench telemetry")
    parser.add_argument("diag", help="pulled diagnostics dir (contains engine/generations.jsonl)")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--expected", type=int, required=True,
                        help="take count from the test's manifest line")
    args = parser.parse_args()

    engine_path = os.path.join(args.diag, "engine", "generations.jsonl")
    if not os.path.isfile(engine_path):
        print(f"FAIL: {engine_path} not found", file=sys.stderr)
        return 1

    rows = []
    with open(engine_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            notes = row.get("notes") or {}
            if notes.get("benchRunID") == args.run_id:
                rows.append(row)

    failures = []
    if len(rows) < args.expected:
        failures.append(f"engine rows {len(rows)} < expected {args.expected} for runID {args.run_id}")

    cells: dict[tuple, list] = {}
    qc_fail_rows = []
    for row in rows:
        chars = (row.get("notes") or {}).get("promptChars") or 0
        key = (row.get("mode") or "?", len_bucket(int(chars)), row.get("warmState") or "?")
        cells.setdefault(key, []).append(row)
        verdict = qc_verdict(row)
        if verdict.startswith("fail"):
            qc_fail_rows.append((key, row.get("generationID"), verdict))

    for key, gen_id, verdict in qc_fail_rows:
        failures.append(f"audioQC {verdict} in cell {'/'.join(key)} ({gen_id})")

    print(f"iOS UI bench gate: runID={args.run_id} expected={args.expected} engine={len(rows)}")
    for key in sorted(cells):
        verdicts = {qc_verdict(r) for r in cells[key]}
        print(f"  {key[0]:<8} {key[1]:<7} {key[2]:<5} n={len(cells[key])}  QC={','.join(sorted(verdicts))}")

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
