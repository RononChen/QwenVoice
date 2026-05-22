# iOS Simulator UI testing

Review every iPhone UI surface on a Mac without iPhone hardware. The Simulator uses a fake backend that exercises the normal app paths: fake model install/delete state, fake generation progress, deterministic WAV output, History persistence, Saved Voice files, and the Studio inline player.

Real MLX generation, real model downloads, and real voice-quality synthesis still cannot run in the iOS Simulator. The fake backend writes playable review audio, not speech-quality output. For voice-quality validation, use the maintained on-device validation path documented in [`release-readiness.md`](release-readiness.md) § "iPhone Shipping Plan".

## What works vs what doesn't

| Surface | Works in Simulator | Notes |
|---|---|---|
| Studio / Custom Voice | ✅ Full UI + fake generation | Voice picker, delivery picker, primary CTA, generating state, fake WAV, History row, inline player |
| Studio / Voice Design | ✅ Full UI + fake generation | Voice brief, delivery picker, primary CTA, fake WAV, History row, inline player |
| Studio / Voice Cloning | ✅ Full UI + fake generation | Reference picker, transcript field, batch affordance, fake WAVs, History rows |
| History | ✅ Full UI | Seedable rows, search/filter UI, row tap, menu Play, Delete |
| Saved Voices | ✅ Full UI | Seedable voice files, preview/play, delete |
| Settings → Model Downloads | ✅ Full UI | Fake install / cancel / delete via the path below |
| Settings → Help & support | ✅ External links open in Safari | All four rows |
| Onboarding card (Studio tab) | ✅ Renders + hides | Driven by `modelManager.statuses` via fake-install registry |
| Reduce Motion / Reduce Transparency fallbacks | ✅ | Toggle via Simulator Features menu |
| Actual voice generation | ⚠️ Fake only | Deterministic WAV output exercises UI and persistence; it is not model speech |
| Real model downloads | ❌ Stubbed | Fake install path produces no real bytes |
| Engine lifecycle toast | ⚠️ Limited | Most lifecycle failures still require the real iOS engine or targeted injection |

## Launch sequence

```sh
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/Debug/foundation/local-builds/ios-simulator-derived-data \
  -configuration Debug build

xcrun simctl boot "iPhone 17 Pro"          # safe if already booted
xcrun simctl install booted \
  build/Debug/foundation/local-builds/ios-simulator-derived-data/Build/Products/Debug-iphonesimulator/Vocello.app
xcrun simctl launch booted com.patricedery.vocello
```

Any recent-enough iPhone Simulator works; iPhone 17 Pro matches the macOS dev machine's existing target. If `qwenvoice_contract.json` is missing from the built `.app` and the app crashes on first launch, check the XcodeGen iOS resource gotcha in [`AGENTS.md`](../../AGENTS.md) under "Project generation and build" — the workaround in `project.yml` must be intact.

## Simulator fake backend

`IOSAppBootstrap.makeBackend` swaps in:

- `IOSSimulatorTTSEngine` — functional fake `TTSEngine`. It supports Custom, Design, and Clone requests; validates text/model/reference inputs; emits progress; honors cancellation; writes a deterministic WAV to the requested output path; and returns a normal `GenerationResult`.
- `IOSSimulatorFakeStatusProvider` — wraps `LocalModelStatusProvider` and overlays `IOSSimulatorFakeInstallRegistry`. Any model the fake installer marks as installed returns `.installed(sizeBytes:)` on subsequent `modelManager.refresh()` calls, even though no real model bytes are on disk.
- Simulator persistence helpers — write generated outputs, History rows, saved voices, imported references, and fake model state under the Simulator app-support folder.

To exercise the install flow:

1. Open Settings tab in the Simulator.
2. Tap **Download** on any model row (Custom Voice / Voice Design / Voice Cloning).
3. Watch ~4.2 s of fake progression: 5 progress steps with a Cancel button → Verifying spinner → Installing spinner → "Delete" button.
4. Navigate to the Generate tab. The first-run onboarding card is gone (because `modelManager.statuses[id]` now reports `.installed` via the decorator).
5. To revert: back to Settings, tap **Delete** on the installed row. ~0.7 s deleting spinner → row reverts to "Download". The registry entry clears; the next `modelManager.refresh()` reports `.notInstalled`; the Generate tab's onboarding card returns.

All paths gated on `IOSSimulatorRuntimeSupport.isSimulator`. Real-hardware behavior is unchanged — the entry-point methods on `IOSModelInstallerViewModel` are `simulatorFakeInstall`, `simulatorFakeCancel`, `simulatorFakeDelete`; non-Simulator builds skip them entirely.

