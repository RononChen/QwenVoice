# iOS Simulator UI testing

Review every iPhone UI surface on a Mac without iPhone hardware. The engine is stubbed but every clickable chrome path is exercisable end-to-end through a Simulator-only fake-install path.

Real MLX generation, real model downloads, and real audio synthesis can't run in the iOS Simulator (no Apple Neural Engine, no real bytes on disk). For voice-quality validation, use the maintained on-device validation path documented in [`release-readiness.md`](release-readiness.md) § "iPhone Shipping Plan".

## What works vs what doesn't

| Surface | Works in Simulator | Notes |
|---|---|---|
| Generate / Custom Voice | ✅ Full UI | Speaker carousel, delivery picker, intensity segment, primary CTA all live |
| Generate / Voice Design | ✅ Full UI | Voice description field, delivery picker, primary CTA |
| Generate / Voice Cloning | ✅ Full UI | Reference picker, transcript field, "Generate batch…" affordance |
| Library / History | ✅ Full UI | Empty state + filter pills + long-press menus |
| Library / Saved Voices | ✅ Full UI | Empty state + long-press menus (Share, Delete with confirm) |
| Settings → Model Downloads | ✅ Full UI | Fake install / delete via the path below |
| Settings → Help & support | ✅ External links open in Safari | All four rows |
| Onboarding card (Generate tab) | ✅ Renders + hides | Driven by `modelManager.statuses` via fake-install registry |
| Reduce Motion / Reduce Transparency fallbacks | ✅ | Toggle via Simulator Features menu |
| Actual voice generation | ❌ Stubbed | Engine reports unsupported; primary CTA tap surfaces the Simulator-unavailable message |
| Real model downloads | ❌ Stubbed | Fake install path produces no real bytes |
| Engine lifecycle toast | ⚠️ Hard to trigger | Stub engine stays in `.idle`; the `.interrupted` / `.invalidated` / `.failed` paths only fire on the real iOS engine |

## Launch sequence

```sh
xcodebuild -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/Debug/foundation/local-builds/ios-simulator-derived-data \
  -configuration Debug build

xcrun simctl boot "iPhone 17 Pro"          # safe if already booted
xcrun simctl install booted \
  build/Debug/foundation/local-builds/ios-simulator-derived-data/Build/Products/Debug-iphonesimulator/Vocello.app
xcrun simctl launch booted com.qvoice.ios
```

Any recent-enough iPhone Simulator works; iPhone 17 Pro matches the macOS dev machine's existing target. If `qwenvoice_contract.json` is missing from the built `.app` and the app crashes on first launch, check the XcodeGen iOS resource gotcha in [`AGENTS.md`](../../AGENTS.md) under "Project generation and build" — the workaround in `project.yml` must be intact.

## Simulator fake install / delete

`IOSAppBootstrap.makeBackend` swaps in:

- `IOSSimulatorTTSEngine` — engine stub. All `generate(...)` calls return `.unsupported(reason: ...)` with the standard Simulator-unavailable message.
- `IOSSimulatorFakeStatusProvider` — wraps `LocalModelStatusProvider` and overlays a process-wide `IOSSimulatorFakeInstallRegistry`. Any model the fake installer marks as installed returns `.installed(sizeBytes:)` on every subsequent `modelManager.refresh()`, even though no real bytes are on disk.

To exercise the install flow:

1. Open Settings tab in the Simulator.
2. Tap **Download** on any model row (Custom Voice / Voice Design / Voice Cloning).
3. Watch ~4.2 s of fake progression: 5 progress steps with a Cancel button → Verifying spinner → Installing spinner → "Delete" button.
4. Navigate to the Generate tab. The first-run onboarding card is gone (because `modelManager.statuses[id]` now reports `.installed` via the decorator).
5. To revert: back to Settings, tap **Delete** on the installed row. ~0.7 s deleting spinner → row reverts to "Download". The registry entry clears; the next `modelManager.refresh()` reports `.notInstalled`; the Generate tab's onboarding card returns.

All paths gated on `IOSSimulatorRuntimeSupport.isSimulator`. Real-hardware behavior is unchanged — the entry-point methods on `IOSModelInstallerViewModel` are `simulatorFakeInstall`, `simulatorFakeCancel`, `simulatorFakeDelete`; non-Simulator builds skip them entirely.

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

- **Engine lifecycle toast** (interrupted / recovering / invalidated / failed) won't fire naturally because the stub engine never transitions out of `.idle`. To review the toast layout, drive it via a SwiftUI preview or temporarily inject a state in `IOSEngineLifecycleToast.handle(newState:)`.
- **Reference clip import** via `.fileImporter` works for the picker UI but the imported file lives in a temporary sandbox dir — it won't survive a relaunch unless explicitly saved to Saved Voices.
- **Voice cloning generation** can't actually clone a voice in Simulator — the fake install path puts the model in installed state but the engine itself remains stubbed. To validate cloning quality, follow the on-device validation path.
- **History rows** can't be seeded automatically — to test long-press menus and delete-confirm flows on real-looking data, an XCTest-style fixture isn't in place. Manual hand-seed via the database service if needed.
- **No screenshots in this runbook by design**. iOS UI moves; screenshot drift is a known docs failure mode. Capture screenshots ad-hoc when needed (`xcrun simctl io booted screenshot path.png`) and store them outside the repo.
