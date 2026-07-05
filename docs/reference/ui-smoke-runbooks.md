# UI smoke runbooks — agent-driven exploratory loops

Per-mode smoke procedures for **agent-driven** UI validation in Cursor, pairing
**mobile-mcp** on iOS (WDA accessibility tree) and **script + Axiom** on macOS with the
**deterministic measurement shell** [`scripts/uitest_measure.sh`](../../scripts/uitest_measure.sh).
See [`computer-use-mcp-alternatives-cursor.md`](computer-use-mcp-alternatives-cursor.md).

Successor to the per-mode smoke runbooks deleted at `6d1cca4`. The core design rule
survives: **measurement never depends on how the agent clicked.** Pass/fail comes from
OSSignposts + `history.sqlite` + the WAV on disk via `verify-generation` — the MCP only
drives the UI like a human.

**These runbooks are exploratory QA, not gates.** Regression gates stay
`scripts/macos_test.sh gate` and `scripts/ios_device.sh gate`.

Identifier reference: [`ui-test-surface.md`](ui-test-surface.md) (generated catalog).

---

## macOS — shared skeleton

Every macOS smoke follows the same lifecycle:

```sh
scripts/build.sh build                       # if build/Vocello.app is stale
scripts/uitest_measure.sh smoke-check <mode> # models (+ clone voice) present?
scripts/uitest_measure.sh reset              # clean generations + outputs
scripts/uitest_measure.sh prep               # fresh launch, QWENVOICE_DEBUG=1
ART=$(scripts/uitest_measure.sh artifacts-dir)
T0=$(scripts/uitest_measure.sh now)          # capture BEFORE clicking Generate
# … agent drives the UI via Peekaboo (see per-mode steps) …
scripts/uitest_measure.sh verify-generation <mode> --artifacts-dir "$ART" --since "$T0"
scripts/uitest_measure.sh streaming-preview-check --since "$T0" --artifacts-dir "$ART"  # optional
```

Peekaboo driving pattern (precision-first, vision to confirm):

1. `see` with `app: Vocello` — AX map with element ids; Vocello's
   `accessibilityIdentifier`s appear on the mapped elements.
2. Prefer clicking by element id from `see`; fall back to `image` + click-by-sight for
   visually ambiguous controls.
3. Keyboard-first where possible: `Cmd+Return` = Generate, `Cmd+A` + `Delete` to replace
   script text. SwiftUI Picker menus re-anchor after the first open — re-`see` before the
   second interaction with any picker.
4. Re-`see` (or `image`) after each step to confirm state; watch `*_readiness` markers
   (`ready=true` in the element value).

## macOS — Custom Voice smoke

1. Skeleton above with `<mode> = custom`.
2. `see` → click `sidebar_customVoice` → confirm `screen_customVoice`.
3. Click `textInput_textEditor`, type a short script (≥ a full sentence).
4. Wait for `customVoice_readiness` value to contain `ready=true`.
5. Capture `T0`, then `Cmd+Return`.
6. `verify-generation custom …` — expect `pass: true` in `$ART/result.json`.
7. Evidence: `see`/`image` of the player bar (`sidebarPlayer_bar`).

## macOS — Voice Design smoke

1. Skeleton with `<mode> = design`.
2. Click `sidebar_voiceDesign`.
3. Fill the brief: click `voiceDesign_briefStarters` → pick `voiceDesign_briefStarter_0`
   (or type a custom brief into the brief field).
4. Type script text into `textInput_textEditor` — **readiness needs BOTH brief and text**.
5. Wait for `voiceDesign_readiness` → `ready=true`; capture `T0`; `Cmd+Return`.
6. `verify-generation design …`.

## macOS — Voice Cloning smoke

1. Skeleton with `<mode> = clone` (smoke-check also asserts a saved voice exists —
   `scripts/macos_test.sh models ensure` seeds `A_warm_elderly_woman`).
2. Navigate to Voices (`sidebar_voices`), open the saved voice's "use in clone" action
   (row ids `voicesRow_*`), which hands off to the Clone screen with the reference staged.
3. Type script text; wait for readiness; capture `T0`; `Cmd+Return`.
4. `verify-generation clone …` (default timeout 120 s — clone prefill is slower).

## macOS — settings / download UX tour (no generation)

1. `prep`, then `see` → `sidebar_settings` → confirm `settings_modelDownloadsSummary`.
2. Tour model rows; screenshot evidence per state. Do **not** start real downloads in a
   smoke unless the run is explicitly about download UX (bandwidth + state mutation).

---

## iOS — Studio smoke via mobile-mcp (DEPRECATED mirroir section below)

Device prep:

```sh
scripts/ios_mobile_mcp.sh preflight
scripts/ios_device.sh build && scripts/ios_device.sh install
scripts/ios_device.sh launch
```

