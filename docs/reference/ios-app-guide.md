# Vocello for iPhone — app guide + test-driving reference

A consolidated map of the Vocello iOS app: what every screen/element/option does (user
view) and how to drive it in tests like a human (identifier/label → action → expected).
Use this to author accurate, human-like Computer Use flows and to understand the app before
touching `Sources/iOS/`. All iOS UI work runs on a paired physical device through iPhone
Mirroring; MLX cannot initialize on the iOS Simulator.

> **Where this fits:** this is the canonical "what the app is + how to drive it" reference.
> The testing strategy lives in [`testing-runbook.md`](testing-runbook.md);
> device lanes (`scripts/ios_device.sh`) in [`ios-device-testing.md`](ios-device-testing.md);
> generation-engine internals in [`../ARCHITECTURE.md`](../ARCHITECTURE.md);
> tone/delivery prompt-writing in [`../qwen_tone.md`](../qwen_tone.md).
> The compact UI state map is [`ios-ui-reference.md`](ios-ui-reference.md), and the frontend
> acceptance index is [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md). Bundled Computer Use through
> iPhone Mirroring is the only iOS automation driver.

---

## 1. Overview

Four tabs across the bottom (`rootTab_*`), with **Studio** as the default surface:

| Tab | `rootTab_*` | Purpose |
|-----|-------------|---------|
| Studio | `rootTab_studio` | Compose + generate (three modes — see below) |
| Voices | `rootTab_voices` | Browse built-in speakers + saved (cloned/designed) voices |
| History | `rootTab_history` | Past generations: replay, export, delete, search |
| Settings | `rootTab_settings` | Model downloads, playback/variation/accessibility prefs |

Three generation modes (Studio segmented control `generateSection_*`):

- **Custom Voice** (`generateSection_custom`) — pick a built-in speaker + optional delivery.
- **Voice Design** (`generateSection_design`) — describe a voice in natural language.
- **Voice Cloning** (`generateSection_clone`) — use a reference clip (record on-device or a saved voice).

The UI is what this guide drives. For headless, no-UI generation see `IOSAutorunHarness`
(`ios-device-testing.md` §1) — that path is for benchmarks, not this guide.

---

## 2. The app, screen by screen

### Onboarding (first run) — `Sources/iOS/Overlays/IOSOnboardingFlow.swift`

Three pages (Welcome → Install → Ready). Controls: `onboarding_skip` (top-right on pages
1–2) and `onboarding_cta` (primary button; label changes per page: "Get started" →
"Continue" → "Open Studio"). Fast path: `QVOICE_IOS_SKIP_ONBOARDING=1` (the test
coordinator sets this) bypasses onboarding straight to Studio.

### Studio — `Sources/iOS/IOSStudioCanvas.swift`, `IOSGenerationModeViews.swift`

The mode segmented control is `generateSectionPicker` (`.contain`) with
`generateSection_custom|design|clone`. The Studio surface uses
`screenPresenceMarker("screen_generateStudio")` — a 1pt leaf marker so the screen id is
queryable without shadowing descendants (see §5).

| Element | Identifier | Notes |
|---|---|---|
| Mode segment | `generateSection_custom\|design\|clone` | Tap to switch mode (keeps its id — not shadowed) |
| Script composer | `textInput_textEditor` | Multi-line; live char counter `textInput_lengthCount`; over-limit warning `textInput_limitMessage` |
| Batch affordance | `textInput_batchButton` | Appears for multi-line scripts |
| **Generate CTA** | `textInput_generateButton` | Shown when the mode's model is installed |
| **Install CTA** | `textInput_installModelButton` | Shown instead of Generate when the model is **missing** (see §3) |
| Cancel | `textInput_cancelButton` | Inside the generating progress bar |
| Error retry | `textInput_generationError` | Retry bar on a failed generation |
| Inline player | `studio_inlinePlayer` (completed take) / `studio_livePreviewPlayer` (live streaming preview) | Live streaming preview + completed-take card. `studioPlayerCard` is a SwiftUI view identity, not an accessibility identifier. |

