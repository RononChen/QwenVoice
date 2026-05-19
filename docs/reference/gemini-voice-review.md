# Gemini Voice Review (deprecated)

_Deprecated 2026-05-19._ Google has retired the Gemini CLI in favour of the Antigravity CLI ([announcement](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)). The perceptual-review pipeline now runs through `agy` instead of `gemini`.

**See [`antigravity-voice-review.md`](antigravity-voice-review.md) for the current runbook.**

Quick equivalents:

| Old (Gemini CLI) | New (Antigravity CLI) |
|---|---|
| `scripts/uitest.sh gemini-review <wav>` | `scripts/uitest.sh antigravity-review <wav>` (the old name remains as a deprecation alias) |
| `scripts/gemini_voice_review.sh` | `scripts/antigravity_voice_review.sh` (old path forwards) |
| `gemini-3.1-pro-preview` pin via `~/.gemini/settings.json` | Antigravity CLI default model (no override flag, no config lookup) |
| `metadata.json` keys `gemini_model` + `gemini_cli_version` | `reviewer` + `antigravity_cli_version` |

The migration rationale and flag-mapping discovery live in [`antigravity-cli-probe.md`](antigravity-cli-probe.md).

This stub will be removed once stale links and shell histories have rolled over.
