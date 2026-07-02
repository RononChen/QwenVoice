# Rescue plan — continuation guide

> **Read this first if you are picking up the rescue work.** It is written to be
> self-contained: current state, exact remaining steps with commands and expected
> outputs, and the guardrails that previous sessions learned the hard way. Follow it
> literally; when this doc disagrees with the code, the code wins. Delete this file
> when Phase 5 (release) ships.
>
> Context: [post-mortem](post-mortem/2026-06-post-fable-development-hell.md) → four
> audits (2026-07-01) → phased remediation. Onboarding: [`AGENTS.md`](../AGENTS.md).

## 1. Current state (2026-07-02, `main` @ 42aa64e+)

### Done and verified

| Area | What landed | Key commits |
| --- | --- | --- |
| Visual regression net | 8 macOS + 7 iOS review-baseline PNGs seeded (`docs/*-review-baselines/`); xcresult-attachment fallback in both review lanes | `6586592` |
| Measurement shell | `scripts/uitest_measure.sh` (prep/finish, reset, smoke-check, bench-wait, verify-generation, streaming-preview-check, bench-compare) — validated live end-to-end | `6586592`, `b899d64` |
| Bench regression gating | `benchmarks/baselines/mac-gate-bench.json` + `benchmarks/baselines/full-matrix-speed.json`; `QWENVOICE_GATE_BENCH=1 macos_test.sh gate` compares and fails on >5% regression; summarizer RTF direction fixed | `5b96bbf`, `846721f` |
| Hardened gates | New crashes during a gate run are gate-fatal (both platforms); iOS gate gained a headless generation step (design:speed — the download test uninstalls pro_custom BY DESIGN) | `5b96bbf` |
| Agent-driven UI loop | Peekaboo macOS generate loop verified (see pilot log §4); runbooks regenerated (`ui-test-surface.md` generated catalog + `ui-smoke-runbooks.md`) | `b899d64` |
| Device-state detection | `ios_device.sh device-state` probe (OCR of the Mirroring window; exit code = verdict) wired into preflight/bench/gate/ui-test; on-device `IOSInterruptionRecorder` stamps calls/backgrounding into bench sentinels | `649da0e` |
| Telemetry gaps | P1-2 kvCacheEstimatedPeakMB, P1-4 physFoot timeToPeak, P1-6 notes.memoryPressureBandWorst, P1-7 loud merger drops | `7986c00` |
| P2 bench refresh | Full-matrix Speed CLI bench (idle-machine reference: `benchmarks/baseline-2026-07-02-rescue-p2-speed.md`); HISTORY rows appended | `846721f` |
| Thermal policy | `TTSEngineStore.startThermalObservation` — proactive warm blocked at serious/critical; generation never thermally blocked; `QVOICE_IOS_THERMAL_GATE=off` | `846721f` |
| UI P0/P1 | iOS batch REMOVED (decision) · tab lock RELAXED (decision) · ScrollView + Reduce Motion routing (iOS + macOS live re-read) · player scrubber/transcript VoiceOver ids · dead uiProfile fork removed | `8b78470`, `e396b94` |
| Decisions on record | **1.7B variants only** (0.6B ruled out — Voice Design needs 1.7B) · iOS batch removed · tab lock relaxed · cold launch lands Studio→Custom | `42aa64e`, `8f70f68` |

### Also done: AppModel migration Phases 3b/5/6 (landed in `0df766b` + `411ce84`)

All migration phase comments in `Sources/iOS/App/AppModel.swift` now read
"complete-as-designed" — that is the final architecture, not a TODO:

- **3b:** engine calls deliberately stay in the per-mode views (they need four
  environment-owned stores that predate `AppModel`); shared cancel lives in
  `IOSStudioGenerationActions`.
- **5:** no `presentedSheet` enum (surfaces have different payloads/hosting);
  the real fix was pairing the delete-model sheet with the focus backdrop via
  `AppModel.presentDeleteModelSheet/dismissDeleteModelSheet`. System modals
  (fileImporter/alerts/dialogs) intentionally remain local `@State`.
