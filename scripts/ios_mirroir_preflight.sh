#!/usr/bin/env bash
# mirroir + iPhone Mirroring preflight for agent-driven Vocello iOS UI work.
#
# Usage: scripts/ios_mirroir_preflight.sh [--doctor] [--native-only]
#
# Checks device/mirror readiness, project mirroir config, and vision-bridge calibration.
# Does NOT replace ios_device.sh gate — exploratory QA only.
#
# --native-only  Skip vision-bridge calibrate (Peekaboo fallback not needed this session).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DOCTOR=0
NATIVE_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --doctor) RUN_DOCTOR=1; shift ;;
    --native-only) NATIVE_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[0;32m[ok]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[0;31m[fail]\033[0m %s\n' "$*" >&2; }

note "Vocello iOS mirroir preflight"

PROJECT_MIRROIR="$ROOT_DIR/.mirroir-mcp"
GLOBAL_MIRROIR="$HOME/.mirroir-mcp"

if [[ -f "$PROJECT_MIRROIR/permissions.json" ]]; then
  ok "project permissions.json present"
else
  warn "missing $PROJECT_MIRROIR/permissions.json — mirroir defaults to read-only tools"
fi

if [[ -f "$PROJECT_MIRROIR/settings.json" ]]; then
  ok "project settings.json present (OCR mode)"
else
  warn "missing $PROJECT_MIRROIR/settings.json"
fi

if [[ -f "$GLOBAL_MIRROIR/settings.json" ]]; then
  ok "global ~/.mirroir-mcp/settings.json present"
else
  warn "no ~/.mirroir-mcp/settings.json — English macOS OK; French needs mirroringProcessName override"
fi

# MCP vs shell parity: mirroringProcessName should match between global and repo settings.
_global_name="" _project_name=""
if [[ -f "$GLOBAL_MIRROIR/settings.json" ]]; then
  _global_name="$(python3 -c 'import json; print(json.load(open("'"$GLOBAL_MIRROIR/settings.json"'")).get("mirroringProcessName") or "")' 2>/dev/null || true)"
fi
if [[ -f "$PROJECT_MIRROIR/settings.json" ]]; then
  _project_name="$(python3 -c 'import json; print(json.load(open("'"$PROJECT_MIRROIR/settings.json"'")).get("mirroringProcessName") or "")' 2>/dev/null || true)"
fi
if [[ -n "$_global_name" && -n "$_project_name" ]]; then
  _same="$(GLOBAL="$_global_name" PROJECT="$_project_name" python3 <<'PY'
import os
def norm(s):
    for ch in ("\u2019", "\u2018", "\u02bc", "\u2032"):
        s = s.replace(ch, "'")
    return s
print("1" if norm(os.environ["GLOBAL"]) == norm(os.environ["PROJECT"]) else "0")
PY
)" || _same=0
  if [[ "$_same" != "1" ]]; then
    warn "mirroringProcessName mismatch: global='$_global_name' vs project='$_project_name' — restart Cursor MCP after fixing"
  fi
elif [[ -n "$_project_name" && ! -f "$GLOBAL_MIRROIR/settings.json" ]]; then
  warn "repo has mirroringProcessName='$_project_name' but no ~/.mirroir-mcp/settings.json — copy or merge for mirroir MCP check_health"
fi

if [[ -f "$GLOBAL_MIRROIR/permissions.json" ]] || [[ -f "$PROJECT_MIRROIR/permissions.json" ]]; then
  ok "mirroir mutating tools configured (restart Cursor after first install; expect ~27 tools, not ~11)"
else
  fail "no permissions.json — only ~11 read-only mirroir tools; add .mirroir-mcp/permissions.json"
fi

note "device + mirror (watch probe)"
"$ROOT_DIR/scripts/ios_device.sh" device-state watch --interval 2 --count 3
"$ROOT_DIR/scripts/ios_device.sh" mirror

note "structured probe (--json-v2)"
if json_v2="$("$ROOT_DIR/scripts/ios_device.sh" device-state --json-v2 2>/dev/null || true)"; then
  bounds_line="$(python3 -c '
import json, sys
j = json.load(sys.stdin)
b = (j.get("signals") or {}).get("mirror", {}).get("bounds") or {}
if b.get("w"):
    print("{},{},{},{}".format(int(b.get("x", 0)), int(b.get("y", 0)), int(b.get("w", 0)), int(b.get("h", 0))))
' <<<"$json_v2" 2>/dev/null || true)"
  bounds_h="$(python3 -c 'import json,sys; b=(json.load(sys.stdin).get("signals") or {}).get("mirror",{}).get("bounds") or {}; print(int(b.get("h") or 0))' <<<"$json_v2" 2>/dev/null || echo 0)"
  if [[ -n "$bounds_line" ]]; then
    ok "mirrorBounds: $bounds_line (window origin x,y,w,h — recalibrate vision bridge after move/resize)"
  fi
  if (( bounds_h > 0 && bounds_h < 400 )); then
    warn "mirror window height ${bounds_h}px — very small; OCR tap targets may be tight (min useful ~400px)"
  elif (( bounds_h > 0 && bounds_h < 600 )); then
    ok "mirror bounds height ${bounds_h}px (compact window — coords differ from 326×720 reference; re-OCR)"
  elif (( bounds_h >= 600 )); then
    ok "mirror bounds height ${bounds_h}px"
  fi
fi

if [[ "$NATIVE_ONLY" -eq 1 ]]; then
  note "vision bridge skipped (--native-only; use Peekaboo fallback only if describe_screen fails)"
else
  note "vision bridge (Peekaboo fallback only — prefer mirroir tap when OCR works)"
  "$ROOT_DIR/scripts/lib/ios_vision_bridge.sh" calibrate "$ROOT_DIR/build/ios/vision-bridge.json"
fi

if [[ "$RUN_DOCTOR" -eq 1 ]]; then
  note "mirroir doctor (optional CLI check)"
  if command -v mirroir >/dev/null 2>&1; then
    mirroir doctor || warn "mirroir doctor reported issues"
  elif command -v npx >/dev/null 2>&1; then
    npx -y mirroir-mcp doctor 2>/dev/null || warn "mirroir doctor unavailable via npx"
  else
    warn "mirroir CLI not found — skip or: brew tap jfarcand/tap && brew install mirroir-mcp"
  fi
fi

cat >&2 <<EOF

Next (in Cursor Agent, same macOS Space as iPhone Mirroring):
  1. Restart Cursor if you just added permissions.json or changed mirroringProcessName
  2. mirroir check_health  → must pass (Screen Recording + Accessibility for Cursor.app)
  3. mirroir describe_screen → OCR list with tap coords on Studio/Custom
  4. Native loop: describe_screen → tap / type_text / measure (see ios-agent-ui-tour.md Appendix B.5–B.8)
  5. Multi-clip: B.7 dismiss poll → RESET if no X; B.8 gates before Generate
  6. If describe_screen fails: Allow Screen Recording prompt, same Space as mirror, ios_device.sh mirror
  7. If check_health fails but device-state passes: restart mirroir MCP + verify mirroringProcessName

EOF

ok "preflight complete"
