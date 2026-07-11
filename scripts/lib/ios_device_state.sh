# iOS physical-device and iPhone Mirroring readiness probe.
# Bundled Computer Use drives every UI lane through the mirrored physical device.
#
# Verdicts:
#   READY                0  — CoreDevice reachable; required mirroring state is ready
#   MIRROR_UNAVAILABLE  10  — iPhone Mirroring is required for the selected UI lane
#   DEVICE_UNREACHABLE  14  — devicectl cannot reach the paired device

# shellcheck shell=bash

DEVICE_STATE_PROBE_PY="${ROOT_DIR:?}/scripts/lib/ios_coredevice_probe.py"
. "${ROOT_DIR}/scripts/lib/ios_mirror_discovery.sh"

_device_state_fuse_verdict() {
  local core_json="$1" lane="${2:-computer-use}"
  local reachable
  reachable="$(python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("reachable") else "0")' <<<"$core_json")"

  if [[ "$reachable" != "1" ]]; then
    printf '%s\n' "DEVICE_UNREACHABLE|connect and trust the paired iPhone"
  elif [[ "$lane" == "computer-use" ]] && ! mirror_process_running 2>/dev/null; then
    printf '%s\n' "MIRROR_UNAVAILABLE|open iPhone Mirroring for bundled Computer Use"
  else
    printf '%s\n' "READY|physical device and selected UI lane are ready"
  fi
}

probe_device_state() {
  local dev="${1:-}" lane="${2:-computer-use}" core_json
  core_json="$(python3 "$DEVICE_STATE_PROBE_PY" probe ${dev:+--device "$dev"})"
  _device_state_fuse_verdict "$core_json" "$lane"
}

probe_device_state_json() {
  local dev="${1:-}" lane="${2:-computer-use}" core_json line verdict detail mirror=0
  core_json="$(python3 "$DEVICE_STATE_PROBE_PY" probe ${dev:+--device "$dev"})"
  mirror_process_running 2>/dev/null && mirror=1
  line="$(_device_state_fuse_verdict "$core_json" "$lane")"
  verdict="${line%%|*}"
  detail="${line#*|}"
  DEVICE_STATE_CORE="$core_json" DEVICE_STATE_VERDICT="$verdict" \
  DEVICE_STATE_DETAIL="$detail" DEVICE_STATE_MIRROR="$mirror" DEVICE_STATE_LANE="$lane" \
  python3 <<'PY'
import json, os
core = json.loads(os.environ["DEVICE_STATE_CORE"])
verdict = os.environ["DEVICE_STATE_VERDICT"]
detail = os.environ["DEVICE_STATE_DETAIL"]
out = {
    "verdict": verdict,
    "detail": detail,
    "confidence": "high",
    "advice": {
        "READY": "safe to run the selected physical-device lane",
        "MIRROR_UNAVAILABLE": "open iPhone Mirroring for bundled Computer Use",
        "DEVICE_UNREACHABLE": "connect, trust, and unlock the paired iPhone",
    }.get(verdict, "check the paired physical device"),
    "probeVersion": 3,
    "signals": {
        "coredevice": core,
        "mirror": {
            "processRunning": os.environ.get("DEVICE_STATE_MIRROR") == "1",
            "bundleId": "com.apple.ScreenContinuity",
            "purpose": "bundled-computer-use-ui-surface",
        },
        "automation": {
            "readyForAutomation": verdict == "READY",
            "blockers": [] if verdict == "READY" else [verdict.lower()],
        },
    },
}
print(json.dumps(out, indent=2))
PY
}

device_state_exit_code() {
  case "$1" in
    READY) echo 0 ;;
    MIRROR_UNAVAILABLE) echo 10 ;;
    DEVICE_UNREACHABLE) echo 14 ;;
    *) echo 1 ;;
  esac
}

device_state_advice() {
  case "$1" in
    READY) echo "safe to run physical-device automation" ;;
    MIRROR_UNAVAILABLE) echo "open iPhone Mirroring for bundled Computer Use" ;;
    DEVICE_UNREACHABLE) echo "connect, trust, and unlock the paired iPhone" ;;
  esac
}

probe_device_state_watch() {
  local dev="${1:-}" interval="${2:-2}" count="${3:-3}" lane="${4:-computer-use}"
  local i verdict last="" samples=0 final_line=""
  for (( i = 0; i < count; i++ )); do
    final_line="$(probe_device_state "$dev" "$lane")"
    verdict="${final_line%%|*}"
    if [[ "$verdict" == "$last" ]]; then samples=$((samples + 1)); else last="$verdict"; samples=1; fi
    (( i + 1 < count )) && sleep "$interval"
  done
  printf '%s\n' "$final_line"
  (( samples >= 2 )) || return 1
  return "$(device_state_exit_code "$verdict")"
}

guard_device_state() {
  local dev="${1:-}" lane="${2:-computer-use}" line verdict
  line="$(probe_device_state "$dev" "$lane")"
  verdict="${line%%|*}"
  [[ "$verdict" == "READY" ]] && return 0
  printf '\033[0;31m[device-state]\033[0m %s — %s (%s)\n' \
    "$verdict" "$(device_state_advice "$verdict")" "${line#*|}" >&2
  return "$(device_state_exit_code "$verdict")"
}