- **6:** `HistoryScreen`/`SettingsScreen` own their bodies; `IOSLibraryViews.swift`
  and `IOSSettingsContainerView` deleted (the Voices-library branch was dead code —
  live Voices tab is `IOSVoicesView`). All protected identifiers survive verbatim
  (`docs/reference/ui-test-surface.md` regenerated); the only removed ids were the
  dead branch's `savedVoiceMenu_*`/`savedVoiceDeleteConfirm_*`, unreferenced by tests.

Compile-verified (`build_foundation_targets.sh ios` BUILD SUCCEEDED). On-device
`scripts/ios_device.sh test` NOT yet run post-migration — fold into step A1 below.

### Current performance reference (like-for-like lanes — NEVER mix)

| Lane | Headline (custom/speed/warm/medium) | Reference artifact |
| --- | --- | --- |
| CLI `-Onone` in-process | RTF ≈ 1.05 | `benchmarks/baseline-2026-07-02-rescue-p2-speed.md` |
| Local release `-O` CLI | RTF ≈ 1.7 | HISTORY 2026-06-29 rows |
| macOS XPC bench-ui | RTF ≈ 0.9–1.0 + TTFC ≈ 0.9 s warm | `build/macos/bench-ui-*/summary.log` |
| iPhone 17 Pro on-device | RTF 1.6–1.9, physFoot 2.4–3.3 GB, 0 trims | `docs/reference/ios-engine-optimization.md` §6 |

## 2. Remaining work — exact steps

### A. Attended-device items (need the human; do these first when the phone is available)

1. **Green iOS gate.** Phone unlocked, nearby; install **Voice Design (Speed)** on the
   phone (Vocello → Settings → Model Downloads, ~2.3 GB, one-time).
   ```sh
   scripts/ios_device.sh device-state     # expect MIRROR_ACTIVE (exit 0)
   scripts/ios_device.sh gate             # expect GATE: PASS incl. generation step
   ```
   If the XCTest passcode dialog appears on the phone, the human enters it (Apple
   security — cannot be automated; see ios-device-testing.md §"Unattended").
2. **iOS bench + design QC listening pass.** Install **Custom Voice (Speed)** on device.
   ```sh
   scripts/ios_device.sh bench "custom:speed:" --label "post-rescue check"
   scripts/ios_device.sh bench "design:speed:" --label "design QC investigation"
   scripts/ios_device.sh bench "clone:speed:"  --label "post-rescue check"
   ```
   Pull WAVs land under the app's outputs; the design-mode `fail:dropout`/`warn:clicks`
   from `ios-engine-optimization.md` §6 needs EARS: listen to the design takes; if
   dropouts are audible (not just QC-flagged), file the defect with the chunkTimeline
   row (the v5 telemetry localizes the silence window) before touching engine code.
   Append `--ledger` rows to HISTORY for one cell per mode.
3. **mirroir tour** (after any Cursor restart): `~/.mirroir-mcp/settings.json` already
   maps the French window name. Run pilot log §5's tour; update
   `docs/reference/computer-use-mcp-pilot-log.md` §5 with results.

### B. XPC bench-ui merged-row follow-up (desk work, medium)

Symptom (reproduced twice): `scripts/macos_test.sh bench-ui` → engine rows 29/29 but
engine-service 27–28 and app 27 → `check_macos_xpc_bench.py` FAILs. Rows pending
async flush die when the bench's cold takes relaunch the app (audit J1 family).

Fix direction (pick ONE, smallest first):
1. In `VocelloMacUIBase.relaunchForColdTake`/`relaunchForWarmSession`
   (Tests/VocelloMacUITests), wait on the `mainWindow_lastTelemetryFlushed` marker for
   the LAST generationID before `app.terminate()` (the marker exists; bench uses it
   per-take — the gap is the terminate racing the app/service layer writes).
2. If rows still drop: make `GenerationTelemetryJSONLSink` flush synchronously when
   `QWENVOICE_UI_TEST_HOOKS=1`.
Verify: `scripts/macos_test.sh bench-ui --label "j1-fix"` → gate PASS (29/29/29/29).

### C. Release train (Phase 5 — after A is green)

