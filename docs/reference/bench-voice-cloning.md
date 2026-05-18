# Bench Runbook: Voice Cloning across cold/warm × variant × prompt-length

Multi-sample timing harness for Voice Cloning. Same structure as [`bench-custom-voice.md`](bench-custom-voice.md), passing `clone` as the mode argument.

Follows the [Standard bench skeleton](ui-test-surface.md#standard-bench-skeleton). This file documents the Voice Cloning deltas.

## Prerequisite

Requires the **`UITestRef`** saved-voice fixture. If `scripts/uitest.sh smoke-check clone` fails because the fixture is missing, run [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md) first.

Voice Cloning has an extra subtlety: when the **reference clip changes**, the engine re-primes (`VoiceCloningCoordinator.ensureCloneReferencePrimed`). The cold sample for each variant captures this priming cost; warm samples reuse the primed reference. **Do not change the saved-voice selection between warm samples** — that would make every warm sample look cold.

## Mode-specific inputs

| Field | Value |
|---|---|
| Saved voice | `UITestRef` (created by the bootstrap runbook) |
| Transcript | leave empty |
| smoke-check arg | `clone` |

### Fixed prompts

Same as [`bench-custom-voice.md`](bench-custom-voice.md). Held byte-identical so baselines remain comparable across modes.

## Mode-specific deltas (skeleton step 1b)

For each `variant` in `[speed, quality]`:

- **Sidebar AX id**: `sidebar_voiceCloning`
- **Screen mount check**: `scripts/uitest.sh locate screen_voiceCloning` (exit 0)
- **Variant button AX ids**: `voiceCloning_speedVariantButton`, `voiceCloning_qualityVariantButton`. Container anchors: `voiceCloning_modelVariantPicker`, `voiceCloning_modelVariantSelector`.
- **Extra step (saved-voice bind)**: click `voiceCloning_savedVoicePicker`, screenshot the open menu, click the `UITestRef` menu item visually. Confirm with `scripts/uitest.sh locate voiceCloning_activeReference` (exit 0).

`bench-step` invocations:

```sh
scripts/uitest.sh bench-step clone "$variant" cold medium --artifacts-dir "$ART" --timeout 180
scripts/uitest.sh bench-step clone "$variant" warm short  --artifacts-dir "$ART"
scripts/uitest.sh bench-step clone "$variant" warm medium --artifacts-dir "$ART"
scripts/uitest.sh bench-step clone "$variant" warm long   --artifacts-dir "$ART"
```

Each cold sample requires fresh-launch + re-bind, so the cold-cohort budget is closer to ~4 minutes per sample (vs ~3 minutes for Custom Voice / Voice Design).

## Mode-specific failure handling

- **Saved-voice picker has no `UITestRef` entry**: `smoke-check clone` should have caught this. If it slipped through, abort and run [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md).
- **Warm sample looks unexpectedly slow**: the saved-voice selection may have been re-touched (re-primes the reference). Don't click the picker between warm samples.
- **Quality warning badge on the active reference**: degraded audio possible but doesn't affect bench timings. Note in run notes; baseline timings stay valid.

## Optional perceptual review of a bench sample

Identity-coherence regressions are perceptual-only — the bench can't catch them:

```sh
scripts/uitest.sh gemini-review \
    "$(ls -t "$HOME/Library/Application Support/QwenVoice-Debug/outputs/Clones/"*.wav | head -1)"
```

The script auto-fills `saved_voice` from `generations.voice` so you don't need to pass it explicitly.
