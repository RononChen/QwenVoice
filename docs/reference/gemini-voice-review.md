# Gemini Voice Review (runbook)

Reusable procedure for getting a structured, human-comparable review of a Vocello-generated audio sample by piping it through Google's Gemini multimodal LLM via the web app. The bench harness measures timing + audio RMS/peak; this procedure adds the **subjective dimensions** (naturalness, emotion match, pronunciation, artifacts) that only ear-on-output evaluation can confirm.

Use this when:

- You changed something in the audio path (decoder, limiter, WAV writer) and want a second-opinion read on whether the audio still sounds right, beyond what RMS/peak gates can detect.
- You want comparable cross-sample reviews (same prompt template → same Markdown sections → trivially diff-able).
- You don't want to recruit a human listener for every regression check.

Use the **Réflexion / Thinking** model (not Pro — overkill for this task; not Rapide — too shallow). Réflexion gives the best speed/quality balance for nuanced perceptual review.

---

## Prerequisites

| Requirement | How to satisfy |
|---|---|
| Chrome + Claude-in-Chrome MCP extension connected | `mcp__Claude_in_Chrome__list_connected_browsers` returns ≥ 1 entry. Install via the Claude.ai Chrome extension if absent. |
| Gemini account signed in | The Gemini tab shows the user's avatar (not "Sign in"). Already done if `gemini.google.com/app` opens directly to the prompt UI. |
| **One-time file-upload consent accepted** | On first upload attempt, Gemini shows a "Création de contenu à partir d'images et de fichiers" / "Content generation from images and files" dialog. Accept it once per profile — the click is `mcp__Claude_in_Chrome__computer left_click` at the **Accepter / Accept** button. Subsequent reviews don't see it. |
| Vocello WAV file present on disk | Defaults under `~/Library/Application Support/QwenVoice-Debug/outputs/<Mode>/<timestamp>_<text-prefix>.wav` (mode = `CustomVoice`, `VoiceDesign`, `Clones`). Pick a recent file. |

---

## Why this is semi-automated (not fully)

Gemini's web app uses the **File System Access API** (`window.showOpenFilePicker`) for "Téléverser des fichiers". This opens a native OS file picker dialog and never creates a persistent `<input type="file">` element in the DOM. Two consequences:

- `mcp__Claude_in_Chrome__file_upload` **cannot be used** — it requires a ref to an `<input type="file">` element, which Gemini doesn't expose.
- The OS file picker is a separate Chrome dialog window. macOS computer-use grants Chrome at tier "read" (clicks/typing blocked), so the picker can't be driven by `mcp__computer-use__*` either.

The workable path is **drag-and-drop from Finder**: the user drags the WAV from a Finder window onto Gemini's prompt area. That's one ~2-second gesture; everything else (find textarea, type prompt, submit, wait, capture, save) is fully automated. A future fully-automated path is described in "Advanced: fully automated mode" below — it works in principle but is fragile.

---

## Procedure

### Step 1 — Set up the session (once)

```
# 1a. Confirm the extension is connected.
mcp__Claude_in_Chrome__list_connected_browsers

# 1b. Pick the browser (the deviceId from above).
mcp__Claude_in_Chrome__select_browser(deviceId: "<deviceId>")

# 1c. Make sure an MCP tab group exists; create one if not.
mcp__Claude_in_Chrome__tabs_context_mcp(createIfEmpty: true)

# 1d. Navigate the MCP tab to Gemini.
mcp__Claude_in_Chrome__navigate(tabId, "https://gemini.google.com/app")
```

### Step 2 — Confirm Réflexion mode is selected

```
mcp__Claude_in_Chrome__find(tabId, "model selector button showing Réflexion or Pro or Rapide")
```

Returns the model selector button ref. Visual inspection of the screenshot confirms which mode is active (the label inside the button is the current selection). If "Pro" or "Rapide", click the button → click the "Réflexion" menu item.

### Step 3 — (Once per Gemini profile) Accept the upload consent

On a fresh account, the first attempt to upload triggers Gemini's "Content from images and files" consent dialog. To get it out of the way at setup time so it doesn't interrupt review batches:

```
# Open the "+" menu, click "Téléverser des fichiers". 
# A native file picker opens (invisible to MCP) — just hit Escape on the page
# to dismiss it (it doesn't have to be a valid upload). The consent dialog
# then appears as an HTML overlay in the page (NOT a native dialog) and IS
# clickable via the MCP.
mcp__Claude_in_Chrome__computer left_click on "+" button
mcp__Claude_in_Chrome__computer left_click on "Téléverser des fichiers" item
mcp__Claude_in_Chrome__computer key("Escape")  # closes the OS picker
mcp__Claude_in_Chrome__computer left_click on "Accepter" button in consent overlay
```

