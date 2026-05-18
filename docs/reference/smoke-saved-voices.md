# Smoke Runbook: Saved Voices surface lists and plays `UITestRef`

Lightweight functional smoke for the Saved Voices library: the screen mounts, the `UITestRef` fixture is listed, clicking its play button triggers playback.

Follows the [Standard smoke skeleton](ui-test-surface.md#standard-smoke-skeleton) for setup + teardown. This file documents the Saved Voices–specific drive sequence and verify steps.

## Prerequisite

The `UITestRef` saved-voice fixture must exist. `scripts/uitest.sh smoke-check clone` should exit 0. If not, run [`bootstrap-saved-voice.md`](bootstrap-saved-voice.md) first.

## Mode-specific inputs

| Field | Value |
|---|---|
| Saved voice name asserted | `UITestRef` |
| Expected list state | ≥ 1 row (the fixture); voice quality warning may be present (short reference) |
| smoke-check arg | `clone` (confirms the fixture is on disk) |

## Mode-specific deltas

Skeleton Phases 1–3 are unchanged. In Phase 4:

1. **Navigate to Saved Voices**: click `sidebar_voices`. Confirm with `scripts/uitest.sh locate screen_voices` (exit 0).
2. **Verify the `UITestRef` row is present**: `scripts/uitest.sh locate voicesRow_UITestRef` — must return non-empty. The voice id is the sanitized display name, so the fixture's id is literally `UITestRef`.
   - The list MAY show `voicesRow_UITestRef_qualityWarning` (short reference clip; expected for the bootstrap fixture).
3. **Click play**: click `voicesRow_play_UITestRef`. Verify by inspecting the sidebar Player section (the reference audio should start playing within ~1 s).
4. **Optional**: click `voicesRow_use_UITestRef`. If this switches the sidebar to Voice Cloning AND `voiceCloning_savedVoicePicker` shows `UITestRef`, the "use" flow works.

### Skipping `verify-generation`

This smoke doesn't generate audio. In Phase 5, write `result.json` manually:

```sh
cat > "$ART/result.json" <<JSON
{
  "pass": true,
  "screen": "voices",
  "rows_visible": <count>,
  "quality_warning_present": <true|false>,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
```

Set `"pass": false` and add `"reason"` on any failed assertion (e.g., `locate voicesRow_UITestRef` returned non-zero).

## Notes

- This runbook does NOT enroll a new voice or delete the fixture — both would corrupt the test fixture used by Voice Cloning. Those flows can be exercised by separate runbooks if needed.
- The quality warning on `UITestRef` is expected — the bootstrap reference is shorter than the 10-second recommendation. Acknowledge, don't fail on it.
- Row + per-row-action AX ids are canonical (`voicesRow_<voiceID>`, `voicesRow_play_<voiceID>`, `voicesRow_use_<voiceID>`, `voicesRow_delete_<voiceID>`). Visual fallback is no longer expected — if `locate` fails for a known id, treat that as a regression.
- Perceptual review doesn't apply (this smoke plays back an existing fixture, not a freshly-generated take).
