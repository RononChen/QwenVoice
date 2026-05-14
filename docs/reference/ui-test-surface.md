# UI Test Surface

Reference for a Claude Code session driving the **Debug build** of Vocello via the computer-use MCP. Pair this with [`smoke-custom-voice.md`](smoke-custom-voice.md) for the first end-to-end runbook.

## Permissions

Computer-use access is granted per session and is not persisted. At the top of any session that drives the app:

1. Call `mcp__computer-use__request_access` with `applications: ["Vocello"]`. Vocello is a normal native app — tier "full" — so clicks, typing, modifier keys all work.
2. System-wide: macOS Accessibility permission must already be granted to the controlling app (Claude). If `osascript` System Events calls return permission errors, the user grants in *System Settings → Privacy & Security → Accessibility*.

The `osascript` calls inside `scripts/uitest.sh locate` rely on the same Accessibility permission and will surface the OS prompt the first time if not yet granted.

## Click vocabulary

Every interactive element in the macOS UI has a stable `accessibilityIdentifier`. Resolve any of these names to pixel coordinates with `scripts/uitest.sh locate <ax-id>`. The script prints `cx cy w h` (center coordinates + size). Container/screen identifiers are listed so a session can confirm "I'm on the right screen" before clicking.

### Sidebar

| Identifier | Kind | Purpose |
|---|---|---|
| `sidebar_customVoice` | row | Switch to Custom Voice generation |
| `sidebar_voiceDesign` | row | Switch to Voice Design generation |
| `sidebar_voiceCloning` | row | Switch to Voice Cloning generation |
| `sidebar_history` | row | Open Generation Library / History |
| `sidebar_voices` | row | Open Saved Voices library |
| `sidebar_settings` | row | Open Settings |
| `sidebarSection_generate` | header | "Generate" section label |
| `sidebarSection_library` | header | "Library" section label |
| `sidebarSection_settings` | header | "Settings" section label |

### Generation screens

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_customVoice` | container | Confirms Custom Voice screen is up |
| `screen_voiceDesign` | container | Confirms Voice Design screen is up |
| `screen_voiceCloning` | container | Confirms Voice Cloning screen is up |

Field-level identifiers for the script text area, voice/emotion pickers, and Generate button vary per generation mode and are not all catalogued here yet — when a specific control isn't found via `locate`, fall back to a screenshot-driven click and add the discovered identifier to this table.

### History

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_history` | container | History screen container |
| `history_searchField` | text field | Filter history rows |
| `history_sortPicker` | picker | Newest / oldest order |

