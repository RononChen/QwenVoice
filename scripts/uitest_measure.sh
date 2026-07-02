#!/usr/bin/env bash
# Deterministic measurement + lifecycle shell for macOS UI-driven testing.
#
# Restores the measurement core of the deleted `uitest.sh` (removed 6d1cca4, design
# recovered from git history — see docs/post-mortem/2026-06-post-fable-development-hell.md
# §2.8) adapted to today's single-Release-config app. DELIBERATELY DECOUPLED from any
# UI-driving method: an agent may drive Vocello via the Peekaboo MCP, XCUITest, or a
# human hand — timing and verification always come from OSSignposts + history.sqlite +
# the WAV on disk, never from how the click happened.
#
# The app must be launched in debug-data mode (QWENVOICE_DEBUG=1 → data dir
# ~/Library/Application Support/QwenVoice-Debug) so measurements never touch the
# user's real library. `prep` does this for you.
#
# usage: scripts/uitest_measure.sh <command> [options]
#
# commands:
#   prep                  Launch build/Vocello.app in debug-data mode (persisted
#                         DebugMode flag; fresh instance, quits any running copy).
#                         Prints the PID. Pair with `finish` when done.
#   finish                Quit the app + clear the persisted debug flag (so normal
#                         user launches return to the real data dir).
#   reset [--include-voices|--full]
#                         Quit Vocello and reset debug-mode runtime state.
#                         Default: clear generations table + delete outputs/<mode>/ files.
#                         --include-voices also removes voices/. --full removes the
#                         entire QwenVoice-Debug folder (forces model re-download).
#   activate              Bring Vocello to the front (mid-test focus recovery).
#   artifacts-dir         Create build/macos/uitest-measure/<timestamp>/ and print it.
#   smoke-check [mode]    Preconditions for generation: model variant installed for
#                         mode ∈ custom|design|clone (default custom); clone also
#                         requires a saved voice. Exit 0 ready / 1 with message.
#   now                   Print a timestamp usable as --since (log-show format).
#   bench-wait [--since <ts>] [--timeout <s>]
#                         Block until a "Final File Ready" signpost appears after <ts>
#                         (defaults: now; 90 s). Prints the event timestamp.
#   verify-generation <mode> --artifacts-dir <dir> --since <ts> [--timeout <s>] [--text <t>]
#                         Post-generate verification: wait for Final File Ready, find
#                         the new WAV under outputs/<Mode>/, check the latest
#                         history.sqlite row matches, write <dir>/result.json.
#   streaming-preview-check [--since <ts>] [--timeout <s>] [--artifacts-dir <dir>]
#                         Wait for Final File Ready then assert the live preview was
#                         healthy (Live Engine Play + Autoplay Start before final, no
#                         Live Preview Underrun / Chunk Gap) + DB/WAV sane. Writes
#                         <dir>/streaming-preview.json when --artifacts-dir given.
#   db <sql>              Read-only SELECT against debug history.sqlite (CSV output).
#   logs [--predicate <p>]
#                         Tail `log stream --info --signpost` for Vocello (default
#                         predicate: subsystem == "com.qwenvoice.app").
#   bench-compare [<diagnostics-dir>] --baseline <json> [--] [summarizer args…]
#                         Regression compare via scripts/summarize_generation_telemetry.py
#                         --compare-baseline (exit 2 on >threshold regression). Default
#                         diagnostics dir: the QwenVoice-Debug diagnostics folder.
#   help                  Show this message.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="Vocello"
BUNDLE_ID="com.qwenvoice.app"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
DEBUG_DATA_DIR="$HOME/Library/Application Support/QwenVoice-Debug"
HISTORY_DB="$DEBUG_DATA_DIR/history.sqlite"
DIAGNOSTICS_DIR="$DEBUG_DATA_DIR/diagnostics"
CONTRACT_JSON="$ROOT_DIR/Sources/Resources/qwenvoice_contract.json"
BENCH_LOG_PREDICATE='subsystem == "com.qwenvoice.app"'
SUMMARIZER="$ROOT_DIR/scripts/summarize_generation_telemetry.py"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

