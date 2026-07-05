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
