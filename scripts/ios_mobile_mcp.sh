#!/usr/bin/env bash
# mobile-mcp / WDA preflight, automation mutex, and bench run comparison for Vocello iOS.
#
# Usage:
#   scripts/ios_mobile_mcp.sh preflight [--strict]
#   scripts/ios_mobile_mcp.sh lock|unlock|mutex-status
#   scripts/ios_mobile_mcp.sh spike-record [--pass|--fail] [--note TEXT]
#   scripts/ios_mobile_mcp.sh compare-bench <xcuitest-dir> <mcp-dir>
#
# See docs/reference/mobile-mcp-ios-evaluation.md

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${QVOICE_IOS_MOBILE_MCP_LOCK:-$ROOT_DIR/build/ios/mobile-mcp-automation.lock}"
WDA_PORT="${QVOICE_IOS_WDA_PORT:-8100}"
SPIKE_DIR="$ROOT_DIR/build/ios/mobile-mcp-spike"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

_ios_mcp_have() {
  command -v "$1" >/dev/null 2>&1 && return 0
  [[ -x "${HOME}/.local/bin/$1" ]] && return 0
  return 1
}

_ios_mcp_ios_bin() {
  if command -v ios >/dev/null 2>&1; then
    command -v ios
  elif [[ -x "${HOME}/.local/bin/ios" ]]; then
    echo "${HOME}/.local/bin/ios"
  fi
}

cmd_preflight() {
  local strict=0
  [[ "${1:-}" == "--strict" ]] && strict=1

  local ok=1
  note "mobile-mcp preflight"

  if _ios_mcp_have mobilecli; then
    note "  mobilecli: $(mobilecli --version 2>/dev/null || mobilecli version 2>/dev/null || echo present)"
  else
    warn "  mobilecli: not installed (npm install -g mobilecli)"
    ok=0
  fi

  if _ios_mcp_have ios; then
    local ios_bin; ios_bin="$(_ios_mcp_ios_bin)"
    note "  go-ios: present ($ios_bin)"
    if "$ios_bin" list 2>/dev/null | head -5 >&2; then
      :
    else
      warn "  go-ios: ios list failed — USB trust / Developer Mode?"
      (( strict )) && ok=0
    fi
  else
    warn "  go-ios (ios): not in PATH — needed for tunnel/forward"
    (( strict )) && ok=0
  fi

  if curl -sf "http://127.0.0.1:${WDA_PORT}/status" >/dev/null 2>&1; then
    note "  WDA: responding on localhost:${WDA_PORT}"
  else
    warn "  WDA: not reachable on localhost:${WDA_PORT}"
    warn "    start: ios tunnel start --userspace (keep open)"
    warn "    start: ios forward ${WDA_PORT} ${WDA_PORT} (keep open)"
    warn "    launch WebDriverAgentRunner (Xcode Test or mobilecli)"
    ok=0
  fi

  if [[ -f "$LOCK_FILE" ]]; then
    warn "  mutex: XCUITest/automation lock ACTIVE ($LOCK_FILE)"
    warn "    finish mobile-mcp work or: scripts/ios_mobile_mcp.sh unlock"
    note "    lock holder: $(cat "$LOCK_FILE" 2>/dev/null || echo unknown)"
  else
    note "  mutex: free"
  fi

  if pgrep -fl "xcodebuild.*VocelloiOSUITests" >/dev/null 2>&1; then
    warn "  xcodebuild UI test appears RUNNING — do not use mobile-mcp concurrently"
    ok=0
  fi

  note "  docs: docs/reference/mobile-mcp-ios-evaluation.md"
  if (( ok == 0 )); then
    if (( strict )); then
      die "mobile-mcp preflight FAILED"
    fi
    warn "mobile-mcp preflight incomplete — fix warnings before bench-ui-mcp"
    return 0
  fi
  note "mobile-mcp preflight OK"
}

cmd_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  if [[ -f "$LOCK_FILE" ]]; then
    die "automation lock already held: $LOCK_FILE ($(cat "$LOCK_FILE"))"
  fi
  printf '%s pid=%s time=%s\n' "mobile-mcp" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$LOCK_FILE"
  note "mobile-mcp lock acquired → $LOCK_FILE"
}