quit_app_if_running() {
    # SIGTERM (graceful) → SIGKILL. Never `tell application … to quit`: AppleScript
    # app-name targeting can LAUNCH a fresh LaunchServices instance first.
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        pkill -x "$APP_NAME" 2>/dev/null || true
        for _ in {1..20}; do
            pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
            sleep 0.25
        done
        pkill -9 -x "$APP_NAME" 2>/dev/null || true
        sleep 0.5
    fi
    pkill -x QwenVoiceEngineService >/dev/null 2>&1 || true
}

now_ts() {
    python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])"
}

# Bring the RUNNING instance frontmost by PID via System Events (safe: cannot
# spawn a second copy the way `tell application "Vocello" to activate` can).
activate_pid() {
    local pid="$1"
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" \
        >/dev/null 2>&1
}

DEBUG_FLAG_KEY="QwenVoice.DebugModeEnabled"

cmd_prep() {
    [[ -d "$APP_BUNDLE" ]] || die "app not built at $APP_BUNDLE — run: scripts/build.sh build"
    quit_app_if_running
    # Launch via LaunchServices (survives this script's shell — a direct binary exec
    # dies with the tool session). LaunchServices strips env vars, so debug-data mode
    # comes from the persisted DebugMode flag that DebugMode.resolve() reads as its
    # env fallback. `finish` (or reset --full) clears it again.
    defaults write "$BUNDLE_ID" "$DEBUG_FLAG_KEY" -bool true
    /usr/bin/open -na "$APP_BUNDLE"
    local pid=""
    for _ in {1..40}; do
        pid="$(pgrep -x "$APP_NAME" | head -1)"
        [[ -n "$pid" ]] && break
        sleep 0.25
    done
    [[ -n "$pid" ]] || die "$APP_NAME did not appear in the process list after launch"
    local count; count="$(pgrep -x "$APP_NAME" | wc -l | tr -d ' ')"
    (( count == 1 )) || die "expected exactly 1 $APP_NAME instance, found $count — quit the extras and re-run prep"
    sleep 1
    activate_pid "$pid" || true
    echo "$pid"
}

# finish: quit the app and clear the persisted debug flag so the user's normal
# launches go back to the real data dir.
cmd_finish() {
    quit_app_if_running
    defaults delete "$BUNDLE_ID" "$DEBUG_FLAG_KEY" >/dev/null 2>&1 || true
    note "debug flag cleared; $APP_NAME quit"
}

cmd_reset() {
    local mode="default"
    case "${1:-}" in
        "") ;;
        --include-voices) mode="include-voices" ;;
        --full)           mode="full" ;;
        *) die "unknown reset option '$1' (try --include-voices or --full)" ;;
    esac
    quit_app_if_running
    if [[ "$mode" == "full" ]]; then
        if [[ -d "$DEBUG_DATA_DIR" ]]; then
            note "removing $DEBUG_DATA_DIR"
            rm -rf "$DEBUG_DATA_DIR"
        else
            note "nothing to remove ($DEBUG_DATA_DIR does not exist)"
        fi
        return 0
    fi
    if [[ -f "$HISTORY_DB" ]]; then
        note "clearing generations table in $HISTORY_DB"
        sqlite3 "$HISTORY_DB" "DELETE FROM generations;" 2>/dev/null \
            || warn "could not clear generations (table missing or db locked)"
    fi
    local outputs_dir="$DEBUG_DATA_DIR/outputs"
    if [[ -d "$outputs_dir" ]]; then
        note "deleting files under $outputs_dir"
        find "$outputs_dir" -type f -delete
    fi
    if [[ "$mode" == "include-voices" && -d "$DEBUG_DATA_DIR/voices" ]]; then
        note "removing $DEBUG_DATA_DIR/voices"
        rm -rf "$DEBUG_DATA_DIR/voices"
    fi
}

cmd_activate() {
    local pid; pid="$(pgrep -x "$APP_NAME" | head -1)"
    [[ -n "$pid" ]] || die "$APP_NAME is not running — run: $0 prep"
    activate_pid "$pid" || die "could not bring $APP_NAME (pid $pid) frontmost"
}

cmd_artifacts_dir() {
    local dir="$ROOT_DIR/build/macos/uitest-measure/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dir"
    echo "$dir"
}

