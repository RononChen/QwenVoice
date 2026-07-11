# Release / QA Engineer

> Agent role for build scripts, CI workflow, packaging, signing, notarization,
> benchmarks, UI smoke, crash/profile analysis, and release QA gates.

## Boundaries

**Owns:**
- `scripts/*.sh` and `scripts/lib/`
- `.github/workflows/release.yml`
- `benchmarks/` committed summaries
- `docs/releases/`
- `docs/ios-review-baselines/`, `docs/macos-review-baselines/`
- Release verification scripts (`scripts/verify_*.sh`, `scripts/create_dmg.sh`, etc.)

**Does NOT own:**
- App source code (`.agents/backend-mlx.md`, `.agents/ios-engineer.md`, `.agents/macos-engineer.md`)
- Marketing site (`website/AGENTS.md`)

**Consults:**
- `docs/reference/{macos-release-qa,telemetry-and-benchmarking,cli,macos-testing,ios-device-testing}.md`
- `docs/ARCHITECTURE.md` §12 (telemetry)
- Root `AGENTS.md` (Workflows, Commands) + [`docs/project-map.html`](../docs/project-map.html)

## Required pre-read

Before changing scripts or CI, read:
1. The script you are modifying (header comments encode intent and env vars).
2. `.github/workflows/release.yml` if touching CI.
3. `docs/reference/macos-release-qa.md` for the full macOS release QA checklist.
4. `docs/reference/benchmarking-procedure.md` for the operator runbook (when to bench, platform lanes, preflight).
5. `docs/reference/telemetry-and-benchmarking.md` for benchmark/telemetry schema and knobs.

## Tools and skills (Codex)

- **Shell scripts are the source of truth**; run them directly and preserve their artifacts.
- Use the installed GitHub integration for PR, release, and Actions context; use `gh` when the
  integration does not expose the required operation or log detail.
- Use relevant installed Codex skills for test triage, performance, signing, packaging, or
  telemetry after reading their instructions. Start from script output and generated artifacts.
- macOS frontend acceptance is driven by `$vocello-macos-ui-qa`; iOS frontend acceptance is driven
  by `$vocello-ios-ui-qa` through iPhone Mirroring. Both use bundled Computer Use and script-owned
  reports/attestations; iOS adds pulled on-device telemetry proof.
- Development CI is deterministic-only. Commits, pushes, pull requests, and ordinary merges must
  not wait for Computer Use, models, a paired phone, or UI attestations; impact reports are advisory.
- Release packaging is strict and platform-specific. macOS packaging is subordinate to
  `scripts/macos_test.sh release-readiness`, which requires deterministic tests, project-input and
  crash-delta checks, independent fresh macOS full and benchmark attestations,
  telemetry-overhead, frontend review, and matching identities. iOS archive/TestFlight is
  subordinate to `scripts/ios_agent_ui.sh release-check` and requires only fresh iOS frontend
  evidence. Neither platform's UI proof blocks the other platform's artifact.
- **iOS artifact paths** (see [`ios-device-testing.md`](../docs/reference/ios-device-testing.md)):
  `build/ios/agent-ui/<run>/` (Computer Use report, screenshots, pulled telemetry),
  `build/ios-diagnostics/` (headless generation telemetry + crashes),
  `build/ios/gate-<runID>/verdict.txt`, `build/ios/profile-*.trace` / `bench-ui-*/vocello.trace`.

## Build / test commands

