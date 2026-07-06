# iOS device-state probe — layered fusion of CoreDevice, mirroring process/window,
# and Vision OCR session classification.
#
# Verdicts (exit codes for `ios_device.sh device-state`):
#   MIRROR_ACTIVE        0  — mirroring session live; no interference detected
#   PHONE_IN_USE        10  — user unlocked / is using the iPhone (mirror paused)
#   CALL_ACTIVE         11  — call UI visible on the mirrored screen
#   MIRROR_CONNECTING   12  — mirroring app up but session not established
#   MIRROR_DISCONNECTED 13  — mirroring app/window missing
#   DEVICE_UNREACHABLE  14  — devicectl cannot reach the device at all
#   PROBE_DEGRADED      15  — cannot classify safely (permissions, OCR fail, helper build)
#   DEVICE_LOCKED       16  — advisory: lockState reports locked (OK for bench, not XCUITest)
#
# Sourced by scripts/ios_device.sh. Requires: Screen Recording permission for the
# calling terminal (same as `ios_device.sh shot`), Xcode CLT (swiftc, first run only).

# shellcheck shell=bash

DEVICE_STATE_HELPER_SRC="${ROOT_DIR:?}/scripts/lib/mirror_state_ocr.swift"
DEVICE_STATE_HELPER_BIN="$ROOT_DIR/build/cache/mirror_state_ocr"
DEVICE_STATE_PROBE_PY="${ROOT_DIR}/scripts/lib/ios_coredevice_probe.py"

device_state_helper() {
  if [[ ! -x "$DEVICE_STATE_HELPER_BIN" || "$DEVICE_STATE_HELPER_SRC" -nt "$DEVICE_STATE_HELPER_BIN" ]]; then
    mkdir -p "$(dirname "$DEVICE_STATE_HELPER_BIN")"
    if ! xcrun swiftc -O -o "$DEVICE_STATE_HELPER_BIN" "$DEVICE_STATE_HELPER_SRC" \
        -framework AppKit -framework Vision 2>/dev/null; then
      return 1
    fi
  fi
  printf '%s' "$DEVICE_STATE_HELPER_BIN"
}

. "${ROOT_DIR}/scripts/lib/ios_mirror_discovery.sh"

# Collect session signals (mirror process, window, OCR classify). Sets globals:
#   DS_MIRROR_RUNNING DS_WINDOW_ID DS_SESSION_VERDICT DS_SESSION_DETAIL DS_FRAME_VARIANCE
_device_state_collect_session() {
  DS_MIRROR_RUNNING=0
  DS_WINDOW_ID=""
  DS_SESSION_VERDICT=""
  DS_SESSION_DETAIL=""
  DS_FRAME_VARIANCE=""

  local helper
  if ! helper="$(device_state_helper)"; then
    DS_SESSION_VERDICT="PROBE_DEGRADED"
    DS_SESSION_DETAIL="could not build OCR helper (swiftc missing?)"
    return 0
  fi

  if ! "$helper" running 2>/dev/null; then
    DS_MIRROR_RUNNING=0
    return 0
  fi
  DS_MIRROR_RUNNING=1

  if ! DS_WINDOW_ID="$("$helper" window-id 2>/dev/null)"; then
    DS_SESSION_VERDICT="MIRROR_DISCONNECTED"
    DS_SESSION_DETAIL="Mirroring app running but no window on screen"
    return 0
  fi

  local shot classify_json
  shot="$(mktemp -t mirror-state).png"
  if ! screencapture -x -o -l "$DS_WINDOW_ID" "$shot" 2>/dev/null || [[ ! -s "$shot" ]]; then
    rm -f "$shot"
    DS_SESSION_VERDICT="PROBE_DEGRADED"
    DS_SESSION_DETAIL="screencapture failed (Screen Recording permission?)"
    return 0
  fi

  if ! classify_json="$("$helper" classify "$shot" 2>/dev/null)"; then
    rm -f "$shot"
    DS_SESSION_VERDICT="PROBE_DEGRADED"
    DS_SESSION_DETAIL="OCR classify failed"
    return 0
  fi
  rm -f "$shot"

  DS_SESSION_VERDICT="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("verdict","MIRROR_ACTIVE"))' <<<"$classify_json")"
  DS_FRAME_VARIANCE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("frameVariance",0))' <<<"$classify_json")"
  local kw
  kw="$(python3 -c 'import json,sys; v=json.load(sys.stdin).get("matchedKeyword"); print(v or "")' <<<"$classify_json")"
  if [[ -n "$kw" ]]; then
    DS_SESSION_DETAIL="matched '$kw'"
  else
    DS_SESSION_DETAIL="no interference keywords"
  fi
}