cmd_smoke_check() {
    local mode="${1:-custom}"
    case "$mode" in custom|design|clone) ;; *) die "unknown mode '$mode' (custom|design|clone)" ;; esac
    [[ -f "$CONTRACT_JSON" ]] || die "contract not found at $CONTRACT_JSON"
    [[ -d "$DEBUG_DATA_DIR/models" ]] || die "no models at $DEBUG_DATA_DIR/models — run: scripts/macos_test.sh models ensure"

    local installed
    installed="$(python3 - "$CONTRACT_JSON" "$DEBUG_DATA_DIR/models" "$mode" <<'PY'
import json, sys
from pathlib import Path
contract = json.loads(Path(sys.argv[1]).read_text())
models_dir = Path(sys.argv[2])
mode = sys.argv[3]
model = next((m for m in contract["models"] if m.get("mode") == mode), None)
if model is None:
    print("CONTRACT_MISSING"); sys.exit(0)
candidates = []
if model.get("folder"):
    candidates.append((model["folder"], "base"))
for v in model.get("variants", []):
    if v.get("folder"):
        candidates.append((v["folder"], v.get("id", "variant")))
found = [label for folder, label in candidates
         if (models_dir / folder / "model.safetensors").is_file()
         and (models_dir / folder / "model.safetensors").stat().st_size > 0]
print(",".join(found) if found else "NONE_INSTALLED")
PY
)"
    case "$installed" in
        CONTRACT_MISSING) die "no model with mode='$mode' in the contract" ;;
        NONE_INSTALLED)   die "no $mode model variant installed — run: scripts/macos_test.sh models ensure" ;;
        "")               die "contract inspection failed" ;;
        *)                note "smoke-check OK: $mode variant(s) installed: $installed" ;;
    esac

    if [[ "$mode" == "clone" ]]; then
        local wavs
        wavs="$(find "$DEBUG_DATA_DIR/voices" -maxdepth 1 -type f -name '*.wav' 2>/dev/null | wc -l | tr -d ' ')"
        if (( wavs > 0 )); then
            note "smoke-check OK: $wavs saved voice(s) present"
        else
            die "clone mode requires a saved voice under $DEBUG_DATA_DIR/voices — run: scripts/macos_test.sh models ensure"
        fi
    fi
}

# Wait for generation completion after <since>. PRIMARY signal: a new
# history.sqlite row (written at the same instant GenerationPersistence emits
# "Final File Ready"). The signpost store is only a FALLBACK because logd
# flushes os_signpost events to the `log show` store with multi-minute lag —
# polling the store right after a generation reliably misses fresh events.
cmd_bench_wait() {
    local since="" timeout=90
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since)   since="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            *) die "unknown bench-wait arg '$1'" ;;
        esac
    done
    [[ -n "$since" ]] || since="$(now_ts)"
    # since is local time (from `now`); DB createdAt is UTC — convert once.
    local since_utc
    since_utc="$(SINCE="$since" python3 -c '
import datetime as dt, os
local = dt.datetime.strptime(os.environ["SINCE"], "%Y-%m-%d %H:%M:%S.%f").astimezone()
print(local.astimezone(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])
')" || die "invalid --since '$since' (expect: YYYY-MM-DD HH:MM:SS.mmm — get one from: $0 now)"

    local deadline=$(($(date +%s) + timeout))
    while [[ "$(date +%s)" -lt "$deadline" ]]; do
        # 1) DB row (authoritative completion signal, no flush lag)
        if [[ -f "$HISTORY_DB" ]]; then
            local row_ts
            row_ts="$(sqlite3 -readonly "$HISTORY_DB" \
                "SELECT createdAt FROM generations WHERE createdAt > '$since_utc' ORDER BY createdAt DESC LIMIT 1" 2>/dev/null || true)"
            if [[ -n "$row_ts" ]]; then
                ROW_TS="$row_ts" python3 -c '
import datetime as dt, os
utc = dt.datetime.strptime(os.environ["ROW_TS"], "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=dt.timezone.utc)
print(utc.astimezone().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])
'
                return 0
            fi
        fi
        # 2) Signpost store fallback (may lag; covers [since, now] not a fixed window).
        # log show rejects fractional seconds in --start — trim to whole seconds.
        local found
        found="$(/usr/bin/log show --signpost --predicate "$BENCH_LOG_PREDICATE" \
                    --start "${since%.*}" --style compact 2>/dev/null \
            | SINCE="$since" python3 -c '
