# Computer-use MCP alternatives for Cursor

Research-backed replacement paths for Claude Code’s embedded `mcp__computer-use__*` MCP when developing in **Cursor** on Apple Silicon. Historical context: [post-mortem §2.8](../post-mortem/2026-06-post-fable-development-hell.md).

**Pilot adopted (2026-07-01):** user-scoped **Peekaboo** + **mirroir-mcp** via [`computer-use-mcp-pilot-log.md`](computer-use-mcp-pilot-log.md).

**Current (2026-07-04 evening):** **Peekaboo** (macOS) + **mirroir** (iPhone Mirroring) in `~/.cursor/mcp.json` — re-validated in [`computer-use-mcp-pilot-log.md`](computer-use-mcp-pilot-log.md) §8. iOS agent UI map (living): [`ios-agent-ui-tour.md`](ios-agent-ui-tour.md). **mobile-mcp** deferred (WDA signing); see [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md).

---

## Critical framing

Claude Code computer-use was three layers:

1. **Platform MCP** — vision loop (`screenshot` → click/type/key)
2. **Model operator** — long-context agent (Fable 5)
3. **Repo shell** — deleted `uitest.sh` (prep/reset/bench-step/verify-generation)

**Cursor native “computer use” (cloud agents, Jun 2026+)** runs in **remote VMs** for PR artifacts — not on your local Mac for MLX Metal + XPC. For Vocello you need **local MCP servers** in user or project config.

**Vocello hard rules (unchanged):**

- Real-engine iOS = **physical device only** (`scripts/ios_device.sh`)
- [`scripts/ios_device.sh`](../../scripts/ios_device.sh) `mirror` / `shot` = **observation only** — no shell coordinate driving
- Pre-merge gates: `macos_test.sh gate`, `ios_device.sh gate`

---

## User-scoped setup (current — Peekaboo + mirroir)

Config lives in **`~/.cursor/mcp.json`** (all projects). **Do not commit** this file or API keys to the repo.

### 1. Stdio wrapper (Cursor spawn fix)

Required because Cursor may set `ELECTRON_RUN_AS_NODE` and a broken PATH when spawning stdio MCP children.

Create **`$HOME/.cursor/bin/mcp_stdio_wrapper.sh`** (if not already present):

```bash
#!/usr/bin/env bash
set -euo pipefail
unset ELECTRON_RUN_AS_NODE
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
exec npx -y "$@"
```

```bash
chmod +x "$HOME/.cursor/bin/mcp_stdio_wrapper.sh"
```

### 2. Merge into `~/.cursor/mcp.json`

Add **peekaboo** + **mirroir** alongside existing servers (context7, xcodebuildmcp, axiom):

```json
"peekaboo": {
  "command": "/Users/you/.cursor/bin/mcp_stdio_wrapper.sh",
  "args": ["@steipete/peekaboo", "mcp"]
},
"mirroir": {
  "command": "/Users/you/.cursor/bin/mcp_stdio_wrapper.sh",
  "args": ["mirroir-mcp"]
}
```

French macOS: `~/.mirroir-mcp/settings.json` → `{"mirroringProcessName": "Recopie de l'iPhone"}`.

Cmd+Q and reopen Cursor after editing `mcp.json`.

### Verify

- Settings → MCP → **peekaboo** (~27 tools) + **mirroir** (~11 tools) Connected
- Peekaboo `permissions`; mirroir `check_health` + `status`
- Full validation log: [`computer-use-mcp-pilot-log.md`](computer-use-mcp-pilot-log.md) §8

---

## User-scoped setup (deferred — mobile-mcp)

See [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) for WDA prerequisites. Pin `@mobilenext/mobile-mcp@0.0.61` with `MOBILEMCP_DISABLE_TELEMETRY=1` when WDA signing is unblocked.

---

## User-scoped setup (reference — Peekaboo + mirroir detail)

Config lives in **`~/.cursor/mcp.json`** (all projects). **Do not commit** this file or API keys to the repo.

### 1. Stdio wrapper (Cursor spawn fix)

