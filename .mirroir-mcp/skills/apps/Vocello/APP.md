---
app: Vocello
archetype: dashboard
obstacle_mode: auto
tabs: [Studio, Voices, History, Settings]
---

# Vocello (QVoiceiOS) — iPhone Mirroring agent map

On-device MLX text-to-speech. **English UI** on test device. Cold launch: **Studio → Custom Voice**.

Full owner tour: repo `docs/reference/ios-agent-ui-tour.md`.

## Structure

Four bottom tabs (always visible):

| Tab | Role |
| --- | --- |
| **Studio** | Compose + **Generate** (Custom / Design / Clone modes) |
| **Voices** | Saved references + built-in speakers |
| **History** | Generated takes log |
| **Settings** | Model downloads (one at a time), prefs |

**Studio only:** segmented control **Custom | Design | Clone** at top (~y 108 in mirror window).

## Studio — Custom Voice (default smoke)

- Script composer: placeholder *Type or paste your script.* — **150 char** limit.
- Chips: **AI** (voice), **NE** (delivery), **AU/EN/…** (language). Default Aiden + Neutral + Auto/EN.
- **Generate** full-width bar **below** chips — do not tap chip row when aiming for Generate.
- Readiness: non-empty script + Custom Voice model installed (**Install Custom Voice** if missing).

### Custom generate loop (agent)

1. `describe_screen` → confirm `Custom`, script area, **Generate** label with coords.
2. Tap composer → `type_text` script (≤150 chars).
3. Dismiss keyboard if Generate obscured (`press_key` return or tap composer chrome).
4. `tap` **Generate** coords from OCR (not NE chip).
5. `measure` with `until: "Streaming preview"` or `"Just now"` OR poll `describe_screen` until inline player / complete card.
6. Verify in **History** tab (deterministic); listening pass for tone (human).

## Studio — Voice Design

- First chip **`+`** = voice brief (500 chars). Starters fill + dismiss. **Generate** needs brief + script.
- Do not confuse brief **`+`** with Clone reference **`+`**.

## Studio — Voice Cloning

- Two chips: reference + language (no NE). Pick saved voice from Reference clip sheet.
- **Do not** drive **Record new clip** via mirror — mic unavailable from Mac. Use existing saved voice.

## Voices tab

| Tap target | Result |
| --- | --- |
| Row body (name area) | **Studio → Clone** with reference staged |
| **▶** play only | Full-screen preview player — stays on Voices |
| Built-in row body | **Studio → Custom** with speaker selected |
| **Save a new voice** | Record flow — avoid in agent smokes |

**Navigation shortcut:** From Voices, tap a **built-in speaker row** (e.g. Aiden) to reach Studio → Custom when bottom **Studio** tab taps are flaky.

## History tab

- Row body → full-screen player. **…** menu → Play / Save / Delete take.
- Deleting a take does **not** remove saved voice from Voices.

## Settings tab

- Install models **one at a time** — parallel downloads not supported on iOS.
- Trash on model row → delete weights confirmation.

## Obstacles (auto-dismiss when possible)

- **Delivery** sheet — Confirm with Neutral OK for smokes.
- **Voice** / **Language** pickers — Confirm after selection.
- Onboarding **Install your first voice** — Open Settings or install any model.
- Microphone / Speech permission prompts — only on record flows (avoid).

## Skip (never tap in exploration)

- Delete saved voices (no UI exists — append-only list)
- Record / Save a new voice (mirror cannot use iPhone mic from Mac)
- Delete model / Clear History / bulk trash unless test explicitly targets cleanup
- Quality → Speed fallback paths (not applicable on iOS product)

## OCR hints

`Generate`, `Custom`, `Design`, `Clone`, `Studio`, `Voices`, `History`, `Settings`, `Built-in voice`,
`0/150`, `Generating`, `Streaming preview`, `Just now`, `Install Custom Voice`, `Confirm`,
`Delivery`, `Voice brief`, `Reference clip`, `Search voices`, `Cloned reference`.

## Tips

- Tab **labels** (~y 619–690) more reliable than icons alone; **Voices** tab often flaky — use row shortcuts.
- Coordinates are **window-relative points** from `describe_screen` — use mirroir **`tap`**, not Peekaboo, when permissions enabled.
- Fallback observation: `scripts/ios_device.sh shot` if `describe_screen` capture fails (TCC / Space / paused mirror).
