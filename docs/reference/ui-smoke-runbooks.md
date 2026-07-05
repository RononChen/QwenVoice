# UI smoke runbooks — agent-driven exploratory loops

Per-mode smoke procedures for **agent-driven** UI validation in Cursor, pairing
**mirroir** on iOS (native iPhone Mirroring OCR) and **Peekaboo + uitest_measure** on macOS.
See [`computer-use-mcp-alternatives-cursor.md`](computer-use-mcp-alternatives-cursor.md).
**mobile-mcp** (WDA) remains **deferred** — see [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md).

Successor to the per-mode smoke runbooks deleted at `6d1cca4`. The core design rule
survives: **measurement never depends on how the agent clicked.** Pass/fail comes from
OSSignposts + `history.sqlite` + the WAV on disk via `verify-generation` — the MCP only
drives the UI like a human.

**These runbooks are exploratory QA, not gates.** Regression gates stay
`scripts/macos_test.sh gate` and `scripts/ios_device.sh gate`.

**Driving discipline:** [`.cursor/rules/agent-ui-driving.mdc`](../../.cursor/rules/agent-ui-driving.mdc)
— **Observe → act once → verify** on every step; OCR/AX ids only; poll don't sleep.

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

Peekaboo driving pattern (**O-A-V loop** — match iOS mirroir discipline in Appendix **B.5–B.8**):

1. **`see`** with `app: Vocello` — observe AX map (`accessibilityIdentifier`s on elements).
2. **Act once** — click by element id from `see`; keyboard-first script replace (Cmd+A, Delete, type).
3. **`see` again** — verify state before the next action. No back-to-back clicks.
4. SwiftUI pickers re-anchor after first open — re-`see` before the second picker interaction.
5. Watch `*_readiness` markers (`ready=true` in element value) before Generate.
6. **Generate wait:** re-`see` every few seconds for player bar — no multi-minute fixed sleeps.
7. Fallback: `image` + click-by-sight only when AX id missing.

### macOS — Custom Voice multi-clip (O-A-V)

Same skeleton as single-clip; between clips on Studio → Custom:

- **Do not** navigate away from Custom Voice screen.
- Replace script via keyboard (Cmd+A, Delete, type).
- Cmd+Return to generate; re-`see` until player appears.
- Dismiss/clear player if it blocks Generate before the next clip.

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

## iOS — procedure index

| Need | Doc / script |
| --- | --- |
| **Exploratory smokes (agent)** | This file § mirroir Studio smoke + [`ios-agent-ui-tour.md`](ios-agent-ui-tour.md) Appendix B |
| **Driving invariants (always on)** | [`.cursor/rules/agent-ui-driving.mdc`](../../.cursor/rules/agent-ui-driving.mdc) |
| **App map + XCTest ids** | [`ios-app-guide.md`](ios-app-guide.md) |
| **Device lanes / gates** | [`ios-device-testing.md`](ios-device-testing.md) Playbooks A–D |
| **Preflight** | `scripts/ios_mirroir_preflight.sh --native-only` |
| **Full UI matrix** | XCUITest `scripts/ios_device.sh bench-ui` — **not** agent-driven |
| **mobile-mcp (WDA)** | **Deferred** — [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) |

---

## iOS — mirroir Studio smoke (primary)

Preflight:

```sh
scripts/install_mirroir_user_config.sh --merge-settings   # once; restart Cursor
scripts/ios_mirroir_preflight.sh --native-only              # skip vision-bridge when native OCR works
scripts/ios_device.sh launch
```

Drive via **mirroir MCP** (not Peekaboo on the mirror) — **Appendix B.5–B.8** in
[`ios-agent-ui-tour.md`](ios-agent-ui-tour.md):

1. `check_health` — must pass (Screen Recording + Accessibility for Cursor.app).
2. **`describe_screen`** — observe OCR + window-relative coords.
3. **One action** — `tap` / `type_text` / `measure`.
4. **`describe_screen`** — verify transition. Repeat (O-A-V loop).
5. **Stay on Studio → Custom** for multi-clip smokes — change voice/delivery via chip row only.
6. End-of-session optional: **History** tab to verify rows.

**Custom generate smoke:** OCR **Generate** → verify **`N / 150` N > 0** (B.8) → `tap` → poll / `measure` until
*Just now* → **DISMISS_POLL** for **X** (B.7) → next clip or `scripts/ios_device.sh launch` RESET.

**iOS script entry (mirror):** type-only on `0/150`; replace uses cmd+a → **delete** → type — **not** macOS Peekaboo rules.

**Evidence:** `scripts/ios_device.sh shot` **only** when `describe_screen` fails or the user asks.

**Generation proof (not agent-driven):** `scripts/ios_device.sh gate`, `test --cold`, or headless `bench` — for ad-hoc smokes after mirroir driving. **Full UI matrix:** XCUITest `scripts/ios_device.sh bench-ui`.

Legacy Peekaboo + `ios_vision_bridge.sh` — fallback only when `describe_screen` fails.

---

## iOS — archived procedures (do not use for new smokes)

<details>
<summary>RETIRED hybrid mirroir + Peekaboo (Jul 2026) — superseded by native mirroir above</summary>

Device prep: `ios_device.sh build && install && launch && mirror`. Same O-A-V loop but
Peekaboo clicked mirror-window coords via `ios_vision_bridge.sh` — higher error rate.
Use native **`tap`/`type_text`** from `describe_screen` coords instead.

</details>

<details>
<summary>mobile-mcp exploratory (deferred — WDA signing blocked)</summary>

Use [mirroir smoke](#ios--mirroir-studio-smoke-primary) for exploratory QA. When WDA unblocks,
see [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) and Playbook F in
[`ios-device-testing.md`](ios-device-testing.md).

</details>

---

## iOS — mobile-mcp bench-ui matrix (deferred)
> **Deferred 2026-07** — use XCUITest `bench-ui` for matrix; mirroir for exploratory smokes.
> Retained for when WDA signing unblocks.

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

> **Deprecated 2026-07** — use XCUITest [`scripts/ios_device.sh bench-ui`](../../scripts/ios_device.sh) for the matrix; mirroir for exploratory smokes only.
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
