# Antigravity CLI probe results (2026-05-19)

_One-shot discovery doc that backed the Gemini CLI → Antigravity CLI migration._

This is the evidence that the migration is feasible against the actual `agy` flag surface. Kept as a record so future contributors don't have to re-derive the mapping.

## Install + identity

| Item | Value |
|---|---|
| Install command | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` |
| Binary name | `agy` (not `antigravity`) |
| Install path | `$HOME/.local/bin/agy` |
| Probed version | `1.0.0` (`agy --version`) |
| Companion app | Antigravity desktop app v2.0.0 (`/Applications/Antigravity.app/`) — coexists; shares auth via the language server pointing at `generativelanguage.googleapis.com`. |
| Auth state | Once the desktop app is signed in, `agy` runs prompts non-interactively without an additional CLI login flow. |

## Flag surface (verbatim from `agy --help`)

```
--add-dir                       Add a directory to the workspace (repeatable)
-c, --continue                  Continue the most recent conversation
--conversation                  Resume a previous conversation by ID
--dangerously-skip-permissions  Auto-approve all tool permission requests
-i, --prompt-interactive        Run an initial prompt interactively
--log-file                      Override CLI log file path
-p, --print, --prompt           Run a single prompt non-interactively and print the response
--print-timeout                 Timeout for print mode wait (default 5m0s)
--sandbox                       Run in a sandbox with terminal restrictions enabled

Subcommands: changelog, help, install, plugin/plugins, update
```

## Flag mapping (Gemini CLI → Antigravity CLI)

| Gemini CLI flag | Antigravity CLI flag | Notes |
|---|---|---|
| `gemini` (binary) | `agy` (binary) | |
| `-p "<prompt>"` | `-p "<prompt>"` | Identical syntax. |
| `-o text` | (omit) | `agy` is text-only output; no equivalent flag, none needed. |
| `--approval-mode yolo` | `--dangerously-skip-permissions` | Functionally equivalent. |
| `--include-directories <dir>` | `--add-dir <dir>` | Identical purpose; grant workspace access to a directory. |
| `@<path>` inside the prompt body | `@<path>` inside the prompt body | **Same file-attachment convention.** Verified end-to-end with a WAV in `--add-dir`. |
| `model.name` in `~/.gemini/settings.json` | (no override available) | `agy` uses Antigravity CLI's default model. No `-m`/`--model` flag exists. |

## Audio capability — verified end-to-end

The crucial probe was: feed `agy` a WAV via `@<path>` and ask it to describe the audio.

```bash
WAV_DIR="$HOME/Library/Application Support/QwenVoice-Debug/voices"
agy --print-timeout 180s --dangerously-skip-permissions \
    --add-dir "$WAV_DIR" \
    -p "Listen to @$WAV_DIR/UITestRef.wav and answer in 3 short sentences:
        (a) male or female speaker, (b) emotional tone, (c) audio clarity."
```

**Result (verbatim from probe on 2026-05-19):**

> The audio features a female speaker with a calm and neutral emotional tone. The audio clarity is excellent, with a clean and professional sound quality.
>
> (a) Female speaker.
> (b) Calm and neutral.
> (c) Excellent and professional.

The result is correct for `UITestRef.wav` (a Voice Design-generated narrator clip) — confirming that:

- `agy` accepts the `@<path>` file-attachment convention.
- The default model has multimodal audio understanding (gender, emotion, quality assessment).
- Print-mode runs in well under the 5-minute default timeout (this probe completed in ≈30 s).
- Stdout is clean — no banner lines or warnings preceded the response. The chatter-stripping that the legacy Gemini script needed at lines 227–243 is unnecessary for `agy`.

## What `agy` does NOT support

- **No model-selection flag.** No `-m`, `--model`, `--engine`, etc. The default model is what runs. This matches the migration requirement ("use the default").
- **No JSON / schema output flag.** No `--json`, `--format`, `--schema`. The existing pipeline never relied on structured JSON output anyway — it asks the model to produce Markdown in a fixed shape and parses that — so this is not a blocker. (The `metadata.json` next to each review is built by our wrapper, not by the model.)
- **No "headless" auth subcommand.** Auth presence is inherited from the desktop app's keyring. CI use would need the desktop app installed and signed in first.

## Implications for the migration

1. The migration is a 1:1 swap. No prompt-template change is needed — the `@<path>` convention works across both CLIs.
2. Drop the `~/.gemini/settings.json` lookup. Default model only.
3. Drop the chatter-stripping prefix marker list (`Warning:`, `YOLO mode is enabled`, etc.) — `agy` doesn't emit them. Keep a minimal "strip leading blank lines" pass for safety.
4. Bump procedure version (`scripts/antigravity_voice_review.sh`) and rename metadata keys (`gemini_model` → `antigravity_model`, `gemini_cli_version` → `antigravity_cli_version`).
5. Auth is a one-time human step (sign into the Antigravity desktop app) — document in the runbook.

## Stop-conditions check (from the migration plan)

| Plan stop-condition | Result |
|---|---|
| Lacks audio attachment | **PASS** — `@<path>` works. |
| Cannot emit parseable output | **PASS** — Markdown response is parseable by our existing schema. |
| Auth is uniquely hostile to CLI | **PASS** — desktop-app-shared auth works for non-interactive prompts. |

Migration cleared to proceed.
