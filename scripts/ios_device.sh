#!/usr/bin/env bash
# Headless iPhone build/test driver for Vocello — the on-device analog of
# `vocello bench`. Drives a real device over Apple's `devicectl` (CoreDevice): no
# screen mirroring, no UI scripting. This is the durable replacement for the
# deprecated iPhone-Mirroring UI-driving method (see docs/reference/ui-driving.md).
#
# Pairs with IOSAutorunHarness (Sources/iOS/IOSAutorunHarness.swift): `bench`
# launches the app with QVOICE_IOS_AUTORUN set, the in-app harness runs one
# generation with no UI and writes a completion sentinel + telemetry into the
# App-Group container, and this script pulls them back and summarizes.
#
# Privacy: the signing team comes from $QWENVOICE_DEVELOPMENT_TEAM (never hardcoded,
# matching project.yml). The device is auto-discovered, or pinned via
# $QVOICE_IOS_DEVICE_ID — neither is committed.
#
# Usage:
#   scripts/ios_device.sh doctor                  # environment + device preflight
#   scripts/ios_device.sh build                   # signed device build (-Onone)
#   scripts/ios_device.sh install                 # install the built app
#   scripts/ios_device.sh launch [spec]           # launch (with autorun if spec given)
#   scripts/ios_device.sh console [spec]          # attached launch, stream [autorun] stdout live
#   scripts/ios_device.sh pull [dest]             # pull the app-container diagnostics mirror
#   scripts/ios_device.sh bench [spec] [--label "note"]
#                                                 # build→install→autorun→pull→summarize
#
# Autorun spec: <mode>:<variant>:<text> (default custom:speed:<built-in sentence>).
#   mode ∈ custom|design|clone, variant ∈ speed|quality (iPhone is speed-only).
#
# Env:
#   QWENVOICE_DEVELOPMENT_TEAM   (required for build/install) Apple team id
#   QVOICE_IOS_DEVICE_ID         (optional) devicectl device id/name/udid; else auto
#   QVOICE_IOS_BENCH_TIMEOUT     (optional) bench sentinel timeout seconds (default 300)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="VocelloiOS"
CONFIG="Release"
BUNDLE_ID="com.patricedery.vocello"
APP_GROUP="group.com.patricedery.vocello.shared"
# Single shared iOS DerivedData tree: device (iphoneos) + simulator (build-for-testing)
# builds coexist here with one SourcePackages, so iOS build trees don't multiply.
# Swept/reclaimed by scripts/clean_build_caches.sh (--aggressive) + build.sh's prune.
DERIVED="$ROOT_DIR/build/ios"
APP_PATH="$DERIVED/Build/Products/Release-iphoneos/Vocello.app"
PROJECT="$ROOT_DIR/QwenVoice.xcodeproj"

# Reuse the shared storage-bloat advisory (warn-only; never deletes).
. "$ROOT_DIR/scripts/lib/build_cache.sh"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_team() {
  [[ -n "${QWENVOICE_DEVELOPMENT_TEAM:-}" ]] \
    || die "set QWENVOICE_DEVELOPMENT_TEAM=<apple-team-id> first (matches project.yml)"
}

# Resolve the target device id. Prefer $QVOICE_IOS_DEVICE_ID; otherwise auto-pick the
# single connected/paired CoreDevice. Errors with the device list when ambiguous.
resolve_device() {
  if [[ -n "${QVOICE_IOS_DEVICE_ID:-}" ]]; then
    printf '%s' "$QVOICE_IOS_DEVICE_ID"
    return
  fi
  local tmp; tmp="$(mktemp)"
  xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1 \
    || die "devicectl could not list devices (is Xcode 26 installed?)"
  local id
  id="$(python3 - "$tmp" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
devs = (data.get("result") or {}).get("devices") or []
def connected(d):
    cp = d.get("connectionProperties") or {}
    return cp.get("pairingState") == "paired" or cp.get("tunnelState") in ("connected", "available")
cands = [d for d in devs if connected(d)]
if len(cands) == 1:
    print(cands[0].get("identifier", ""))
elif not cands:
    sys.exit(3)
else:
    for d in cands:
        props = d.get("deviceProperties") or {}
        sys.stderr.write(f"  {d.get('identifier')}  {props.get('name','?')}\n")
    sys.exit(4)
PY
)" || {
    local code=$?
    rm -f "$tmp"
    [[ $code -eq 3 ]] && die "no paired iPhone found — connect via USB + trust this Mac, or set QVOICE_IOS_DEVICE_ID"
    [[ $code -eq 4 ]] && die "multiple devices found (above) — set QVOICE_IOS_DEVICE_ID to one"
    die "device discovery failed"
  }
  rm -f "$tmp"
  [[ -n "$id" ]] || die "could not resolve a device id"
  printf '%s' "$id"
}