After this, Gemini accepts drag-and-drop uploads without further dialogs.

### Step 4 — User drags the WAV onto the prompt area

The agent prints to the user:

```
Please drag this file onto Gemini's prompt bar:
  /Users/.../QwenVoice-Debug/outputs/CustomVoice/<filename>.wav

(Open Finder → navigate to that path → drag the WAV onto the dark prompt bar at the bottom of the Gemini page.)
```

Wait for the user to confirm or detect via polling.

### Step 5 — Detect that the upload completed

Poll `mcp__Claude_in_Chrome__find` for a file chip / preview pill in the prompt area:

```
mcp__Claude_in_Chrome__find(tabId, "uploaded audio file chip on the prompt bar")
```

Poll every 2 seconds, timeout 60 seconds. The chip's text contains the filename, confirming the upload succeeded.

### Step 6 — Type the review prompt

Fill in the template (full text below in "Prompt template") with the per-sample context, then:

```
mcp__Claude_in_Chrome__form_input(tabId, ref: <textarea-ref>, value: <prompt>)
```

The textarea ref comes from `mcp__Claude_in_Chrome__find(tabId, "main message textarea where users type to Gemini")`.

### Step 7 — Submit

```
mcp__Claude_in_Chrome__find(tabId, "send message button")
mcp__Claude_in_Chrome__computer left_click on that ref
```

### Step 8 — Wait for completion

Gemini Réflexion mode shows a "Thinking" / "Réflexion" badge while the model is reasoning, then streams the response. Poll until both conditions hold:

1. The page text stops growing for ≥ 5 seconds (response stream completed).
2. The "Thinking" indicator is gone.

```
while True:
  text = mcp__Claude_in_Chrome__get_page_text(tabId)
  if text_unchanged_for_5s and "Thinking" not in screenshot:
    break
  sleep(5)
# hard cap: 180 s
```

### Step 9 — Capture the response

```
mcp__Claude_in_Chrome__get_page_text(tabId)
```

Extract the last assistant turn — it starts at the most recent `## Voice Quality Review` heading and ends at the bottom of the conversation. The Markdown structure is fixed by the prompt template, so this is straightforward.

### Step 10 — Save to disk

Write to:

```
build/voice-reviews/<UTC-timestamp>-<mode>-<wav-basename>.md
```

Example: `build/voice-reviews/2026-05-16T16-22-30Z-custom-20260516_15-52-17-612_Plan_mode_is_active.md`

Use the file structure shown in "Storage convention" below.

---

## Prompt template

Fill in `<...>` placeholders. The Markdown structure is **rigid** — Gemini is instructed to emit exactly these sections so reviews diff cleanly across runs.

```
You are evaluating a text-to-speech audio sample produced by a local on-device TTS model on macOS (Vocello / Qwen3-TTS). I have attached the audio file. Listen carefully (the full clip) and provide a structured review.

Generation context:
- Mode: <Custom Voice | Voice Design | Voice Cloning>
- Text the model was asked to speak: "<EXACT TEXT VERBATIM>"
- Requested delivery: <e.g., "Neutral, Subtle" | "Excited" | "Calm and measured">
- Speaker/voice context:
  <For Custom Voice:>
  - Built-in speaker: <e.g., "Aiden — English native male">
  <For Voice Design:>
  - Voice description requested: "<DESCRIPTION>"
  <For Voice Cloning:>
  - Cloned from a saved reference clip; rate naturalness + identity coherence, NOT similarity to a specific person.

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

---

## Storage convention

Reviews land under `build/voice-reviews/` (which falls under `build/` → already gitignored).

File naming: `<UTC-timestamp>-<mode>-<wav-basename>.md`

File body:

```markdown
# Voice review

**Source WAV**: /Users/.../QwenVoice-Debug/outputs/<Mode>/<filename>.wav
**Mode**: <Custom Voice | Voice Design | Voice Cloning>
**Speaker / voice context**: <e.g., "Aiden — English native male" | "A calm, deep documentary narrator" | "Saved voice: UITestRef">
**Requested delivery**: <e.g., "Neutral, Subtle">
**Text**: "..."
**Audio duration**: X.X s
**Vocello commit**: <git short hash at time of generation>

**Reviewer**: Gemini Réflexion (thinking mode)
**Reviewed at**: 2026-MM-DDTHH:MM:SSZ
**Procedure version**: 1.0 (docs/reference/gemini-voice-review.md)

