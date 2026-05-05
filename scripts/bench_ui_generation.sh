#!/usr/bin/env bash
# scripts/bench_ui_generation.sh — timing primitives for the desktop-UI
# Vocello generation benchmark.
#
# This is the timing helper called by Claude (or you) AFTER each
# Cmd+Return to a foreground Vocello window. It does not drive the UI
# itself — it only times the post-trigger pipeline (file appears →
# size stable → audio decodable) and computes wall_secs / audio_secs /
# RTF. Driving the UI (paste brief, paste script, click Generate / hit
# Cmd+Return) lives in Claude's computer-control session because
# Vocello's GenerationDraft state isn't surfaced via CLI.
#
# NO SWAP / RAM PREFLIGHT (by policy). The desktop-UI bench
# characterises behaviour at the hardware floor including memory-
# pressure regimes; aborting on high swap would defeat the purpose.
# Only the single-instance rule applies: caller must `pkill -x Vocello`
# before each cold relaunch. Engine wedge (no chunk progress for >60 s
# with the Vocello process still alive) is the one legitimate abort
# condition; the script's existing 4000×0.1s = 400 s completion-detect
# loop covers it via a 60 s no-growth fallback.
#
# Usage:
#   scripts/bench_ui_generation.sh <mode> <length> <state> <sample> [csv_path]
#
#   mode      custom | design | clone
#   length    label (micro / short / medium / long / very-long / ...)
#   state     cold | warm
#   sample    numeric sample number (1, 2, 3, ...)
#   csv_path  optional; default /tmp/vocello-ui-bench-results.csv
#
# Cold/warm semantics are the caller's responsibility:
#   - cold = kill Vocello, relaunch, wait for "Engine ready", paste
#            inputs, then run this script
#   - warm = call this script back-to-back without restarting Vocello
#
# CSV columns: mode,length,state,sample,wall_secs,audio_secs,rtf,filename
#
# This is the **default** benchmark method per CLAUDE.md "Performance
# benchmarking" — it captures the full user-perceived pipeline (paste,
# UI activation, generation, file write, autoplay handoff, live preview
# behavior). For tighter engine-only regression checks, see
# `./scripts/qa.sh test --layer perf`.

set -euo pipefail

LOG_FILE=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --log-file)
            LOG_FILE="$2"; shift 2 ;;
        --log-file=*)
            LOG_FILE="${1#*=}"; shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: bench_ui_generation.sh <mode> <length> <state> <sample> [csv_path]
                              [--log-file <path>]

  mode       custom | design | clone
  length     label (micro / short / medium / long / very-long / ...)
  state      cold | warm
  sample     numeric sample number (1, 2, 3, ...)
  csv_path   optional; default /tmp/vocello-ui-bench-results.csv
  --log-file optional; when provided, the script reads `[LivePreview]`
             trace lines emitted during this sample's timing window
             and adds anomaly columns to the CSV (underrun_count,
             total_stall_ms, ttfa_ms, max_chunk_gap_ms, decode_fails,
             stream_errors, duration_mismatch_s, chunk_count).
             Caller is responsible for launching Vocello with stdout
             redirected to this file, e.g.:
               nohup .../Vocello > /tmp/vocello-bench.log 2>&1 &

Vocello must be the foreground app with the script + (for design)
brief fields populated. The script issues Cmd+Return to trigger
generation, then times wall-clock to file size stability.
USAGE
            exit 0 ;;
        *)
            POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [ $# -lt 4 ]; then
    echo "missing required positional args; run with --help for usage" >&2
    exit 1
fi

MODE="$1"
LENGTH="$2"
STATE="$3"
SAMPLE="$4"
CSV="${5:-/tmp/vocello-ui-bench-results.csv}"

case "$MODE" in
    custom)  OUT_DIR="CustomVoice" ;;
    design)  OUT_DIR="VoiceDesign" ;;
    clone)   OUT_DIR="Clones" ;;
    *) echo "unknown mode: $MODE (expected custom|design|clone)" >&2; exit 2 ;;
esac

OUT="$HOME/Library/Application Support/QwenVoice/outputs/$OUT_DIR"
HDR_SIZE=4096
# Cmd+Return takes ~1.5s to round-trip activation + UI through the
# generation handoff; subtract it so wall_secs reflects actual
# generation time rather than activation overhead.
ACTIVATION_OVERHEAD=1.5

[ -d "$OUT" ] || { echo "output dir not found: $OUT" >&2; exit 3; }

# Snapshot file set before triggering
BEFORE=$(ls "$OUT" 2>/dev/null | sort)

