#!/usr/bin/env bash
# Simulator UI-review driver for Vocello — the simulator counterpart to
# scripts/ios_device.sh. Builds the iOS app for the iphonesimulator SDK and
# launches it with the FAKE engine (IOSSimulatorTTSEngine) so you can click
# through and screenshot the full UI with no models, no Metal/MLX, no signing.
#
# The app swaps to the fake engine on the simulator at compile time
# (#if targetEnvironment(simulator) in IOSAppBootstrap), and the fake reads seed
# env vars so every surface is populated. This script wires those in + opens the
# Simulator window for review.
#
# Usage:
#   scripts/ios_sim.sh doctor              # Xcode + simulator preflight; software keyboard on
#   scripts/ios_sim.sh build               # build for the simulator (-Onone, unsigned)
#   scripts/ios_sim.sh install             # boot the sim + install the built app
#   scripts/ios_sim.sh run [--preset NAME] [--no-seed] [--rebuild]
#                                          # build→boot→install→launch; opens Simulator
#   scripts/ios_sim.sh shot [path]         # screenshot the booted sim (default build/ios-sim-shot.png)
#   scripts/ios_sim.sh ui-test [--all] [only]
#                                          # default: Smoke+Sheet+DownloadManager+SimGeneration
#
# Seed (read by the fake engine; `run` sets defaults, override via env):
#   QVOICE_SIM_FAKE_MODELS       all|custom|design|clone|<ids>|none  (default: all → "Generate")
#   QVOICE_SIM_SEED_DATA         voices,history                      (default: voices,history)
#   QVOICE_SIM_BACKEND_SCENARIO  success|slow|fail|cancel_mid|clone_missing_ref
#   QVOICE_SIM_DOWNLOAD_SCENARIO success|slow|fail_mid|fail_verify   (default: success)
#   QVOICE_SIM_BACKEND_DELAY_MS  <ms>                                (override generation/download delay)
#   QVOICE_SIM_CLONE_CAPABLE     0|1                                 (force clone mode off/on)
#   --preset studio-seeded|settings-fresh|download-slow|generation-fail
#   --no-seed                    launch clean (empty / onboarding state)
#
# Env:
#   QVOICE_IOS_SIM   (optional) simulator name or UDID to target; else auto-pick
#                    (a booted iPhone, else newest-iOS iPhone, preferring Pro).
#
# No signing / no QWENVOICE_DEVELOPMENT_TEAM needed (simulator). Real-device testing +
# on-device generation live in scripts/ios_device.sh. See
# docs/reference/ios-simulator-ui-review.md (supplementary UI lane; device stays release gate).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="VocelloiOS"
CONFIG="Release"
BUNDLE_ID="com.patricedery.vocello"
# One shared iOS DerivedData tree: device (iphoneos) + simulator (iphonesimulator)
# builds coexist here with one SourcePackages, so iOS build trees don't multiply.
DERIVED="$ROOT_DIR/build/ios"
APP_PATH="$DERIVED/Build/Products/Release-iphonesimulator/Vocello.app"
PROJECT="$ROOT_DIR/QwenVoice.xcodeproj"

# Reuse the shared build helpers (ensure_project_regenerated, warn_if_storage_bloated).
. "$ROOT_DIR/scripts/lib/build_cache.sh"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Resolve the target simulator UDID. Prefer $QVOICE_IOS_SIM (name or UDID); else
# auto-pick from the available iPhone simulators: a booted one, else the newest iOS
# runtime, preferring a Pro model. Prints the chosen sim to stderr, the UDID to stdout.
resolve_sim() {
  local tmp; tmp="$(mktemp)"
  xcrun simctl list devices available --json > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; die "simctl could not list simulators (is Xcode installed?)"; }
  local udid
  udid="$(QVOICE_IOS_SIM="${QVOICE_IOS_SIM:-}" python3 - "$tmp" <<'PY'
import json, os, re, sys
data = json.load(open(sys.argv[1]))
want = os.environ.get("QVOICE_IOS_SIM", "").strip()
cands = []  # (version_tuple, booted, is_pro, name, udid)
for runtime, devs in (data.get("devices") or {}).items():
    if "iOS" not in runtime:
        continue
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    ver = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    for d in (devs or []):
        if not d.get("isAvailable"):
            continue
        name = d.get("name", "")
        if not name.startswith("iPhone"):
            continue
        cands.append((ver, d.get("state") == "Booted", "Pro" in name, name, d.get("udid", "")))
