# iOS UI reference

> Codex/ChatGPT Desktop reference for the physical-device Vocello UI. `$vocello-ios-ui-qa`
> drives the paired iPhone through bundled Computer Use and iPhone Mirroring;
> `scripts/ios_agent_ui.sh` records evidence. The iOS Simulator is unsupported.

Related sources:

- [`ios-app-guide.md`](ios-app-guide.md) — architecture and implementation map.
- [`ios-device-testing.md`](ios-device-testing.md) — physical-device lanes and gates.
- [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md) — Codex frontend acceptance index.

## Navigation hierarchy

Vocello opens on the Studio tab in Custom mode. The root tabs are:

| Surface | Purpose | Stable identifier family |
| --- | --- | --- |
| Studio | Custom, Design, and Clone generation | `rootTab_studio`, `screen_studio`, `studio*`, `textInput_*` |
| Voices | Saved voices and built-in speakers | `rootTab_voices`, `screen_voices`, `voicesRow_*` |
| History | Generated takes, playback, export, deletion | `rootTab_history`, `screen_history`, `historyRow_*` |
| Settings | Models, preferences, storage, permissions, About | `rootTab_settings`, `screen_settings`, `iosSettings_*`, `iosModel*` |

The Studio mode selector changes the composer in place; it does not change the selected root tab.
Cold launch selects Custom mode. Explicit handoffs, such as using a saved voice for cloning, may
switch the in-session Studio mode.

## Studio — Custom Voice

Custom mode contains:

- script editor and character count (`textInput_textEditor`, `textInput_lengthCount`);
- selected built-in speaker / saved voice control;
- delivery, language, and variation controls;
- Generate button (`textInput_generateButton`);
- inline generation progress and player state.

Generate remains unavailable until the script and required model are ready. Successful generation
must create a History row and readable output; UI visibility alone is not backend proof.

## Studio — Voice Design

Design mode replaces the voice picker with a required voice brief. The brief can be entered
directly or started from a suggestion, then confirmed before generation. After a successful take,
the generated voice may be saved into the Saved Voices collection.

The full Computer Use suite should verify:

- brief setup and restoration;
- script entry and readiness;
- successful generation;
- optional Save as Voice handoff;
- correct behavior when the Design model is missing.

## Studio — Voice Cloning

Clone mode requires a reference clip before generation. References may come from saved voices or
the physical-device recording flow. Automated tests should prefer a pre-enrolled saved reference;
microphone authorization and recording remain attended device operations unless the test explicitly
owns that state.

The iOS production load profile may omit clone encoders when memory entitlement or device budget
requires it. Preserve the `.fullCapabilities` versus `.iOSProductionDefault` policy.

## Voices

The Voices tab presents:

- saved voice rows (`voicesRow_saved_*`);
- built-in speaker rows;
- separate row-body and preview-play actions;
- search and filter controls;
- the physical-device Save a New Voice flow.

Using a saved voice hands it to Studio Clone mode. Using a built-in speaker hands it to Studio
Custom mode. Keep row and action identifiers stable across layout refactors.

## History

History groups completed generations by date and supports:

- transcript or voice search;
- mode filtering and sorting;
- playback;
- saving/exporting audio;
- saving a take as a voice;
- individual deletion and bulk Clear History.

Deletion is destructive and must be isolated in tests. Test output must use the app's test/debug
storage and must not touch the owner's production library.

## Settings

### Voice models

There is one Speed model for each generation mode on iOS. Model rows expose stable states and
identifiers for:

- not installed / Install;
- downloading / progress / Cancel;
- installed / Active;
- repair when verification fails;
- delete with storage impact.

iOS ships the 1.7B Speed variants only. Model lifecycle tests are opt-in and must not run as part of
ordinary UI smoke coverage.

### Preferences and storage

Settings includes autoplay, variation, output-copy destination, storage summary, permissions, and
About/version information. Tests must restore reversible preferences after validation. System
permission enrollment remains attended setup.

## Sheets and overlays

Important transient surfaces include:

- Custom voice picker;
- Design voice-brief editor;
- Clone reference picker;
- delivery and language controls;
- batch-independent generation/player UI;
- reference recording and Save This Voice naming flow;
- History action and delete confirmations;
- model lifecycle confirmations;
- system folder picker.

Tests should wait for semantic conditions and stable identifiers rather than fixed delays or
coordinate assumptions.

## Accessibility and visual acceptance

All interactive controls must retain stable `accessibilityIdentifier` values. Visual review checks:

- no clipping or truncation;
- readable hierarchy and copy;
- correct enabled/disabled states;
- VoiceOver labels and focus order;
- Dynamic Type behavior;
- non-color cues for mode and status;
- Reduce Motion and Reduce Transparency behavior;
- error and recovery presentation.

The authoritative review lane is:

```sh
scripts/ios_device.sh review
```

It runs on a paired physical iPhone and produces screenshots for manual/Codex inspection. It does
not authorize a second UI automation driver.

## Test routing

| Goal | Command |
| --- | --- |
| Device/environment readiness | `scripts/ios_device.sh preflight` |
| Default physical-device UI regression | `$vocello-ios-ui-qa quick` → `scripts/ios_device.sh test` |
| Full UI acceptance | `$vocello-ios-ui-qa full` → `scripts/ios_device.sh ui-test --suite full` |
| Full UI generation matrix | `$vocello-ios-ui-qa benchmark` → `scripts/ios_device.sh bench-ui` |
| Visual review | Full Computer Use report → `scripts/ios_device.sh review` |
| Explicit frontend / iOS release acceptance | `scripts/ios_device.sh gate` |

Never use an iOS Simulator, Simulator Browser, another desktop-control/mobile MCP, or a committed
coordinate table. Bundled Computer Use on iPhone Mirroring is the supported UI driver.
