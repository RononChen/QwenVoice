# Computer-use MCP pilot log (2026-07-01)

> **Reopened 2026-07-04 (evening):** **Peekaboo** + **mirroir** restored in `~/.cursor/mcp.json`
> (Option 3 — macOS Peekaboo + iPhone mirroir). **mobile-mcp** deferred (WDA signing blocked).
> §7 closure below is historical; current validation is §8.

Pilot for **Option 1**: user-scoped **Peekaboo** (macOS) + **mirroir-mcp** (iPhone Mirroring) in `~/.cursor/mcp.json`, launched via `~/.cursor/bin/mcp_stdio_wrapper.sh`.

**Regression gates unchanged:** `scripts/macos_test.sh gate`, `scripts/ios_device.sh gate`. Exploratory agent QA only — not CI.

---

## 1. User config installed

| Item | Status |
| --- | --- |
| `~/.cursor/bin/mcp_stdio_wrapper.sh` | Created, executable (`exec npx -y "$@"`) |
| `~/.cursor/mcp.json` → `peekaboo` | Added (wrapper → `@steipete/peekaboo mcp`) |
| `~/.cursor/mcp.json` → `mirroir` | Added (wrapper → `mirroir-mcp`) |
| `~/.mirroir-mcp/settings.json` | **`mirroringProcessName` override for French macOS** (see §5) |
| Existing `context7`, `xcodebuildmcp` | Preserved |

---

## 2. TCC + Cursor MCP panel (2026-07-01, post-restart)

| Check | Result |
| --- | --- |
| Screen Recording + Accessibility for **Cursor.app** | **Granted** (System Settings; initial repeat-prompt quirk resolved after grant + restart) |
| Cursor → Settings → Tools & MCP | **Connected** (green) for all servers |
| **peekaboo** tools enabled | **27** |
| **mirroir** tools enabled | **11** (curated MCP subset; full catalog is larger) |
| **context7** / **xcodebuildmcp** | Unchanged (2 / 59+4 tools) |

**TCC note:** Cursor may prompt for Screen Recording even when “Cursor” is already ON in Settings — the MCP child chain (`npx` → Node → Peekaboo/mirroir) can need a fresh Allow from an in-app tool call. See [`computer-use-mcp-alternatives-cursor.md`](computer-use-mcp-alternatives-cursor.md) troubleshooting.

---

## 3. Wrapper + stdio validation (initial probe)

| Check | Result |
| --- | --- |
| Wrapper → `peekaboo permissions status` | Pass — Screen Recording, Accessibility, Event Synthesizing granted (terminal probe) |
| Live validation | **Superseded by §2** — Cursor MCP panel green after TCC + restart |

---

## 4. macOS Vocello — FULL generate loop via Peekaboo MCP (2026-07-01 evening)

**Validated end to end in Agent chat**, paired with the restored measurement shell
[`scripts/uitest_measure.sh`](../../scripts/uitest_measure.sh):

| Step | Result |
| --- | --- |
| `uitest_measure.sh reset` + `prep` (debug-data mode, single-instance guard) | Pass |
| Peekaboo `see` on Vocello | Pass — **291 AX elements** incl. all `accessibilityIdentifier`s (`sidebar_*`, `textInput_*`, `customVoice_readiness`, …) |
| `click` editor + `type` 126-char script | Pass — `textInput_charCount` = “126 characters”, readiness → ready |
| `hotkey cmd,return` (app-targeted) | Pass — generation started |
| `uitest_measure.sh verify-generation custom` | **Pass** — WAV (365 KB, 7.52 s) + `history.sqlite` row matched, `result.json` written |
| `uitest_measure.sh streaming-preview-check` | **Pass** — Live Engine Play + Autoplay Start before final; 0 underruns, 0 chunk gaps |
| `uitest_measure.sh finish` | Pass — debug flag cleared |

**Hard-won operational rules (encoded in the shell):**

