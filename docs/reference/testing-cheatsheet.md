# Testing Cheatsheet

Copy-pasteable commands for the three testing layers. For when-to-run-what, see [`testing-overview.md`](testing-overview.md). For the AX-id vocabulary and standard skeletons, see [`ui-test-surface.md`](ui-test-surface.md).

## Preflight

```sh
[ -d build/Debug/Vocello.app ] || scripts/build.sh debug
scripts/uitest.sh smoke-check custom   # or design / clone
```

## One-shot Custom Voice smoke (~1 min)

```sh
# 1) Setup
ART=$(scripts/uitest.sh artifacts-dir)
(scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &); LOG_PID=$!
scripts/uitest.sh reset
scripts/uitest.sh prep

# 2) Front the app (computer-use)
#    mcp__computer-use__request_access(apps: ["Vocello"], reason: "Smoke")
#    mcp__computer-use__open_application(app: "Vocello")
#    SHOT = mcp__computer-use__screenshot()  → record IW=1456 IH=819 on 1280×720 logical

# 3) Drive UI (computer-use, batched)
#    Click sidebar_customVoice → click textInput_textEditor → type → cmd+Return

# 4) Record T0 just before cmd+Return:
T0="$(/usr/bin/python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])')"

# 5) Verify
scripts/uitest.sh verify-generation custom \
    --artifacts-dir "$ART" --since "$T0" \
    --text "This is a Vocello smoke test. The quick brown fox jumps over the lazy dog."

# 6) Teardown
/usr/sbin/screencapture -x "$ART/post.png"
kill "$LOG_PID" 2>/dev/null || true
```

Substitute `design` or `clone` for `custom` to run the other smokes. See [`smoke-*.md`](.) for the per-mode deltas (different fixed inputs, screen check, extra steps before generate).

## Full bench matrix for one mode (~12 min)

```sh
ART=$(scripts/uitest.sh artifacts-dir); echo "$ART"
# Computer-use: request_access + open_application + screenshot → record IW × IH

for variant in speed quality; do
  # 1a — fresh launch
  scripts/uitest.sh reset && scripts/uitest.sh prep && scripts/uitest.sh activate

  # 1b — nav + variant select + (clone) saved-voice bind
  #     Computer-use: click sidebar_<mode>, then variant button (3-fallback ladder)

  # 1c — initial T0
  python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])" > /tmp/uitest_bench_t0

  # 1d — three cold/medium samples
  for i in 1 2 3; do
    # Computer-use: click+type+cmd+Return with medium prompt
    scripts/uitest.sh bench-step <mode> "$variant" cold medium --artifacts-dir "$ART" --timeout 180
    # (between cold samples — quit/reset/prep/relaunch and re-do 1b)
  done

  # 1e — warm samples
  for bucket in short medium long; do
    for i in 1 2 3; do
      # Computer-use: cmd+a → delete → type bucket prompt → cmd+Return
      scripts/uitest.sh bench-step <mode> "$variant" warm "$bucket" --artifacts-dir "$ART"
    done
  done
done

scripts/uitest.sh bench-summarize "$ART"
scripts/uitest.sh bench-compare "$ART"   # exits 1 on ±15 % drift
```

Promote new baseline only when intentional:

```sh
scripts/uitest.sh bench-update-baselines
git diff docs/reference/benchmark-baselines.json
```

## Perceptual review (~30 s per WAV)

```sh
scripts/uitest.sh gemini-review <path/to/sample.wav>
```

Auto-fills mode/text/speaker/delivery from `history.sqlite` by matching `audioPath`. For ad-hoc WAVs outside the harness or for Voice Design, pass explicit context:

```sh
scripts/uitest.sh gemini-review sample.wav \
    --mode design \
    --text "..." \
    --voice-description "..." \
    --delivery "Neutral"
```

Output bundle lands at `build/Debug/voice-reviews/<UTC>-<mode>-<basename>/review.md`.

Verify the active model is Gemini 3.1 Pro before a test session:

```sh
python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.gemini/settings.json')))['model']['name'])"
# → gemini-3.1-pro-preview
```

## Recovery (when computer-use clicks miss)

```sh
scripts/uitest.sh activate                  # bring Vocello to front (osascript)
```
```text
mcp__computer-use__open_application(app: "Vocello")   # Claude Code path
mcp__computer-use__screenshot()                       # re-record IW × IH; the window may have moved
```

Common causes: Notification Center stole focus (filtered out of Claude Code's screenshot but still owns clicks), or another non-allowed app got fronted. Re-fronting + re-screenshotting always recovers.

## Inspect a generation after the fact

```sh
# Newest row + audio path
scripts/uitest.sh db "SELECT id, mode, text, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"

# All Custom Voice WAVs from this Debug session
ls -lt "$HOME/Library/Application Support/QwenVoice-Debug/outputs/CustomVoice/" | head

# Tail the signpost log live
scripts/uitest.sh logs
```