```sh
# Ordinary development / CI (no Computer Use, model, or device prerequisite)
./scripts/check_project_inputs.sh
scripts/macos_test.sh test
./scripts/build.sh build
./scripts/build_foundation_targets.sh ios
scripts/macos_agent_ui.sh impact      # advisory only
scripts/ios_agent_ui.sh impact        # advisory only

# Explicit macOS frontend/release acceptance (step 0 is read-only model verification)
scripts/macos_test.sh models ensure   # explicit repair/bootstrap only; normal readiness is visible in Settings
scripts/macos_test.sh gate
QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate   # optional: bounded custom/speed/medium bench + audioQC

# macOS Computer Use evidence (suite selected by impact)
scripts/macos_agent_ui.sh doctor --suite full --json
scripts/macos_agent_ui.sh impact
# Run every required suite; full and benchmark are orthogonal.
# Invoke $vocello-macos-ui-qa full first, then validate its visible model-readiness proof:
scripts/macos_test.sh ui-report --suite full
scripts/macos_test.sh telemetry-overhead   # when listed; refuses without current full evidence
# Invoke benchmark independently when required, then validate:
scripts/macos_test.sh bench-ui --report <benchmark-run>
python3 scripts/check_macos_xpc_bench.py ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --run-id mac-ui-benchmark-YYYYMMDD-HHMMSS

# Language-path verification (optional pre-release; Phases 1–3)
scripts/macos_test.sh core-test
python3 scripts/test_check_language_hints.py
python3 scripts/test_check_language_output.py
scripts/macos_test.sh lang-bench --subset quick              # Phase 2 hint gate (CLI)
scripts/ios_device.sh lang-bench --subset quick --label "release-QA"   # Phases 2–3 on device
# Full 19-cell iOS matrix: scripts/ios_device.sh lang-bench --subset full --label "…"
# Phase 3 output (DE/ES/ZH/JA): language-bench.md § Phase 3 prerequisites — Speech Wi‑Fi assets
# Historical 2026-07-06 language run: hint 19/19 PASS; output 7/18 pending Speech assets.
# Current acceptance state and resume commands: docs/development-progress.md

# Semantic frontend/release review (Computer Use report required)
scripts/macos_test.sh review --report <full-run>
scripts/ios_device.sh gate

# Model fixture helpers
scripts/macos_test.sh models check|ensure|install
# iOS model readiness is reviewed live in Settings through Computer Use.

# Release packaging
./scripts/build.sh release

# Benchmark driver (--ledger = single summarizer pass → benchmarks/HISTORY.md)
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <prepared-voice> \
  --label "release-QA" --ledger

# Optional regression compare (see macos-release-qa.md step 3)
python3 scripts/summarize_generation_telemetry.py \
  ~/Library/Application\ Support/QwenVoice-Debug/diagnostics \
  --compare-baseline benchmarks/baseline-2026-06-16-45720dd-streaming-default.md \
  --label "release-QA"

# Crash/profile (profile fails on bench error unless --allow-bench-fail / QVOICE_MAC_PROFILE_ALLOW_BENCH_FAIL=1)
scripts/macos_test.sh crashes
scripts/macos_test.sh profile [spec]
scripts/ios_device.sh crashes
scripts/ios_device.sh profile [spec]
```

## Invariants (do not regress)

- **Single shippable config: `Release` only.** There is no `Debug` config or `DEBUG` symbol.
  `build.sh` compiles `-Onone`; `release.sh` compiles optimized.
- **XcodeGen project generation.** `project.yml` is the source of truth; never edit
  `QwenVoice.xcodeproj/project.pbxproj` directly.
- **Developer ID signing + notarization.** macOS release uses Developer ID Application cert,
  hardened runtime, and `notarytool` stapling. CI uses App Store Connect API key auth.
- **Ordinary CI is deterministic-only.** GitHub CI builds `VocelloiOS` with
  `generic/platform=iOS` and runs macOS deterministic verification. Real Computer Use evidence is
  required only by explicit frontend acceptance and the matching platform's release lane.
- **Committed benchmark summaries ≤256 KB.** Raw `*.jsonl` is gitignored.
- **Deep checkout on CI.** `fetch-depth: 0` is required so `git rev-parse HEAD` in
  `scripts/release.sh` resolves for `release-metadata.txt`.
- **Burn-in-safe iOS testing.** All on-device lanes go through `scripts/ios_device.sh`.
- **macOS real-generation acceptance needs model fixtures.** Computer Use verifies readiness in Settings;
  run `scripts/macos_test.sh models ensure` only to repair/bootstrap the debug link and clone voice. See [`scripts/lib/test_models.sh`](../scripts/lib/test_models.sh) and
  [`docs/reference/testing-runbook.md`](../docs/reference/testing-runbook.md) §1b.
- **No macOS XCUITest frontend.** `VocelloMacUITests`, runner signing, coordinate hooks, hidden
  UI-test markers, and a generated accessibility catalog must not return. Stable controls are
  validated when explicit Computer Use scenarios encounter them.

## Common mistakes

- Adding a `Debug` configuration or `#if DEBUG` scaffolding in scripts.
- Running iOS UI work in the Simulator or expecting ordinary CI to drive the UI. Use
  `$vocello-ios-ui-qa` and `scripts/ios_device.sh gate` on a paired iPhone for explicit frontend
  acceptance and before iOS archive/TestFlight, not as a prerequisite to preserve development work.
- Committing raw `.jsonl` telemetry to `benchmarks/`.
- Forgetting to preserve dSYMs (`scripts/build.sh` copies them to `build/macos/dsyms`).
- Changing signing/notarization env vars without updating the workflow secret docs.
