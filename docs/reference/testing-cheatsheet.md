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
#    scripts/uitest.sh activate
#    STATE = mcp__computer_use__.get_app_state(app: "Vocello")
#    record IW × IH from the key-window screenshot for window-locate

# 3) Drive UI (computer-use)
#    Click sidebar_customVoice → click textInput_textEditor → type → super+Return

# 4) Record T0 just before super+Return:
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
# Computer-use: scripts/uitest.sh activate + get_app_state → record IW × IH

for variant in speed quality; do
  # 1a — fresh launch
  scripts/uitest.sh reset && scripts/uitest.sh prep && scripts/uitest.sh activate

  # 1b — nav + variant select + (clone) saved-voice bind
  #     Computer-use: click sidebar_<mode>, then variant button (3-fallback ladder)

  # 1c — initial T0
  python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])" > /tmp/uitest_bench_t0

  # 1d — three cold/medium samples
  for i in 1 2 3; do
    # Computer-use: click+type_text+super+Return with medium prompt
    scripts/uitest.sh bench-step <mode> "$variant" cold medium --artifacts-dir "$ART" --timeout 180
    # (between cold samples — quit/reset/prep/relaunch and re-do 1b)
  done

  # 1e — warm samples
  for bucket in short medium long; do
    for i in 1 2 3; do
      # Computer-use: super+a → BackSpace → type_text bucket prompt → super+Return
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

## Recovery (when computer-use clicks miss)

```sh
scripts/uitest.sh activate                  # bring Vocello to front (osascript)
```
```text
STATE = mcp__computer_use__.get_app_state(app: "Vocello")  # re-record IW × IH; the window may have moved
```

Common causes: Notification Center stole focus, or another app got fronted. Re-fronting + refreshing state always recovers.

## Inspect a generation after the fact

```sh
# Newest row + audio path
scripts/uitest.sh db "SELECT id, mode, text, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"

# All Custom Voice WAVs from this Debug session
ls -lt "$HOME/Library/Application Support/QwenVoice-Debug/outputs/CustomVoice/" | head

# Tail the signpost log live
scripts/uitest.sh logs
```