cmd_doctor() {
  note "Vocello iOS device doctor"
  command -v xcrun >/dev/null || die "xcrun not found (install Xcode)"
  printf '  xcode: %s\n' "$(xcodebuild -version 2>/dev/null | head -1)" >&2
  if [[ -n "${QWENVOICE_DEVELOPMENT_TEAM:-}" ]]; then
    printf '  team:  set (QWENVOICE_DEVELOPMENT_TEAM)\n' >&2
  else
    warn "QWENVOICE_DEVELOPMENT_TEAM is NOT set (required for build/install)"
  fi
  local dev; dev="$(resolve_device)"
  printf '  device: %s\n' "$dev" >&2
  if [[ -d "$APP_PATH" ]]; then
    printf '  app:   built (%s)\n' "$APP_PATH" >&2
    printf '  entitlement: ' >&2
    codesign -d --entitlements :- "$APP_PATH" 2>/dev/null \
      | grep -o 'increased-memory-limit' | head -1 || printf '(not found)\n' >&2
    printf '\n' >&2
  else
    printf '  app:   not built yet (run: %s build)\n' "$0" >&2
  fi
  note "doctor OK"
}

cmd_build() {
  require_team
  local dev; dev="$(resolve_device)"
  note "building $SCHEME ($CONFIG, -Onone) for $dev"
  xcodebuild \
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination "id=$dev" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$QWENVOICE_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    build
  [[ -d "$APP_PATH" ]] || die "build finished but $APP_PATH is missing"
  note "built $APP_PATH"
  warn_if_storage_bloated
}

cmd_install() {
  [[ -d "$APP_PATH" ]] || die "no built app at $APP_PATH (run: $0 build)"
  local dev; dev="$(resolve_device)"
  note "installing on $dev"
  xcrun devicectl device install app --device "$dev" "$APP_PATH"
}

# launch [spec]: with a spec, set the autorun + telemetry env; without, a plain launch.
cmd_launch() {
  local spec="${1:-}"
  local dev; dev="$(resolve_device)"
  if [[ -n "$spec" ]]; then
    local run_id="ios-$(date +%Y%m%d-%H%M%S)"
    note "launching with autorun ($spec), runID=$run_id"
    local env_json
    env_json="$(QV_SPEC="$spec" QV_RUNID="$run_id" python3 -c '
import json, os
print(json.dumps({
    "QWENVOICE_DEBUG": "1",
    "QVOICE_IOS_DEVICE_RUN_ID": os.environ["QV_RUNID"],
    "QVOICE_IOS_AUTORUN": os.environ["QV_SPEC"],
}))')"
    xcrun devicectl device process launch --device "$dev" \
      --terminate-existing -e "$env_json" "$BUNDLE_ID" >&2
    printf '%s\n' "$run_id"   # stdout: ONLY the runID (consumed by bench)
  else
    note "launching $BUNDLE_ID"
    xcrun devicectl device process launch --device "$dev" --terminate-existing "$BUNDLE_ID"
  fi
}

# console [spec]: launch ATTACHED (devicectl --console) with the autorun env and stream
# the app's stdout live (the `[autorun] …` prints). Blocks until the app exits / Ctrl-C.
# Best for diagnosing a failed bench — you watch exactly where the harness gets.
cmd_console() {
  local spec="${1:-custom:speed:Console diagnostic autorun.}"
  [[ "$spec" == *:* ]] || spec="custom:speed:$spec"
  local dev; dev="$(resolve_device)"
  local run_id="ios-console-$(date +%Y%m%d-%H%M%S)"
  note "attached launch ($spec), runID=$run_id — Ctrl-C to detach"
  local env_json
  env_json="$(QV_SPEC="$spec" QV_RUNID="$run_id" python3 -c '
import json, os
print(json.dumps({
    "QWENVOICE_DEBUG": "1",
    "QVOICE_IOS_DEVICE_RUN_ID": os.environ["QV_RUNID"],
    "QVOICE_IOS_AUTORUN": os.environ["QV_SPEC"],
}))')"
  xcrun devicectl device process launch --device "$dev" --console --terminate-existing \
    -e "$env_json" "$BUNDLE_ID"
}

