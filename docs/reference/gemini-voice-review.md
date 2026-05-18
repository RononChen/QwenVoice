# Gemini Voice Review (runbook)

Reusable procedure for getting a structured, human-comparable review of a Vocello-generated audio sample through Gemini 3.1 Pro. The bench harness measures timing, RMS/peak, and memory; this procedure adds subjective dimensions such as naturalness, emotion match, pronunciation, and artifacts.

Use this when:

- Audio-path code changed and RMS/peak alone cannot prove the sample still sounds right.
- You want comparable cross-sample reviews with one fixed prompt template.
- You want Gemini to act as the multimodal/audio reviewer while Claude Code prepares context and records the result.

## Two paths

Prefer the **CLI path**. It is fully automated, leaves no browser-state footprint, and produces the same `build/Debug/voice-reviews/<UTC-ts>-<mode>-<basename>/` bundle the browser path used to. The **browser path** is a fallback for when the CLI is unavailable, when you want the multi-turn Gemini chat UI, or when you need to inspect the response interactively.

## Path 1 — CLI (preferred)

Powered by the [Gemini CLI](https://github.com/google-gemini/gemini-cli) (`@google/gemini-cli`) reading `~/.gemini/settings.json` for the active model. The Vocello harness expects `gemini-3.1-pro-preview` as the default — the script reads the setting and records it in `metadata.json`.

### Prerequisites

| Requirement | How to satisfy |
|---|---|
| Gemini CLI installed | `gemini --version` (need `0.42.0` or newer). Install via `npm install -g @google/gemini-cli`. |
| OAuth-personal auth | `~/.gemini/settings.json`'s `security.auth.selectedType` is `oauth-personal`; first run prompts a Google sign-in flow. |
| Default model = Gemini 3.1 Pro | `model.name = "gemini-3.1-pro-preview"` in `~/.gemini/settings.json`. Confirm before any test session. |
| WAV file present on disk | Defaults under `~/Library/Application Support/QwenVoice-Debug/outputs/<Mode>/<timestamp>_<text-prefix>.wav`. |
| Sample context (auto-filled) | When the WAV's path matches a `generations.audioPath` row in `history.sqlite`, the script auto-fills mode/text/speaker/delivery. For ad-hoc WAVs outside the harness, pass `--mode` + `--text` (and `--voice-description` for Voice Design) explicitly. |

### Recommended Flow

One command:

```sh
scripts/uitest.sh gemini-review <wav-path>
```

(Equivalent: `scripts/gemini_voice_review.sh <wav-path>`. The `uitest.sh` subcommand just delegates.)

What the script does, end-to-end:

1. Canonicalizes the WAV path.
2. Looks up the matching `generations` row by `audioPath` and pulls `mode`, `text`, `voice` (→ speaker for `custom`, saved-voice for `clone`), and `emotion` (→ delivery).
3. Reads `~/.gemini/settings.json` to record the active model name.
4. Computes audio duration from the WAV header for the bundle metadata.
5. Builds the mode-specific prompt (template below) and writes it to `review_prompt.md`.
6. Invokes `gemini -p ... -o text --approval-mode yolo --include-directories <wav-dir>`. The `--include-directories` flag is required when the WAV lives outside the repo workspace (which it does — the Debug data store is in `~/Library/Application Support/QwenVoice-Debug/`). `--approval-mode yolo` auto-approves the file read.
7. Strips CLI startup chatter from stdout, writes `review_body.md` (clean) + `review_body.raw` (pre-strip).
8. Composes `review.md` (front-matter + body) and `metadata.json`.
9. Prints the overall-score line and the path to `review.md`.

Wall-clock: ~30 seconds end-to-end on a short clip with Gemini 3.1 Pro.

### Optional overrides

Auto-fill from `history.sqlite` covers the common case. For ad-hoc WAVs or when you need to override:

```sh
scripts/uitest.sh gemini-review path/to/sample.wav \
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

Sending a WAV to Gemini transmits local audio data to Google. The CLI's OAuth-personal auth ties the request to your Google account, and the audio is processed under your account's privacy posture. Do not invoke `gemini-review` on samples that contain anything you wouldn't paste into a public Gemini chat. The script writes the bundle locally; nothing else is uploaded.

## Path 2 — Browser (fallback)

Use this when the CLI errors out (auth flow expired, model unavailable, network issues), when you want the multi-turn chat UI to follow up with Gemini, or when the CLI returns an answer that's malformed and you want to dialogue. Otherwise the CLI is strictly better.

### Prerequisites (browser path)

| Requirement | How to satisfy |
|---|---|
| Chrome signed into Gemini | `https://gemini.google.com/app` opens to the prompt UI. |
| Claude in Chrome extension installed and connected | Required for `mcp__Claude_in_Chrome__*` tools (DOM-aware browser automation). If the extension is not connected, stop and ask the user to install it — do NOT fall back to pixel-level `mcp__computer-use__left_click` on Chrome, which is gated to tier "read" (clicks are blocked). |

### Flow (browser path)

1. **Reuse the CLI script to make the bundle directory + prompt file.** Even when sending to Gemini in the browser, you want the same `review_prompt.md` + `metadata.json` layout for diffability. The cleanest path is: run `scripts/uitest.sh gemini-review` once first; if the CLI errored, the bundle dir + `review_prompt.md` already exist — open them and re-send manually.
2. **Open Gemini in Chrome.** `mcp__Claude_in_Chrome__navigate(url: "https://gemini.google.com/app")` or pick an existing Gemini tab via `list_connected_browsers` + `switch_browser`.
3. **Read the DOM.** `mcp__Claude_in_Chrome__read_page()`, then `mcp__Claude_in_Chrome__find` to resolve the prompt field, model selector, upload affordance, and send button to specific element handles.
4. **Upload the WAV only after explicit user confirmation.** Try `mcp__Claude_in_Chrome__file_upload(filePath: "<absolute WAV path>", ...)` against the upload control's element handle. If Gemini uses a native picker, fall back to the manual drag-drop fallback (below).
5. **Submit the prompt.** Paste the contents of `review_prompt.md` via `mcp__Claude_in_Chrome__form_input(...)` (or `mcp__Claude_in_Chrome__computer` for contenteditable fields). Click the send button.
6. **Wait** until the response stops changing.
7. **Save the response** verbatim into `review.md` (under the same bundle dir).

### Manual drag-drop fallback

Use whenever Chrome upload automation cannot see a real file input or reliable upload control:

1. Claude Code opens Gemini and prepares the prompt.
2. Claude Code prints the exact WAV path.
3. The user drags the WAV from Finder onto Gemini's prompt bar.
4. Claude Code waits for the visible uploaded-file chip, then fills and submits the prompt.

This is faster and safer than fighting native-picker automation.

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

**Overall score**: X/10 — <one sentence summary>

### Naturalness
- Score: X/10
- Notes: <one or two sentences>

### Intelligibility
- Score: X/10
- Notes: <one or two sentences>

### Emotion / delivery match
- Score: X/10
- Notes: <one or two sentences — does the delivery match the requested tone? For Voice Design, does it match the voice description?>

### Pronunciation
- Score: X/10
- Notes: <one or two sentences — note any specific mispronounced words>

### Pacing & prosody
- Score: X/10
- Notes: <one or two sentences>

### Artifacts
- Detected: <list clicks, pops, glitches, hiss, mid-word cuts, chunk-boundary discontinuities, background tones — OR "None">
- Severity: <None | Subtle | Noticeable | Severe>

### Strengths
- <bullet point>
- <bullet point>

### Weaknesses
- <bullet point>
- <bullet point>

### Suggested investigation
<one sentence — e.g., "Pronunciation of 'X' was unclear, worth checking the tokenizer's handling of that word." Or "None — sample is clean.">
```

For the `@<absolute WAV path>` syntax: the Gemini CLI resolves `@path/to/file` as a file attachment if the path is inside an allowed workspace. The script always passes `--include-directories <wav-dir>` so the WAV is reachable.

## Storage Convention

Reviews land under `build/Debug/voice-reviews/` (already under ignored `build/`).

Bundle directory: `<UTC-timestamp>-<mode>-<wav-basename>/` (e.g., `20260518T183547Z-custom-20260518_13-24-11-781_This_is_a_Vocello_sm/`).

Files (CLI path produces all of these):

- `review_prompt.md` — exact prompt sent to Gemini.
- `review_body.raw` — Gemini CLI stdout verbatim (includes startup chatter).
- `review_body.md` — cleaned response (chatter stripped).
- `review.md` — the canonical review = front-matter (source WAV, mode, speaker/voice, delivery, text, duration, commit, reviewer model, timestamp) + the cleaned body.
- `metadata.json` — structured version of the front-matter, including `gemini_model`, `gemini_cli_version`, `vocello_commit`, `reviewed_at_utc`.
- `gemini_stderr.log` — anything the CLI wrote to stderr.

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

**Reviewer**: Gemini gemini-3.1-pro-preview (via gemini CLI)
**Reviewed at (UTC)**: YYYYMMDDTHHMMSSZ
**Procedure version**: 3.0 (scripts/gemini_voice_review.sh)

---

<Gemini's response verbatim — the structured Markdown from the prompt template>
```

## Caveats

- Gemini's web UI may use a native file picker or change upload markup; if upload automation fails, use manual drag/drop.
- Reviews in one Gemini conversation share context. Start a new chat between large batches (the CLI starts a fresh session per invocation by default, so this only matters for the browser path).
- The prompt requests English output, which Gemini generally honors even when the UI is localized.
- Gemini model names and capabilities can change. `metadata.json` records the model name and CLI version per review so you can diff across product updates.
- Scores are subjective and not deterministic. For regression detection, review at least n=3 representative samples and compare medians.

## Cross-references

- `CLAUDE.md` — Vocello project root, including `shouldStream: true` enable status and bench-baseline conventions.
- `docs/reference/ui-test-surface.md` — how to know what text was generated for a given WAV, per-mode AX ids, and streaming-state signposts.
- `docs/reference/benchmark-baselines.json` — the timing/RMS/peak baselines this review pairs with.
- `scripts/gemini_voice_review.sh` — the CLI-path implementation.