import os, re, sys
since = os.environ["SINCE"]
last = None
for line in sys.stdin:
    if "Final File Ready" not in line:
        continue
    m = re.match(r"(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d+)", line)
    if not m:
        continue
    ts = f"{m.group(1)} {m.group(2)}"
    if ts > since:
        last = ts
print(last) if last else exit(1)
' 2>/dev/null || true)"
        if [[ -n "$found" ]]; then
            echo "$found"
            return 0
        fi
        sleep 1
    done
    echo "error: timeout after ${timeout}s waiting for a completed generation since $since (no new history.sqlite row, no Final File Ready signpost)" >&2
    return 1
}

cmd_verify_generation() {
    local mode="" artifacts_dir="" since="" timeout="" text=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --artifacts-dir) artifacts_dir="$2"; shift 2 ;;
            --since)         since="$2"; shift 2 ;;
            --timeout)       timeout="$2"; shift 2 ;;
            --text)          text="$2"; shift 2 ;;
            custom|design|clone)
                [[ -z "$mode" ]] && mode="$1" || die "mode set twice"; shift ;;
            *) die "unknown verify-generation arg '$1'" ;;
        esac
    done
    [[ -n "$mode" ]] || die "verify-generation requires <mode>"
    [[ -n "$artifacts_dir" && -d "$artifacts_dir" ]] || die "verify-generation requires --artifacts-dir <existing dir>"
    [[ -n "$since" ]] || die "verify-generation requires --since (get one from: $0 now)"
    if [[ -z "$timeout" ]]; then
        case "$mode" in clone) timeout=120 ;; *) timeout=90 ;; esac
    fi

    # Mode → output subfolder (source of truth: qwenvoice_contract.json output_subfolder).
    local subfolder
    case "$mode" in
        custom) subfolder="CustomVoice" ;;
        design) subfolder="VoiceDesign" ;;
        clone)  subfolder="Clones" ;;
    esac
    local outputs_dir="$DEBUG_DATA_DIR/outputs/$subfolder"

    local final_ts
    if ! final_ts="$(cmd_bench_wait --since "$since" --timeout "$timeout" 2>&1)"; then
        ARTIFACTS_DIR="$artifacts_dir" MODE="$mode" TEXT="$text" SINCE="$since" REASON="$final_ts" \
            python3 - <<'PY' || true