if want:
    for ver, booted, pro, name, udid in cands:
        if udid == want or name == want:
            print(udid); sys.exit(0)
    sys.exit(5)
if not cands:
    sys.exit(3)
booted = [c for c in cands if c[1]]
pool = booted if booted else cands
pool.sort(key=lambda c: (c[0], c[2]), reverse=True)  # newest iOS, then Pro
ver, b, pro, name, udid = pool[0]
sys.stderr.write("  sim: %s (iOS %d.%d)%s\n" % (name, ver[0], ver[1], " [booted]" if b else ""))
print(udid)
PY
)" || {
    local code=$?
    rm -f "$tmp"
    [[ $code -eq 3 ]] && die "no available iPhone simulator found — add one in Xcode (Settings > Components / Window > Devices and Simulators)"
    [[ $code -eq 5 ]] && die "QVOICE_IOS_SIM='${QVOICE_IOS_SIM:-}' matched no available iPhone simulator"
    die "simulator discovery failed"
  }
  rm -f "$tmp"
  [[ -n "$udid" ]] || die "could not resolve a simulator udid"
  printf '%s' "$udid"
}

# Boot the sim (if needed) + open the Simulator window. Disconnect the hardware
# keyboard first so the SOFTWARE keyboard (and the Studio "Done" accessory bar)
# render — this preference is read on the next Simulator launch.
boot_and_show() {
  local udid="$1"
  defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false 2>/dev/null || true
  note "booting simulator [$udid] (if needed)…"
  xcrun simctl boot "$udid" 2>/dev/null || true   # no-op if already booted
  xcrun simctl bootstatus "$udid" >/dev/null 2>&1 || true
  open -a Simulator 2>/dev/null || warn "could not open Simulator.app"
}

cmd_doctor() {
  note "Vocello iOS simulator doctor"
  command -v xcrun >/dev/null || die "xcrun not found (install Xcode)"
  printf '  xcode: %s\n' "$(xcodebuild -version 2>/dev/null | head -1)" >&2
  local udid; udid="$(resolve_sim)"
  printf '  sim udid: %s\n' "$udid" >&2
  if defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false 2>/dev/null; then
    printf '  software keyboard: on (hardware keyboard disconnected — restart Simulator if already open)\n' >&2
  else
    warn "could not set ConnectHardwareKeyboard"
  fi
  if [[ -d "$APP_PATH" ]]; then
    printf '  app:   built (%s)\n' "$APP_PATH" >&2
  else
    printf '  app:   not built yet (run: %s build)\n' "$0" >&2
  fi
  note "doctor OK"
}

# Build the app for the iphonesimulator SDK. Captures the log + greps for the
# explicit success marker (never trusts a wrapped exit code).
cmd_build() {
  ensure_project_regenerated
  local udid; udid="$(resolve_sim)"
  note "building $SCHEME ($CONFIG, -Onone, unsigned) for the simulator"
  mkdir -p "$DERIVED"
  local log="$DERIVED/sim-build.log"
  set +e
  xcodebuild \
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED" -sdk iphonesimulator \
    CODE_SIGNING_ALLOWED=NO SWIFT_OPTIMIZATION_LEVEL=-Onone \
    build 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  grep -q '\*\* BUILD SUCCEEDED \*\*' "$log" \
    || die "no '** BUILD SUCCEEDED **' in the build log ($log)"
  [[ $status -eq 0 ]] || die "xcodebuild exited $status (see $log)"
  [[ -d "$APP_PATH" ]] || die "build finished but $APP_PATH is missing"
  note "built $APP_PATH"
  warn_if_storage_bloated
}

cmd_install() {
  [[ -d "$APP_PATH" ]] || die "no built app at $APP_PATH (run: $0 build)"
  local udid; udid="$(resolve_sim)"
  boot_and_show "$udid"
  note "installing on the simulator [$udid]"
  xcrun simctl install "$udid" "$APP_PATH"
}