1. **Never** `tell application "Vocello" to activate` / `open -na` while a measured
   session runs — LaunchServices can spawn a **second instance without debug mode**
   whose takes land in the user's real library. `prep` writes the persisted DebugMode
   flag + enforces a single instance; `activate` targets the PID via System Events;
   `finish` clears the flag.
2. **Signpost store lag:** `log show` exposes fresh `os_signpost` events only after a
   multi-minute logd flush. `bench-wait` therefore waits on the **history.sqlite row**
   (written at the same instant as “Final File Ready”) and uses the signpost store as
   fallback; `streaming-preview-check` queries with `--start <since>` (not `--last Nm`).
3. Peekaboo `type`/`hotkey`: click the field first (`foreground: true`), then type at
   focus; target hotkeys at the app (`app: "Vocello"`).

Per-mode procedures: [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md).

---

## 5. iOS mirroir — blocked on localized window name, fix staged

| Step | Result |
| --- | --- |
| `scripts/ios_device.sh build` + `install` + `launch` | Pass (app on device, foreground) |
| iPhone Mirroring up (`ios_device.sh mirror`) | Pass — window present |
| mirroir `status` / `describe_screen` | **FAIL — “'iphone' is not open”** |
| Root cause | mirroir-mcp looks up the Mirroring window by process name **“iPhone Mirroring”**; French macOS names it **“Recopie de l’iPhone”** |
| Fix | `~/.mirroir-mcp/settings.json` → `{"mirroringProcessName": "Recopie de l’iPhone"}` ([config reference](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/configuration.md)) |
| Status | **Settings written; requires Cursor restart** (mirroir reads settings at server startup) — re-run the Studio tour after restart |

**Planned tour after restart:** `check_health` → `describe_screen` → Studio tab smoke
(Custom/Design/Clone segments) → Settings → Model Downloads (drive the one-time
Voice Design (Speed) install the hardened gate needs) → evidence via `ios_device.sh shot`.

---

## 6. Summary

| Goal | Status |
| --- | --- |
| Peekaboo connected + full macOS generate loop | ✅ **Done** (verified WAV + DB + streaming health) |
| Deterministic measurement decoupled from driving | ✅ `uitest_measure.sh` restored |
| mirroir connected | ✅ (11 tools) |
| mirroir driving Vocello iOS | ⏳ blocked on Cursor restart for the localization fix |
| Gates | Unchanged — XCUITest + script lanes remain authoritative |

---

## 7. Closure (2026-07-04)

| Action | Status |
| --- | --- |
| Remove `peekaboo` + `mirroir` from `~/.cursor/mcp.json` | Done |
| Add `mobile-mcp` (`@mobilenext/mobile-mcp@0.0.61`, telemetry off, stdio wrapper) | Done |
| iOS agent UI | **mobile-mcp** + `bench-ui-mcp` — see [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) |
| macOS agent UI | Script gates + `uitest_measure.sh` + Axiom (Peekaboo no longer in MCP config) |

---

## 8. Full re-validation (2026-07-04 evening)

After restoring **Peekaboo** + **mirroir** in `~/.cursor/mcp.json` (stdio wrapper unchanged).

### Phase 1 — connectivity smoke

| Check | Result |
| --- | --- |
| Peekaboo `permissions` | **Pass** — Screen Recording + Accessibility granted |
| mirroir `check_health` | **Pass** — mirroring window 326×720, capture OK |
| mirroir `status` | **Pass** — connected, mirroring active (not paused) |

### Phase 2 — macOS full generate loop (Peekaboo)

