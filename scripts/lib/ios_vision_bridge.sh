#!/usr/bin/env bash
# Coordinate bridge: mirroir describe_screen (window-relative) → Peekaboo/global screen pixels.
#
# Usage:
#   scripts/lib/ios_vision_bridge.sh calibrate [out.json]
#   scripts/lib/ios_vision_bridge.sh to-global <localX> <localY>
#   scripts/lib/ios_vision_bridge.sh mirror-app-name
#   scripts/lib/ios_vision_bridge.sh bridge-path
#
# Calibration uses macOS Accessibility (System Events) — same window rect as ios_device.sh shot.
# Agents: run calibrate once per session, then mirroir describe_screen → to-global → Peekaboo click.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRIDGE_DEFAULT="$ROOT_DIR/build/ios/vision-bridge.json"
. "$ROOT_DIR/scripts/lib/ios_mirror_discovery.sh"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

ios_vision_mirror_app_name() {
  mirror_app_display_name
}

ios_vision_window_rect() {
  mirror_window_rect
}

cmd_calibrate() {
  local out="${1:-$BRIDGE_DEFAULT}"
  local app_name
  app_name="$(ios_vision_mirror_app_name)"
  open -a "$app_name" >/dev/null 2>&1 || true
  osascript -e "tell application \"$app_name\" to activate" >/dev/null 2>&1 || true
  sleep 0.6

  local rect
  rect="$(ios_vision_window_rect)"
  [[ -n "$rect" ]] || die "could not read Mirroring window for '$app_name' — run: scripts/ios_device.sh mirror"

  mkdir -p "$(dirname "$out")"
  python3 - "$out" "$app_name" "$rect" <<'PY'
import json, sys, datetime

out, app, rect = sys.argv[1], sys.argv[2], sys.argv[3]
x, y, w, h = (int(v) for v in rect.split(","))
# Optional content inset if mirroir coords exclude window chrome (tune via env at calibrate time).
off_x = int(__import__("os").environ.get("QVOICE_IOS_VISION_CONTENT_OFFSET_X", "0"))
off_y = int(__import__("os").environ.get("QVOICE_IOS_VISION_CONTENT_OFFSET_Y", "0"))
payload = {
    "calibratedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mirroringAppName": app,
    "originX": x + off_x,
    "originY": y + off_y,
    "width": w,
    "height": h,
    "windowOriginX": x,
    "windowOriginY": y,
    "contentOffsetX": off_x,
    "contentOffsetY": off_y,
}
with open(out, "w") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
print(out)
PY
  note "vision bridge calibrated → $out (app=$app_name rect=$rect)"
}

cmd_to_global() {
  local local_x="${1:?local X required}"
  local local_y="${2:?local Y required}"
  local bridge="${QVOICE_IOS_VISION_BRIDGE:-$BRIDGE_DEFAULT}"
  [[ -f "$bridge" ]] || die "no bridge file at $bridge — run: scripts/lib/ios_vision_bridge.sh calibrate"
  python3 - "$bridge" "$local_x" "$local_y" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
lx, ly = float(sys.argv[2]), float(sys.argv[3])
gx = int(round(data["originX"] + lx))
gy = int(round(data["originY"] + ly))
print(f"{gx},{gy}")
PY
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    calibrate) cmd_calibrate "${1:-}" ;;
    to-global) cmd_to_global "${1:?}" "${2:?}" ;;
    mirror-app-name) ios_vision_mirror_app_name ;;
    bridge-path) printf '%s\n' "${QVOICE_IOS_VISION_BRIDGE:-$BRIDGE_DEFAULT}" ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
      ;;
    *) die "unknown subcommand '$sub' (try: calibrate|to-global|mirror-app-name|bridge-path|help)" ;;
  esac
}

main "$@"
