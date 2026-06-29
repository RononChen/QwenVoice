#!/usr/bin/env bash
# Floor-tier macOS frontend status capture — one Vocello instance at a time.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Vocello"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
OUT="$ROOT_DIR/build/frontend-audit"
LOG_PREDICATE='subsystem == "com.qwenvoice.app"'

quit_vocello() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x QwenVoiceEngineService >/dev/null 2>&1 || true
  for _ in {1..40}; do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.25; done
}

launch_app_with_env() {
  quit_vocello
  local -a env_vars=("$@")
  env "${env_vars[@]}" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" &
  for _ in {1..40}; do pgrep -x "$APP_NAME" >/dev/null 2>&1 && return 0; sleep 0.25; done
  echo "error: $APP_NAME did not launch" >&2
  exit 1
}

service_state() {
  if pgrep -x QwenVoiceEngineService >/dev/null 2>&1; then
    echo "service=running pid=$(pgrep -xn QwenVoiceEngineService)"
  else
    echo "service=absent"
  fi
}

capture_run() {
  local label="$1"
  shift
  local env_vars=("$@")
  mkdir -p "$OUT"
  local log="$OUT/${label}.log"
  local meta="$OUT/${label}-meta.txt"
  quit_vocello
  echo "==> Capture $label → $log"
  {
    echo "label=$label"
    echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "env=${env_vars[*]:-none}"
  } > "$meta"
  # Stream logs in background for the capture window.
  /usr/bin/log stream --info --style compact --predicate "$LOG_PREDICATE" > "$log" 2>&1 &
  local logpid=$!
  launch_app_with_env "${env_vars[@]}"
  echo "$(date +%H:%M:%S) after_launch $(service_state)" >> "$meta"
  sleep 15
  echo "$(date +%H:%M:%S) t15s $(service_state)" >> "$meta"
  sleep 30
  echo "$(date +%H:%M:%S) t45s $(service_state)" >> "$meta"
  sleep 45
  echo "$(date +%H:%M:%S) t90s $(service_state)" >> "$meta"
  quit_vocello
  sleep 2
  echo "$(date +%H:%M:%S) after_quit $(service_state)" >> "$meta"
  kill "$logpid" 2>/dev/null || true
  wait "$logpid" 2>/dev/null || true
  # Summarize log keywords
  {
    echo "--- keyword counts ---"
    rg -c 'warm|Warm|prewarm|idle.?unload|retire|Reconnect|starting|loadState' "$log" 2>/dev/null || true
    echo "--- retire/idle lines (last 20) ---"
    rg -i 'retire|idle.?unload|engine_service|warmup|prewarm' "$log" 2>/dev/null | tail -20 || true
  } >> "$meta"
  echo "==> Done $label"
}

capture_xpc_retire() {
  local label="runC-xpc-retire"
  mkdir -p "$OUT"
  local log="$OUT/${label}.log"
  local meta="$OUT/${label}-meta.txt"
  quit_vocello
  echo "==> Capture $label (fast retirement dwell=8s)"
  {
    echo "label=$label"
    echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$meta"
  /usr/bin/log stream --info --style compact --predicate "$LOG_PREDICATE" > "$log" 2>&1 &
  local logpid=$!
  launch_app_with_env \
    QWENVOICE_DEBUG=1 \
    QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac \
    QWENVOICE_ENGINE_RETIRE_DWELL_SECONDS=8
  echo "$(date +%H:%M:%S) launch $(service_state)" >> "$meta"
  # Wait for proactive warmup to spawn service on floor tier.
  for i in {1..60}; do
    pgrep -x QwenVoiceEngineService >/dev/null 2>&1 && break
    sleep 1
  done
  echo "$(date +%H:%M:%S) post-wait $(service_state)" >> "$meta"
  # Watch service for 90s (retirement dwell 8s + grace after idle).
  local end=$(( $(date +%s) + 90 ))
  local prev=0 now=0
  while (( $(date +%s) < end )); do
    now=0; pgrep -x QwenVoiceEngineService >/dev/null 2>&1 && now=1
    if (( now != prev )); then
      if (( now == 1 )); then
        echo "$(date +%H:%M:%S) service SPAWNED pid=$(pgrep -xn QwenVoiceEngineService)" >> "$meta"
      else
        echo "$(date +%H:%M:%S) service RETIRED" >> "$meta"
      fi
      prev=$now
    fi
    sleep 1
  done
  quit_vocello
  kill "$logpid" 2>/dev/null || true
  wait "$logpid" 2>/dev/null || true
  rg -i 'retire|idle|warm|service' "$log" 2>/dev/null | tail -25 >> "$meta" || true
  echo "==> Done $label"
}

case "${1:-all}" in
  runA)
    capture_run "runA-normal-warm" \
      QWENVOICE_DEBUG=1 QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac
    ;;
  runB)
    capture_run "runB-suppress-warmup" \
      QWENVOICE_DEBUG=1 QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac QWENVOICE_SUPPRESS_WARMUP=1
    ;;
  runC) capture_xpc_retire ;;
  all)
    capture_run "runA-normal-warm" \
      QWENVOICE_DEBUG=1 QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac
    capture_run "runB-suppress-warmup" \
      QWENVOICE_DEBUG=1 QWENVOICE_FORCE_MEMORY_CLASS=floor_8gb_mac QWENVOICE_SUPPRESS_WARMUP=1
    capture_xpc_retire
    ;;
  quit) quit_vocello; echo "quit" ;;
  *) echo "usage: $0 {runA|runB|runC|all|quit}"; exit 1 ;;
esac