| Step | Result |
| --- | --- |
| `uitest_measure.sh prep` (debug-data mode) | Pass |
| Peekaboo `see` (`PID:77904`) | Pass — **291 AX elements** (`screen_customVoice`, `textInput_*`, …) |
| `click` editor + `type` 117-char script | Pass — `customVoice_readiness` → `ready=true` |
| `hotkey cmd,return` (`app: Vocello`) | Pass |
| `verify-generation custom` | **Pass** — WAV 392 KB, 8.08 s, `db_id=307` |
| `streaming-preview-check` | **Pass** — 1 Live Engine Play, 0 underruns, 0 chunk gaps |
| `finish` | Pass |

### Phase 3 — iOS Studio tour (mirroir + Peekaboo mirror clicks)

| Step | Result |
| --- | --- |
| `ios_device.sh device-state` | Pass |
| `build` + `install` + `launch` | Pass |
| `ios_vision_bridge.sh calibrate` | Pass — `Recopie de l'iPhone` rect 919,30,326,720 |
| mirroir `describe_screen` (Studio / Custom) | Pass — segments + composer OCR |
| Segment taps (Custom / Design / Clone) | **Pass** — distinct OCR per segment |
| Tab: Settings (`to-global` + Peekaboo click y≈690) | **Pass** — VOICE MODELS, Storage, … |
| Tab: Studio (label y≈619) | **Pass** — returned to composer |
| Tab: History (label y≈618) | **Pass** — search + generation rows |
| Tab: Voices | **Partial** — tab tap did not switch screen in this session |
| `ios_device.sh shot` | Pass — `build/ios/mcp-tour-20260704-1910.png` |

**iOS hybrid rule confirmed:** mirroir `describe_screen` → `ios_vision_bridge.sh to-global` → Peekaboo
`click coords:` with `foreground: true`. Segment controls (top bar) are reliable; bottom tab bar may
need label coords (y≈619–690) — icon-only taps at y≈719 were inconsistent.

### Phase 3 summary

| Goal | Status |
| --- | --- |
| Peekaboo + mirroir connected | ✅ |
| macOS generate loop | ✅ (reproduced Jul 1 pilot) |
| iOS mirroir perception + hybrid navigation | ✅ (segments + Settings/History; Voices flaky) |
| Gates | Unchanged |

---

## 9. mirroir hardening (2026-07-04 evening)

