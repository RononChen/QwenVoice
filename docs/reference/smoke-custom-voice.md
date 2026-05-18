# Smoke Runbook: Custom Voice generate → verify

End-to-end check that exercises the autonomous-UI foundation: launch the Debug build, drive Custom Voice through one short generation via computer-use, and verify completion three ways (log signpost, output `.wav`, history DB row).

Companion reference: [`ui-test-surface.md`](ui-test-surface.md).

## Prerequisites

- Vocello Debug build exists at `build/Debug/Vocello.app`. If not, run `scripts/build.sh debug`.
- At least one Custom Voice model variant is installed (the runbook checks via `scripts/uitest.sh smoke-check`).
- macOS Accessibility permission granted to Claude Code.

## Fixed inputs

| Field | Value |
|---|---|
| Speaker | the app default (Aiden) — do not change |
| Script text | `This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.` |
| Variant | whichever variant is the app default for this Mac |

The runbook does not adjust pickers — it tests the minimum-effort generate path.

## Steps

1. **Precondition: build present, models installed.**
   - If `[ -d build/Debug/Vocello.app ]` is false → `scripts/build.sh debug`.
   - `scripts/uitest.sh smoke-check` — abort the run if it exits non-zero.

2. **Reset to a known-clean state.**
   - `scripts/uitest.sh reset` (default mode — keep models and saved voices).

3. **Create the artifacts directory and start log capture.**
   - `ART=$(scripts/uitest.sh artifacts-dir)`
   - `scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &`
   - `LOG_PID=$!`
   - Remember `$LOG_PID` so step 13 can stop the capture.

4. **Launch the app.**
   - `scripts/uitest.sh prep` — prints the Vocello PID once the window is up.

5. **Front the app, capture state, archive pre-screenshot.**
   - `mcp__computer-use__request_access(apps: ["Vocello"], reason: "Run Custom Voice smoke")` (once per session — subsequent calls in the same session no-op for already-granted apps).
   - `mcp__computer-use__open_application(app: "Vocello")` to ensure frontmost.
   - `SHOT = mcp__computer-use__screenshot()` — record `IW × IH` from the result and reuse them in every `scaled-locate` call below.
   - `/usr/sbin/screencapture -x "$ART/pre.png"` for the artifact bundle.

6. **Navigate to Custom Voice.**
   - `scripts/uitest.sh scaled-locate sidebar_customVoice $IW $IH` → parse `cx cy w h`.
   - `mcp__computer-use__left_click(coordinate: [cx, cy])`.
   - If Vocello isn't frontmost, the click won't dispatch — run `mcp__computer-use__open_application(app: "Vocello")` (or `scripts/uitest.sh activate`), re-take `mcp__computer-use__screenshot()`, then retry.

7. **Confirm Custom Voice screen is mounted.**
   - `scripts/uitest.sh locate screen_customVoice` — exit code 0 means the screen is up. If non-zero, screenshot, wait 500 ms, retry once.

8. **Enter the script text.**
   - The script-text field has accessibility identifier `textInput_textEditor` (shared across all three generation modes via `TextInputView`).
   - `scripts/uitest.sh scaled-locate textInput_textEditor $IW $IH` → `mcp__computer-use__left_click`.
   - `mcp__computer-use__type(text: "<fixed script text>")`.

9. **Trigger Generate.**
   - Send `mcp__computer-use__key(text: "cmd+Return")` while the script field is focused. `cmd+Return` is the macOS Cmd+Return shortcut. There is no dedicated "Generate" button visible in the default Custom Voice viewport on a 1280×720 display.
   - Immediately before pressing the key, record `T0` in the signpost timestamp format:
     ```sh
     T0="$(/usr/bin/python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])')"
     ```

10. **Wait for `Final File Ready`.**
    - Run `scripts/uitest.sh bench-wait --since "$T0" --timeout 90`; the printed timestamp is the matching `Final File Ready` event.
    - The log stream must include `--signpost` for these events to show; `scripts/uitest.sh logs` and `bench-wait` both use signpost-aware log queries. The signpost line format is:
      `<ts> Sp Vocello[pid:tid] [com.qwenvoice.app:performance] [...] Final File Ready`.
    - On timeout: stop the log capture, save the post-state screenshot, write `result.json` with `pass=false` and reason `"timeout waiting for Final File Ready"`, and abort.

11. **Verify the output file.**
    - The Custom Voice output subfolder is **`CustomVoice/`** (PascalCase — `TTSModel.outputSubfolder`), not `custom_voice/`.
    - `find "$HOME/Library/Application Support/QwenVoice-Debug/outputs/CustomVoice" -type f -name '*.wav' -newer "$ART/pre.png"` should print exactly one path. Record it as `AUDIO_PATH`. Confirm `[ -s "$AUDIO_PATH" ]` (file exists and is non-empty). Expected format: RIFF WAVE, 16-bit, mono, 24000 Hz.

12. **Verify the database row.**
    - `scripts/uitest.sh db "SELECT id, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"` should print one CSV line. Parse `DB_ID` (first field), `DB_AUDIO_PATH` (second), `DB_DURATION` (third). Assert `DB_AUDIO_PATH == AUDIO_PATH` and `DB_DURATION > 0`.

13. **Final screenshot, stop log capture.**
    - `mcp__computer-use__screenshot()` for visual inspection, then `/usr/sbin/screencapture -x "$ART/post.png"`.
    - `kill "$LOG_PID" 2>/dev/null || true`.

14. **Write the result file.**
    - Compose `$ART/result.json` with this shape:
      ```json
      {
        "pass": true,
        "final_file_ready_ts": "<timestamp printed by bench-wait>",
        "audio_path": "<path>",
        "audio_bytes": <number>,
        "db_id": "<uuid>",
        "db_duration": <number>,
        "fixed_script": "This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.",
        "vocello_pid": <number>,
        "timestamp": "<iso8601>"
      }
      ```
    - On any failed assertion, set `"pass": false` and add a `"reason": "<short string>"` field.

15. **Report.**
    - Print to the conversation: pass/fail, `MS_CLICK_TO_FINAL` in ms, `AUDIO_PATH`, `$ART/` for follow-up inspection.

## Notes

- This runbook is the contract for "the smoke test works." When any step changes — new accessibility identifiers, a different completion signal, a UI restructure — update both this file and `ui-test-surface.md`.
- `MS_CLICK_TO_FINAL` here is a single number. It's not yet a benchmark (no statistics, no comparison baseline). Element 2 of the autonomous-testing rollout will formalize benchmarking.
- The runbook deliberately does not navigate Settings or download models — `smoke-check` enforces the "models are already installed" precondition so the smoke test stays focused on the generate path.
