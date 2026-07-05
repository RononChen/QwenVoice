#!/usr/bin/env bash
# Wait for one vision bench-ui take to land in pulled engine telemetry.
#
# Usage:
#   scripts/lib/ios_vision_bench_wait.sh --run-id ID --since ISO8601 [--timeout 240] [--pull-root DIR]
#
# Polls ios_device.sh pull and counts rows in engine/generations.jsonl where notes.benchRunID == run-id
# with createdAt after --since (or row count increase when --expected-count is set).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

cmd_wait() {
  local run_id="" since="" timeout=240 pull_root="" expected_count=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id) run_id="${2:-}"; shift 2 ;;
      --run-id=*) run_id="${1#*=}"; shift ;;
      --since) since="${2:-}"; shift 2 ;;
      --since=*) since="${1#*=}"; shift ;;
      --timeout) timeout="${2:-240}"; shift 2 ;;
      --timeout=*) timeout="${1#*=}"; shift ;;
      --pull-root) pull_root="${2:-}"; shift 2 ;;
      --pull-root=*) pull_root="${1#*=}"; shift ;;
      --expected-count) expected_count="${2:-}"; shift 2 ;;
      --expected-count=*) expected_count="${1#*=}"; shift ;;
      *) die "unknown arg: $1" ;;
    esac
  done
  [[ -n "$run_id" ]] || die "--run-id required"
  [[ -n "$since" ]] || die "--since required (capture before tapping Generate)"

  pull_root="${pull_root:-$ROOT_DIR/build/ios-diagnostics}"
  local interval=10 waited=0
  note "vision-bench-wait: runID=$run_id since=$since timeout=${timeout}s"

  while (( waited < timeout )); do
    "$ROOT_DIR/scripts/ios_device.sh" pull "$pull_root" >/dev/null 2>&1 || true
    local engine_jsonl
    engine_jsonl="$(find "$pull_root" -path '*/engine/generations.jsonl' 2>/dev/null | head -1)"
    if [[ -n "$engine_jsonl" && -f "$engine_jsonl" ]]; then
      local result
      result="$(RUN_ID="$run_id" SINCE="$since" EXPECTED="$expected_count" ENGINE="$engine_jsonl" python3 <<'PY'
import json, os, sys

run_id = os.environ["RUN_ID"]
since = os.environ.get("SINCE", "")
expected = os.environ.get("EXPECTED", "")
path = os.environ["ENGINE"]

rows = []
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        notes = row.get("notes") or {}
        if notes.get("benchRunID") != run_id:
            continue
        rows.append(row)

if expected:
    try:
        need = int(expected)
    except ValueError:
        need = 0
    if len(rows) >= need > 0:
        row = rows[-1]
        qc = row.get("audioQC") or {}
        verdict = qc.get("verdict", "pass")
        if isinstance(verdict, str) and verdict.startswith("fail"):
            print(f"fail qc={verdict} id={row.get('generationID')}")
            sys.exit(1)
        print(f"ok count={len(rows)} id={row.get('generationID')}")
        sys.exit(0)
    print(f"pending count={len(rows)} need={need}")
    sys.exit(2)

# Prefer rows whose notes include a completed generation (audioQC or generationID).
for row in reversed(rows):
    ts = row.get("createdAt") or row.get("timestamp") or row.get("startedAt") or ""
    since_ok = (not since) or (ts and ts >= since) or len(rows) == 1
    if not since_ok and since:
        continue
    if row.get("generationID") or row.get("audioQC"):
        qc = row.get("audioQC") or {}
        verdict = qc.get("verdict", "pass")
        if isinstance(verdict, str) and verdict.startswith("fail"):
            print(f"fail qc={verdict} id={row.get('generationID')}")
            sys.exit(1)
        print(f"ok id={row.get('generationID')} mode={row.get('mode')}")
        sys.exit(0)

print(f"pending rows={len(rows)}")
sys.exit(2)
PY
)" || true
      case "${result%% *}" in
        ok)
          note "vision-bench-wait: ${result#ok }"
          return 0
          ;;
        fail)
          die "generation failed: ${result#fail }"
          ;;
      esac
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  die "vision-bench-wait timed out after ${timeout}s (runID=$run_id)"
}

main() {
  local sub="${1:-wait}"; shift || true
  case "$sub" in
    wait|"") cmd_wait "$@" ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
      ;;
    *) die "unknown subcommand (try: wait|help)" ;;
  esac
}

main "$@"