Research: [mirroir-mcp](https://github.com/jfarcand/mirroir-mcp) docs + failed agent generate session (0/3 clips).

### Root causes (agent session)

| Issue | Cause |
| --- | --- |
| `describe_screen` / `check_health` capture fail | TCC / cross-Space / paused mirror — while `ios_device.sh shot` still worked |
| Only ~11 mirroir tools | **fail-closed** default — no `permissions.json` → `tap`/`type_text` hidden |
| Peekaboo hybrid coord miss | Generate tap hit **NE** chip (~30–40 px) — no OCR anchor |
| Bottom **Studio** tab taps | Flaky — **Aiden row** shortcut worked |

### Repo changes (implemented)

| Artifact | Purpose |
| --- | --- |
| [`.mirroir-mcp/permissions.json`](../../.mirroir-mcp/permissions.json) | Expose tap/type/measure; skip destructive labels |
| [`.mirroir-mcp/settings.json`](../../.mirroir-mcp/settings.json) | Force OCR mode, `en-US` |
| [`.mirroir-mcp/skills/apps/Vocello/APP.md`](../../.mirroir-mcp/skills/apps/Vocello/APP.md) | mirroir exploration context |
| [`scripts/install_mirroir_user_config.sh`](../../scripts/install_mirroir_user_config.sh) | Copy permissions + merge settings to `~/.mirroir-mcp/` |
| [`scripts/ios_mirroir_preflight.sh`](../../scripts/ios_mirroir_preflight.sh) | device-state, mirror, bridge calibrate |
| [`ios-agent-ui-tour.md`](ios-agent-ui-tour.md) Appendix B | Native driving loop (preferred over Peekaboo hybrid) |

### Operator steps (once per machine)

```bash
scripts/install_mirroir_user_config.sh --merge-settings
# Cmd+Q Cursor → reopen
scripts/ios_mirroir_preflight.sh --doctor
# In Agent: mirroir check_health → describe_screen on Studio/Custom
```

**Driving rule:** `describe_screen` → **`mirroir tap`** (not Peekaboo on mirror). Peekaboo stays **macOS Vocello only**.

### Next validation

| Step | Expected |
| --- | --- |
| mirroir tool count | ~25+ after permissions + Cursor restart |
| `check_health` | Pass — window 326×720, capture OK |
| Custom generate smoke | OCR **Generate** coords → tap → `measure` until player |
| 3 funny clips retry | Native loop only |

---

## 10. Anti-patterns and efficiency remediation (2026-07-04 night)

Follow-up to the **post-restart 3-clip Custom smoke** (3/3 success, ~20–30% wasted actions).
Invariants codified in [`ios-agent-ui-tour.md`](ios-agent-ui-tour.md) Appendix **B.5–B.6** and
[`.cursor/rules/agent-ui-driving.mdc`](../../.cursor/rules/agent-ui-driving.mdc).

### Observed anti-patterns (Jul 4 run)

| Anti-pattern | Cost | Fix |
| --- | --- | --- |
| Tap coords without OCR (e.g. guessed dismiss) | Wrong state / recovery taps | **OCR-only** — B.5 |
| **Voices tab ×2** mid-Studio between clips | +4–6 taps | **Stay on Studio** — B.5 / B.6 |
| **130 s fixed sleep** after 5 s clip | ~125 s wasted | **Poll / measure** every 5–8 s |
| Duplicate `ios_device.sh mirror` | Redundant setup | Preflight once |
| Screenshot + read image unprompted | Context noise | Evidence only on OCR fail |
| `press_key` without Auto-review approval | Failed round-trip | `requestSmartModeApproval` upfront |

### Validation acceptance (3-clip Custom smoke, native mirroir)

Re-run under B.5–B.6 rules and record:

| Metric | Target |
| --- | --- |
| Illegal transitions | **0** (see B.6 table) |
| UI actions per clip | **≤15** (describe_screen + tap/type + dismiss) |
| Idle wait per generate | **<30 s** wall-clock beyond actual TTS (poll, don't sleep) |
| Voices tab opens mid-session | **0** |

Results: see **§10.1** below after validation rerun.

### §10.1 Validation rerun results (2026-07-04, B.5–B.6 rules)

**Session:** `ios_mirroir_preflight.sh --native-only`; mirror resumed; Studio → Custom.

| Metric | Clip 1 | Clip 2 | Clip 3 | Target |
| --- | --- | --- | --- | --- |
| Illegal transitions | 0 | 0 | — | 0 |
| Voices tab opens | 0 | 0 | — | 0 |
| Poll wait (not fixed sleep) | ~8 s | — | — | <30 s idle |
| UI actions (tap/type/press) | 4 | 10+ (incomplete) | — | ≤15/clip |
| describe_screen calls | 4 | 6+ | — | — |
| Outcome | **PASS** (Aiden/NE, ~4 s) | **BLOCKED** | — | 3/3 |

**Clip 1 (efficient):** History → Studio (O-A-V) → composer → script → Generate → poll 8 s →
`Just now • Custom` + `0:04`. No Voices tab, no fixed 130 s sleep, no screenshot.

**Clip 2 (blocked):** Stay-on-Studio path worked (RY chip → Happy via delivery sheet → script
replace). **Generate not in OCR** while clip 1 inline player remained; **X** dismiss label
intermittent (visible once at `(277, 573)` after voice pick, absent afterward). Esc / player-body
tap did not surface **X** or **Generate**.

**Follow-up doc fix:** B.5 — dismiss inline player **immediately** after generate poll, before chip
changes (X drops from OCR otherwise).

**Clips 2–3:** Re-run when maintainer available — dismiss player right after each generate poll.
