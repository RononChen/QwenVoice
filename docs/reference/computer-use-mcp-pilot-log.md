# Computer-use MCP pilot log (2026-07-01)

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
