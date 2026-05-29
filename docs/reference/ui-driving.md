# Driving UI tests, reviews, and benchmarks

How Claude exercises the Vocello UI directly — **macOS via the native `computer-use` MCP** (mouse +
keyboard + vision), **iOS via the iPhone Mirroring window**. This is live agent-driving, **not** a
script harness: no `scripts/uitest.sh`, no committed baselines, no smoke/bench runbook files
(`scripts/check_project_inputs.sh` still bans those). The agent drives the app and reads results; it
does not commit a test matrix.

## Principle

**Drive with computer-use; observe results by sight; capture timing out-of-band.** Take a
`screenshot`, find the control **by sight**, click its pixel (or use a keyboard chord). Confirm
outcomes from the screen (the Player appears with a clip duration, readiness flips to "Ready"). For
benchmark *timing*, do not time wall-clock around clicks — capture it from the engine instead (see
**Benchmark flow**; note that the unified `log` does **not** surface these signposts — verified).

## Availability (check first, every session)

Computer use is available to **Claude Code and Cowork** in the Claude Desktop app (Pro/Max) once
**Settings → General → Computer use** is on — verified working end-to-end here. The tools are
`mcp__computer-use__*`. Per session: load the toolkit (one `ToolSearch` with query `computer-use`,
`max_results: 30`), call `mcp__computer-use__request_access` for `Vocello` (resolves to **full** tier
— clicks + typing both work), then `screenshot`. They are action tools, so they're hidden while in
plan mode; a normal session exposes them. Screen Recording is already granted.

Run all shell work (builds, `log`, Instruments, DB queries) through the **Bash tool**, never through
computer-use — Terminal/IDE are restricted tiers where typing is blocked.

**Isolate test data:** launch with `QWENVOICE_DEBUG=1` (or flip the in-app toggle) so generated
takes land in `QwenVoice-Debug/` instead of polluting the real `QwenVoice/` History.

## Tool mapping + gotchas

| Intent | Call |
|---|---|
| Capture screen | `mcp__computer-use__screenshot` (locate elements by sight) |
| Click a pixel | `mcp__computer-use__left_click`, `coordinate: [x, y]` |
| Type into focused field | `mcp__computer-use__type` (click the field first) |
| Key / chord | `mcp__computer-use__key` — `cmd+Return` (Generate), `cmd+a`, `BackSpace`, `Down`/`Up`/`Return` |

- **Re-front if focus is stale:** clicking an unfocused window may only raise it — re-`screenshot`
  and click again.
- **SwiftUI Picker menus** open *anchored to the current selection*, so a remembered pixel only works
  for the first open. Drive them by keyboard: click to open → `Down`/`Up` N times from the current
  index → `Return`; track the index to compute N. (Affected: delivery tone, intensity, saved-voice,
  model-variant pickers.)
- Forbidden: AppleScript `keystroke` / `click at` global coordinates for the Vocello UI — they hit
  whatever window has focus and are fragile. Use computer-use.

## macOS surface reference (what to look for)

Stable `accessibilityIdentifier`s — semantic anchors, not coordinate sources. Keep them when
refactoring views.

- **Launch marker:** `mainWindow_ready` (window mounted), `mainWindow_activeScreen`.
- **Sidebar nav:** `sidebar_customVoice` / `sidebar_voiceDesign` / `sidebar_voiceCloning` /
  `sidebar_history` / `sidebar_voices` / `sidebar_settings`; each screen is `screen_*`.
- **Composer (all three generate screens):** `textInput_textEditor` (script field),
  `textInput_generateButton` (**Generate = `cmd+Return`**), `textInput_cancelButton` (during a run),
  `textInput_charCount`.
- **Per mode:** variant Speed/Quality + delivery controls under `customVoice_*` / `voiceDesign_*` /
  `voiceCloning_*` (e.g. `customVoice_speakerPicker`, `voiceDesign_voiceDescriptionField`,
  `voiceCloning_savedVoicePicker`, `*_toneSpeed`); readiness/completion shows as a `*_readiness`
  status ("Ready" → inline player; Design/Clone expose a save-to-Saved-Voices button).