import json, os, pathlib, datetime as dt
out = {
    "pass": False,
    "mode": os.environ["MODE"],
    "reason": os.environ["REASON"].replace("error: ", "", 1),
    "since": os.environ["SINCE"],
    "text": os.environ.get("TEXT") or None,
    "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
pathlib.Path(os.environ["ARTIFACTS_DIR"], "result.json").write_text(json.dumps(out, indent=2) + "\n")
PY
        echo "FAIL: $final_ts" >&2
        return 1
    fi

    local audio_path
    audio_path="$(find "$outputs_dir" -type f -name '*.wav' -newer "$artifacts_dir" 2>/dev/null | sort -r | head -1 || true)"

    ARTIFACTS_DIR="$artifacts_dir" MODE="$mode" SUBFOLDER="$subfolder" \
        AUDIO_PATH="$audio_path" FINAL_TS="$final_ts" TEXT="$text" SINCE="$since" DB="$HISTORY_DB" \
        python3 - <<'PY'
import json, os, pathlib, sqlite3, sys, datetime as dt

art = pathlib.Path(os.environ["ARTIFACTS_DIR"])
mode = os.environ["MODE"]
subfolder = os.environ["SUBFOLDER"]
audio_path = os.environ["AUDIO_PATH"] or None
final_ts = os.environ["FINAL_TS"]
text = os.environ.get("TEXT") or None
db = os.environ["DB"]

def fail(reason, **extra):
    out = {
        "pass": False, "mode": mode, "reason": reason,
        "final_file_ready_ts": final_ts, "text": text,
        "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        **extra,
    }
    (art / "result.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"FAIL: {reason}", file=sys.stderr)
    sys.exit(1)

if not audio_path or not os.path.isfile(audio_path) or os.path.getsize(audio_path) == 0:
    fail(f"no new WAV under outputs/{subfolder}/ after the bench-wait")

audio_bytes = os.path.getsize(audio_path)
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
row = con.execute(
    "SELECT id, mode, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"
).fetchone()
con.close()

if row is None:
    fail("history.sqlite has no rows", audio_path=audio_path, audio_bytes=audio_bytes)
db_id, db_mode, db_audio_path, db_duration = row
if db_audio_path != audio_path:
    fail(
        f"latest DB row's audioPath does not match the new WAV (db={db_audio_path}, file={audio_path})",
        audio_path=audio_path, audio_bytes=audio_bytes, db_id=db_id, db_audio_path=db_audio_path,
    )
if not db_duration or db_duration <= 0:
    fail(f"db_duration is null or non-positive ({db_duration})",
         audio_path=audio_path, audio_bytes=audio_bytes, db_id=db_id, db_duration=db_duration)

out = {
    "pass": True, "mode": mode, "final_file_ready_ts": final_ts,
    "audio_path": audio_path, "audio_bytes": audio_bytes,
    "db_id": db_id, "db_mode": db_mode, "db_duration": db_duration,
    "text": text,
    "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
(art / "result.json").write_text(json.dumps(out, indent=2) + "\n")
print(f"ok: {mode} pass=true final={final_ts} audio={audio_path} ({audio_bytes} B) db_id={db_id} db_duration={db_duration}")
PY
}

cmd_streaming_preview_check() {
    local since="" timeout=90 artifacts_dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since)         since="$2"; shift 2 ;;
            --timeout)       timeout="$2"; shift 2 ;;
            --artifacts-dir) artifacts_dir="$2"; shift 2 ;;
            *) die "unknown streaming-preview-check arg '$1'" ;;
        esac
    done
    [[ -n "$since" ]] || since="$(now_ts)"
    [[ -z "$artifacts_dir" || -d "$artifacts_dir" ]] || die "artifacts dir not found: $artifacts_dir"

    local final_ts
    final_ts="$(cmd_bench_wait --since "$since" --timeout "$timeout")" || return $?

    # --start (not a fixed --last window): logd flushes signposts with lag and the
    # check may run well after the generation completed. log show rejects fractional
    # seconds in --start, so trim to whole seconds (the > since filter below still
    # uses the full-precision timestamp).
    local log_buf start_ts="${since%.*}"
    log_buf="$(/usr/bin/log show --signpost --predicate "$BENCH_LOG_PREDICATE" --start "$start_ts" --style compact 2>/dev/null)" \
        || die "log show --signpost failed"

    local db_row=""
    for _ in 1 2 3 4 5 6 7 8; do
        db_row="$(sqlite3 -readonly -separator $'\t' "$HISTORY_DB" \
            "SELECT id, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1" 2>/dev/null || true)"
        [[ -n "$db_row" ]] && break
        sleep 0.25
    done

    SINCE="$since" FINAL_TS="$final_ts" LOG_BUF="$log_buf" DB_ROW="$db_row" \
        ARTIFACTS_DIR="$artifacts_dir" python3 - <<'PY'
import json, os, re, sys, wave
import datetime as dt
from pathlib import Path

since = os.environ["SINCE"]
final_ts = os.environ["FINAL_TS"]
lines = os.environ.get("LOG_BUF", "").splitlines()
db_row = os.environ.get("DB_ROW", "")
artifacts_dir = os.environ.get("ARTIFACTS_DIR", "")

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d+)")

window = []
for line in lines:
    m = TS_RE.match(line)
    if not m:
        continue
    ts = f"{m.group(1)} {m.group(2)}"
    if since < ts <= final_ts:
        window.append((ts, line))

def hits(name):
    return [(ts, line) for ts, line in window if name in line]

live_engine_play = hits("Live Engine Play")
autoplay_start = hits("Autoplay Start")
underrun = hits("Live Preview Underrun")
chunk_gap = hits("Live Preview Chunk Gap")

db_id = audio_path = None
db_duration_s = audio_bytes = wav_duration_s = None
if db_row:
    parts = db_row.split("\t")
    if len(parts) >= 3:
        db_id, audio_path = parts[0], parts[1]
        try:
            db_duration_s = float(parts[2])
        except ValueError:
            db_duration_s = None
        if audio_path and os.path.isfile(audio_path):
            audio_bytes = os.path.getsize(audio_path)
            try:
                with wave.open(audio_path, "rb") as w:
                    if w.getframerate() > 0:
                        wav_duration_s = w.getnframes() / float(w.getframerate())
            except Exception:
                wav_duration_s = None

