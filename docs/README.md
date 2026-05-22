# QwenVoice Documentation

This folder contains the current repo-authored documentation for QwenVoice.

## Maintained Reference Docs

- [`reference/current-state.md`](reference/current-state.md) — shared current repo facts
- [`reference/engineering-status.md`](reference/engineering-status.md) — current strengths, caveats, and validation posture
- [`reference/backend-freeze-gate.md`](reference/backend-freeze-gate.md) — release-readiness gate run entirely on Mac mini M2 via `scripts/` tooling (CI retired May 2026)
- [`reference/frontend-backend-contract.md`](reference/frontend-backend-contract.md) — app-facing backend state, delivery state, and gate
- [`reference/release-readiness.md`](reference/release-readiness.md) — macOS-first release-track policy, proof status, public-homepage freeze rules, and the tier→workflow mapping table
- [`reference/privacy-storage.md`](reference/privacy-storage.md) — local model, output, history, saved-voice, App Group, and deletion-path reference
- [`reference/foundation-projects-audit.md`](reference/foundation-projects-audit.md) — upstream model/runtime/database foundations, current pins, freshness, and local customization status
- [`reference/vendoring-runtime.md`](reference/vendoring-runtime.md) — runtime, vendoring, and packaging boundaries
- [`reference/mlx-audio-swift-patching.md`](reference/mlx-audio-swift-patching.md) — vendor delta under `third_party_patches/mlx-audio-swift/`, rebase procedure, and post-rebase build checklist

### Autonomous UI testing and bench

The Debug build is drivable by a Codex session via the computer-use MCP. The harness lives in `scripts/uitest.sh`. Testing is two-layered: functional smoke → timing bench. Subjective audio quality is a listen-and-judge call by the maintainer.

**Start here:**

- [`reference/testing-overview.md`](reference/testing-overview.md) — the three-layer pyramid + "what test should I run when I change X" decision table.
- [`reference/testing-cheatsheet.md`](reference/testing-cheatsheet.md) — single-page command card with copy/paste recipes.

**Agent reference (read once, refer back):**

- [`reference/ui-test-surface.md`](reference/ui-test-surface.md) — accessibility-id vocabulary, completion signals (signposts + DB + file), the Standard smoke + bench skeletons that the per-mode runbooks delta against.
- [`reference/bootstrap-saved-voice.md`](reference/bootstrap-saved-voice.md) — one-time setup of the `UITestRef` saved-voice fixture used by every Voice Cloning test.

**Layer 1 — Functional smoke** (per scenario, ~1 min each):

- [`reference/smoke-custom-voice.md`](reference/smoke-custom-voice.md) — Custom Voice generation
- [`reference/smoke-voice-design.md`](reference/smoke-voice-design.md) — Voice Design generation
- [`reference/smoke-voice-cloning.md`](reference/smoke-voice-cloning.md) — Voice Cloning (uses the `UITestRef` fixture)
- [`reference/smoke-settings.md`](reference/smoke-settings.md) — Settings screen renders + model packages show "Ready"
- [`reference/smoke-history.md`](reference/smoke-history.md) — History list renders + search filters + row plays
- [`reference/smoke-saved-voices.md`](reference/smoke-saved-voices.md) — Saved Voices lists the fixture + row plays

**Layer 2 — Timing bench** (per mode, ~12 min each, 24 samples × cold/warm × variant × prompt-length):

- [`reference/bench-custom-voice.md`](reference/bench-custom-voice.md)
- [`reference/bench-voice-design.md`](reference/bench-voice-design.md)
- [`reference/bench-voice-cloning.md`](reference/bench-voice-cloning.md)
- [`reference/benchmark-baselines.json`](reference/benchmark-baselines.json) — committed regression baselines, schema v3, regression-ready (24 cells × n=3 on Apple M2, May 2026). `bench-compare` flags timing/RTF drift past ±15 %; depth metrics (audio RMS/peak dBFS, peak RSS combined + app/XPC split) are stored for forensic comparison.

**iOS Simulator UI review** (per surface, ~5 min):

- [`reference/ios-simulator-testing.md`](reference/ios-simulator-testing.md) — review iPhone chrome on a Mac without iPhone hardware via the stubbed engine + Simulator-only fake install/delete path. Covers Reduce Motion / Reduce Transparency toggle review and side-by-side chrome comparison against the macOS app. Distinct from the macOS `scripts/uitest.sh` harness because iOS has no equivalent automation surface.

Useful local diagnostics can be exported with:

```sh
./scripts/export_diagnostics.sh
```

These are the maintained source-of-truth docs for contributor and repository behavior. When prose disagrees, trust the repo code, manifests, scripts, and workflows first, then these reference docs.

## Product And Public Docs

- [`../README.md`](../README.md) — public GitHub landing page and end-user overview
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — contributor workflow, source-of-truth order, and validation entrypoints

The public landing page leads with `Vocello 2.0.0` (stable) as the current Mac download, with `QwenVoice v1.2.3` retained as the legacy macOS 15 fallback. See [`reference/release-readiness.md`](reference/release-readiness.md) for the public-messaging rules.

## Supplemental Guides

- [`qwen_tone.md`](qwen_tone.md) — supplemental tone and prompt-writing guidance

Supplemental guides are useful, but they are not the primary source of truth for current repo structure or shipped-product behavior.

## Historical Docs

- [`releases/`](releases/) — checked-in release notes for past published versions

## Notes

- Maintained contributor guidance in this checkout lives in `CONTRIBUTING.md` and the maintained reference docs listed above.
- This repo does not maintain project-scoped QwenVoice skills; contributor guidance lives in the maintained docs above.
- Current automation surfaces live in `scripts/` and a single GitHub workflow (`.github/workflows/release.yml`) scoped to release packaging only — two jobs run in parallel on `release.published`: `package` (macOS DMG: sign, notarize, staple, attach to the Release) and `compile-ios` (iOS compile-safety only, no signing, no tests). There is no XCTest target — retired in May 2026 along with the historical CI workflows. Local behavioral validation runs **on Mac mini M2** via `scripts/check_project_inputs.sh`, `scripts/build_foundation_targets.sh`, `scripts/release.sh`, and `scripts/release_ios_testflight.sh`. Behavioral verification is twofold: (a) manual — launch the app and exercise the affected paths by hand, and (b) agent-driven — a Codex session can drive `Vocello.app` via the computer-use MCP, following the smoke and bench runbooks above. The agent-driven harness lives in `scripts/uitest.sh` plus the runbooks under `reference/`; it's distinct from the XCTest / Python-benchmark harnesses `check_project_inputs.sh` actively bans.
- Generated or vendored dependency documentation is intentionally out of scope for the repo docs.