---

<Gemini's response verbatim — the structured Markdown from the prompt template>

---

## Procedure metadata

- Chrome MCP: mcp__Claude_in_Chrome__*
- Gemini tab ID: <N>
- Wall-clock time to capture: <seconds>
```

---

## Tool reference

The agent uses these `mcp__Claude_in_Chrome__*` tools, in roughly the order they're called per review:

| Tool | What it's used for here |
|---|---|
| `list_connected_browsers` | Setup — confirm extension connected. |
| `select_browser` | Setup — pick the browser deviceId. |
| `tabs_context_mcp` (createIfEmpty: true) | Setup — ensure an MCP tab group exists. |
| `navigate` | Setup — open the Gemini tab. |
| `find` | Locate textarea, model selector, send button, file chip, consent dialog buttons. |
| `read_page` (filter: "interactive") | When `find` can't pin down an element, the a11y tree dump is the fallback. |
| `computer` (action: `left_click` / `key` / `screenshot`) | All in-page interactions: clicks on buttons, Escape to dismiss menus, periodic screenshots for visual verification. |
| `form_input` | Type the prompt into the textarea. |
| `get_page_text` | Capture Gemini's response. |
| `javascript_tool` | Debug + state inspection (e.g., `document.querySelectorAll('input[type=file]')`). Useful for advanced workflows; not strictly required. |
| `browser_batch` | Group multiple steps into one round-trip — faster than serial calls. |

---

## Advanced: fully-automated mode (drag-drop via DataTransfer)

The semi-automated workflow above requires a 2-second user gesture (drag-drop). For unattended batch reviews, the file can be injected programmatically:

1. Read the WAV bytes from disk (Bash `base64 -i <path>`).
2. Inject the base64 string into the page via `javascript_tool` (sets `window.__VOCELLO_AUDIO_B64`).
3. In a second `javascript_tool` call, run:
   ```js
   const res = await fetch('data:audio/wav;base64,' + window.__VOCELLO_AUDIO_B64);
   const blob = await res.blob();
   const file = new File([blob], 'vocello-test.wav', { type: 'audio/wav' });
   const dt = new DataTransfer();
   dt.items.add(file);
   const target = document.querySelector('.input-area');
   for (const t of ['dragenter','dragover','drop']) {
     target.dispatchEvent(new DragEvent(t, { bubbles: true, cancelable: true, dataTransfer: dt }));
   }
   ```
4. Poll for the file chip the same way Step 5 does.

**Caveats**:

- The base64 payload for a typical 5-second WAV is ~400 KB. The `javascript_tool` `text` parameter handles it but watch for tool-level limits.
- Gemini's React component may validate the dispatched event's `isTrusted` flag. Synthetic `DragEvent` instances have `isTrusted = false`, which can cause Gemini to silently drop the upload. Status unknown — needs validation.
- This bypasses the consent dialog only if it was already accepted via a real upload.

**Recommendation**: don't bother with this unless you're running ≥ 20 reviews back-to-back. The drag-drop manual step is cheaper than maintaining a fragile JS injection.

---

## Caveats and known limitations

- **File size**: Gemini's web app caps file uploads at ~25 MB per file. Vocello WAVs are typically 200–500 KB — well under.
- **Audio length**: longer than ~10 minutes may exceed Gemini's input window. Vocello generates short clips so this isn't a current concern.
- **Model variants change**: if Réflexion is renamed or removed, update the model-selector check (Step 2). The procedure isn't tied to a specific underlying model — any Gemini variant that accepts audio multimodal input + thinking-mode reasoning works.
- **Conversation accumulation**: reviews in the same conversation share context. After ~10 reviews in one thread, Gemini's context window starts to fill and reviews may degrade. Mitigation: start a new chat (`find` "New chat button" → click) between batches.
- **Language**: the prompt template asks for English responses, which Gemini honors even when the web UI is in French (or any other locale).
- **Determinism**: Réflexion mode is **not** deterministic — same input can produce slightly different scores across runs. For regression detection, use median over n=3 reviews per sample.

---

## Cross-references

- `CLAUDE.md` — Vocello project root, including `shouldStream: true` enable status and bench-baseline conventions.
- `docs/reference/ui-test-surface.md` — how to know what text was generated for a given WAV (so the prompt's `<EXACT TEXT VERBATIM>` field is filled correctly), per-mode AX-ids, and the streaming-state signposts that complement quality review.
- `docs/reference/benchmark-baselines.json` — the timing/RMS/peak baselines this review pairs with.