# Fuse layer signals into a verdict|detail line (legacy stdout contract).
_device_state_fuse_verdict() {
  local core_json="$1"
  local reachable
  reachable="$(python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("reachable") else "0")' <<<"$core_json")"

  if [[ "$DS_MIRROR_RUNNING" -eq 0 ]]; then
    if [[ "$reachable" == "0" ]]; then
      printf '%s\n' "DEVICE_UNREACHABLE|iPhone Mirroring not running and devicectl cannot reach device"
      return
    fi
    printf '%s\n' "MIRROR_DISCONNECTED|iPhone Mirroring app is not running (bundle $MIRROR_BUNDLE_ID)"
    return
  fi

  if [[ -n "$DS_SESSION_VERDICT" ]]; then
    printf '%s\n' "${DS_SESSION_VERDICT}|${DS_SESSION_DETAIL}"
    return
  fi

  printf '%s\n' "MIRROR_ACTIVE|no interference keywords"
}

# probe_device_state [device-id] — prints "VERDICT|detail" on stdout.
probe_device_state() {
  local dev="${1:-}"
  local core_json
  core_json="$(python3 "$DEVICE_STATE_PROBE_PY" probe ${dev:+--device "$dev"})"
  _device_state_collect_session
  _device_state_fuse_verdict "$core_json"
}

# Structured JSON probe (v2).
probe_device_state_json() {
  local dev="${1:-}" lane="${2:-xcuitest}"
  local core_json bounds_json classify_json="" shot=""
  core_json="$(python3 "$DEVICE_STATE_PROBE_PY" probe ${dev:+--device "$dev"})"
  _device_state_collect_session

  local line verdict detail
  line="$(_device_state_fuse_verdict "$core_json")"
  verdict="${line%%|*}"
  detail="${line#*|}"

  bounds_json="null"
  if [[ "$DS_MIRROR_RUNNING" -eq 1 ]] && helper="$(device_state_helper 2>/dev/null)"; then
    bounds_json="$("$helper" window-bounds 2>/dev/null || echo null)"
  fi

  local confidence="high"
  if [[ "$verdict" == "PROBE_DEGRADED" ]]; then
    confidence="none"
  elif [[ "$verdict" == "MIRROR_CONNECTING" ]]; then
    confidence="medium"
  fi

  DEVICE_STATE_PROBE_PY="$DEVICE_STATE_PROBE_PY" \
  DEVICE_STATE_VERDICT="$verdict" \
  DEVICE_STATE_DETAIL="$detail" \
  DEVICE_STATE_CONFIDENCE="$confidence" \
  DEVICE_STATE_CORE="$core_json" \
  DEVICE_STATE_BOUNDS="$bounds_json" \
  DEVICE_STATE_FRAME_VARIANCE="${DS_FRAME_VARIANCE:-0}" \
  DEVICE_STATE_SESSION_VERDICT="${DS_SESSION_VERDICT:-}" \
  DEVICE_STATE_MIRROR_RUNNING="${DS_MIRROR_RUNNING:-0}" \
  DEVICE_STATE_WINDOW_ID="${DS_WINDOW_ID:-}" \
  DEVICE_STATE_LANE="$lane" \
  python3 <<'PY'
import json, os, subprocess, sys

verdict = os.environ["DEVICE_STATE_VERDICT"]
detail = os.environ["DEVICE_STATE_DETAIL"]
confidence = os.environ["DEVICE_STATE_CONFIDENCE"]
core = json.loads(os.environ["DEVICE_STATE_CORE"])
bounds_raw = os.environ.get("DEVICE_STATE_BOUNDS", "null")
try:
    bounds = json.loads(bounds_raw) if bounds_raw and bounds_raw != "null" else None
except json.JSONDecodeError:
    bounds = None

lane = os.environ.get("DEVICE_STATE_LANE", "xcuitest")
probe_py = os.environ["DEVICE_STATE_PROBE_PY"]
auto = json.loads(subprocess.check_output(
    [sys.executable, probe_py, "automation", "--lane", lane, "--verdict", verdict,
     "--core-json", json.dumps(core)],
    text=True,
))

advice_map = {
    "MIRROR_ACTIVE": "no interference — safe to run device lanes",
    "PHONE_IN_USE": "you are using the iPhone — lock it and keep it nearby, then re-run",
    "CALL_ACTIVE": "a call is in progress on the iPhone — finish/decline it, then re-run",
    "MIRROR_CONNECTING": "iPhone Mirroring session not established — lock the phone and wait (ios_device.sh mirror)",
    "MIRROR_DISCONNECTED": "iPhone Mirroring is not running — start it (ios_device.sh mirror)",
    "DEVICE_UNREACHABLE": "device unreachable — connect/trust the iPhone and start Mirroring",
    "PROBE_DEGRADED": "probe could not classify safely — grant Screen Recording, same Space as mirror, retry",
    "DEVICE_LOCKED": "device is locked — OK for bench/headless; unlock once for XCUITest attach",
}

out = {
    "verdict": verdict,
    "detail": detail,
    "confidence": confidence,
    "advice": advice_map.get(verdict, "check device and mirroring session"),
    "probeVersion": 2,
    "signals": {
        "coredevice": core,
        "mirror": {
            "processRunning": os.environ.get("DEVICE_STATE_MIRROR_RUNNING") == "1",
            "bundleId": "com.apple.ScreenContinuity",
            "windowId": os.environ.get("DEVICE_STATE_WINDOW_ID") or None,
            "bounds": bounds,
        },
        "session": {
            "ocrVerdict": os.environ.get("DEVICE_STATE_SESSION_VERDICT") or verdict,
            "frameVariance": float(os.environ.get("DEVICE_STATE_FRAME_VARIANCE") or 0),
        },
        "automation": auto,
    },
}
print(json.dumps(out, indent=2))
PY
}

