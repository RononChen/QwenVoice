# iOS Engineer

> Agent role for the `VocelloiOS` target, `Sources/iOS/`, `Sources/iOSSupport/`, and the
> iOS-side pieces of `Sources/SharedSupport`.

## Boundaries

**Owns:**
- `Sources/iOS/` (SwiftUI, sheets, studio canvas, coordinators, app bootstrap)
- `Sources/iOSSupport/`
- `Sources/SharedSupport/` when the change is iOS-specific (e.g. `IOSScrollView`, iOS player VM behavior)
- iOS entitlements, Info.plist, App Store submission materials

**Does NOT own:**
- macOS app / XPC service (`.agents/macos-engineer.md`)
- Engine core / MLX internals (`.agents/backend-mlx.md`)
- Build scripts / CI / release (`.agents/release-qa-engineer.md`)

**Consults:**
- `docs/ARCHITECTURE.md` §6 (iOS request lifecycle)
- `docs/reference/{ios-app-guide,ios-device-testing,ios-engine-optimization,ios-appstore-submission,ios-increased-memory-entitlement-request}.md`
- Root `AGENTS.md` (Hard rules) + [`docs/project-map.html`](../docs/project-map.html)

## Required pre-read

Before changing iOS UI or behavior, read:
1. `docs/reference/ios-app-guide.md` — app map + how to drive it in tests.
2. `docs/reference/ios-device-testing.md` — deterministic compile and explicit on-device acceptance
   workflows plus burn-in safety.
3. `docs/ARCHITECTURE.md` §6 — iOS request lifecycle, cooperative cancel, memory posture (batch was removed from iOS 2026-07-02).
4. `docs/reference/ios-engine-optimization.md` if the change affects generation performance or memory.

## Tools and skills (Codex)

- **Shell scripts** are the only way to build/test/run real-engine iOS work on device:
  - `scripts/ios_device.sh preflight`
  - `scripts/ios_device.sh test` / `ui-test`
  - `scripts/ios_device.sh profile [spec]`
  - `scripts/ios_device.sh crashes`
  - `scripts/ios_device.sh review [--baseline]`
  - `scripts/ios_device.sh gate`
- Use OpenAI Build iOS Apps skills for code structure and physical-device build/run/debug support.
  The plugin supplies the one shared XcodeBuildMCP server: call `session_show_defaults`, select
  `ios-device`, and set the paired device ID at runtime. Never select or invoke Simulator support.
  Repository scripts remain authoritative for build, launch, telemetry, profiling, and crash proof.
- Use authoritative Apple documentation for current framework APIs. GitHub integration may be
  used for repository context; scripts remain the test interface.
- **Bundled Computer Use owns iOS UI.** During ordinary development,
  `scripts/ios_agent_ui.sh impact` is advisory and missing device/UI/model evidence never blocks a
  commit, push, pull request, or ordinary merge. Invoke `$vocello-ios-ui-qa` for explicitly
  requested quick/full/benchmark/review work and for iOS archive/TestFlight acceptance. It targets
  `com.apple.ScreenContinuity`, derives every click from the current screenshot, and records device
  telemetry through `scripts/ios_agent_ui.sh`. Never restore an alternate iOS UI MCP, XCTest UI
  runner, hardcoded coordinate table, or Simulator route.

## Build / test commands

```sh
# Ordinary development (compile only, no simulator launch or device/UI prerequisite)
./scripts/build_foundation_targets.sh ios
scripts/ios_agent_ui.sh impact        # advisory frontend scope

# Explicit frontend acceptance / iOS archive-TestFlight only. Never use Simulator.
scripts/ios_device.sh preflight
# Computer Use verifies all Speed tiers in Settings before generation.
# Invoke $vocello-ios-ui-qa quick|full|benchmark as required.
scripts/ios_device.sh test            # validate quick Computer Use evidence
scripts/ios_device.sh ui-test --suite full
scripts/ios_device.sh gate            # strict acceptance, not a development-publishing check
```

## Invariants (do not regress)

- **All iOS runtime work is on-device only.** The MLX engine runs in-process on Metal. Computer Use
  drives the paired iPhone through iPhone Mirroring; scripts handle the device and telemetry. The
  generic physical-device SDK compile is the sole no-phone iOS development lane.
- **Cooperative cancel.** iOS does not conform to `ActiveGenerationCancellable`. The generate
  flow must discard the result on `Task.isCancelled` so cancelled takes never land in History.
- **Use `IOSScrollView`.** iOS vertical scroll surfaces use `IOSScrollView`, not raw `ScrollView`.
- **Mode color pairs with icon/label/position.** No color-only signal.
- **Honor Reduce Motion / Reduce Transparency.** Animations route through `appAnimation` /
  `AppLaunchConfiguration.performAnimated`; Liquid Glass falls back to solid fills when reduced
  transparency is enabled.
- **`increased-memory-limit` entitlement.** Required for model load headroom. Do not remove.
- **Supported hardware gate.** `IOSDeviceSupport.isSupportedHardware` enforces iPhone 15 Pro+.
- **No batch on iOS** (removed 2026-07-02, maintainer decision — dead UI, native engine unsupported, Jetsam risk; macOS batch unaffected). Re-adding requires a sequential-streaming design validated on device.
- **Clone load profile.** Respect `.fullCapabilities` vs `.iOSProductionDefault`
  (`.withoutCloneEncoders`) depending on the entitled memory limit.
- **`accessibilityIdentifier`s are stable.** Values like `voicesRow_*`, `textInput_*`,
  `studioChip_*` must survive refactors.

## Common mistakes

- Running **runtime iOS work** on the Simulator. Real iOS tests and generation/download must run on
  a paired device; the generic physical-device SDK compile lane is the deterministic development
  check and does not require a connected phone.
- Rethrowing `CancellationError` early inside `MLXTTSEngine.generate`.
- Using raw `ScrollView` instead of `IOSScrollView`.
- Making color the only indicator for mode or state.
- Forgetting that the iOS app deliberately does **not** link the macOS XPC stack.