## Scenario controls

For shell launches, prefix env vars with `SIMCTL_CHILD_`:

```sh
SIMCTL_CHILD_QVOICE_SIM_FAKE_MODELS=all \
SIMCTL_CHILD_QVOICE_SIM_BACKEND_SCENARIO=success \
xcrun simctl launch --terminate-running-process booted com.patricedery.vocello
```

Supported controls:

- `QVOICE_SIM_BACKEND_SCENARIO=success|slow|fail` — default is `success`. Use `slow` to verify cancel/Stop states and `fail` to verify errors without saving output.
- `QVOICE_SIM_BACKEND_DELAY_MS=<milliseconds>` — overrides the fake generation delay.
- `QVOICE_SIM_FAKE_MODELS=none|all|custom,design,clone|<model-id-list>` — seeds fake installed model state for review and automation.
- `QVOICE_SIM_SEED_DATA=history,voices` — seeds reviewable History and Saved Voice fixtures into real Simulator stores.

When launching through XcodeBuildMCP, pass the same env names through the simulator launch tool's `env` dictionary. If a screenshot shows "Simulator fake backend failure", relaunch with `QVOICE_SIM_BACKEND_SCENARIO=success` or no scenario.

For visual parity work against the React reference, follow [`ios-reference-ui-workflow.md`](ios-reference-ui-workflow.md).

## Accessibility toggle review

AGENTS.md "Conventions to preserve" requires Reduce Motion and Reduce Transparency to be honored. Toggle them via the Simulator menu:

- **Reduce Motion**: Simulator → Features → Accessibility → Reduce Motion. Selection pills should stop animating; mode-crossfade transitions should snap rather than fade.
- **Reduce Transparency**: Simulator → Features → Accessibility → Reduce Transparency. All glass surfaces — selection pills, cards, onboarding card, dock selected tab — should fall back to the solid `smokedGlassTint` fill. No translucent backgrounds.

The central honor-points are `IOSSubtleGlassSurfaceModifier` in `Sources/iOS/IOSShellPrimitives.swift` (Reduce Transparency) and the `iosAppAnimation` helper in `Sources/iOS/IOSAccessibility.swift` (Reduce Motion).

## Side-by-side chrome review against macOS

PRODUCT.md positions iOS and macOS as the same brand. To sanity-check that visually after touching any iOS chrome:

1. Launch the macOS Vocello.app (`./scripts/build.sh run` for Debug, or `build/Release/Vocello.app` after `./scripts/release.sh`).
2. Launch the iOS Simulator alongside it on the same Mac.
3. Walk surface-by-surface and confirm:
   - **Vocello wordmark**: SF Rounded semibold on both (iOS uses `.system(.title3, design: .rounded, weight: .semibold)`; macOS uses 18pt rounded in `Sources/Views/Sidebar/SidebarView.swift`).
   - **Mode colors**: Custom Voice gold (`#EBCD8A` dark), Voice Design lavender (`#C0ABDB` / `#BFADD8`), Voice Cloning terracotta (`#DB8B87` / `#DBAA87`). Both platforms whisper-tint these into glass (14% opacity).
   - **Selection cues**: macOS sidebar uses a smoked-glass background + accent stripe; iOS dock selected tab mirrors that (smoked glass + 1pt accent ring, NOT the gradient gold capsule that pre-Track-B.3 builds had).

If a surface diverges in identity, check the design tokens in `Sources/iOS/IOSShellPrimitives.swift` against `Sources/Views/Components/AppTheme.swift` — they're intentionally locked together (AGENTS.md "iOS design tokens align to macOS").

## Known limitations

- **Engine lifecycle toast** (interrupted / recovering / invalidated / failed) is still hard to trigger naturally because the fake backend does not reproduce every extension failure path. To review the toast layout, drive it via a SwiftUI preview or temporarily inject a state in `IOSEngineLifecycleToast.handle(newState:)`.
- **Reference clip import** via `.fileImporter` works for the picker UI but the imported file lives in a temporary sandbox dir — it won't survive a relaunch unless explicitly saved to Saved Voices.
- **Voice cloning quality** cannot be validated in Simulator. Clone flows can produce deterministic fake WAVs and History rows, but they do not synthesize from the reference voice.
- **Audio quality** is fake. Use Simulator for UI, persistence, and controls; use real hardware for MLX output quality and performance.
- **No screenshots in this runbook by design**. iOS UI moves; screenshot drift is a known docs failure mode. Capture screenshots ad-hoc when needed (`xcrun simctl io booted screenshot path.png`) and store them outside the repo.
