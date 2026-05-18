#!/usr/bin/env bash
# Perceptual voice-quality + tone/emotion review of a Vocello-generated WAV,
# powered by the Gemini CLI (gemini-3.1-pro-preview default).
#
# Complements the bench harness: bench-* measures timing, RMS/peak, and memory;
# this script adds subjective dimensions (naturalness, emotion match,
# pronunciation, pacing, artifacts). Pulls the generation context (mode, text,
# voice, emotion) straight out of history.sqlite so the caller only has to pass
# the WAV path.
#
# usage:
#   scripts/gemini_voice_review.sh <wav-path>
#       [--mode custom|design|clone]                # override DB lookup
#       [--text "<spoken text>"]                    # override DB lookup
#       [--voice-description "..."]                 # required for Voice Design
#       [--speaker "..."]                           # override DB lookup
#       [--delivery "..."]                          # override DB lookup
#       [--saved-voice "..."]                       # required for Voice Cloning
#       [--commit <hash>]                           # optional repo commit hash
#       [--out-dir <dir>]                           # default: build/voice-reviews/

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Lives under build/Debug/ (a maintained folder per CLAUDE.md) so it's wiped by
# `scripts/build.sh clean`. Do not move outside build/Debug/ without updating
# CLAUDE.md's "Only two maintained top-level folders belong under build/" rule.
DEFAULT_OUT_ROOT="$ROOT_DIR/build/Debug/voice-reviews"
DEBUG_DATA_DIR="$HOME/Library/Application Support/QwenVoice-Debug"
HISTORY_DB="$DEBUG_DATA_DIR/history.sqlite"

usage() {
    cat <<'USAGE'
usage: scripts/gemini_voice_review.sh <wav-path>
           [--mode custom|design|clone]
           [--text "<spoken text>"]
           [--voice-description "..."]
           [--speaker "..."]
           [--delivery "..."]
           [--saved-voice "..."]
           [--commit <hash>]
           [--out-dir <dir>]

Generates a structured perceptual review via the Gemini CLI.
Auto-fills mode/text/speaker/delivery from history.sqlite when the WAV
matches a row's audioPath. The resulting bundle lands under
build/voice-reviews/<UTC-ts>-<mode>-<wav-basename>/.
USAGE
    exit 64
}

WAV_PATH=""
MODE=""
TEXT=""
VOICE_DESCRIPTION=""
SPEAKER=""
DELIVERY=""
SAVED_VOICE=""
COMMIT=""
OUT_ROOT="$DEFAULT_OUT_ROOT"

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2;;
        --text) TEXT="$2"; shift 2;;
        --voice-description) VOICE_DESCRIPTION="$2"; shift 2;;
        --speaker) SPEAKER="$2"; shift 2;;
        --delivery) DELIVERY="$2"; shift 2;;
        --saved-voice) SAVED_VOICE="$2"; shift 2;;
        --commit) COMMIT="$2"; shift 2;;
        --out-dir) OUT_ROOT="$2"; shift 2;;
        -h|--help) usage;;
        -*) echo "unknown flag: $1" >&2; usage;;
        *)
            if [ -z "$WAV_PATH" ]; then WAV_PATH="$1"
            else echo "extra positional: $1" >&2; usage
            fi
            shift;;
    esac
done

[ -n "$WAV_PATH" ] || { echo "error: WAV path required" >&2; usage; }
[ -f "$WAV_PATH" ] || { echo "error: not a file: $WAV_PATH" >&2; exit 2; }

# Canonicalize so DB lookups match the audioPath stored at generation time.
WAV_PATH="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$WAV_PATH")"
WAV_DIR="$(dirname "$WAV_PATH")"
WAV_BASENAME="$(basename "$WAV_PATH" .wav)"

# Auto-fill missing fields from the generations row matching this audioPath.
if [ -f "$HISTORY_DB" ]; then
    ROW_JSON="$(WAV="$WAV_PATH" DB="$HISTORY_DB" /usr/bin/python3 - <<'PY'