device_state_exit_code() {
  case "$1" in
    MIRROR_ACTIVE)       echo 0 ;;
    PHONE_IN_USE)        echo 10 ;;
    CALL_ACTIVE)         echo 11 ;;
    MIRROR_CONNECTING)   echo 12 ;;
    MIRROR_DISCONNECTED) echo 13 ;;
    DEVICE_UNREACHABLE)  echo 14 ;;
    PROBE_DEGRADED)      echo 15 ;;
    DEVICE_LOCKED)       echo 16 ;;
    *)                   echo 1 ;;
  esac
}

device_state_advice() {
  case "$1" in
    MIRROR_ACTIVE)       echo "no interference — safe to run device lanes" ;;
    PHONE_IN_USE)        echo "you are using the iPhone — lock it and keep it nearby, then re-run" ;;
    CALL_ACTIVE)         echo "a call is in progress on the iPhone — finish/decline it, then re-run" ;;
    MIRROR_CONNECTING)   echo "iPhone Mirroring session not established — lock the phone and wait for the mirror to connect (ios_device.sh mirror)" ;;
    MIRROR_DISCONNECTED) echo "iPhone Mirroring is not running — start it (ios_device.sh mirror)" ;;
    DEVICE_UNREACHABLE)  echo "device unreachable — connect/trust the iPhone and start Mirroring (ios_device.sh mirror)" ;;
    PROBE_DEGRADED)      echo "probe could not classify safely — grant Screen Recording to this terminal, keep mirror in the same Space, then re-run device-state" ;;
    DEVICE_LOCKED)       echo "device is locked — OK for bench/headless; unlock once before XCUITest attach" ;;
  esac
}

# Poll with hysteresis: require 2 consecutive agreeing samples before accepting a change.
probe_device_state_watch() {
  local dev="${1:-}" interval="${2:-2}" count="${3:-3}" lane="${4:-xcuitest}"
  local i verdict last="" stable="" samples=0 final_line=""
  for (( i = 0; i < count; i++ )); do
    final_line="$(probe_device_state "$dev")"
    verdict="${final_line%%|*}"
    if [[ "$verdict" == "$last" ]]; then
      samples=$((samples + 1))
    else
      last="$verdict"
      samples=1
    fi
    if (( samples >= 2 )); then
      stable="$verdict"
    fi
    (( i + 1 < count )) && sleep "$interval"
  done
  printf '%s\n' "$final_line"
  return "$(device_state_exit_code "${final_line%%|*}")"
}

guard_device_state() {
  local allow_connecting=0 dev=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-connecting) allow_connecting=1; shift ;;
      *) dev="$1"; shift ;;
    esac
  done
  local line verdict detail
  line="$(probe_device_state "$dev")"
  verdict="${line%%|*}"
  detail="${line#*|}"
  case "$verdict" in
    MIRROR_ACTIVE) return 0 ;;
    MIRROR_CONNECTING)
      (( allow_connecting )) && return 0
      ;;
  esac
  printf '\033[0;31m[device-state]\033[0m %s — %s (%s)\n' \
    "$verdict" "$(device_state_advice "$verdict")" "$detail" >&2
  return "$(device_state_exit_code "$verdict")"
}