### Saved Voices

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_voices` | container | Saved Voices screen container |
| `voices_enrollButton` | button | Add a new saved voice |
| `voices_retryButton` | button | Retry after a load failure |
| `voicesRow_<voiceID>` | row | One saved voice row (keyed by UUID) |
| `voicesRow_<voiceID>_use` | button | Use this voice in cloning |
| `voicesRow_<voiceID>_play` | button | Play a preview |
| `voicesRow_<voiceID>_delete` | button | Delete this voice |
| `voicesRow_<voiceID>_qualityWarning` | badge | Quality warning visible |
| `voicesRow_<voiceID>_replaceReference` | button | Replace reference clip |

### Voice enrollment modal

| Identifier | Kind | Purpose |
|---|---|---|
| `voicesEnroll_nameField` | text field | Voice display name |
| `voicesEnroll_audioPathField` | text field | Audio file path |
| `voicesEnroll_browseButton` | button | File picker |
| `voicesEnroll_transcriptField` | text field | Optional transcript |
| `voicesEnroll_confirmButton` | button | Save |
| `voicesEnroll_cancelButton` | button | Cancel |
| `voicesEnroll_errorMessage` | container | Inline error |
| `voicesEnroll_keepDespiteWarning` | button | Proceed past quality warning |
| `voicesEnroll_discardOnWarning` | button | Discard reference, edit again |
| `voicesEnroll_cancelOnWarning` | button | Cancel out of warning |

### Settings — model management

`<id>` below is a model id from `Sources/Resources/qwenvoice_contract.json` (e.g. `pro_custom`, `pro_design`, `pro_clone`).

| Identifier | Kind | Purpose |
|---|---|---|
| `screen_settings` | container | Settings screen container |
| `settings_mode_<mode>` | segment | Switch sub-tab (custom / design / clone) |
| `settings_package_<id>` | row | Model package row |
| `settings_packageStatus_<id>` | label | Current status (downloaded, downloading, etc.) |
| `settings_download_<id>` | button | Start download |
| `settings_cancel_<id>` | button | Cancel in-progress download |
| `settings_repair_<id>` | button | Repair missing files |
| `settings_manage_<id>` | button | Reveal / delete |
| `settings_downloadProgress_<id>` | progress | Active download progress |
| `settings_checking_<id>` | label | "Checking…" indicator |
| `settings_downloadRecommendedModels` | button | One-click install all |
| `settings_cancelRecommendedSetup` | button | Cancel the recommended bundle |
| `settings_recommendedSetupProgress` | progress | Bundle progress |
| `settings_modelDownloadsSummary` | label | "X of Y models installed" |
| `preferences_autoPlayToggle` | toggle | Auto-play after generation |
| `preferences_outputDirectory` | text field | Output folder override |
| `preferences_browseButton` | button | Pick output folder |
| `preferences_outputResetButton` | button | Reset to default folder |
| `preferences_openFinderButton` | button | Reveal output folder |

### Startup diagnostics

| Identifier | Kind | Purpose |
|---|---|---|
| `startupDiagnostics_view` | container | Shown only if preflight failed |
| `startupDiagnostics_retryButton` | button | Re-run preflight |
| `startupDiagnostics_copyButton` | button | Copy diagnostics to clipboard |

## Locating an element

```sh
scripts/uitest.sh locate sidebar_customVoice
# example output (logical-points coordinate space, see caveat below):
# 413 221 202 34
```

The output is `cx cy w h` — center already computed — in **macOS logical-points space** (what `osascript` System Events reports). The computer-use screenshot you see may use a **different image pixel space**: on this Mac the screen is 1280×720 logical points but the captured screenshot renders at ~1456×816 image pixels, a ratio of ~1.138×. `mcp__computer-use__left_click` expects coordinates in screenshot-image pixels.

Two ways to handle this:

1. **Scale before clicking** (preferred when you know both sizes):
   ```
   image_width  = <from your most recent screenshot>
   image_height = <from your most recent screenshot>
   screen_w_h   = `scripts/uitest.sh screen-size`   # "1280 720" on this Mac
   sx = locate_cx * image_width  / screen_logical_w
   sy = locate_cy * image_height / screen_logical_h
   ```
2. **Visual-fallback click**: take a screenshot, find the target visually, and click the center of its visible rectangle. Use this when scaling is awkward (e.g., elements whose `accessibilityIdentifier` isn't yet catalogued in the click vocabulary).

The smoke runbook uses (2) for the script text area and Generate trigger (Cmd+Return), and (1) for the sidebar navigation.

If `locate` exits non-zero ("accessibility identifier not found"), either the screen isn't mounted yet (give SwiftUI another half-second and retry) or the identifier doesn't exist on the current screen. A screenshot will tell you which.

## Completion signals

Three independent ways to confirm a generation finished. Use at least two — they cross-check each other.

### 1. Log signposts

Subsystem `com.qwenvoice.app`. The key milestones are `OSSignposter` events (not regular `os.log` messages) — they only appear with `--signpost` enabled, which `scripts/uitest.sh logs` already passes to `log stream`. If you call `log stream` directly, include `--signpost` or the events will be silently dropped.

Sample line:

```
2026-05-13 21:33:06.295 Sp Vocello[93368:53c81] [com.qwenvoice.app:performance] [spid excl, process, event] Final File Ready
```

Stable substrings emitted by `AppPerformanceSignposts` (`Sources/Services/AppPerformanceSignposts.swift`):

| Substring | Meaning |
|---|---|
| `XPC Engine Command` begin/end | One round-trip to the engine XPC service (begin/end pair, category `xpc`) |
| `Preview To First Chunk` | First audio chunk decoded — TTS pipeline has started producing audio |
| `Final File Ready` | The on-disk `.wav` is fully written (emitted in `Sources/SharedSupport/Services/GenerationPersistence.swift`) |
| `Autoplay Start` | Playback has begun |

`Final File Ready` is the canonical "generation complete" marker. Poll for that substring in the log capture file. Note that `[Performance][...] autoplay_start_wall_ms=...` and similar lines go through `print()` (stderr), not OSLog — they only appear when the app's stderr is captured (e.g., launching the binary directly from a terminal), not from `log stream`.

### 2. File system

A `.wav` lands at:

```
~/Library/Application Support/QwenVoice-Debug/outputs/<Subfolder>/<filename>.wav
```

`<Subfolder>` is the `TTSModel.outputSubfolder` value — observed values are `CustomVoice/`, `VoiceDesign/`, and `Clones/` (PascalCase, not snake_case). Filenames look like `20260513_21-32-56-544_<first 20 chars of script>.wav`. The file appears once `Final File Ready` has fired. A non-zero byte size confirms a real generation; a current Speed-tier Custom Voice take is RIFF WAVE, 16-bit, mono, 24000 Hz, ~50 KB per second of audio.

### 3. Database

A row is inserted into `generations` in `~/Library/Application Support/QwenVoice-Debug/history.sqlite` after autoplay starts (slight lag after the `.wav` appears). Query with:

```sh
scripts/uitest.sh db "SELECT id, mode, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"
```

`db` opens the DB read-only so concurrent app access can't corrupt anything. Output is CSV.

## Reset semantics

`scripts/uitest.sh reset` always quits Vocello first to avoid racing with SQLite writes.

| Mode | Touches | Keeps | Time |
|---|---|---|---|
| (default) | `generations` rows, every file under `outputs/<mode>/` | models, saved voices, preferences, history table schema | ~1 s |
| `--include-voices` | above + `voices/` directory | models, preferences | ~1 s |
| `--full` | the entire `QwenVoice-Debug/` folder | nothing | <1 s rm, but next launch re-downloads ~5+ GB of models |

Default mode is the right choice between every test run. `--full` is for "I'm starting truly from scratch" scenarios.

## Artifact conventions

Every UI-driven run should anchor on a single directory from `scripts/uitest.sh artifacts-dir`:

```sh
ART=$(scripts/uitest.sh artifacts-dir)
# returns: /Users/.../build/uitest/20260513-201500
```

Convention for what to drop in `$ART/`:

- `pre.png` — screenshot before the test action
- `post.png` — screenshot after completion
- `log.txt` — captured `log stream` output for the run window
- `result.json` — structured outcome (pass/fail booleans, timings, paths, db row ids)

The `build/uitest/` parent is wiped by `scripts/build.sh clean` along with the rest of `build/`. Don't put anything load-bearing in there.

## Session flow (typical)

```
1. mcp__computer-use__request_access(["Vocello"])
2. scripts/build.sh debug                 # if Debug build is stale or missing
3. scripts/uitest.sh smoke-check          # confirm prerequisites
4. scripts/uitest.sh reset                # known-clean baseline
5. read SW SH < <(scripts/uitest.sh screen-size)   # for coord scaling
6. ART=$(scripts/uitest.sh artifacts-dir)
7. (scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)   # background, signpost-aware
8. scripts/uitest.sh prep                 # launch app
9. mcp__computer-use__open_application(app: "Vocello")   # ensure frontmost
10. /usr/sbin/screencapture -x "$ART/pre.png"
11. mcp__computer-use__screenshot         # for the agent's reasoning
12. <drive UI: locate → scale by (IW/SW, IH/SH) → left_click → type → cmd+return>
13. <poll $ART/log.txt for "Final File Ready">
14. scripts/uitest.sh db "SELECT ..."     # verify DB row
15. /usr/sbin/screencapture -x "$ART/post.png"
16. kill the background log PID; write $ART/result.json
17. Report $ART path + pass/fail + measured timings to the user.
```

That flow is the structure every future test runbook should follow.
