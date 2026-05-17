# Apple Platform Release-Readiness Gate

This document defines the source, integration, build, and unsigned-release gate that must stay green before release-hardening work is treated as reviewable.

The "gate" is **entirely local** as of May 2026: project-input validation, foundation builds, unsigned + signed/notarized release packaging, and iPhone archive/export all run on Mac mini M2 via the `scripts/` tooling. There is no CI counterpart; the prior GitHub workflows were retired in a deliberate reset.

## Purpose

The gate keeps the native Apple-platform codebase aligned with the current `macOS-first release track` using project-input validation, deterministic builds, and release-verification checks.

It protects against:

- stale project generation
- accidental reintroduction of removed Python, CLI, vendored-test, screenshot, or automation surfaces
- source/runtime regression drift that should be caught before packaging
- macOS or iPhone compile drift
- release artifact drift around `Vocello.app` and `Vocello-macos26.dmg`
- packaged-resource drift around prohibited `backend`, `python`, and `ffmpeg` resources

## Gate Owner

The canonical runtime policy owner remains `QwenVoiceCore`.

The maintained process shells are:

- macOS: `Sources/QwenVoiceEngineService/EngineServiceHost.swift`
- iPhone: `Sources/QwenVoiceCore/ExtensionEngineHostManager.swift` plus `Sources/iOSEngineExtension/`

The legacy `Sources/QwenVoiceNativeRuntime/` retained compatibility surface was retired in May 2026; the active macOS helper path now flows through `QwenVoiceCore` end-to-end.

## Frontend-Safe Contract

Frontend work is allowed to depend on:

- `TTSEngineFrontendState`
- `TTSEngineSnapshot`
- `EngineLoadState`
- `ClonePreparationState`
- `GenerationEvent`
- `IOSModelDeliverySnapshot`

Frontend work is not allowed to depend on:

- `NSXPCConnection`
- `QwenVoiceEngineServiceXPCProtocol`
- `AppExtensionPoint.Monitor`
- `AppExtensionProcess`
- transport request and reply envelope details
- trust-policy string construction
- runtime-host construction details

See:

- `docs/reference/frontend-backend-contract.md`

## Required Proof

The gate is green only when the maintained checks below are green for the current change.

### Local Build Proof

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

After a clean foundation build, exercise the affected paths locally. Use `./scripts/build.sh run` or `scripts/uitest.sh prep` for persistent Debug behavior, and use `build/Release/Vocello.app` after `./scripts/release.sh` for fresh repo-local release behavior. There is no CI or XCTest harness as of May 2026; manual smoke and the maintained Codex-driven `scripts/uitest.sh` runbooks are the behavioral regression checks.

### Local Unsigned Release Proof

```sh
./scripts/release.sh
./scripts/verify_release_bundle.sh build/Release/Vocello.app
./scripts/verify_packaged_dmg.sh build/Release/Vocello-macos26.dmg build/Release/release-metadata.txt
```

### Maintained CI Proof

None. GitHub workflows were retired in May 2026. Build, packaging, signing, notarization, and TestFlight-prep work all run locally on Mac mini M2 via:

- `scripts/release.sh` + `scripts/verify_release_bundle.sh` + `scripts/verify_packaged_dmg.sh` — signed/notarized macOS DMG
- `scripts/check_ios_catalog.sh` + `scripts/release_ios_testflight.sh` + `scripts/verify_ios_release_archive.sh` — iPhone archive/export/TestFlight prep
- `scripts/build_foundation_targets.sh macos\|ios` — deterministic foundation builds

These are the authoritative source-of-truth tools for any build, packaging, or distribution work. There is no CI mirror.

Deferred but still maintained local proof:

- `scripts/release_ios_testflight.sh` + `scripts/verify_ios_release_archive.sh`
- iPhone archive/export/upload-prep on Mac mini M2 via the local TestFlight tooling

## Acceptance Checklist

Treat frontend work as unblocked only when these statements are true:

- `QwenVoiceCore` is the sole semantic and runtime-policy owner for active macOS and iPhone behavior.
- macOS and iPhone publish the same lifecycle vocabulary: `idle`, `launching`, `connected`, `interrupted`, `recovering`, `invalidated`, `failed`.
- app-facing engine state is consumed through `TTSEngineFrontendState`, not transport-specific state.
- app-facing delivery state is consumed through `IOSModelDeliverySnapshot`, not URLSession or staging internals.
- macOS model catalog exposes variant-specific Speed and Quality rows with hardware-based Recommended defaults and per-mode Active selection; iPhone model catalog remains Speed-only.
- capability, bundle identity, entitlement, and packaged-resource drift are caught by `scripts/check_project_inputs.sh`.
- macOS and iPhone compile through the maintained foundation build script.
- the maintained local proof lanes above are green for the current change.

## Current Explicit Non-Blockers

These items remain important, but they do not block the current macOS-first release gate by themselves:

- official `iPhone 15 Pro` minimum-device evidence is still pending while owned-device proof continues on newer local hardware
- iPhone release/TestFlight proof is deferred from the current macOS-first public release milestone
- upstream MLX and package warning noise may still appear in `.xcresult` bundles as long as repo-owned targets compile
- controlled-machine manual acceptance remains required for release signoff

## Current Explicit Follow-Ons

When one of these changes, treat it as a backend contract review:

- engine lifecycle meaning
- engine load-state meaning
- clone-preparation meaning
- generation progress or event semantics
- user-visible backend error semantics
- model-delivery phase meaning
- capability or entitlement declarations

Update these docs together when the gate changes:

- `docs/README.md`
- `docs/reference/current-state.md`
- `docs/reference/engineering-status.md`
- `docs/reference/frontend-backend-contract.md`
- this file
