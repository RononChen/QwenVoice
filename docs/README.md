# QwenVoice Documentation

This folder contains the current repo-authored documentation for QwenVoice.

## Maintained Reference Docs

- [`../CLAUDE.md`](../CLAUDE.md) — canonical repository operating guide for coding agents
- [`reference/current-state.md`](reference/current-state.md) — shared current repo facts
- [`reference/engineering-status.md`](reference/engineering-status.md) — current strengths, caveats, and validation posture
- [`reference/backend-freeze-gate.md`](reference/backend-freeze-gate.md) — release-readiness gate run entirely on Mac mini M2 via `scripts/` tooling (CI retired May 2026)
- [`reference/backend-hardening-validation-evidence.md`](reference/backend-hardening-validation-evidence.md) — local proof checklist for backend hardening patches touching trust, transport, audio prep, or runtime boundaries
- [`reference/frontend-backend-contract.md`](reference/frontend-backend-contract.md) — app-facing backend state, delivery state, and QA gate
- [`reference/live-testing.md`](reference/live-testing.md) — local QA lanes, strict e2e behavior, result paths, and xcresult triage commands
- [`reference/release-readiness.md`](reference/release-readiness.md) — macOS-first release-track policy, proof status, public-homepage freeze rules, and the tier→workflow mapping table
- [`reference/privacy-storage.md`](reference/privacy-storage.md) — local model, output, history, saved-voice, App Group, and deletion-path reference
- [`reference/foundation-projects-audit.md`](reference/foundation-projects-audit.md) — upstream model/runtime/database foundations, current pins, freshness, and local customization status
- [`reference/vendoring-runtime.md`](reference/vendoring-runtime.md) — runtime, vendoring, and packaging boundaries
- [`reference/mlx-audio-swift-patching.md`](reference/mlx-audio-swift-patching.md) — vendor delta under `third_party_patches/mlx-audio-swift/`, rebase procedure, and post-rebase build checklist
- [`reference/instruments-profiling.md`](reference/instruments-profiling.md) — Instruments / `xctrace` workflow for kernel-level engine profiling (when wall-clock probes have hit their limit)

Useful local diagnostics can be exported with:

```sh
./scripts/export_diagnostics.sh
```

These are the maintained source-of-truth docs for contributor and repository behavior. When prose disagrees, trust the repo code, manifests, scripts, and workflows first, then these reference docs.

## Product And Public Docs

- [`../README.md`](../README.md) — public GitHub landing page and end-user overview
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — contributor workflow, source-of-truth order, and validation entrypoints

The public landing page leads with `Vocello` as the next Mac identity while making `QwenVoice v1.2.3` the safe current download. See [`reference/release-readiness.md`](reference/release-readiness.md) for the public-messaging rules.

## Supplemental Guides

- [`qwen_tone.md`](qwen_tone.md) — supplemental tone and prompt-writing guidance

Supplemental guides are useful, but they are not the primary source of truth for current repo structure or shipped-product behavior.

## Historical Docs

- [`releases/`](releases/) — checked-in release notes for past published versions

## Notes

- Maintained contributor guidance in this checkout lives in `CLAUDE.md`, `CONTRIBUTING.md`, and the maintained reference docs listed above.
- This repo does not maintain project-scoped QwenVoice skills; contributor guidance lives in the maintained docs above.
- Current automation surfaces live in `scripts/`. There are no GitHub workflows — CI was retired in May 2026. Builds, tests, debugging, benchmarks, packaging, signing, notarization, and TestFlight prep all run **locally on Mac mini M2** via `scripts/qa.sh`, `scripts/bench_ui_generation.sh`, `scripts/compare_perf_manifest.sh`, `scripts/release.sh`, and `scripts/release_ios_testflight.sh`.
- Generated or vendored dependency documentation is intentionally out of scope for the repo docs.
