# iPhone Mirroring process discovery for interference detection only.
# Uses the stable bundle identity plus known localized executable names. No user configuration,
# window inspection, screenshot capture, or input driving is permitted here.

# shellcheck shell=bash

MIRROR_BUNDLE_ID="com.apple.ScreenContinuity"

mirror_process_running() {
  [[ -n "$(/usr/bin/lsappinfo find "bundleid=$MIRROR_BUNDLE_ID" 2>/dev/null)" ]] && return 0
  local candidate
  for candidate in "iPhone Mirroring" "Recopie de l’iPhone" "Recopie de l'iPhone"; do
    pgrep -x "$candidate" >/dev/null 2>&1 && return 0
  done
  return 1
}
