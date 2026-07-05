#!/usr/bin/env bash
# Build the iOS vision bench-ui take manifest (parity with VocelloiOSBenchUITests matrix).
#
# Usage:
#   scripts/lib/ios_vision_bench_matrix.sh emit --modes custom,design,clone \
#       --lengths short,medium,long --warm 3 --run-id ID --out manifest.json

set -euo pipefail

die() { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

cmd_emit() {
  local modes="custom,design,clone" lengths="short,medium,long" warm=3 run_id="" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --modes) modes="${2:-}"; shift 2 ;;
      --modes=*) modes="${1#*=}"; shift ;;
      --lengths) lengths="${2:-}"; shift 2 ;;
      --lengths=*) lengths="${1#*=}"; shift ;;
      --warm) warm="${2:-3}"; shift 2 ;;
      --warm=*) warm="${1#*=}"; shift ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --run-id=*) run_id="${1#*=}"; shift ;;
      --out) out="${2:-}"; shift 2 ;;
      --out=*) out="${1#*=}"; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ -n "$run_id" ]] || die "emit requires --run-id"
  [[ -n "$out" ]] || die "emit requires --out"

  MODES="$modes" LENGTHS="$lengths" WARM="$warm" RUN_ID="$run_id" OUT="$out" python3 <<'PY'
import json, os

modes = [m.strip() for m in os.environ["MODES"].split(",") if m.strip()]
lengths = [l.strip() for l in os.environ["LENGTHS"].split(",") if l.strip()]
warm = max(1, int(os.environ["WARM"]))
run_id = os.environ["RUN_ID"]
out_path = os.environ["OUT"]

corpus = {
    "short": "The train left the station at dawn.",
    "medium": "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast.",
    "long": "The morning train slipped quietly out of the station, carrying a handful of sleepy travelers toward the coast. Outside the fogged windows, pale fields gave way to grey water, and the rhythm of the rails settled into a steady, hypnotic hum. By the time the sun finally broke through, most of the passengers had drifted into an unhurried silence.",
}

def takes_for(mode):
    takes = []
    cold_len = "medium" if "medium" in lengths else (lengths[0] if lengths else None)
    if mode != "clone" and cold_len and cold_len in corpus:
        takes.append({
            "mode": mode,
            "length": cold_len,
            "warmState": "cold",
            "rep": 0,
            "text": corpus[cold_len],
            "forceColdRelaunch": True,
            "timeoutSec": 300,
        })
    for ln in lengths:
        if ln not in corpus:
            continue
        for rep in range(warm):
            takes.append({
                "mode": mode,
                "length": ln,
                "warmState": "warm",
                "rep": rep,
                "text": corpus[ln],
                "forceColdRelaunch": False,
                "timeoutSec": 240,
            })
    return takes

blocks = []
all_takes = []
idx = 0
for mode in modes:
    mode_takes = takes_for(mode)
    if not mode_takes:
        continue
    block = {"mode": mode, "takeIndices": [], "skipCloneIfNoSavedVoice": mode == "clone"}
    for t in mode_takes:
        t["index"] = idx
        t["label"] = f"{t['mode']}/{t['length']}/{t['warmState']}#{t['rep']}"
        all_takes.append(t)
        block["takeIndices"].append(idx)
        idx += 1
    blocks.append(block)

manifest = {
    "runID": run_id,
    "modes": modes,
    "lengths": lengths,
    "warm": warm,
    "takeCount": len(all_takes),
    "blocks": blocks,
    "takes": all_takes,
}
with open(out_path, "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
print(len(all_takes))
PY
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    emit) cmd_emit "$@" ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
      ;;
    *) die "unknown subcommand '$sub' (try: emit|help)" ;;
  esac
}

main "$@"