# Apply a named launch preset (sets QVOICE_SIM_* for the caller).
_apply_run_preset() {
  local preset="$1"
  case "$preset" in
    studio-seeded)
      export QVOICE_SIM_FAKE_MODELS="${QVOICE_SIM_FAKE_MODELS:-all}"
      export QVOICE_SIM_SEED_DATA="${QVOICE_SIM_SEED_DATA:-voices,history}"
      unset QVOICE_SIM_DOWNLOAD_SCENARIO QVOICE_SIM_BACKEND_SCENARIO
      ;;
    settings-fresh)
      export QVOICE_SIM_FAKE_MODELS=none
      export QVOICE_SIM_SEED_DATA="${QVOICE_SIM_SEED_DATA:-voices,history}"
      unset QVOICE_SIM_DOWNLOAD_SCENARIO QVOICE_SIM_BACKEND_SCENARIO
      ;;
    download-slow)
      export QVOICE_SIM_FAKE_MODELS=none
      export QVOICE_SIM_SEED_DATA="${QVOICE_SIM_SEED_DATA:-voices,history}"
      export QVOICE_SIM_DOWNLOAD_SCENARIO=slow
      export QVOICE_SIM_BACKEND_DELAY_MS="${QVOICE_SIM_BACKEND_DELAY_MS:-8000}"
      unset QVOICE_SIM_BACKEND_SCENARIO
      ;;
    generation-fail)
      export QVOICE_SIM_FAKE_MODELS="${QVOICE_SIM_FAKE_MODELS:-all}"
      export QVOICE_SIM_SEED_DATA="${QVOICE_SIM_SEED_DATA:-voices,history}"
      export QVOICE_SIM_BACKEND_SCENARIO=fail
      unset QVOICE_SIM_DOWNLOAD_SCENARIO
      ;;
    *)
      die "unknown run preset '$preset' (try: studio-seeded|settings-fresh|download-slow|generation-fail)"
      ;;
  esac
}