**Selector pills (chips)** — `studioChip_*` identifiers are directly queryable in Studio
(via `screenPresenceMarker`). Per mode:

| Mode | Pills (label prefix → opens) |
|---|---|
| Custom | Voice (`"Voice: "` → voice picker) · Delivery (`"Delivery: "` → delivery picker) · Language (`"Language:"` → language picker) |
| Design | Voice brief (`"Voice brief:"` → brief editor) · Delivery (`"Delivery: "`) · Language (`"Language:"`) |
| Clone | Reference (`studioChip_reference` → record or saved voice) · Language (`"Language:"`) |

### Bottom sheets — `Sources/iOS/Sheets/IOSBottomSheets.swift`

Sheets are separate overlays, so **inside-sheet elements keep their own identifiers**
(not shadowed). Every sheet has a confirm header and/or `bottomSheet_close` (×).

**Voice picker** — rows `voicePickerRow_<id>`, per-row preview `voicePickerPreview_<id>`,
confirm `voicePicker_confirm`. Selecting a row is **provisional** (sheet stays open) —
tap Confirm to commit + dismiss. Preview plays audio without selecting/closing.

**Language picker** — rows `languagePicker_<rawValue>` (e.g. `languagePicker_auto`,
`languagePicker_english`), confirm `languagePicker_confirm`.

**Delivery picker** — confirm `deliveryPicker_confirm`; a 2-column preset grid over
`EmotionPreset.all` (cells `deliveryPickerPreset_<presetID>`); an intensity row
(Subtle/Normal/Strong → `deliveryPickerIntensity_<level>`, disabled for Neutral); and a custom
tone editor: `deliveryPickerSheet_customTone` (toggle in), `deliveryPickerSheet_customTone_editor`
(text, `/500` counter `deliveryPickerSheet_customTone_charCount`),
`deliveryPickerSheet_customTone_examples`, `deliveryPickerSheet_customTone_back`.

**Voice brief editor** (Design only) — `voiceBrief_editor` (multi-line) + `voiceBrief_confirm`.

### Voices tab — `Sources/iOS/IOSVoicesView.swift`

Container `screen_voices`. Filter chips `voicesFilter_all|builtIn|saved`. Built-in rows
`voicesRow_<speakerId>` (e.g. `voicesRow_aiden`); saved-voice rows `voicesRow_saved_<id>`.
"Save a new voice" card `voices_saveNewVoice` (opens the record flow). Search field
`voicesSearchField`. Record/import flow uses the `iosRecord_*` controls (see below).

### History tab — `Sources/iOS/IOSLibraryViews.swift`

Search `historySearchField`; clear menu `historyClearMenu` → `historyClearKeepFiles` /
`historyClearDeleteFiles`; retry `historyRetryButton`. Mode-filter chips
`historyModeFilter` container + `historyModeFilter_all|custom|design|clone`. Rows:
`historyRow_<id>`, tap area `historyRowTap_<id>` (opens player), menu `historyRowMenu_<id>`
(Play/Save/Delete), delete-confirm `historyRowDeleteConfirm_<id>`. Grouped by Today /
Yesterday / Previous 7/30 Days / Earlier.

### Settings tab — `Sources/iOS/IOSSettingsViews.swift`

Voice Models rows `iosModelRow_<modelID>` (full lifecycle — see §3). Prefs:
`iosSettings_autoPlayToggle`, `iosSettings_variationRow` (Expressive/Balanced/Consistent),
`iosSettings_savedOutputsRow`, `iosSettings_storageRow`, `iosSettings_reduceMotionToggle`,
`iosSettings_reduceTransparencyToggle`. About: `iosSettings_privacyPolicyRow`,
`iosSettings_openSourceRow`, `iosSettings_openIOSSettingsRow`, `iosSettings_versionLabel`
(read-only version label; the 7-tap debug toggle is macOS-only).

### Player + overlays