```sh
QWENVOICE_GATE_BENCH=1 scripts/macos_test.sh gate   # PASS required
scripts/ios_device.sh gate                          # PASS required (attended)
scripts/macos_test.sh review && scripts/ios_device.sh review   # diff vs baselines
```
Then follow `docs/reference/macos-release-qa.md` (version bump in `project.yml` →
`regenerate_project.sh` → tag → GitHub release triggers the DMG workflow). iOS
TestFlight lane is optional (`archive-ios` manual dispatch).

## 3. Guardrails (learned the hard way — do not violate)

From the post-mortem (repo-fatal):
- **Never** build simulator/fake-engine test tiers for iOS. On-device only.
- **Never** rewrite agent guides per harness/model. AGENTS.md is the single guide.
- **Never** land multi-hundred-line features without `macos_test.sh gate` /
  `ios_device.sh gate` first. Reverts = planning failure.
- **Never** float `mlx-swift`/`mlx-swift-lm` pins independently or without a
  benchmark-gated throwaway branch.

From this rescue (operational traps that WILL bite again):
- **LaunchServices double-instance trap:** never `tell application "Vocello" to
  activate` / `open -na` while a measured debug session runs — it can spawn a second
  instance WITHOUT debug mode whose takes land in the user's real library.
  `uitest_measure.sh prep/activate/finish` handle this correctly (persisted DebugMode
  flag + PID-based activation + single-instance guard).
- **logd flush lag:** `log show` exposes fresh os_signpost events minutes late. Wait
  on the history.sqlite row (what `bench-wait` does), never poll `log show --last Nm`.
- **`log show --start` rejects fractional seconds** — trim to whole seconds.
- **xcodebuild env:** plain env vars do NOT reach the test runner; use the
  `TEST_RUNNER_` prefix (review lanes do), and expect on-device runners to be unable
  to write Mac paths (use the xcresult-attachment fallback).
- **Engine JSONL auto-prunes oldest-first** — never isolate a run's rows by line
  count; filter by `recordedAt` (gate bench) or the run label.
- **bash 3.2 + `set -u`:** expanding an empty array errors; use
  `${arr[@]+"${arr[@]}"}`.
- **New/deleted Swift files require `./scripts/regenerate_project.sh`** before the
  Xcode build sees them.
- **French macOS localization:** the Mirroring process is "Recopie de l'iPhone" —
  mirroir needs `~/.mirroir-mcp/settings.json` (done on this machine); the device-state
  OCR keyword sets are fr+en (`scripts/lib/ios_device_state.sh`).
- **RTF = audioSeconds/wallSeconds — HIGHER is better.** A drop is the regression.
- **Benches need an idle machine** — a concurrent xcodebuild contaminated a full
  matrix (design/long 0.57 vs 1.11 idle). Check `pgrep -x xcodebuild` first.
- **devicectl `screenIsLocked` does not exist** on Xcode 26.6/iOS 26.5 — the visual
  device-state probe is the authoritative interference signal.

## 4. Where everything lives (quick index)

| Need | Location |
| --- | --- |
| Build/test commands | `AGENTS.md` §8 |
| Testing lanes + gates | `docs/reference/testing-runbook.md`, `macos-testing.md`, `ios-device-testing.md` |
| Deterministic measurement | `scripts/uitest_measure.sh` (header = manual) |
| Device interference probe | `scripts/ios_device.sh device-state`; lib `scripts/lib/ios_device_state.sh` |
| Agent-driven UI smoke procedure | `docs/reference/ui-smoke-runbooks.md` |
| Identifier catalog (generated) | `docs/reference/ui-test-surface.md` (`python3 scripts/generate_ui_test_surface.py`) |
| Bench procedure + like-for-like rules | `docs/reference/benchmarking-procedure.md` §7 |
| Bench baselines | `benchmarks/baselines/*.json` (machine) + `benchmarks/baseline-*.md` (human) |
| iOS engine posture + records | `docs/reference/ios-engine-optimization.md` |
| MCP pilot state | `docs/reference/computer-use-mcp-pilot-log.md` |