checks = {
    "live_engine_play_before_final": len(live_engine_play) > 0,
    "autoplay_start_before_final": len(autoplay_start) > 0,
    "no_live_preview_underrun": len(underrun) == 0,
    "no_live_preview_chunk_gap": len(chunk_gap) == 0,
    "final_wav_exists": bool(audio_path and audio_bytes and audio_bytes > 44),
    "final_wav_has_duration": bool((db_duration_s and db_duration_s > 0) or (wav_duration_s and wav_duration_s > 0)),
    "db_row_landed": db_id is not None,
}
failures = [name for name, ok in checks.items() if not ok]
result = {
    "pass": not failures,
    "failures": failures,
    "since": since,
    "final_ts": final_ts,
    "counts": {
        "live_engine_play": len(live_engine_play),
        "autoplay_start": len(autoplay_start),
        "underrun": len(underrun),
        "chunk_gap": len(chunk_gap),
    },
    "db_id": db_id,
    "audio_path": audio_path,
    "audio_bytes": audio_bytes,
    "db_duration_s": db_duration_s,
    "wav_duration_s": wav_duration_s,
    "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if artifacts_dir:
    Path(artifacts_dir, "streaming-preview.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
sys.exit(0 if result["pass"] else 1)
PY
}

cmd_db() {
    local sql="${1:-}"
    [[ -n "$sql" ]] || die "db requires a SQL statement"
    [[ -f "$HISTORY_DB" ]] || die "history.sqlite not found at $HISTORY_DB (launch the app once with prep)"
    sqlite3 -readonly -separator , "$HISTORY_DB" "$sql"
}

cmd_logs() {
    local predicate="$BENCH_LOG_PREDICATE"
    if [[ "${1:-}" == "--predicate" ]]; then
        [[ $# -ge 2 ]] || die "--predicate requires a value"
        predicate="$2"
    fi
    exec /usr/bin/log stream --info --signpost --style compact --predicate "$predicate"
}

cmd_bench_compare() {
    local diagnostics="" baseline=""
    local -a extra=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --baseline) baseline="$2"; shift 2 ;;
            --) shift; extra=("$@"); break ;;
            *)
                if [[ -z "$diagnostics" ]]; then diagnostics="$1"; shift
                else die "unknown bench-compare arg '$1'"; fi ;;
        esac
    done
    [[ -n "$baseline" ]] || die "bench-compare requires --baseline <json> (create one with: python3 $SUMMARIZER <diag> --save-baseline <json>)"
    [[ -f "$baseline" ]] || die "baseline not found: $baseline"
    [[ -n "$diagnostics" ]] || diagnostics="$DIAGNOSTICS_DIR"
    [[ -d "$diagnostics" ]] || die "diagnostics dir not found: $diagnostics"
    exec python3 "$SUMMARIZER" "$diagnostics" --compare-baseline "$baseline" "${extra[@]}"
}

main() {
    local sub="${1:-help}"; shift || true
    case "$sub" in
        prep)                    cmd_prep "$@" ;;
        finish)                  cmd_finish "$@" ;;
        reset)                   cmd_reset "$@" ;;
        activate)                cmd_activate "$@" ;;
        artifacts-dir)           cmd_artifacts_dir "$@" ;;
        smoke-check)             cmd_smoke_check "$@" ;;
        now)                     now_ts ;;
        bench-wait)              cmd_bench_wait "$@" ;;
        verify-generation)       cmd_verify_generation "$@" ;;
        streaming-preview-check) cmd_streaming_preview_check "$@" ;;
        db)                      cmd_db "$@" ;;
        logs)                    cmd_logs "$@" ;;
        bench-compare)           cmd_bench_compare "$@" ;;
        help|-h|--help)          usage ;;
        *) die "unknown command '$sub' (try: prep|finish|reset|activate|artifacts-dir|smoke-check|now|bench-wait|verify-generation|streaming-preview-check|db|logs|bench-compare|help)" ;;
    esac
}

main "$@"