Full-screen player (`Sources/iOS/Sheets/IOSPlayerSheet.swift`): `iosPlayer_save`,
`iosPlayer_playPause`, `iosPlayer_download` (the scrubber + transcript stay unlabeled —
minor gap). Recording overlay (`Sources/iOS/Overlays/IOSRecordingOverlay.swift`):
`iosRecord_close`, `iosRecord_start` / `iosRecord_stop`, `iosRecord_retake`, `iosRecord_use`.
Lifecycle toasts (`IOSEngineLifecycleToast.swift`) are transient ("Preparing runtime",
"Model loading") and labeled with `engineLifecycleToast_<id>`.

---

## 3. Model download management & state (generation precondition)

**A generation is impossible without the mode's model installed.** Three mode models map
to the contract: `pro_custom` (Custom), `pro_design` (Design), `pro_clone` (Clone). iOS
ships the **Speed (4-bit)** variant only (Quality is macOS-only); the iOS-eligible set
comes from `qwenvoice_ios_model_catalog.json`.

### Per-model states (Settings → Voice Models, `iosModelRow_<modelID>`)

| State | Visible control | What it means |
|---|---|---|
| Not installed | `iosModelDownload_<id>` ("Install") | Default; nothing staged |
| Downloading | `iosModelCancel_<id>` ("Cancel") + progress bar | Active download |
| Paused | `iosModelResume_<id>` ("Resume") | Reached by the runtime when a download stalls; not a user-facing pause button |
| Failed/incomplete | `iosModelRetry_<id>` ("Retry") / `iosModelRepair_<id>` ("Repair") | Error or interrupted |
| Installed | `iosModelDelete_<id>` (trash) | Ready to generate |

Cancel opens a confirmation dialog: `iosModelCancelDownloadConfirmButton` (cancel, deletes data).
There is no user-facing pause button; paused state is reached by the runtime. Download progress
`iosModelProgress_<id>` (downloading / resuming / paused states).

### The Studio gates generation on the installed model

The composer's primary CTA reflects model readiness:

- **Model missing → `textInput_installModelButton`** (Install CTA; `textInput_generateButton` absent).
- **Model installed → `textInput_generateButton`** (Generate CTA).

So "is this mode ready to generate?" is **test-readable from the Studio surface**: if
`textInput_installModelButton` is present, the model isn't installed.

### Human and Computer Use preconditions

**Always confirm the mode's model is installed before composing/generating.** The current mirror
screenshot must show Generate rather than Install. Destructive install/cancel/delete actions are
outside normal suites and require action-time confirmation.

### Model lifecycle sequence

- **Install:** Settings → `iosModelDownload_<id>`.tap() → (wait for complete → `iosModelDelete_<id>`).
- **Cancel:** `iosModelDownload_<id>`.tap() → `iosModelCancel_<id>`.tap() →
  `waitForConfirmationButton("iosModelCancelDownloadConfirmButton")` → tap it → Install reappears.
- **Pause/resume/cancel:** The runtime may pause a download (showing `iosModelResume_<id>`). Tap
  Resume, then tap Cancel and confirm with `iosModelCancelDownloadConfirmButton`.
- **Delete:** `iosModelDelete_<id>`.tap() → `deleteModelSheet_confirm`.tap() → Install reappears.

---

## 4. What each option means

### Modes

- **Custom Voice** — a built-in Qwen3 speaker reads your script, with an optional delivery
  style. Fastest, most consistent path.
- **Voice Design** — describe a voice in plain language (character, age, accent, gender,
  pitch); the model invents a new voice from that brief each call. Name gender + concrete
  pitch register to avoid underspecified results. The result can be saved and reused in Clone.
- **Voice Cloning** — supply a reference clip (record in-app on this iPhone; ~10–20 s clean clip),
  optionally with a transcript (auto-fillable via on-device speech
  recognition). Saved voices from the Voices tab are reusable references. Clone cannot take a
  separate delivery instruction on current checkpoints — pick a reference clip that already
  carries the delivery you want.

### Speakers (Custom Voice) — `qwenvoice_contract.json`