Drive via **mobile-mcp**:

1. `mobile_list_available_devices` — confirm paired iPhone
2. `mobile_launch_app` → `com.patricedery.vocello`
3. `mobile_list_elements_on_screen` — find tabs and mode segments by identifier
4. Tour: Studio → Voices → History → Settings; re-list elements after each navigation
5. Evidence: `mobile_take_screenshot` or `scripts/ios_device.sh shot`

See [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) and Playbook F in [`ios-device-testing.md`](ios-device-testing.md).

---

## iOS — mirroir Studio smoke (native — preferred)

Preflight:

```sh
scripts/install_mirroir_user_config.sh --merge-settings   # once; restart Cursor
scripts/ios_mirroir_preflight.sh
scripts/ios_device.sh launch
```

Drive via **mirroir MCP** (not Peekaboo on the mirror):

1. `check_health` — must pass (Screen Recording + Accessibility for Cursor.app).
2. `describe_screen` — OCR + **window-relative** tap coordinates.
3. `tap` / `type_text` / `measure` — see [`ios-agent-ui-tour.md`](ios-agent-ui-tour.md) Appendix B.
4. Tour: Studio segments → Voices (row shortcuts if tab flaky) → History → Settings.
5. Evidence: `scripts/ios_device.sh shot build/<name>.png` if OCR capture fails.

**Custom generate smoke:** OCR **Generate** label → `tap` → `measure` until *Streaming preview* /
*Just now* → verify History row.

Legacy Peekaboo + `ios_vision_bridge.sh` — fallback only when `describe_screen` fails.

---

## iOS — mirroir Studio smoke (RETIRED hybrid — 2026-07-04)

Device prep (phone **unlocked**, Mirroring connected):

```sh
scripts/ios_device.sh build && scripts/ios_device.sh install
scripts/ios_device.sh launch          # plain launch, no autorun spec
scripts/ios_device.sh mirror          # ensure Mirroring is up/foreground
```

Drive via mirroir MCP:

1. `check_health` / `status` — session sanity.
2. `describe_screen` — OCR + tap coordinates for the current screen.
3. Tour: Studio (`Custom` / `Design` / `Clone` segments) → Voices → History → Settings
   tabs; `describe_screen` after each tap to confirm the transition.
4. Evidence: `scripts/ios_device.sh shot build/<name>.png` (observation lane) or the
   mirroir screenshot tool.

**Generation verification on iOS** for ad-hoc smokes: `scripts/ios_device.sh gate` (headless
autorun) or `scripts/ios_device.sh test --cold`. For the **full UI matrix**, use
[`bench-ui-mcp`](#ios--mobile-mcp-bench-ui-matrix-preferred) (same telemetry gate as
XCUITest `bench-ui`).

### iOS exploratory (mobile-mcp — preferred)

1. `scripts/ios_mobile_mcp.sh preflight` — WDA + mutex
2. `mobile_list_available_devices` → `scripts/ios_device.sh install`
3. `mobile_launch_app` → `com.patricedery.vocello`
4. `mobile_list_elements_on_screen` after each navigation (tabs, mode segments)
5. Evidence: `scripts/ios_device.sh shot` or `mobile_take_screenshot`

See [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) and Playbook F in
[`ios-device-testing.md`](ios-device-testing.md).

---

## iOS — mobile-mcp bench-ui matrix (preferred)

Agent-driven full-matrix bench: **mobile-mcp** drives via WDA accessibility tree; **shell proves**
via pulled `generations.jsonl` + `check_ios_ui_bench.py`.

### Session prep

```sh
scripts/ios_device.sh device-state
scripts/ios_mobile_mcp.sh preflight
scripts/ios_device.sh bench-ui-mcp --agent-drive \
  --warm 1 --lengths medium --modes custom --label "mcp-pilot"
```

The driver prints `MCP_BENCH_TAKE_BEGIN` blocks and waits for `take-N.done` after each take.

### Hybrid MCP loop (every take)

1. **Preflight once:** `scripts/ios_mobile_mcp.sh preflight` + `lock` (driver acquires lock)
2. **Perceive:** `mobile_list_elements_on_screen` — find `generateSection_*`, `textInput_*`
3. **Act:** element tap / `mobile_type_keys` — **not** mirror coordinates
4. **Measure:** `SINCE=$(scripts/ios_device.sh vision-now)` before Generate; after tap,
   `scripts/ios_device.sh vision-bench-wait --run-id … --since "$SINCE"`
5. **Signal:** `touch build/ios/bench-ui-mcp-<runID>/take-N.done`

Workflow map: [`ios-app-guide.md`](ios-app-guide.md).

---

