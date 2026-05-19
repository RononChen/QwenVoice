# Antigravity Voice Review (runbook)

Reusable procedure for getting a structured, human-comparable review of a Vocello-generated audio sample through the Antigravity CLI (`agy`). The bench harness measures timing, RMS/peak, and memory; this procedure adds subjective dimensions such as naturalness, emotion match, pronunciation, and artifacts.

This runbook replaces the retired `gemini-voice-review.md`. See [`antigravity-cli-probe.md`](antigravity-cli-probe.md) for the discovery + flag-mapping that the migration is built on.

Use this when:

- Audio-path code changed and RMS/peak alone cannot prove the sample still sounds right.
- You want comparable cross-sample reviews with one fixed prompt template.
- You want a multimodal model to act as the audio reviewer while Claude Code prepares context and records the result.

## When to run this (vs the bench / smoke layers)

This is the **perceptual review** layer of the three-layer testing pyramid documented in [`testing-overview.md`](testing-overview.md). The full decision table is there; the quick version:

| What changed | Run perceptual review? |
|---|---|
| Audio-path code (PCM limiter, AVAudioFile writer, streaming preview) | **Yes — primary signal**. RMS/peak gates can't catch identity-coherence or tone regressions. |
| Engine code (decoder, vocoder, KV cache) | Yes — alongside smoke + bench. |
| Voice description / prompt tone work | Yes — bench is blind to whether the take matches the description. |
| UI/view code that doesn't touch audio | No. Smoke is enough. |
| Bench-baseline-affecting perf change | Yes — confirm no audio-quality regression alongside the new timing numbers. |

Per-mode bench and smoke runbooks each have an "Optional perceptual review" callout that fires the same `scripts/uitest.sh antigravity-review` call documented below.

## Two paths

Prefer the **CLI path**. It is fully automated, leaves no app-state footprint, and produces the same `build/Debug/voice-reviews/<UTC-ts>-<mode>-<basename>/` bundle the script has always produced. The **desktop-app path** is a fallback for when the CLI errors out, when you want a multi-turn conversation, or when you need to inspect the response interactively.

## Path 1 — CLI (preferred)