# Capture pre-trigger log state. We pin OUR session as the
# (SESSION_START_COUNT_BEFORE + 1)-th `event=session_start` in the log.
#
# Why session-counter gating instead of byte-offset slicing: the engine
# emits `session_start` and `preview_completed` 1:1 per generation in
# causal order (sample N's preview_completed is always written before
# sample N+1's session_start, since the live-preview engine processes
# one session at a time). Byte-offset slicing was fooled by a previous
# sample's late-arriving preview_completed flushing into the log AFTER
# our LOG_OFFSET_BEFORE was captured — sample N+1 would then read sample
# N's stale summary as its own. Counter gating is immune: even if the
# stale event appears anywhere in the log past our offset, it's by
# definition before our session_start, so the awk filter rejects it.
HAS_LOG_FILE=false
SESSION_START_COUNT_BEFORE=0
TARGET_SESSION_INDEX=0
if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    HAS_LOG_FILE=true
    SESSION_START_COUNT_BEFORE=$(grep -c "event=session_start" "$LOG_FILE" 2>/dev/null || echo 0)
    SESSION_START_COUNT_BEFORE=${SESSION_START_COUNT_BEFORE//[^0-9]/}
    SESSION_START_COUNT_BEFORE=${SESSION_START_COUNT_BEFORE:-0}
    TARGET_SESSION_INDEX=$((SESSION_START_COUNT_BEFORE + 1))
fi

osascript -e 'tell application "Vocello" to activate' 2>/dev/null
sleep 0.4

T0=$(date +%s.%N)
osascript -e 'tell application "System Events" to keystroke return using command down'

# Wait for the first new wav to appear (max ~180s of 0.1s polls)
NEW=""
for i in $(seq 1 1800); do
    CURRENT=$(ls "$OUT" 2>/dev/null | sort)
    if [ "$CURRENT" != "$BEFORE" ]; then
        NEW=$(comm -13 <(echo "$BEFORE") <(echo "$CURRENT") | grep -E "\.wav$" | head -1 || true)
        [ -n "$NEW" ] && break
    fi
    sleep 0.1
done
[ -z "$NEW" ] && { echo "FILE_TIMEOUT (no new wav appeared in $OUT)" >&2; exit 4; }
NEWFILE="$OUT/$NEW"

# Wait for file size to grow past the WAV header
for i in $(seq 1 2000); do
    S=$(stat -f %z "$NEWFILE" 2>/dev/null || echo 0)
    [ "$S" -gt "$HDR_SIZE" ] && break
    sleep 0.1
done

# Wait for completion. Two signals:
#
# (1) When --log-file is provided: wait for the `[LivePreview]
#     event=preview_completed` line. This is the engine's own
#     authoritative signal — fires once per session at final-handoff
#     or teardown. Size-stability is treated as a hang fallback only,
#     not a primary signal, because inter-chunk pauses can falsely
#     trip a short stability window during a healthy generation.
#
# (2) Without --log-file: fall back to size stability (5s of no growth).
#     The 5s window must exceed normal inter-chunk gaps (~1.6s for
#     medium/long gens) to avoid false positives.
LAST_SIZE=0
STABLE=0
COMPLETED_VIA_LOG=false
SUMMARY_LINE=""
for i in $(seq 1 4000); do
    if [ "$HAS_LOG_FILE" = "true" ]; then
        # Look for OUR session's preview_completed: the first preview_completed
        # AFTER the (TARGET_SESSION_INDEX)-th session_start. awk exits early
        # if it walks past our session (session_idx > target) without a match,
        # which keeps the per-tick scan cheap.
        SUMMARY_LINE=$(awk -v target="$TARGET_SESSION_INDEX" '
            /event=session_start/ {
                session_idx++
                if (session_idx == target) { our_seen = 1; next }
                if (session_idx > target) exit
                next
            }
            our_seen && /event=preview_completed/ { print; exit }
        ' "$LOG_FILE" 2>/dev/null || true)
        if [ -n "$SUMMARY_LINE" ]; then
            COMPLETED_VIA_LOG=true
            break
        fi
        # Size-stability is a HANG fallback when --log-file is set:
        # only break on 60 s of no growth (truly stuck) so normal
        # inter-chunk pauses never short-circuit the wait.
        S=$(stat -f %z "$NEWFILE" 2>/dev/null || echo 0)
        if [ "$S" = "$LAST_SIZE" ]; then
            STABLE=$((STABLE + 1))
            [ "$STABLE" -ge 600 ] && break
        else
            STABLE=0
            LAST_SIZE=$S
        fi
    else
        # No log file: 5 s size-stability is the only signal.
        S=$(stat -f %z "$NEWFILE" 2>/dev/null || echo 0)
        if [ "$S" = "$LAST_SIZE" ]; then
            STABLE=$((STABLE + 1))
            [ "$STABLE" -ge 50 ] && break
        else
            STABLE=0
            LAST_SIZE=$S
        fi
    fi
    sleep 0.1
done

T1=$(date +%s.%N)
WALL=$(echo "scale=3; $T1 - $T0 - $ACTIVATION_OVERHEAD" | bc)

# Audio duration source — two paths:
#
# (A) When --log-file is provided AND preview_completed was seen, read
#     `total_audio_s` from the trace. This is the engine's own ground
#     truth and avoids the afinfo race on the WAV header (which can
#     read 0.000000 between streaming-write completion and
#     finalWriter.finish() updating the RIFF header).
#
# (B) Otherwise (no log file, or batch path with no live preview),
#     fall back to summing afinfo durations across all wavs newer
#     than T0. Includes a retry loop for the header-finalization race.
T0_INT=$(echo "$T0" | cut -d. -f1)
TOTAL_AUDIO=0
SEG_COUNT=0

if [ "$COMPLETED_VIA_LOG" = "true" ]; then
    # SUMMARY_LINE was captured in the wait loop above and is already
    # scoped to OUR session via session-counter gating.
    LOG_AUDIO=$(echo "$SUMMARY_LINE" | grep -oE 'total_audio_s=[0-9.]+' | cut -d= -f2)
    if [ -n "$LOG_AUDIO" ] && [ "$LOG_AUDIO" != "0" ]; then
        TOTAL_AUDIO="$LOG_AUDIO"
        SEG_COUNT=1
    fi
fi

if [ "$TOTAL_AUDIO" = "0" ] || [ -z "$TOTAL_AUDIO" ]; then
    for retry in $(seq 1 50); do
        TOTAL_AUDIO=0
        SEG_COUNT=0
        while IFS= read -r -d '' seg; do
            D=$(afinfo "$seg" 2>/dev/null | grep "estimated duration" | awk '{print $3}' || true)
            if [ -n "$D" ] && [ "$D" != "0.000000" ]; then
                TOTAL_AUDIO=$(echo "scale=3; $TOTAL_AUDIO + $D" | bc)
                SEG_COUNT=$((SEG_COUNT + 1))
            fi
        done < <(find "$OUT" -name "*.wav" -newermt "@$T0_INT" -print0 2>/dev/null | sort -z)
        [ "$TOTAL_AUDIO" != "0" ] && [ -n "$TOTAL_AUDIO" ] && break
        sleep 0.2
    done
fi

if [ "$TOTAL_AUDIO" = "0" ] || [ -z "$TOTAL_AUDIO" ]; then
    echo "PARSE_FAILED (no readable audio in new files; neither preview_completed event nor afinfo returned a non-zero duration)" >&2
    exit 5
fi

RTF=$(echo "scale=3; $WALL / $TOTAL_AUDIO" | bc)

if [ "$SEG_COUNT" -gt 1 ]; then
    FILE_LABEL="${SEG_COUNT}-segment-batch"
else
    FILE_LABEL="$NEW"
fi

# ---------------------------------------------------------------------
# Anomaly parsing — when --log-file points at a captured Vocello stdout,
# extract the `[LivePreview]` event lines emitted in this sample's
# timing window and reduce them to summary columns.
#
# Schema (emitted by AudioPlayerViewModel.swift, DEBUG-only):
#   [LivePreview] event=session_start session=<id>
#   [LivePreview] event=chunk_arrived seq=N audio_s=X cumulative_s=Y queue_depth=Q gap_ms=G
#   [LivePreview] event=playback_started ttfa_ms=T queue_depth=Q
#   [LivePreview] event=underrun_paused underrun_n=N audio_played_s=X
#   [LivePreview] event=underrun_resumed stall_ms=S queue_depth=Q
#   [LivePreview] event=decode_failed branch=<file|inline>
#   [LivePreview] event=stream_error message=<text>
#   [LivePreview] event=final_handoff preview_audio_s=X final_audio_s=Y delta_s=D
#   [LivePreview] event=preview_completed underruns=N total_stall_ms=S ...
# ---------------------------------------------------------------------
UNDERRUN_COUNT=""
TOTAL_STALL_MS=""
TTFA_MS=""
MAX_CHUNK_GAP_MS=""
DECODE_FAILS=""
STREAM_ERRORS=""
DURATION_MISMATCH_S=""
CHUNK_COUNT=""

if [ "$HAS_LOG_FILE" = "true" ] && [ "$TARGET_SESSION_INDEX" -gt 0 ]; then
    # Pull all `[LivePreview]` lines belonging to OUR session: from our
    # session_start (inclusive) up to the next session_start (exclusive)
    # or end of log. Same counter-gating as the wait loop.
    TRACE=$(awk -v target="$TARGET_SESSION_INDEX" '
        /\[LivePreview\]/ && /event=session_start/ {
            session_idx++
            if (session_idx == target) { our_seen = 1; print; next }
            if (session_idx > target) exit
            next
        }
        our_seen && /\[LivePreview\]/ { print }
    ' "$LOG_FILE" 2>/dev/null || true)

    if [ -n "$TRACE" ]; then
        # preview_completed line carries all aggregate counters.
        # `|| true` on every grep so a missing line (e.g. very short
        # audio that skips the live-preview path) doesn't trip
        # `set -e` and kill the script before the CSV is written.
        SUMMARY=$(echo "$TRACE" | grep "event=preview_completed" | tail -1 || true)
        if [ -n "$SUMMARY" ]; then
            UNDERRUN_COUNT=$(echo "$SUMMARY" | grep -oE 'underruns=[0-9]+' | cut -d= -f2 || true)
            TOTAL_STALL_MS=$(echo "$SUMMARY" | grep -oE 'total_stall_ms=[0-9]+' | cut -d= -f2 || true)
            DECODE_FAILS=$(echo "$SUMMARY" | grep -oE 'decode_fails=[0-9]+' | cut -d= -f2 || true)
            STREAM_ERRORS=$(echo "$SUMMARY" | grep -oE 'stream_errors=[0-9]+' | cut -d= -f2 || true)
            MAX_CHUNK_GAP_MS=$(echo "$SUMMARY" | grep -oE 'max_chunk_gap_ms=[0-9]+' | cut -d= -f2 || true)
            CHUNK_COUNT=$(echo "$SUMMARY" | grep -oE 'chunk_count=[0-9]+' | cut -d= -f2 || true)
        fi

        # ttfa_ms comes from playback_started — missing for very-short
        # generations where the live-preview path never engages
        # (queue duration < initial prebuffer threshold of 2.25 s).
        STARTED_LINE=$(echo "$TRACE" | grep "event=playback_started" | tail -1 || true)
        if [ -n "$STARTED_LINE" ]; then
            TTFA_MS=$(echo "$STARTED_LINE" | grep -oE 'ttfa_ms=[0-9]+' | cut -d= -f2 || true)
        fi

        # duration_mismatch_s = abs(delta_s) from final_handoff
        HANDOFF_LINE=$(echo "$TRACE" | grep "event=final_handoff" | tail -1 || true)
        if [ -n "$HANDOFF_LINE" ]; then
            DELTA=$(echo "$HANDOFF_LINE" | grep -oE 'delta_s=-?[0-9.]+' | cut -d= -f2 || true)
            if [ -n "$DELTA" ]; then
                DURATION_MISMATCH_S=$(echo "$DELTA" | tr -d -)
            fi
        fi
    fi
fi

UNDERRUN_COUNT=${UNDERRUN_COUNT:-}
TOTAL_STALL_MS=${TOTAL_STALL_MS:-}
TTFA_MS=${TTFA_MS:-}
MAX_CHUNK_GAP_MS=${MAX_CHUNK_GAP_MS:-}
DECODE_FAILS=${DECODE_FAILS:-}
STREAM_ERRORS=${STREAM_ERRORS:-}
DURATION_MISMATCH_S=${DURATION_MISMATCH_S:-}
CHUNK_COUNT=${CHUNK_COUNT:-}

if [ ! -f "$CSV" ]; then
    echo "mode,length,state,sample,wall_secs,audio_secs,rtf,filename,underrun_count,total_stall_ms,ttfa_ms,max_chunk_gap_ms,decode_fails,stream_errors,duration_mismatch_s,chunk_count" > "$CSV"
fi

ROW="$MODE,$LENGTH,$STATE,$SAMPLE,$WALL,$TOTAL_AUDIO,$RTF,$FILE_LABEL,$UNDERRUN_COUNT,$TOTAL_STALL_MS,$TTFA_MS,$MAX_CHUNK_GAP_MS,$DECODE_FAILS,$STREAM_ERRORS,$DURATION_MISMATCH_S,$CHUNK_COUNT"
echo "$ROW"
echo "$ROW" >> "$CSV"