# pull [dest]: copy the diagnostics mirror to dest (default build/ios-diagnostics).
# IMPORTANT: devicectl `copy from` can read the app's OWN data container
# (appDataContainer) but NOT the App-Group container — any App-Group source fails with
# a bogus "File paths cannot contain '..'". So IOSAutorunHarness mirrors the sentinel +
# engine telemetry to Library/Caches/Vocello/diagnostics in the app container, and we
# pull from there. devicectl copies the SOURCE DIR'S CONTENTS into dest.
cmd_pull() {
  local dest="${1:-$ROOT_DIR/build/ios-diagnostics}"
  local dev; dev="$(resolve_device)"
  mkdir -p "$dest"
  note "pulling diagnostics from app container → $dest"
  # 1>&2: keep devicectl chatter off this function's stdout (reserved for the path).
  xcrun devicectl device copy from --device "$dev" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Library/Caches/Vocello/diagnostics" --destination "$dest" 1>&2 \
    || die "could not pull diagnostics (has an autorun happened on THIS installed build?)"
  printf '%s\n' "$dest"
}

cmd_bench() {
  require_team
  local spec="custom:speed:" label=""
  # parse: first non-flag arg = spec; --label "note"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="${2:-}"; shift 2 ;;
      --label=*) label="${1#*=}"; shift ;;
      *) spec="$1"; shift ;;
    esac
  done
  [[ "$spec" == *:* ]] || spec="custom:speed:$spec"   # bare text → custom:speed:<text>

  cmd_build
  cmd_install
  local run_id; run_id="$(cmd_launch "$spec" | tail -1)"

  local timeout="${QVOICE_IOS_BENCH_TIMEOUT:-300}"
  local dest="$ROOT_DIR/build/ios-diagnostics"
  rm -rf "$dest"
  note "waiting for autorun sentinel (runID=$run_id, timeout=${timeout}s)…"
  local waited=0 sentinel=""
  while (( waited < timeout )); do
    sleep 10; waited=$((waited + 10))
    cmd_pull "$dest" >/dev/null 2>&1 || true
    # devicectl nesting varies, so locate the sentinel by name+runID rather than a fixed path.
    sentinel="$(find "$dest" -name autorun-done.json -path "*/${run_id}/*" 2>/dev/null | head -1)"
    if [[ -n "$sentinel" && -f "$sentinel" ]]; then
      note "sentinel found after ${waited}s"
      break
    fi
    note "…still generating (${waited}s)"
  done

  [[ -n "$sentinel" && -f "$sentinel" ]] || die "no sentinel after ${timeout}s — autorun didn't write. Diagnose live with: $0 console \"$spec\""

  # The summarizer reads <dir>/engine/generations.jsonl — find the dir that holds it.
  local diag="$dest"
  local engine_jsonl; engine_jsonl="$(find "$dest" -path '*/engine/generations.jsonl' 2>/dev/null | head -1)"
  [[ -n "$engine_jsonl" ]] && diag="$(dirname "$(dirname "$engine_jsonl")")"

  note "── autorun result ─────────────────────────────"
  # Heredoc (quoted delimiter) so the Python body needs no shell-quote escaping.
  python3 - "$sentinel" <<'PY' >&2 || true
import json, sys
r = json.load(open(sys.argv[1]))
def num(x): return x if isinstance(x, (int, float)) else 0.0
print("  status   :", r.get("status"))
print("  mode     :", r.get("mode"), "/", r.get("variant"))
print("  model    :", r.get("modelID"))
if r.get("status") == "ok":
    print("  audio    : %.2fs   wall %.2fs   rtf %.2f"
          % (num(r.get("durationSeconds")), num(r.get("wallSeconds")), num(r.get("realtimeFactor"))))
    print("  finish   :", r.get("finishReason"))
    print("  out      :", r.get("audioPath"))
else:
    print("  error    :", r.get("error"))
print("  device   :", r.get("deviceModel"), r.get("systemName"), r.get("systemVersion"))
PY

  note "── telemetry summary (engine decode / RTF / audioQC / RAM) ──"
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diag" \
    ${label:+--label "$label"} >&2 || warn "summarizer found no engine rows (was QWENVOICE_DEBUG=1 honored?)"

  # Exit non-zero on a failed generation so CI/automation can gate on it.
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status")=="ok" else 1)' "$sentinel"
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    doctor)  cmd_doctor "$@" ;;
    build)   cmd_build "$@" ;;
    install) cmd_install "$@" ;;
    launch)  cmd_launch "$@" ;;
    console) cmd_console "$@" ;;
    pull)    cmd_pull "$@" ;;
    bench)   cmd_bench "$@" ;;
    help|-h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' >&2 ;;
    *) die "unknown subcommand '$sub' (try: doctor|build|install|launch|console|pull|bench|help)" ;;
  esac
}

main "$@"