## iOS — vision bench-ui matrix (DEPRECATED)

> **Deprecated 2026-07** — use [mobile-mcp bench-ui](#ios--mobile-mcp-bench-ui-matrix-preferred) instead.
> Retained for emergency fallback only.

Human-like full-matrix bench: **mirroir sees**, **Peekaboo clicks/types** on the Mac-side
Mirroring window, **shell proves** via pulled `generations.jsonl`.

### Session prep

```sh
scripts/ios_device.sh device-state          # exit 0
scripts/ios_device.sh models check --strict
scripts/ios_device.sh bench-ui-vision --agent-drive \
  --warm 1 --lengths medium --modes custom --label "vision-pilot"
```

The driver prints `VISION_BENCH_TAKE_BEGIN` blocks and waits for `take-N.done` after each take.

### Hybrid MCP loop (every take)

1. **Calibrate once** (driver does this): `scripts/lib/ios_vision_bridge.sh calibrate`
2. **Perceive:** mirroir `check_health` → `describe_screen` (OCR + window-relative tap coords)
3. **Transform:** `scripts/lib/ios_vision_bridge.sh to-global X Y` → screen coords for Peekaboo
4. **Act:** Peekaboo `window` focus (Mirroring app name from `mirror-app-name`) → `click coords:` with `foreground: true` → `type` for script text
5. **Confirm:** `describe_screen` again — verify tab/mode/keyboard state before Generate
6. **Measure:** capture `SINCE=$(scripts/ios_device.sh vision-now)` **before** Generate; after tap,
   `scripts/ios_device.sh vision-bench-wait --run-id … --since "$SINCE" --timeout …`
7. **Signal:** `touch build/ios/bench-ui-vision-<runID>/take-N.done`

Workflow map: [`ios-app-guide.md`](ios-app-guide.md) (tabs, `generateSection_*`, chips, sheets).

### Per-mode preparation (semantic)

| Mode | Vision check | Steps |
| --- | --- | --- |
| **custom** | OCR: `Custom` segment + composer | Tap Custom → clear script → type corpus text |
| **design** | `Voice brief:` chip | Tap chip → starter row or type brief once per warm session → type script |
| **clone** | Saved voice on device (`models check` → `cloneVoicesEnrolled`) | Voices tab → first saved card → handoff to Clone (no mic over mirror) |

### Clear composer

- OCR tap **`bench clear script`** (`QWENVOICE_UI_TEST_HOOKS=1` — driver sets via `vision-launch`)
- Fallback: tap editor → Peekaboo `hotkey cmd,a` + delete, then type

### Keyboard + Generate

- Tap composer → Peekaboo `type` with `foreground: true`, human `--wpm 120`
- Press `{return}` / Done to dismiss keyboard (**required** before Generate)
- Tap `Generate` via transformed coords; never tap while keyboard is visible

### Coordinate bridge

```sh
scripts/lib/ios_vision_bridge.sh calibrate build/ios/vision-bridge.json
scripts/lib/ios_vision_bridge.sh to-global 120 450   # → gx,gy for Peekaboo click
```

Recalibrate if taps miss (window moved/resized). French macOS: `~/.mirroir-mcp/settings.json` →
`mirroringProcessName`.

### Pilot vs full matrix

| Scope | Command | Takes (approx) |
| --- | --- | --- |
| Pilot | `--warm 1 --lengths medium --modes custom` | 2 (cold + warm medium) |
| Full | default flags | ~29 |

Gate: same `scripts/check_ios_ui_bench.py` as XCUITest `bench-ui` (driver runs at end).

---

## Failure triage

| Symptom | Do |
| --- | --- |
| `verify-generation` timeout | `scripts/uitest_measure.sh logs` (signpost stream); check `sidebar_backendStatus_error` via `see` |
| WAV/DB mismatch | Inspect `$ART/result.json` reason; `scripts/uitest_measure.sh db "SELECT id,mode,audioPath,duration FROM generations ORDER BY createdAt DESC LIMIT 3"` |
| Preview underrun/chunk gap | `streaming-preview-check` output names the failing signpost; escalate to the backend-mlx role |
| Focus stolen mid-run | `scripts/uitest_measure.sh activate`, re-`see`, continue |
| mirroir taps landing wrong | Re-run `describe_screen`; `scripts/lib/ios_vision_bridge.sh calibrate`; Peekaboo `window` focus Mirroring app |
| vision-bench-wait timeout | `ios_device.sh pull`; grep `engine/generations.jsonl` for `benchRunID`; check mirror still active (`device-state`) |
| Run died mid-flight for no code reason | `scripts/ios_device.sh device-state` — phone in use / call / mirror paused are named verdicts; bench sentinels also carry `interruptions` events |