Peekaboo’s [official MCP docs](https://peekaboo.sh/MCP.html) recommend bare `npx`. We use a wrapper because Cursor may set `ELECTRON_RUN_AS_NODE` and a broken PATH when spawning stdio MCP children ([forum report](https://forum.cursor.com/t/cursor-3-4-20-kills-stdio-mcp-servers-1-5s-after-successful-initialize-sigkill-v2-fsm-race/160892)).

The wrapper does **not** change tool names or schemas — it only `exec`s into the real MCP server.

Create **`$HOME/.cursor/bin/mcp_stdio_wrapper.sh`**:

```bash
#!/usr/bin/env bash
set -euo pipefail
unset ELECTRON_RUN_AS_NODE
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
exec npx -y "$@"
```

```bash
chmod +x "$HOME/.cursor/bin/mcp_stdio_wrapper.sh"
```

### 2. Merge into `~/.cursor/mcp.json`

Add alongside existing servers (e.g. context7, xcodebuildmcp):

```json
"peekaboo": {
  "command": "$HOME/.cursor/bin/mcp_stdio_wrapper.sh",
  "args": ["@steipete/peekaboo", "mcp"]
},
"mirroir": {
  "command": "$HOME/.cursor/bin/mcp_stdio_wrapper.sh",
  "args": ["mirroir-mcp"]
}
```

Use your expanded home path in the JSON file (JSON does not expand `$HOME` — substitute literally, e.g. `/Users/you/.cursor/bin/mcp_stdio_wrapper.sh`).

### 3. Permissions (Cursor.app)

| Permission | Peekaboo | mirroir |
| --- | --- | --- |
| Accessibility | Input, AX tree | tap/type |
| Screen Recording | `image`, `see` | screenshot, OCR |

Grant to **Cursor.app**, not Terminal. Cmd+Q and reopen Cursor after editing `mcp.json`.

### TCC repeat-prompt quirk

macOS may show a Screen Recording prompt from Cursor **even when Cursor is already ON** in System Settings → Privacy & Security → Screen & System Audio Recording. Common causes:

- The MCP spawn chain (`npx` → Node → Peekaboo/mirroir) triggers a fresh Allow tied to the in-app tool call.
- Peekaboo may route capture through **Peekaboo Bridge** — grant the Bridge host if it appears ([Peekaboo permissions](https://peekaboo.sh/permissions.html)).

**Fix:** Click **Allow** when the prompt appears during an Agent tool call, Cmd+Q Cursor, reopen, confirm Settings → Tools & MCP shows green for `peekaboo` and `mirroir`. Run `peekaboo permissions status --all-sources` in Terminal if still stuck.

### mirroir on localized macOS (e.g. French)

mirroir-mcp locates the Mirroring window by process name **"iPhone Mirroring"**; localized
systems rename it (French: **"Recopie de l'iPhone"**) and every tool fails with
*"'iphone' is not open"*. Fix once in `~/.mirroir-mcp/settings.json`:

```json
{ "mirroringProcessName": "Recopie de l'iPhone" }
```

(Use the exact localized name from `System Events`, including the typographic apostrophe.)
Restart Cursor so the MCP server re-reads settings. Reference:
[mirroir configuration](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/configuration.md).

### Verify

- Settings → MCP → **peekaboo** + **mirroir** Connected
- Agent chat: Peekaboo `list` or `permissions`; mirroir `status` or `check_health`
- Second tool call in same turn — confirms session not SIGKILL’d mid-flight

Terminal sanity (optional): `"$HOME/.cursor/bin/mcp_stdio_wrapper.sh" @steipete/peekaboo permissions status`

---

## Recommended stacks

### Option 1 — Recreate Fable exploratory loop (RETIRED 2026-07-04)

| Platform | MCP | Role |
| --- | --- | --- |
| macOS | [Peekaboo](https://github.com/steipete/Peekaboo) | ~~AX + screenshot~~ — removed from user config |
| iOS | [mirroir-mcp](https://github.com/jfarcand/mirroir-mcp) | ~~Mirror OCR + HID~~ — removed from user config |

**Superseded by:** [mobile-mcp](https://github.com/mobile-next/mobile-mcp) for iOS agent UI; macOS uses script gates + Axiom auditors.

### Option 2 — Precision + accessibility IDs

| Platform | MCP |
| --- | --- |
| macOS | Peekaboo or [mac-control-mcp](https://github.com/AdelElo13/mac-control-mcp) |
| iOS | [appium/appium-mcp](https://github.com/appium/appium-mcp) via WDA — see [on-device-ui-testing-research-report.md §4.2](on-device-ui-testing-research-report.md) |

Stateful Appium needs persistent server or [mcpkit](https://github.com/balakumardev/mcpx) — Cursor stdio respawn risk.

### Option 3 — Background macOS only

[Cua Driver](https://cua.ai/docs/cua-driver/guide/getting-started/introduction) — agent drives apps without stealing cursor; iOS stays on `ios_device.sh` + XCUITest.

---

## Tier A — macOS desktop MCPs (survey)

| Project | Notes |
| --- | --- |
| **Peekaboo** | ~4.7k ★; explicit Cursor docs; 40+ tools (`see`, `image`, `click`, `hotkey`, …) |
| **computer-use-mcp** (minghinmatthewlam) | Background-safe Swift binary; vision-first |
| **Cua Driver** | Signed app bundle for TCC; background input ladder |
| **mac-control-mcp** | 63-tool Swift `.app`; AX + OCR + browser |
| **macos-computer-use-mcp** | Near CC tool names (`left_click`, `screenshot`) |
| **background-computer-use** | AX-first, no focus steal |
| **MacOS-MCP** | Lightweight AX via `uvx macos-mcp` |

**Not GUI automation:** Desktop Commander (shell/files only), macOS Automator MCP (AppleScript recipes).

---

## Tier B — iPhone via Mirroring

| Project | Notes |
| --- | --- |
| **mirroir-mcp** | 33 tools; DriverKit HID; `describe_screen` + `tap`; no programmatic clipboard paste to iPhone |
| **MCP-MacOSControl** | `iphone_*` normalized 0–1 coords + macOS tools |
| **iphone-mirror-mcp** | Smaller fork; similar normalized coords |

Mirror driving is **exploratory only** — brittle vs WDA/XCUITest ([research §4.7](on-device-ui-testing-research-report.md)).

---

## Tier C — iPhone via WDA (mobile-mcp / Appium)

**Preferred (2026-07):** [**mobile-mcp**](https://github.com/mobile-next/mobile-mcp) (`@mobilenext/mobile-mcp`) — packaged WDA + MCP tools (`mobile_list_elements_on_screen`, taps, typing). Real device only for Vocello MLX. Setup: [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md), preflight `scripts/ios_mobile_mcp.sh`.

**Fallback:** Official **`appium/appium-mcp`**: heavier session ceremony; same WDA + `accessibilityIdentifier` surface if mobile-mcp spike fails.

Mirror driving (Tier B) is **observation only** — do not extend for agent bench matrix.

---

## Tier D — Insufficient alone for Vocello

| Option | Why |
| --- | --- |
| Cursor cloud agent computer use | Remote VM — no local MLX |
| cursor-ide-browser | Web only |
| XcodeBuildMCP simulator tools | Off-limits for real MLX iOS (AGENTS.md §7) |
| Axiom xcui / simulator-tester | Same |

---

## Agent routing (Vocello)

| Task | Use |
| --- | --- |
| macOS exploratory UI / ad-hoc settings tours | **Peekaboo** MCP (`see` first, then element IDs) |
| iOS exploratory UI + agent bench matrix | **mobile-mcp** (WDA tree; `bench-ui-mcp --agent-drive`) |
| iOS observation (no taps) | `scripts/ios_device.sh shot` or `mobile_take_screenshot` |
| macOS regression | `scripts/macos_test.sh gate` |
| iOS regression | `scripts/ios_device.sh gate` |
| Crash / profile / audit analysis | **Axiom MCP** (`user-axiom`: `axiom_xcsym_*`, `axiom_xcprof_*`, `axiom_get_agent`) |
| Deterministic bench timing / generation verification | `scripts/uitest_measure.sh` (verify-generation, streaming-preview-check, bench-compare) — no MCP replaces it |

---

## Comparison vs Claude Code embedded computer-use

| Capability | CC embedded | Cursor pilot |
| --- | --- | --- |
| Vision macOS loop | Built-in | Peekaboo |
| iPhone UI drive (real device) | CC + Fable | **mobile-mcp** (WDA) |
| iOS AX tree | No (mirror) | **mobile-mcp** / Appium WDA |
| Measurement shell | Deleted `uitest.sh` | **Restored** — `scripts/uitest_measure.sh` (2026-07-01) |
| Zero setup | Yes | User `mcp.json` + TCC |

---

## Sources

- [Peekaboo MCP](https://peekaboo.sh/MCP.html) · [GitHub](https://github.com/steipete/Peekaboo)
- [mirroir-mcp](https://github.com/jfarcand/mirroir-mcp) · [mirroir.dev](https://mirroir.dev)
- [mobile-mcp](https://github.com/mobile-next/mobile-mcp) · [evaluation doc](mobile-mcp-ios-evaluation.md)
- [appium/appium-mcp](https://github.com/appium/appium-mcp)
- [Cursor cloud computer use](https://cursor.com/blog/agent-computer-use)
- [Post-mortem §2.8](../post-mortem/2026-06-post-fable-development-hell.md)
