#!/usr/bin/env bash
# Helpers for generation perf investigation — build vocello at -Onone or -O and run bench.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
CLI_BUILT="$DERIVED_DATA/Build/Products/Release/vocello"
CLI_LINK="$ROOT_DIR/build/vocello"
RESULTS="$ROOT_DIR/build/perf-investigation"
INV_DATA="$RESULTS/data"
APP_NAME="Vocello"

# Never leave more than one Vocello.app (+ its XPC service) running.
quit_vocello() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x QwenVoiceEngineService >/dev/null 2>&1 || true
  for _ in {1..40}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.25
  done
  for _ in {1..20}; do
    pgrep -x QwenVoiceEngineService >/dev/null 2>&1 || break
    sleep 0.25
  done
}

prepare_inv_data() {
  mkdir -p "$INV_DATA"
  # shellcheck source=lib/test_models.sh
  . "$ROOT_DIR/scripts/lib/test_models.sh"
  test_models_init "$ROOT_DIR"
  link_models_symlink_to_canonical "$INV_DATA/models"
}

build_vocello() {
  local opt="${1:--Onone}"  # -Onone or -O
  local mode="incremental"
  local gcc="0"
  if [[ "$opt" == "-O" ]]; then
    mode="wholemodule"
    gcc="s"
  fi
  echo "==> Building vocello ($opt)..."
  xcodebuild \
    -project "$ROOT_DIR/QwenVoice.xcodeproj" \
    -target VocelloCLI \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -onlyUsePackageVersionsFromResolvedFile \
    -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" \
    SYMROOT="$DERIVED_DATA/Build/Products" \
    OBJROOT="$DERIVED_DATA/Build/Intermediates.noindex" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
    SWIFT_OPTIMIZATION_LEVEL="$opt" \
    SWIFT_COMPILATION_MODE="$mode" \
    GCC_OPTIMIZATION_LEVEL="$gcc" \
    build 2>&1 | tail -5
  ln -sf "$CLI_BUILT" "$CLI_LINK"
  echo "==> vocello ready: $CLI_LINK ($opt)"
}

run_bench() {
  local label="$1"
  local debug="${2:-1}"  # 1 = QWENVOICE_DEBUG=1
  quit_vocello
  prepare_inv_data
  local data_dir="$INV_DATA"
  mkdir -p "$RESULTS"
  local out="$RESULTS/${label}.log"
  echo "==> Bench: $label (debug=$debug, data=$data_dir) → $out"
  if [[ "$debug" == "1" ]]; then
    env QWENVOICE_DEBUG=1 "$CLI_LINK" bench \
      --modes custom --variants speed --lengths medium \
      --warm 3 --label "$label" \
      --data-dir "$data_dir" 2>&1 | tee "$out"
    env QWENVOICE_DEBUG=1 python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" \
      "$data_dir/diagnostics" \
      --ledger-row --label "$label" 2>&1 | tee -a "$RESULTS/ledger-rows.txt"
  else
    "$CLI_LINK" bench \
      --modes custom --variants speed --lengths medium \
      --warm 3 --label "$label" \
      --data-dir "$data_dir" 2>&1 | tee "$out"
    python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" \
      "$data_dir/diagnostics" \
      --ledger-row --label "$label" 2>&1 | tee -a "$RESULTS/ledger-rows.txt"
  fi
}

# Phase 1: wall-clock for one warm Custom Voice medium take (CLI, same engine).
run_app_timed() {
  local label="$1"
  quit_vocello
  prepare_inv_data
  mkdir -p "$RESULTS"
  local out="$RESULTS/${label}-timed.log"
  echo "==> Timed warm gen: $label → $out"
  # One throwaway warmup so the timed take is warm.
  "$CLI_LINK" generate --mode custom --variant speed \
    --text "Warmup for timing." --data-dir "$INV_DATA" >/dev/null 2>&1 || true
  {
    echo "label=$label"
    /usr/bin/time -p "$CLI_LINK" generate --mode custom --variant speed \
      --text "The quick brown fox jumps over the lazy dog near the river bank at dawn." \
      --data-dir "$INV_DATA" 2>&1
  } | tee "$out"
}

run_matrix_head() {
  local sha
  sha=$(git -C "$ROOT_DIR" rev-parse --short HEAD)
  echo "==> HEAD matrix @ $sha"
  ./scripts/perf_investigation.sh build-onone
  ./scripts/perf_investigation.sh bench "HEAD-${sha}-onone-debug" 1
  ./scripts/perf_investigation.sh bench "HEAD-${sha}-onone-nodebug" 0
  ./scripts/perf_investigation.sh build-o
  ./scripts/perf_investigation.sh bench "HEAD-${sha}-O-debug" 1
  ./scripts/perf_investigation.sh bench "HEAD-${sha}-O-nodebug" 0
}

case "${1:-help}" in
  build-onone) build_vocello "-Onone" ;;
  build-o)     build_vocello "-O" ;;
  bench)
    shift
    run_bench "$@"
    ;;
  app-timed)
    shift
    run_app_timed "$@"
    ;;
  matrix-head)
    run_matrix_head
    ;;
  quit)
    quit_vocello
    echo "==> Vocello quit"
    ;;
  *)
    echo "usage: $0 {build-onone|build-o|bench <label> [debug=0|1]|app-timed <label>|matrix-head|quit}"
    exit 1
    ;;
esac