# run [--preset NAME] [--no-seed] [--rebuild]: build-if-stale → boot → install → launch the app
# with the fake-engine seed env, then open the Simulator window.
cmd_run() {
  local seed=1 rebuild=0 preset=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-seed) seed=0; shift ;;
      --rebuild) rebuild=1; shift ;;
      --preset)
        preset="${2:-}"
        [[ -n "$preset" ]] || die "--preset requires a name"
        shift 2
        ;;
      --preset=*) preset="${1#--preset=}"; shift ;;
      *) warn "ignoring unknown arg '$1'"; shift ;;
    esac
  done

  if [[ -n "$preset" ]]; then
    _apply_run_preset "$preset"
    note "run preset: $preset"
  fi

  if [[ "$rebuild" == "1" || ! -d "$APP_PATH" ]]; then
    cmd_build
  else
    note "using existing build ($APP_PATH) — pass --rebuild to refresh"
  fi

  local udid; udid="$(resolve_sim)"
  boot_and_show "$udid"
  note "installing on the simulator [$udid]"
  xcrun simctl install "$udid" "$APP_PATH"

  # The fake engine reads QVOICE_SIM_* from its environment; simctl forwards child
  # env stripped of the SIMCTL_CHILD_ prefix. Caller-exported QVOICE_SIM_* override.
  local -a child=()
  if [[ "$seed" == "1" ]]; then
    export QVOICE_SIM_FAKE_MODELS="${QVOICE_SIM_FAKE_MODELS:-all}"
    export QVOICE_SIM_SEED_DATA="${QVOICE_SIM_SEED_DATA:-voices,history}"
    local var
    for var in $(compgen -v QVOICE_SIM_); do
      [[ -n "${!var:-}" ]] && child+=( "SIMCTL_CHILD_$var=${!var}" )
    done
    note "launching seeded (models installed, sample voices + history) — override via QVOICE_SIM_* env, or --no-seed"
  else
    note "launching clean (no seed — empty / onboarding state)"
  fi

  if [[ ${#child[@]} -gt 0 ]]; then
    env "${child[@]}" xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" >&2
  else
    xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" >&2
  fi
  note "launched — the Simulator window is open for review (capture with: $0 shot)"
}

cmd_shot() {
  local out="${1:-$ROOT_DIR/build/ios-sim-shot.png}"
  local udid; udid="$(resolve_sim)"
  mkdir -p "$(dirname "$out")"
  xcrun simctl io "$udid" screenshot "$out" \
    || die "screenshot failed (is the simulator booted + the app running? run: $0 run)"
  note "screenshot → $out"
  printf '%s\n' "$out"
}

SIM_UI_TEST_DEFAULT_CLASSES=(
  "VocelloiOSUITests/VocelloiOSSmokeUITests"
  "VocelloiOSUITests/VocelloiOSSheetUITests"
  "VocelloiOSUITests/VocelloiOSDownloadManagerUITests"
  "VocelloiOSUITests/VocelloiOSSimulatorGenerationUITests"
)

ensure_sim_ready() {
  cmd_doctor >/dev/null
  local udid; udid="$(resolve_sim)"
  boot_and_show "$udid"
  note "simulator preflight OK on [$udid] — software keyboard enabled for Studio typing tests"
}

_sim_test_build_for_testing() {
  local udid="$1"
  ensure_project_regenerated
  note "building $SCHEME + VocelloiOSUITests for simulator testing"
  mkdir -p "$DERIVED"
  local log="$DERIVED/sim-uitest-build.log"
  set +e
  xcodebuild build-for-testing \
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED" -sdk iphonesimulator \
    CODE_SIGNING_ALLOWED=NO SWIFT_OPTIMIZATION_LEVEL=-Onone \
    2>&1 | tee "$log"
  local st=${PIPESTATUS[0]}; set -e
  [[ $st -eq 0 ]] || die "build-for-testing failed (see $log)"
  [[ -d "$APP_PATH" ]] || die "build-for-testing finished but $APP_PATH is missing"
}

_sim_test_latest_xcresult() {
  find "$DERIVED/Logs/Test" -name '*.xcresult' -type d 2>/dev/null | sort | tail -1
}

_run_sim_ui_test_once() {
  local udid="$1"
  local log="$2"
  shift 2
  local -a only_args=( "$@" )
  set +e
  if [[ -s "$log" ]]; then
    xcodebuild test-without-building \
      -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$DERIVED" \
      ${only_args[@]+"${only_args[@]}"} \
      2>&1 | tee -a "$log"
  else
    xcodebuild test-without-building \
      -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$DERIVED" \
      ${only_args[@]+"${only_args[@]}"} \
      2>&1 | tee "$log"
  fi
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

# ui-test [--all] [only]: run VocelloiOSUITests on the simulator (unsigned fake backend).
cmd_ui_test() {
  local scope="default"
  local only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) scope="all"; shift ;;
      -*) die "unknown ui-test flag: $1 (try --all or a VocelloiOSUITests/… target)" ;;
      *) only="$1"; shift ;;
    esac
  done

  ensure_sim_ready
  local udid; udid="$(resolve_sim)"
  note "running VocelloiOSUITests on simulator [$udid] (scope: ${only:-$scope})"
  mkdir -p "$DERIVED"
  export UI_TEST_SCREENSHOT_DIR="$DERIVED/uitest-screenshots"
  local log="$DERIVED/sim-uitest.log"

  _sim_test_build_for_testing "$udid"
  note "installing host app before XCUITest attach"
  xcrun simctl install "$udid" "$APP_PATH"

  local all_ok=1
  local status=0
  local -a run_targets=()
  if [[ -n "$only" ]]; then
    run_targets=( "$only" )
  elif [[ "$scope" == "default" ]]; then
    run_targets=( "${SIM_UI_TEST_DEFAULT_CLASSES[@]}" )
  else
    run_targets=( "" )
  fi

  : >"$log"
  if ((${#run_targets[@]} == 0)); then
    set +e
    _run_sim_ui_test_once "$udid" "$log"
    status=$?
    set -e
    (( status != 0 )) && all_ok=0
  else
    local target
    for target in "${run_targets[@]}"; do
      note "ui-test class: $target"
      set +e
      _run_sim_ui_test_once "$udid" "$log" -only-testing:"$target"
      local one=$?
      set -e
      if (( one != 0 )); then
        all_ok=0
        status=$one
        break
      fi
    done
  fi

  # Xcode 26 emits '** TEST EXECUTE SUCCEEDED **' for test-without-building;
  # older versions emitted '** TEST SUCCEEDED **'. Accept either.
  if (( all_ok == 1 )) && grep -qE '\*\* TEST (EXECUTE )?SUCCEEDED \*\*' "$log"; then
    note "simulator UI tests PASSED"
    return 0
  fi

  local xcresult; xcresult="$(_sim_test_latest_xcresult || true)"
  [[ -n "$xcresult" ]] && warn "xcresult bundle: $xcresult"
  warn "ui-test log: $log"
  [[ -d "$UI_TEST_SCREENSHOT_DIR" ]] && warn "screenshots: $UI_TEST_SCREENSHOT_DIR"
  die "simulator UI tests did not report TEST SUCCEEDED (exit ${status:-1}; see $log)"
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    doctor)   cmd_doctor "$@" ;;
    build)    cmd_build "$@" ;;
    install)  cmd_install "$@" ;;
    run)      cmd_run "$@" ;;
    shot)     cmd_shot "$@" ;;
    ui-test)  cmd_ui_test "$@" ;;
    help|-h|--help)
      sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//' >&2 ;;
    *) die "unknown subcommand '$sub' (try: doctor|build|install|run|shot|ui-test|help)" ;;
  esac
}

main "$@"