9 built-in: **Aiden, Ryan** (English) · **Vivian, Serena, Uncle Fu, Dylan, Eric** (Chinese) ·
**Ono Anna** (Japanese) · **Sohee** (Korean). Default: Aiden. Speakers carry baked-in
delivery biases (e.g. Ryan is naturally expressive; start from Aiden/Serena for a neutral read).

### Delivery — `Sources/QwenVoiceCore/EmotionPreset.swift`

10 presets: **Neutral** (no intensity tiers — treated as "no style instruction"), plus
**Happy, Sad, Angry, Fearful, Surprised, Excited, Calm, Whisper, Dramatic**. Each non-Neutral
preset has three **intensity** tiers — **Subtle / Normal / Strong** (`EmotionIntensity`,
disabled for Neutral). Or write a **custom tone** (free text, 500-char cap) — see
[`../qwen_tone.md`](../qwen_tone.md) for the prompt-writing rules (combine emotion + pace +
pitch + timbre; negative constraints like "without laughing" work; write instructions in
English or Chinese regardless of output language; describe the sound, not a persona).

### Languages — `GenerationSemantics` / language picker

**Auto** (detected from the script's Unicode ranges / `NLLanguageRecognizer`) or pinned to
one of 10: English, Chinese, Japanese, Korean, German, French, Russian, Portuguese, Spanish,
Italian. The instruction/brief language is independent of the spoken-text language.

### Cross-cutting

- **Speed vs Quality** — iOS is Speed-only (smaller, faster, lower memory). Quality (8-bit) is macOS-only.
- **Reproducible takes** — Settings → `iosSettings_variationRow`: **Expressive** (most variety, default) / **Balanced** / **Consistent** (most stable). Each generation records its seed; a multi-line batch shares one seed so it reads as one performance.
- **Text limits** — enforced live (`textInput_lengthCount` + `textInput_limitMessage`); custom-tone cap `/500`.

---

## 5. Driving through Computer Use

The mirror accessibility tree exposes only window chrome. `$vocello-ios-ui-qa` therefore observes
the current device screenshot, locates the target visually, clicks its current center in app-local
coordinates, and immediately re-observes. Coordinates are never reused across states or committed
as a table.

Canonical flows remain:

- Onboarding → Studio: advance or skip until the Studio tabs and composer are visible.
- Custom: select Custom, confirm model readiness, configure voice/delivery/language, compose,
  Generate, verify the completed player, then run `ios_agent_ui.sh verify-generation`.
- Design: select Design, enter a voice brief, compose, Generate, and verify telemetry.
- Clone: select Clone, choose a saved reference, compose, Generate, and verify telemetry.
- History: open the History tab, find the generated take, and replay it.
- Settings: review model and preference state; restore any reversible preference change.

Gotchas:

1. Picker selection is provisional until its visible Confirm action is activated.
2. Dismiss the keyboard before Generate when it obscures the button.
3. Wait for cold model loading rather than repeating a click.
4. Save a new screenshot after every semantic state transition.
5. Recording and destructive model lifecycle actions require attended confirmation and are outside
   ordinary quick/full/benchmark suites.

---

## 6. Remaining test-coverage gaps (driveability backlog)

Most interactive controls now carry an `accessibilityIdentifier`. Still missing (driving
them needs label/coordinate hacks or new ids):

- ~~Player sheet scrubber + transcript~~ — **closed 2026-07-02**: the scrubber is an adjustable VoiceOver element (`iosPlayer_scrubber`, "Playback position" + value) and the karaoke transcript reads as one prose element (`iosPlayer_transcript`).
- **Mode meta labels** ("Built-in voice" / "Designed voice"), section headings, empty-state cards, sheet titles — low-value to drive; label by text if needed.
- **Lifecycle toasts** — transient, but labeled with `engineLifecycleToast_<id>`.

A separate, optional follow-up is consolidating **all** ids (most are inline string
literals today) into `Sources/iOS/IOSAccessibilityIdentifiers.swift` so they're grep-able
constants — a refactor, not a behavior change.
