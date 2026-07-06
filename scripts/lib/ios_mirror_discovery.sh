# Shared iPhone Mirroring discovery — bundle ID for process checks, localized display
# name for osascript/Accessibility. Sourced by ios_device_state.sh and ios_device.sh.
#
# shellcheck shell=bash

MIRROR_BUNDLE_ID="com.apple.ScreenContinuity"
MIRROR_APP_DEFAULT="iPhone Mirroring"

# Localized process/display name for osascript (mirroir settings override).
mirror_app_display_name() {
  local settings path name=""
  for path in "${HOME}/.mirroir-mcp/settings.json" "${ROOT_DIR:?}/.mirroir-mcp/settings.json"; do
    [[ -f "$path" ]] || continue
    name="$(python3 - "$path" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("mirroringProcessName") or "")
except Exception:
    print("")
PY
)"
    [[ -n "$name" ]] && break
  done
  if [[ -n "$name" ]]; then
    printf '%s' "$name"
  else
    printf '%s' "$MIRROR_APP_DEFAULT"
  fi
}

mirror_process_running() {
  if ! declare -F device_state_helper >/dev/null 2>&1; then
    return 1
  fi
  local helper
  helper="$(device_state_helper 2>/dev/null)" || return 1
  "$helper" running 2>/dev/null
}

mirror_window_id() {
  if ! declare -F device_state_helper >/dev/null 2>&1; then
    return 1
  fi
  local helper
  helper="$(device_state_helper)" || return 1
  "$helper" window-id 2>/dev/null
}

mirror_window_bounds_json() {
  if ! declare -F device_state_helper >/dev/null 2>&1; then
    return 1
  fi
  local helper
  helper="$(device_state_helper)" || return 1
  "$helper" window-bounds 2>/dev/null
}

mirror_window_rect() {
  local app_name rect
  app_name="$(mirror_app_display_name)"
  rect="$(osascript <<OSA 2>/dev/null || true
tell application "System Events"
  if not (exists process "$app_name") then return ""
  tell process "$app_name"
    if (count of windows) is 0 then return ""
    set p to position of window 1
    set s to size of window 1
    set x to ((item 1 of p) as integer) as text
    set y to ((item 2 of p) as integer) as text
    set w to ((item 1 of s) as integer) as text
    set h to ((item 2 of s) as integer) as text
    return x & "," & y & "," & w & "," & h
  end tell
end tell
OSA
)"
  [[ -n "$rect" ]] && printf '%s' "$rect"
}