import os, sqlite3, json
con = sqlite3.connect(f"file:{os.environ['DB']}?mode=ro", uri=True)
cur = con.execute(
    "SELECT mode,text,voice,emotion FROM generations WHERE audioPath = ? ORDER BY createdAt DESC LIMIT 1",
    (os.environ['WAV'],),
)
row = cur.fetchone()
print(json.dumps({"mode":row[0],"text":row[1],"voice":row[2] or "","emotion":row[3] or ""}) if row else "")
PY
)"
    if [ -n "$ROW_JSON" ]; then
        DB_MODE=$(printf '%s' "$ROW_JSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["mode"])')
        DB_TEXT=$(printf '%s' "$ROW_JSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["text"])')
        DB_VOICE=$(printf '%s' "$ROW_JSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["voice"])')
        DB_EMOTION=$(printf '%s' "$ROW_JSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["emotion"])')
        [ -z "$MODE" ] && MODE="$DB_MODE"
        [ -z "$TEXT" ] && TEXT="$DB_TEXT"
        if [ -z "$SPEAKER" ] && [ "$MODE" = "custom" ]; then SPEAKER="$DB_VOICE"; fi
        if [ -z "$SAVED_VOICE" ] && [ "$MODE" = "clone" ]; then SAVED_VOICE="$DB_VOICE"; fi
        [ -z "$DELIVERY" ] && DELIVERY="$DB_EMOTION"
    fi
fi

[ -n "$MODE" ] || { echo "error: --mode not provided and no DB row for $WAV_PATH" >&2; exit 2; }
[ -n "$TEXT" ] || { echo "error: --text not provided and no DB row for $WAV_PATH" >&2; exit 2; }

case "$MODE" in
    custom|design|clone) ;;
    *) echo "error: --mode must be custom|design|clone (got: $MODE)" >&2; exit 2;;
esac

[ -n "$COMMIT" ] || COMMIT="$(cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

UTC_TS="$(/usr/bin/python3 -c 'import datetime as dt; print(dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ"))')"
BUNDLE_DIR="$OUT_ROOT/${UTC_TS}-${MODE}-${WAV_BASENAME}"
mkdir -p "$BUNDLE_DIR"

GEMINI_BIN="$(command -v gemini || true)"
[ -n "$GEMINI_BIN" ] || { echo "error: gemini CLI not on PATH (npm i -g @google/gemini-cli)" >&2; exit 3; }

GEMINI_MODEL="$(HOME="$HOME" /usr/bin/python3 -c '
import os, json
try:
    with open(os.path.join(os.environ["HOME"], ".gemini/settings.json")) as f:
        print(json.load(f).get("model",{}).get("name","gemini-3.1-pro-preview"))
except Exception:
    print("gemini-3.1-pro-preview")
')"

case "$MODE" in
    custom)
        SPEAKER_BLOCK="- Built-in speaker: ${SPEAKER:-unknown}"
        MODE_LABEL="Custom Voice"
        ;;
    design)
        SPEAKER_BLOCK="- Voice description requested: \"${VOICE_DESCRIPTION:-(not provided — judge naturalness/delivery only)}\""
        MODE_LABEL="Voice Design"
        ;;
    clone)
        SPEAKER_BLOCK="- Cloned from saved reference: \"${SAVED_VOICE:-unknown}\". Rate naturalness + identity coherence, NOT similarity to a specific person."
        MODE_LABEL="Voice Cloning"
        ;;
esac

PROMPT_FILE="$BUNDLE_DIR/review_prompt.md"
cat > "$PROMPT_FILE" <<EOF
You are evaluating a text-to-speech audio sample produced by a local on-device TTS model on macOS (Vocello / Qwen3-TTS).

Listen carefully to @${WAV_PATH} (the full clip) and provide a structured review.

Generation context:
- Mode: $MODE_LABEL
- Text the model was asked to speak: "$TEXT"
- Requested delivery: ${DELIVERY:-(default — Neutral, Subtle)}
- Speaker / voice context:
$SPEAKER_BLOCK

Respond in English, in this EXACT Markdown format (do not add additional sections, do not omit any):

## Voice Quality Review

**Overall score**: X/10 — <one sentence summary>

### Naturalness
- Score: X/10
- Notes: <one or two sentences>

### Intelligibility
- Score: X/10
- Notes: <one or two sentences>

### Emotion / delivery match
- Score: X/10
- Notes: <one or two sentences — does the delivery match the requested tone? For Voice Design, does it match the voice description?>

### Pronunciation
- Score: X/10
- Notes: <one or two sentences — note any specific mispronounced words>

### Pacing & prosody
- Score: X/10
- Notes: <one or two sentences>

### Artifacts
- Detected: <list clicks, pops, glitches, hiss, mid-word cuts, chunk-boundary discontinuities, background tones — OR "None">
- Severity: <None | Subtle | Noticeable | Severe>

### Strengths
- <bullet point>
- <bullet point>

### Weaknesses
- <bullet point>
- <bullet point>

### Suggested investigation
<one sentence — e.g., "Pronunciation of 'X' was unclear, worth checking the tokenizer's handling of that word." Or "None — sample is clean.">
EOF

echo "==> bundle:  $BUNDLE_DIR"
echo "==> model:   $GEMINI_MODEL"
echo "==> mode:    $MODE | speaker: ${SPEAKER:-—} | saved-voice: ${SAVED_VOICE:-—} | delivery: ${DELIVERY:-default}"
echo "==> sending prompt to Gemini ..."

RAW_BODY="$BUNDLE_DIR/review_body.raw"
REVIEW_BODY="$BUNDLE_DIR/review_body.md"
"$GEMINI_BIN" \
    -p "$(cat "$PROMPT_FILE")" \
    -o text \
    --approval-mode yolo \
    --include-directories "$WAV_DIR" \
    > "$RAW_BODY" 2>"$BUNDLE_DIR/gemini_stderr.log"