cmd_unlock() {
  if [[ -f "$LOCK_FILE" ]]; then
    rm -f "$LOCK_FILE"
    note "mobile-mcp lock released"
  else
    note "mobile-mcp lock already free"
  fi
}

cmd_mutex_status() {
  if [[ -f "$LOCK_FILE" ]]; then
    cat "$LOCK_FILE"
    exit 0
  fi
  echo "free"
}

cmd_spike_record() {
  local status="pending" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pass) status="pass"; shift ;;
      --fail) status="fail"; shift ;;
      --note) note="${2:-}"; shift 2 ;;
      --note=*) note="${1#*=}"; shift ;;
      *) die "unknown spike-record flag: $1" ;;
    esac
  done
  mkdir -p "$SPIKE_DIR"
  python3 - "$SPIKE_DIR/spike-result.json" "$status" "$note" <<'PY'
import json, sys, datetime
path, status, note = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "recordedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "status": status,
    "note": note,
    "requiredIdentifiers": [
        "rootTab_studio",
        "generateSection_custom",
        "textInput_generateButton",
    ],
}
with open(path, "w") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
print(path)
PY
}

cmd_compare_bench() {
  local baseline="${1:?xcuitest bench dir required}"
  local candidate="${2:?mcp bench dir required}"
  [[ -d "$baseline" ]] || die "baseline dir missing: $baseline"
  [[ -d "$candidate" ]] || die "candidate dir missing: $candidate"

  python3 - "$baseline" "$candidate" <<'PY'
import glob, json, os, sys

def load_rows(root):
    paths = glob.glob(os.path.join(root, "**/engine/generations.jsonl"), recursive=True)
    if not paths:
        paths = glob.glob(os.path.join(root, "../ios-diagnostics/**/engine/generations.jsonl"), recursive=True)
    rows = []
    for p in paths:
        for line in open(p):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows

def summarize(rows):
    out = {}
    for r in rows:
        notes = r.get("notes") or {}
        rid = notes.get("benchRunID", "?")
        mode = r.get("mode", "?")
        chars = notes.get("promptChars") or 0
        bucket = "short" if chars < 70 else ("long" if chars > 220 else "medium")
        warm = r.get("warmState") or notes.get("benchWarmState") or "?"
        key = (rid, mode, bucket, warm)
        qc = (r.get("audioQC") or {}).get("verdict", "-")
        rtf = r.get("realtimeFactor")
        out[key] = {"rtf": rtf, "qc": qc, "id": r.get("generationID")}
    return out

base_dir, cand_dir = sys.argv[1], sys.argv[2]
b = summarize(load_rows(base_dir))
c = summarize(load_rows(cand_dir))
print(f"baseline rows: {len(b)}  candidate rows: {len(c)}")
all_keys = sorted(set(b) | set(c))
fail = 0
for k in all_keys:
    bb, cc = b.get(k), c.get(k)
    if not bb or not cc:
        print(f"MISSING {k} baseline={bool(bb)} candidate={bool(cc)}")
        fail += 1
        continue
    br, cr = bb.get("rtf"), cc.get("rtf")
    if br and cr:
        delta = abs(float(cr) - float(br)) / max(float(br), 1e-6)
        flag = " OK" if delta < 0.15 else " RTF-DELTA"
        if delta >= 0.15:
            fail += 1
        print(f"{k} rtf {br:.3f} vs {cr:.3f}{flag} qc {bb['qc']}/{cc['qc']}")
    else:
        print(f"{k} rtf missing baseline={br} candidate={cr}")
if fail:
    print(f"compare-bench: {fail} issue(s) — review before gate swap")
    sys.exit(1)
print("compare-bench: PASS (RTF within 15% per matched cell)")
PY
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    preflight) cmd_preflight "$@" ;;
    lock) cmd_lock ;;
    unlock) cmd_unlock ;;
    mutex-status) cmd_mutex_status ;;
    spike-record) cmd_spike_record "$@" ;;
    compare-bench) cmd_compare_bench "$@" ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
      ;;
    *) die "unknown subcommand '$sub' (try: preflight|lock|unlock|mutex-status|spike-record|compare-bench|help)" ;;
  esac
}

main "$@"