- **Settings:** model rows `settings_package_<id>` + `settings_download_<id>` / `settings_repair_<id>`;
  `preferences_autoPlayToggle`; `settings_preferSpeedEverywhere`; `preferences_openFinderButton`.
  The **version label** carries the hidden **7-tap debug-mode toggle** (`appVersion` Text).
- **History / Voices:** `history_searchField`, `historyRow_<id>` (+ `_play_` / `_delete_`);
  `voices_enrollButton`, `voicesRow_<id>` (+ `_play_` / `_use_` / `_delete_`).

## Functional test flow (per mode)

1. `screenshot`; click `sidebar_<mode>`; confirm the `screen_<mode>` mounted.
2. Click the script field (`textInput_textEditor`); optional `cmd+a` → `BackSpace`; `type` the fixed
   prompt. (Clone needs a reference/saved voice first; Design needs a voice description.)
3. `cmd+Return` to generate.
4. Detect completion by `screenshot`: the inline **Player** appears (with a clip duration, e.g.
   `0:04`) and readiness shows "Ready". This screen signal is the reliable completion check (verified).
5. Verify the output landed (History row, or the played audio).

## Visual / UX review flow

Screenshot-driven inspection: layout at representative window sizes, the mode tints, chips/cards, and
the **Reduce Motion / Reduce Transparency** fallbacks (Liquid Glass must fall back to solid fills).
Toggle those in System Settings, relaunch, and compare screenshots.

## Benchmark flow (timing)

Drive Generate via computer-use, then capture timing **out-of-band**. Note: `log show` / `log stream`
do **not** surface the engine's `OSSignposter` signposts — verified here (three driven generations
produced zero `com.qwenvoice` log/signpost entries). These signposts go to the Activity-Tracing
buffer that only Instruments reads, not the unified log. So don't try to read timing from `log`.

- **Coarse, zero setup:** the inline Player shows the generated clip's duration in each `screenshot`
  (e.g. `0:04`) — enough to confirm a take and compare audio length, not latency.
- **Latency milestones (ad-hoc):** capture the always-on signposts with Instruments —
  `xctrace record --instrument os-signpost --attach Vocello --output run.trace`, drive the
  generation, then read the os_signpost track. Subsystems `com.qwenvoice.engine`
  (`generation`/`runtime`) and `com.qwenvoice.app`/`performance`. Milestones: `Native Prepare
  Generation` / `Native Model Load` (intervals), `Native First Audio Chunk` / `First Chunk Received`
  (time-to-first-audio), `Live Engine Play`, `Final File Ready`, `Autoplay Start`, `Native Prewarm
  Cache Hit`.
- **Recommended (durable):** the structured `native-events.jsonl` telemetry from the DebugMode
  telemetry/probing work — file-based, readable via Bash, no Instruments. Prefer this once it lands;
  it's the intended benchmark source. Until then, use Instruments for real latency numbers.

Cold vs warm: force cold by switching the model id (unloads) or letting idle-unload fire; warm =
back-to-back runs. **Ad-hoc per change — do not commit a baseline matrix.**

## iOS via iPhone Mirroring (with caveats)

Open the macOS **iPhone Mirroring** app (mirrors the paired physical iPhone); computer-use drives
that window like any native app (full tier). Drive the bottom tabs `rootTab_studio` /
`rootTab_voices` / `rootTab_history` / `rootTab_settings`, the Studio composer, and the
Custom/Design/Clone mode segmented control.

**Two preconditions right now:**
1. The app must already be installed and running on the device — deploy via **Xcode** (the in-repo
   `ios_device.sh` was removed in the harness cleanup).
2. Real on-device MLX generation is blocked until Apple's increased-memory entitlement
   ([`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md)).
   Until then, Mirroring runs are **UI / flow / visual review** only — generation will block at model
   admission.