# Strip CLI startup chatter that precedes the model response on stdout.
RAW="$RAW_BODY" OUT="$REVIEW_BODY" /usr/bin/python3 - <<'PY'
import os, pathlib
raw = pathlib.Path(os.environ["RAW"]).read_text()
prefix_markers = (
    "Warning:", "YOLO mode is enabled", "Ripgrep is not available",
    "MCP issues detected", "Loaded cached credentials",
)
lines = raw.splitlines(keepends=True)
start = 0
for i, line in enumerate(lines):
    stripped = line.lstrip()
    if any(stripped.startswith(m) for m in prefix_markers) or stripped == "" or stripped.startswith("\n"):
        continue
    start = i
    break
pathlib.Path(os.environ["OUT"]).write_text("".join(lines[start:]).rstrip() + "\n")
PY

AUDIO_DURATION_S="$(WAV="$WAV_PATH" /usr/bin/python3 -c '
import os, wave, contextlib
try:
    with contextlib.closing(wave.open(os.environ["WAV"], "rb")) as w:
        print(f"{w.getnframes() / w.getframerate():.2f}")
except Exception:
    print("")
')"

REVIEW_MD="$BUNDLE_DIR/review.md"
{
    echo "# Voice review"
    echo
    echo "**Source WAV**: $WAV_PATH"
    echo "**Mode**: $MODE_LABEL"
    case "$MODE" in
        custom) echo "**Speaker**: ${SPEAKER:-unknown}" ;;
        design) echo "**Voice description**: ${VOICE_DESCRIPTION:-(not provided)}" ;;
        clone)  echo "**Saved voice**: ${SAVED_VOICE:-unknown}" ;;
    esac
    echo "**Requested delivery**: ${DELIVERY:-default (Neutral, Subtle)}"
    echo "**Text**: \"$TEXT\""
    [ -n "$AUDIO_DURATION_S" ] && echo "**Audio duration**: $AUDIO_DURATION_S s"
    echo "**Vocello commit**: $COMMIT"
    echo
    echo "**Reviewer**: Gemini $GEMINI_MODEL (via gemini CLI)"
    echo "**Reviewed at (UTC)**: $UTC_TS"
    echo "**Procedure version**: 3.0 (scripts/gemini_voice_review.sh)"
    echo
    echo "---"
    echo
    cat "$REVIEW_BODY"
} > "$REVIEW_MD"

GEMINI_CLI_VERSION="$("$GEMINI_BIN" --version 2>/dev/null || echo unknown)"
WAV_PATH_OUT="$WAV_PATH" MODE_OUT="$MODE" MODE_LABEL_OUT="$MODE_LABEL" \
TEXT_OUT="$TEXT" SPEAKER_OUT="$SPEAKER" VOICE_DESC_OUT="$VOICE_DESCRIPTION" \
SAVED_VOICE_OUT="$SAVED_VOICE" DELIVERY_OUT="$DELIVERY" \
AUDIO_DUR_OUT="${AUDIO_DURATION_S:-}" GEMINI_MODEL_OUT="$GEMINI_MODEL" \
GEMINI_CLI_VERSION_OUT="$GEMINI_CLI_VERSION" COMMIT_OUT="$COMMIT" \
UTC_TS_OUT="$UTC_TS" DEST="$BUNDLE_DIR/metadata.json" \
/usr/bin/python3 - <<'PY'
import json, os, pathlib
def maybe(name):
    v = os.environ.get(name, "")
    return v if v else None
def maybe_float(name):
    v = os.environ.get(name, "")
    try: return float(v) if v else None
    except ValueError: return None

m = {
    "source_wav": os.environ["WAV_PATH_OUT"],
    "mode": os.environ["MODE_OUT"],
    "mode_label": os.environ["MODE_LABEL_OUT"],
    "text": os.environ["TEXT_OUT"],
    "speaker": maybe("SPEAKER_OUT"),
    "voice_description": maybe("VOICE_DESC_OUT"),
    "saved_voice": maybe("SAVED_VOICE_OUT"),
    "delivery": maybe("DELIVERY_OUT"),
    "audio_duration_s": maybe_float("AUDIO_DUR_OUT"),
    "gemini_model": os.environ["GEMINI_MODEL_OUT"],
    "gemini_cli_version": os.environ["GEMINI_CLI_VERSION_OUT"],
    "vocello_commit": os.environ["COMMIT_OUT"],
    "reviewed_at_utc": os.environ["UTC_TS_OUT"],
}
m = {k: v for k, v in m.items() if v is not None}
pathlib.Path(os.environ["DEST"]).write_text(json.dumps(m, indent=2) + "\n")
PY

SUMMARY="$(grep -m1 '^\*\*Overall score\*\*' "$REVIEW_BODY" || true)"
echo "==> done"
[ -n "$SUMMARY" ] && echo "==> $SUMMARY"
echo "==> review:  $REVIEW_MD"
