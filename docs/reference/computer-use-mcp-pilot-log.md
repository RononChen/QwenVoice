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

**Cursor session stability:** MCP panel shows persistent connection after restart. Multi-tool calls in Agent chat not formally benchmarked in this log pass.

---

## 3. Wrapper + stdio validation (initial probe)

| Check | Result |
| --- | --- |
| Wrapper → `peekaboo permissions status` | Pass — Screen Recording, Accessibility, Event Synthesizing granted (terminal probe) |
| Wrapper → MCP `initialize` + `tools/list` (scripted newline JSON) | Inconclusive — exit 0, empty stdout (npm MCP framing differs from naive probe) |
| Live validation | **Superseded by §2** — Cursor MCP panel green after TCC + restart |

---

## 4. macOS Vocello smoke (Peekaboo CLI equivalent)

| Step | Result |
| --- | --- |
| `./scripts/build.sh build` | Pass — `build/Vocello.app` |
| Launch Vocello | Pass |
| `peekaboo list windows --app Vocello` | Pass — main window 720×612 at (211, 30) |
| `peekaboo see --app Vocello --window-title Vocello` | Pass — **79** AX elements, **51** interactable (Speed/Quality chips, voice row, etc.) |
| `peekaboo image --app Vocello` | Pass — screenshot captured |
| Full generate loop via Peekaboo MCP in Agent chat | **Not logged yet** |
| Full generate loop (`type` + `cmd+return` + player verify) via CLI | **Not run** (avoid side effects on user history) |

**Friction vs old `uitest.sh` + CC computer-use:**

- Peekaboo exposes rich AX map (`elem_*` IDs) — closer to precision-first than pure pixel math; aligns with Vocello `accessibilityIdentifier` surface.
- No restored `prep`/`reset`/`verify-generation` shell — measurement still decoupled manually via scripts if needed.
- **MCP path validated** via Cursor panel (§2); Agent-driven Vocello flows ready to try.

---

## 5. iOS mirroir smoke

| Step | Result |
| --- | --- |
| `scripts/ios_device.sh preflight` | Partial — device paired, signing OK, Mirroring up; **iOS app not built** on device at initial probe |
| `scripts/ios_device.sh shot` → `build/pilot-mirror-shot.png` | Pass — Mirroring window captured |
| Mirrored content (initial) | **Files app** — Vocello not foreground on phone |
| mirroir MCP connected in Cursor | **Pass** (§2, 11 tools) |
| mirroir `describe_screen` / `tap` on Vocello UI | **Not run yet** — needs `ios_device.sh build` + Vocello foreground on phone |

**Next steps for full iOS pilot:** `scripts/ios_device.sh build` + install, launch Vocello on phone, unlock once, then mirroir `status` → `describe_screen` → Studio tab smoke in Agent chat.

---

## 6. Summary

| Layer | Verdict |
| --- | --- |
| User MCP config + wrapper | **Installed** |
| TCC (Cursor.app) | **Granted** |
| Cursor MCP live session | **Connected** (peekaboo 27, mirroir 11 tools) |
| Peekaboo macOS observe Vocello | **Works** (CLI); MCP ready |
| mirroir iOS drive | **MCP connected**; Vocello-on-device smoke **pending** |
| Replace XCUITest gates | **No** — exploratory only |

See [`computer-use-mcp-alternatives-cursor.md`](computer-use-mcp-alternatives-cursor.md) for full alternative survey and setup reference.
