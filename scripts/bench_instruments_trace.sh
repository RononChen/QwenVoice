#!/usr/bin/env bash
# scripts/bench_instruments_trace.sh — capture a System Trace of one
# Vocello generation so the engine signposts (`com.qwenvoice.engine.*`
# subsystems, including the per-token Qwen3 hot-path markers) align
# with Metal GPU activity, CPU time profiling, and thread state in
# Instruments.
#
# Why this exists: the Phase 2a wall-clock probe identified
# `stream_step_eval` as the dominant per-chunk timer (~80 % of
# `infer_ms`), but a direct .deferred policy switch revealed the
# stream_step_eval was a *visible attribution* of underlying MLX
# kernel work — not standalone overhead. Wall-clock counters can't go
# deeper. This script captures an Instruments-grade trace so we can
# see the actual GPU command buffers, kernel dispatches, and any GPU
# idle gaps that the wall-clock probe is blind to.
#
# Usage:
#   ./scripts/bench_instruments_trace.sh [--seconds N] [--output <path>]
#
#   --seconds   record window in seconds (default 30; bump for long
#               generations — a medium CV gen runs ~30 s, long ~75 s,
#               long with cold model load ~90 s)
#   --output    .trace bundle output path
#               (default: build/instruments-traces/vocello-YYYYMMDD-HHMMSS.trace)
#
# Workflow:
#   1. The script kills any running Vocello and relaunches a fresh
#      Debug build with `defaults` set so the app lands on Custom
#      Voice with Smooth OFF.
#   2. After the engine is ready, the script starts `xctrace record`
#      with the System Trace template and your chosen time window.
#   3. While the trace is recording, the OPERATOR triggers the
#      generation in the Vocello UI (paste a script + Cmd+Return).
#   4. When the trace stops, the script `open`s the .trace bundle in
#      Instruments. Add the "os_signpost" instrument and filter by
#      subsystem `com.qwenvoice.engine.qwen3` to see the per-token
#      sub-stages (Talker Forward, Code Predictor Loop, Audio
#      Decoder, Audio Chunk Eval, Step Eval Flush) aligned with the
#      Metal GPU and Time Profiler tracks.
#
# Required: xctrace (ships with Xcode) — confirmed available via
# `xcrun xctrace help`. No mise / brew dependency.

set -euo pipefail

SECONDS_LIMIT=30
OUTPUT=""
APP="${APP:-/Users/patricedery/Coding_Projects/QwenVoice/build/foundation/local-builds/macos-derived-data/Build/Products/Debug/Vocello.app}"

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds)
            SECONDS_LIMIT="$2"; shift 2 ;;
        --seconds=*)
            SECONDS_LIMIT="${1#*=}"; shift ;;
        --output)
            OUTPUT="$2"; shift 2 ;;
        --output=*)
            OUTPUT="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,42p' "$0"
            exit 0 ;;
        *)
            echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if ! command -v xctrace >/dev/null 2>&1; then
    if ! xcrun --find xctrace >/dev/null 2>&1; then
        echo "xctrace not found. Install Xcode + command-line tools." >&2
        exit 1
    fi
    XCTRACE="xcrun xctrace"
else
    XCTRACE="xctrace"
fi

if [ ! -x "$APP/Contents/MacOS/Vocello" ]; then
    echo "Vocello binary not found at: $APP/Contents/MacOS/Vocello" >&2
    echo "Build with: ./scripts/build_foundation_targets.sh macos" >&2
    exit 2
fi

if [ -z "$OUTPUT" ]; then
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    TRACES_DIR="$REPO_ROOT/build/instruments-traces"
    mkdir -p "$TRACES_DIR"
    TS="$(date +%Y%m%d-%H%M%S)"
    OUTPUT="$TRACES_DIR/vocello-$TS.trace"
fi

# Kill any existing Vocello + reset defaults so we land on a known
# starting screen (Custom Voice). Smooth OFF so the live-preview path
# behaves like the default user experience.
pkill -x Vocello 2>/dev/null || true
sleep 2
defaults write com.qwenvoice.app QwenVoice.LastSelectedSidebarItem -string "Custom Voice"
defaults write com.qwenvoice.app QwenVoice.SmoothLivePreviewPlayback -bool false

# Launch via direct binary so stderr (where the cross-layer probes
# live) is captured separately from the trace.
LOG="/tmp/vocello-bench.log"
rm -f "$LOG"
nohup "$APP/Contents/MacOS/Vocello" > "$LOG" 2>&1 &
VOCELLO_PID=$!
sleep 5

# Confirm Vocello is up.
if ! ps -p "$VOCELLO_PID" >/dev/null 2>&1; then
    echo "Vocello exited unexpectedly. See $LOG" >&2
    exit 3
fi
echo "Vocello running (PID $VOCELLO_PID). Engine should be Ready in the UI."

cat <<'EOF' >&2

------------------------------------------------------------------
INSTRUMENTS TRACE STARTING.

While the trace records (System Trace template; CPU + Metal + signposts),
trigger ONE generation in the Vocello UI:
  1. Click into the Script box
  2. Paste a medium-length script (~50 words)
  3. Press Cmd+Return

Trace records globally — Vocello's main process AND the bundled
QwenVoiceEngineService XPC helper are both captured. The Qwen3
per-token signposts emit from the XPC helper's subsystem
`com.qwenvoice.engine.qwen3` (category=generation).
------------------------------------------------------------------
EOF

# System Trace template captures:
#   - CPU time profiling (per-thread sample stacks)
#   - Metal GPU activity (command buffers, kernel dispatches)
#   - os_signpost events (any subsystem)
#   - Thread state, virtual memory, syscalls
#
# `--time-limit` makes the script self-terminating so the operator
# only has to drive the UI; no manual stop needed.
# --all-processes captures the entire system, which is what we want:
# the bundled QwenVoiceEngineService.xpc helper is a child process of
# Vocello and emits its own os_signpost events that we need.
$XCTRACE record \
    --template "System Trace" \
    --all-processes \
    --time-limit "${SECONDS_LIMIT}s" \
    --output "$OUTPUT" \
    >&2 || true

echo ""
echo "Trace bundle: $OUTPUT"
echo ""
echo "Opening in Instruments..."
open "$OUTPUT"

cat <<'EOF' >&2

------------------------------------------------------------------
ANALYSIS POINTERS
------------------------------------------------------------------

In Instruments:
  • Add the "os_signpost" instrument (View → Instruments Library)
  • Filter by subsystem: com.qwenvoice.engine.qwen3
  • Check the "Points of Interest" / "Logging" track: you should see
    per-token markers — Talker Forward, Code Predictor Loop, Audio
    Decoder, Audio Chunk Eval, Step Eval Flush.
  • Align with the Metal GPU track to see which kernels run during
    each engine stage and where the GPU is idle (= optimization gaps).
  • The Time Profiler track shows where CPU time goes per-thread
    during each interval.

What to look for:
  • Long Talker Forward intervals with GPU idle → CPU-bound work
    (kernel launch overhead, sampling, embed lookup)
  • Code Predictor Loop with 7 sequential GPU bursts → batching
    opportunity (single multi-codebook dispatch)
  • Audio Chunk Eval longer than the Audio Decoder kernel itself →
    sync wait (could pipeline with next forward)
  • Step Eval Flush with substantial GPU activity → confirms the
    wall-clock attribution was correct AND the work is real
EOF