Powered by the [Antigravity CLI](https://github.com/google-antigravity/antigravity-cli) (`agy`). The Vocello harness uses Antigravity's **default model** — there is no model-override flag, and the migration explicitly drops the previous `model.name` config lookup. Whatever Antigravity ships as default is the reviewer.

### Prerequisites

| Requirement | How to satisfy |
|---|---|
| Antigravity CLI installed | `agy --version` (`1.0.0` or newer). Install via `curl -fsSL https://antigravity.google/cli/install.sh \| bash` (drops the binary at `$HOME/.local/bin/agy`). |
| Authenticated | Sign in once via the Antigravity desktop app (`/Applications/Antigravity.app/`). `agy` inherits that auth — no separate CLI login is needed. |
| WAV file present on disk | Defaults under `~/Library/Application Support/QwenVoice-Debug/outputs/<Mode>/<timestamp>_<text-prefix>.wav`. |
| Sample context (auto-filled) | When the WAV's path matches a `generations.audioPath` row in `history.sqlite`, the script auto-fills mode/text/speaker/delivery. For ad-hoc WAVs outside the harness, pass `--mode` + `--text` (and `--voice-description` for Voice Design) explicitly. |

### Recommended Flow

One command:

```sh
scripts/uitest.sh antigravity-review <wav-path>
```

(Equivalent: `scripts/antigravity_voice_review.sh <wav-path>`. The `uitest.sh` subcommand just delegates. The old `gemini-review` name is kept as a deprecation alias for one release.)

What the script does, end-to-end:

1. Canonicalizes the WAV path.
2. Looks up the matching `generations` row by `audioPath` and pulls `mode`, `text`, `voice` (→ speaker for `custom`, saved-voice for `clone`), and `emotion` (→ delivery).
3. Records the `agy --version` in the bundle metadata.
4. Computes audio duration from the WAV header for the bundle metadata.
5. Builds the mode-specific prompt (template below) and writes it to `review_prompt.md`.
6. Invokes `agy -p ... --dangerously-skip-permissions --add-dir <wav-dir>`. `--add-dir` grants the model workspace access to the WAV's parent directory (required when the WAV lives outside the repo workspace, which it does — the Debug data store is in `~/Library/Application Support/QwenVoice-Debug/`). `--dangerously-skip-permissions` auto-approves the file read. The `@<wav-path>` syntax inside the prompt body attaches the audio.
7. Writes `review_body.md` (clean response) + `review_body.raw` (pre-strip — for `agy` the two are typically identical because the CLI emits no banner chatter, but the pre-strip copy is kept for forensics).
8. Composes `review.md` (front-matter + body) and `metadata.json`.
9. Prints the overall-score line and the path to `review.md`.

Wall-clock: ~30 seconds end-to-end on a short clip with Antigravity CLI's default model.

### Optional overrides

Auto-fill from `history.sqlite` covers the common case. For ad-hoc WAVs or when you need to override:

```sh
scripts/uitest.sh antigravity-review path/to/sample.wav \
    --mode design \
    --text "A calm, deep documentary narrator with a measured pace." \
    --voice-description "A calm, deep documentary narrator with a measured pace." \
    --delivery "Neutral, Subtle"
```

| Flag | Effect |
|---|---|
| `--mode custom\|design\|clone` | Skip the DB lookup for mode. |
| `--text "..."` | Skip the DB lookup for the spoken text. |
| `--voice-description "..."` | Required for Voice Design (not stored in `generations`). |
| `--speaker "..."` | Override the auto-detected built-in speaker (Custom Voice). |
| `--delivery "..."` | Override the auto-detected delivery. |
| `--saved-voice "..."` | Override the auto-detected saved-voice name (Voice Cloning). |
| `--commit <hash>` | Override the auto-detected `git rev-parse --short HEAD`. |
| `--out-dir <dir>` | Move the bundle out of `build/Debug/voice-reviews/`. |

### Privacy + policy

Sending a WAV through `agy` transmits local audio data to Google's servers. The Antigravity CLI inherits auth from the Antigravity desktop app, which is tied to your Google account; the audio is processed under that account's privacy posture. Do not invoke `antigravity-review` on samples that contain anything you wouldn't paste into a public Antigravity chat. The script writes the bundle locally; nothing else is uploaded.

## Path 2 — Antigravity desktop app (fallback)

Use this when the CLI errors out (auth flow expired, network issues), when you want the multi-turn chat UI to follow up with the reviewer, or when the CLI returns an answer that's malformed and you want to dialogue. Otherwise the CLI is strictly better.

### Prerequisites (desktop path)

| Requirement | How to satisfy |
|---|---|
| Antigravity desktop app installed | `/Applications/Antigravity.app/` present and signed in (the same auth state the CLI uses). |
| `mcp__computer-use__*` permission for Antigravity | Tier "full" — the app is a native macOS app, not a tier-restricted browser. Use `request_access` once. |

### Flow (desktop path)

1. **Reuse the CLI script to make the bundle directory + prompt file.** Even when sending interactively through the desktop app, you want the same `review_prompt.md` + `metadata.json` layout for diffability. The cleanest path is: run `scripts/uitest.sh antigravity-review` once first; if the CLI errored, the bundle dir + `review_prompt.md` already exist — open them and re-send manually.
2. **Open the Antigravity app** via `mcp__computer-use__open_application`.
3. **Paste `review_prompt.md`** into a new chat, attach the WAV via the app's file-attach affordance, and send.
4. **Wait** until the response stops changing.
5. **Save the response verbatim** into `review.md` (under the same bundle dir). Manually populate `metadata.json` keys — at minimum `reviewer: "antigravity-desktop"`, `antigravity_cli_version`, `reviewed_at_utc`.

## Prompt Template

The CLI script embeds the canonical template inside the bundle's `review_prompt.md`. Keep this copy in sync if you tweak the script:

```markdown
You are evaluating a text-to-speech audio sample produced by a local on-device TTS model on macOS (Vocello / Qwen3-TTS).

Listen carefully to @<absolute WAV path> (the full clip) and provide a structured review.

Generation context:
- Mode: <Custom Voice | Voice Design | Voice Cloning>
- Text the model was asked to speak: "<EXACT TEXT VERBATIM>"
- Requested delivery: <e.g., "Neutral, Subtle" | "Excited" | "Calm and measured">
- Speaker / voice context:
  <For Custom Voice:>
  - Built-in speaker: <e.g., "aiden">
  <For Voice Design:>
  - Voice description requested: "<DESCRIPTION>"
  <For Voice Cloning:>
  - Cloned from saved reference: "<saved-voice-name>". Rate naturalness + identity coherence, NOT similarity to a specific person.

Respond in English, in this EXACT Markdown format (do not add additional sections, do not omit any):

## Voice Quality Review

**Overall score**: X/10 - <one sentence summary>

### Naturalness
- Score: X/10
- Notes: <one or two sentences>

### Intelligibility
- Score: X/10
- Notes: <one or two sentences>

### Emotion / delivery match
- Score: X/10
- Notes: <one or two sentences - does the delivery match the requested tone? For Voice Design, does it match the voice description?>

### Pronunciation
- Score: X/10
- Notes: <one or two sentences - note any specific mispronounced words>

### Pacing & prosody
- Score: X/10
- Notes: <one or two sentences>

### Artifacts
- Detected: <list clicks, pops, glitches, hiss, mid-word cuts, chunk-boundary discontinuities, background tones - OR "None">
- Severity: <None | Subtle | Noticeable | Severe>

### Strengths
- <bullet point>
- <bullet point>

### Weaknesses
- <bullet point>
- <bullet point>

### Suggested investigation
<one sentence - e.g., "Pronunciation of 'X' was unclear, worth checking the tokenizer's handling of that word." Or "None - sample is clean.">
```

For the `@<absolute WAV path>` syntax: Antigravity CLI resolves `@path/to/file` as a file attachment if the path is inside an allowed workspace (verified via the discovery probe). The script always passes `--add-dir <wav-dir>` so the WAV is reachable.

## Storage Convention

Reviews land under `build/Debug/voice-reviews/` (already inside the ignored `build/` tree).

Bundle directory: `<UTC-timestamp>-<mode>-<wav-basename>/` (e.g., `20260519T193547Z-design-20260519_13-24-11-781_UITestRef/`).

Files (CLI path produces all of these):

- `review_prompt.md` — exact prompt sent to `agy`.
- `review_body.raw` — `agy` stdout verbatim (currently identical to `review_body.md`; preserved for forensic diffing if banners ever appear).
- `review_body.md` — cleaned response.
- `review.md` — canonical review = front-matter (source WAV, mode, speaker/voice, delivery, text, duration, commit, reviewer, timestamp) + the cleaned body.
- `metadata.json` — structured version of the front-matter, including `reviewer`, `antigravity_cli_version`, `vocello_commit`, `reviewed_at_utc`.
- `agy_stderr.log` — anything the CLI wrote to stderr.

`review.md` body shape:

```markdown
# Voice review

**Source WAV**: /Users/.../QwenVoice-Debug/outputs/<Mode>/<filename>.wav
**Mode**: <Custom Voice | Voice Design | Voice Cloning>
**Speaker**: <e.g., "aiden">                  (Custom Voice)
**Voice description**: "..."                    (Voice Design)
**Saved voice**: <name>                         (Voice Cloning)
**Requested delivery**: <e.g., "Neutral">
**Text**: "..."
**Audio duration**: X.X s
**Vocello commit**: <git short hash at time of generation>

**Reviewer**: Antigravity CLI default model (via agy)
**Reviewed at (UTC)**: YYYYMMDDTHHMMSSZ
**Procedure version**: 4.0 (scripts/antigravity_voice_review.sh)

---

<agy's response verbatim — the structured Markdown from the prompt template>
```

### Schema migration note (from the old Gemini bundles)

Reviews produced by the retired `scripts/gemini_voice_review.sh` (procedure version 3.0) used keys `gemini_model` + `gemini_cli_version`. The new bundles use `reviewer` + `antigravity_cli_version`. Historical bundles already on disk under `build/Debug/voice-reviews/` are not rewritten — that directory is gitignored and bundles are timestamped, so legacy and new bundles coexist cleanly. Any aggregation script that reads either key should accept both during the transition window.

## Caveats

- Antigravity CLI is freshly released (v1.0.0, 2026-05-19); flag surface may shift. Re-run `agy --help` if invocations start failing unexpectedly; update [`antigravity-cli-probe.md`](antigravity-cli-probe.md) and this runbook if so.
- The default model is whatever Antigravity ships — no override flag exists. If Google rolls a quality regression into the default model, the harness has no per-call escape hatch.
- Reviews from one `agy` invocation are independent (the script starts a fresh print-mode session per call). Multi-turn dialogue requires Path 2.
- The prompt requests English output, which the default model generally honors even when the UI is localized.
- Scores are subjective and not deterministic. For regression detection, review at least n=3 representative samples and compare medians.

## Cross-references

- `CLAUDE.md` — Vocello project root, including `shouldStream: true` enable status and bench-baseline conventions.
- `docs/reference/antigravity-cli-probe.md` — discovery + flag mapping that drove this migration.
- `docs/reference/ui-test-surface.md` — how to know what text was generated for a given WAV, per-mode AX ids, and streaming-state signposts.
- `docs/reference/benchmark-baselines.json` — the timing/RMS/peak baselines this review pairs with.
- `scripts/antigravity_voice_review.sh` — the CLI-path implementation.
