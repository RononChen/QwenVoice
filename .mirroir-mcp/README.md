# mirroir-mcp — Vocello project config

Project-local overrides for [mirroir-mcp](https://github.com/jfarcand/mirroir-mcp) when driving
**Vocello iOS** via iPhone Mirroring from Cursor. Merged with `~/.mirroir-mcp/` (project wins).

| File | Purpose |
| --- | --- |
| [`settings.json`](settings.json) | OCR mode, languages — deterministic `describe_screen` |
| [`permissions.json`](permissions.json) | Expose `tap`, `type_text`, `measure`, … (mirroir defaults fail-closed) |
| [`skills/apps/Vocello/APP.md`](skills/apps/Vocello/APP.md) | App structure for exploration / agent context |

**User-global still required:** `~/.cursor/mcp.json` (peekaboo + mirroir), TCC for **Cursor.app**,
and on French macOS `~/.mirroir-mcp/settings.json` → `mirroringProcessName: "Recopie de l'iPhone"`.

Preflight: [`scripts/ios_mirroir_preflight.sh`](../scripts/ios_mirroir_preflight.sh).

Agent map: [`docs/reference/ios-agent-ui-tour.md`](../docs/reference/ios-agent-ui-tour.md) ·
setup: [`docs/reference/computer-use-mcp-alternatives-cursor.md`](../docs/reference/computer-use-mcp-alternatives-cursor.md).
