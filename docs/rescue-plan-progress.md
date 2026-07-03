# Rescue plan — continuation guide

> **Read this first if you are picking up the rescue work.** It is written to be self-contained: current state, exact remaining steps with commands and expected outputs, and the guardrails that previous sessions learned the hard way. Follow it literally; when this doc disagrees with the code, the code wins. Delete this file when Phase 5 (release) ships.
>
> Context: [post-mortem](post-mortem/2026-06-post-fable-development-hell.md) → four
> audits (2026-07-01) → phased remediation. Onboarding: `[AGENTS.md](../AGENTS.md)`.
>
> **HANDOFF (2026-07-02 ~14:20, Fable 5 → Composer 2.5, same thread):** everything
> through `761c1a4` is committed and pushed; the working tree should be clean apart
> from this doc. One background run may still be in flight (§2 Step 1). Start at §2
> and do the steps in order.

## 1. Current state (2026-07-02, `main` + uncommitted J1 closure)

### Session update (Composer 2.5 pickup, 2026-07-02 afternoon)

| Step | Status | Artifact |
| --- | --- | --- |
| 1 macOS J1 verify | **PASS** | `build/macos/bench-ui-xpc-bench-20260702-155134/` → 29/29/29/29 |
| 2 iOS bench-ui shakeout | **BLOCKED** | iPhone `6AE2516C…` state `unavailable` in devicectl — reconnect/unlock |
| 3 iOS full matrix | **BLOCKED** | same |
| 4 design listening | **OWED (human)** | maintainer listens to History design takes on phone |
| 5 macOS gate+review | **PASS** | `gate-mac-gate-20260702-163644`; review captures `mac-review-20260702-164903` (8 PNG diffs — visual pass) |
| 5 iOS gate | **BLOCKED** | needs phone |

**J1 root cause (final):** warm flush timeout (12 s) << long-take generation time after player bar.
Fix: `VocelloMacBenchUITests.telemetryFlushTimeout` + hard XCTFail; inline `await` app JSONL when hooks on.

### Done and verified


| Area                    | What landed                                                                                                                                                                                                        | Key commits          |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------- |
| Visual regression net   | 8 macOS + 7 iOS review-baseline PNGs seeded (`docs/*-review-baselines/`); xcresult-attachment fallback in both review lanes                                                                                        | `6586592`            |
| Measurement shell       | `scripts/uitest_measure.sh` (prep/finish, reset, smoke-check, bench-wait, verify-generation, streaming-preview-check, bench-compare) — validated live end-to-end                            | `6586592`, `b899d64` |
| Bench regression gating | `benchmarks/baselines/mac-gate-bench.json` + `benchmarks/baselines/full-matrix-speed.json`; `QWENVOICE_GATE_BENCH=1 macos_test.sh gate` compares and fails on >5% regression; summarizer RTF direction fixed       | `5b96bbf`, `846721f` |
| Hardened gates          | New crashes during a gate run are gate-fatal (both platforms); iOS gate gained a headless generation step (design:speed — the download test uninstalls pro_custom BY DESIGN)                                       | `5b96bbf`            |
| Agent-driven UI loop    | Peekaboo macOS generate loop verified (see pilot log §4); runbooks regenerated (`ui-test-surface.md` generated catalog + `ui-smoke-runbooks.md`)                                                                   | `b899d64`            |
| Device-state detection  | `ios_device.sh device-state` probe (OCR of the Mirroring window; exit code = verdict) wired into preflight/bench/gate/ui-test; on-device `IOSInterruptionRecorder` stamps calls/backgrounding into bench sentinels | `649da0e`            |
| Telemetry gaps          | P1-2 kvCacheEstimatedPeakMB, P1-4 physFoot timeToPeak, P1-6 notes.memoryPressureBandWorst, P1-7 loud merger drops                                                                                                  | `7986c00`            |
| P2 bench refresh        | Full-matrix Speed CLI bench (idle-machine reference: `benchmarks/baseline-2026-07-02-rescue-p2-speed.md`); HISTORY rows appended                                                                                   | `846721f`            |
| Thermal policy          | `TTSEngineStore.startThermalObservation` — proactive warm blocked at serious/critical; generation never thermally blocked; `QVOICE_IOS_THERMAL_GATE=off`                                                           | `846721f`            |
| UI P0/P1                | iOS batch REMOVED (decision) · tab lock RELAXED (decision) · ScrollView + Reduce Motion routing (iOS + macOS live re-read) · player scrubber/transcript VoiceOver ids · dead uiProfile fork removed                | `8b78470`, `e396b94` |
| Decisions on record     | **1.7B variants only** (0.6B ruled out — Voice Design needs 1.7B) · iOS batch removed · tab lock relaxed · cold launch lands Studio→Custom                                                                         | `42aa64e`, `8f70f68` |


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


| Lane                    | Headline (custom/speed/warm/medium)       | Reference artifact                                  |
| ----------------------- | ----------------------------------------- | --------------------------------------------------- |
| CLI `-Onone` in-process | RTF ≈ 1.05                                | `benchmarks/baseline-2026-07-02-rescue-p2-speed.md` |
| Local release `-O` CLI  | RTF ≈ 1.7                                 | HISTORY 2026-06-29 rows                             |
| macOS XPC bench-ui      | RTF ≈ 0.9–1.0 + TTFC ≈ 0.9 s warm         | `build/macos/bench-ui-*/summary.log`                |
| iPhone 17 Pro on-device | RTF 1.6–1.9, physFoot 2.4–3.3 GB, 0 trims | `docs/reference/ios-engine-optimization.md` §6      |


## 2. NEXT ACTIONS — do these IN ORDER (handout for the continuing model)

> Written 2026-07-02 ~14:20 for the Composer 2.5 handoff. Everything up to commit
> `761c1a4` is pushed. Do the steps below exactly; each has its own verification.
> If a step fails twice the same way, STOP and report — do not improvise new tools.

### Step 1 — J1 verification (macOS, no phone needed)

**Status: VERIFIED PASS (2026-07-02).** Run `j1-verify-timeout-fix` →
`expected=29 engine=29 service=29 app=29 merged=29` + PASS
(`build/macos/bench-ui-xpc-bench-20260702-155134/`).

Root cause was **not** row-loss from async writes alone — the bench driver's
`waitForTelemetryFlush` used a 12 s warm timeout while `tapGenerateAndWaitForPlayer`
returns at first-chunk (player bar). Warm **long** takes (#10 before design cold,
#29 final) were still generating when the soft-failed flush let relaunch/terminate
kill the app before `recordCompleted`. Fix: length-aware flush timeouts (60/120/300 s)
+ hard XCTFail on flush timeout; kept inline `await` app JSONL write when UI-test
hooks are on (`AppGenerationTimeline.recordCompleted` async).

If a future rerun fails the gate, use the triage tree below (do not revert the fixes):

**Historical failure at handoff:** the `j1-verify-round3` run FAILED EARLY (log:
`/tmp/bench-ui-j5.log`, artifacts `build/macos/bench-ui-xpc-bench-20260702-142137/`)
with a NEW signature, not the J1 row loss: take #1 (custom/medium/cold) died at
`VocelloMacUIQuery.clearScriptEditor` (line 111) — app launched fine, sidebar
navigation worked, the editor was clicked, but `textInput_charCount` never appeared
(3 retries) and the test failed at t≈56 s with 0 telemetry rows. Two possibilities:

- **Flake/environment** (a stray `sysmond service not found` appeared; earlier same-day
  runs passed this step twice). → Rerun once:
  `scripts/macos_test.sh bench-ui --label "j1-verify-round3b"` (idle machine first:
  `pgrep -x xcodebuild`).
- **Regression from `761c1a4`** (it touched `Sources/ContentView.swift` marker block +
  made `MacUITestSurfaceMarkers` an `@Observable` class). If the rerun fails the same
  way: run `scripts/macos_test.sh test` (smoke) — if smoke also fails around the
  composer, inspect the ContentView `HiddenWindowMarkers` change first; `git revert`
  of the ContentView/MacUITestSurfaceMarkers hunks is acceptable ONLY as a last resort
  (it reintroduces frozen markers — J1 round 2 — so prefer a forward fix).

When a rerun completes normally, judge the gate line:

- `expected=29 engine=29 service=29 app=29 merged=29` + PASS → J1 is CLOSED. Update
  this doc (§3b round-3 entry → "verified PASS <date>"), commit, push. Done.
- Rows still missing → find which takes lost rows:

```sh
cd "$HOME/Library/Application Support/QwenVoice-Debug/diagnostics" && python3 - <<'EOF'
import json
def ids(p):
    out = {}
    for line in open(p):
        try:
            r = json.loads(line); out[r["generationID"]] = r.get("recordedAt", "")
        except Exception: pass
    return out
eng = ids("engine/generations.jsonl"); svc = ids("engine-service/generations.jsonl"); app = ids("app/generations.jsonl")
for i, (g, t) in enumerate(sorted(eng.items(), key=lambda kv: kv[1]), 1):
    f = ("" if g in svc else " NO-SVC") + ("" if g in app else " NO-APP")
    if f: print(f"take#{i} {t} {g}{f}")
EOF
```

  Then apply the NEXT lever, already scoped: make
  `GenerationTelemetryJSONLSink.write` synchronous (await, not detached) when
  `QWENVOICE_UI_TEST_HOOKS=1` — touch ONLY the write scheduling, re-run the same
  bench-ui command, expect 29/29/29/29. All prior J1 fixes are described in §3b; do
  not revert them.

### Step 2 — iOS bench-ui shakeout (needs the phone: mirror ACTIVE, unlocked)

Preconditions and full procedure: `docs/reference/testing-runbook.md` §3b (iOS).
Quick loop:

```sh
scripts/ios_device.sh device-state          # must print MIRROR_ACTIVE / exit 0
scripts/ios_device.sh bench-ui --modes custom --lengths short --warm 1 --label shakeout
```

- PASS (gate prints per-cell row + PASS) → lane works; go to Step 3.
- Install error `CoreDeviceError 3002` / `Connection interrupted` → phone
  locked/unreachable; ask the user to unlock + keep the mirror active, retry ONCE.
- A take times out → grep the log for `iosStudio_generationError`; model missing →
  reinstall Custom Voice on the phone (a `gate` run uninstalls it — known behavior).

### Step 3 — Full iOS UI-driven matrix (phone, ~40 min, thermal-sensitive)

```sh
scripts/ios_device.sh bench-ui --label "ios-ui-bench-baseline"
```

Clone cells auto-skip unless a saved voice is enrolled ON the phone (mic does not
work through Mirroring — ask the user to enroll one via Voices → Save a new voice).
On PASS: append one HISTORY.md row per mode cell (medium/warm) with the label, and
record the run dir in this doc. Numbers should match §1b (RTF 1.6–1.9, 0 trims);
>5% RTF drop vs those references = investigate before committing anything.

### Step 4 — Design-mode listening pass (HUMAN ears; cannot be automated)

Takes live in the app's History on the phone. Ask the user to listen to the design
takes for dropouts/clicks. If audible: file the defect with the chunkTimeline row
(v5 telemetry localizes the silence window) BEFORE touching engine code.

### Step 5 — Release train (Phase 5; only after Steps 1–4 are green)

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

- **LaunchServices double-instance trap:** never `tell application "Vocello" to activate` / `open -na` while a measured debug session runs — it can spawn a second
instance WITHOUT debug mode whose takes land in the user's real library.
`uitest_measure.sh prep/activate/finish` handle this correctly (persisted DebugMode
flag + PID-based activation + single-instance guard).
- **logd flush lag:** `log show` exposes fresh os_signpost events minutes late. Wait
on the history.sqlite row (what `bench-wait` does), never poll `log show --last Nm`.
- `log show --start` **rejects fractional seconds** — trim to whole seconds.
- **xcodebuild env:** plain env vars do NOT reach the test runner; use the
`TEST_RUNNER_` prefix (review lanes do), and expect on-device runners to be unable
to write Mac paths (use the xcresult-attachment fallback).
- **Engine JSONL auto-prunes oldest-first** — never isolate a run's rows by line
count; filter by `recordedAt` (gate bench) or the run label.
- **bash 3.2 +** `set -u`**:** expanding an empty array errors; use
`${arr[@]+"${arr[@]}"}`.
- **New/deleted Swift files require** `./scripts/regenerate_project.sh` before the
Xcode build sees them.
- **French macOS localization:** the Mirroring process is "Recopie de l'iPhone" —
mirroir needs `~/.mirroir-mcp/settings.json` (done on this machine); the device-state
OCR keyword sets are fr+en (`scripts/lib/ios_device_state.sh`).
- **RTF = audioSeconds/wallSeconds — HIGHER is better.** A drop is the regression.
- **Benches need an idle machine** — a concurrent xcodebuild contaminated a full
matrix (design/long 0.57 vs 1.11 idle). Check `pgrep -x xcodebuild` first.
- **devicectl** `screenIsLocked` **does not exist** on Xcode 26.6/iOS 26.5 — the visual
device-state probe is the authoritative interference signal.
- **iOS model downloads are SERIAL (concurrent disabled — maintainer, 2026-07-02):**
tapping Install on a second model while one downloads queues it; it starts after the
first completes. Not a stuck download. The maintainer rates the iOS download process
"in poor shape" — treat download-UX polish as a backlog item; do not enable
concurrency as a quick fix.
- **Driving the mirrored phone from the Mac (attended installs):** peekaboo `see`
cannot map elements inside the Mirroring window (video stream, no AX tree). See via
`screencapture -x -o -l $(swift scripts/lib/mirror_state_ocr.swift window-id)`, then
peekaboo `click` with screen coords (window origin/size from peekaboo `see PID:<mirroring-pid>`; screenshot px = 2× window points). Focus the app first
(`app focus`); a paused mirror shows "Connexion en pause" — click Reprendre to resume.
- **The iPhone MICROPHONE is unavailable through iPhone Mirroring** ("Le micro de
l'iPhone n'est pas disponible à partir du Mac", verified 2026-07-02). Voice
recording/enrollment is NOT broken in the app — it works when operated directly on the
phone (maintainer-confirmed same day). Never triage recording as an app defect from a
mirror session, and never drive record/enroll flows via the mirror; that step is
attended, on the physical phone.

## 3b. Active work (2026-07-02 afternoon)

- **iOS gate: PASS** (all 4 steps; all three Speed models installed on the phone).
  iOS single-take benches green: custom RTF 1.89 / design 1.99 / clone 1.68, physFoot
  2.4–3.2 GB, 0 trims, QC pass. Design dropout did NOT reproduce; the perceptual
  listening pass on the History takes is still owed by the maintainer.
- **"Recording broken" report RESOLVED — not an app defect.** The mic is unavailable
  through iPhone Mirroring (see guardrail above); works on the physical phone.
- **iOS UI-driven bench (`ios_device.sh bench-ui`) — NEW, shakeout in progress.**
  Parts: `VocelloiOSBenchUITests` (matrix driver; corpus must stay identical to
  `BenchMatrixSpec.corpus`), `IOSStudioBenchHooks` (env-gated markers + hidden
  clear-script button), driver verb in `ios_device.sh`, gate
  `scripts/check_ios_ui_bench.py` (expected count comes from the test's
  `VOCELLO-BENCH-UI-MANIFEST ran=N` line — clone cells skip without a saved voice).
  Shakeout command: `scripts/ios_device.sh bench-ui --modes custom --lengths short
  --warm 1 --label shakeout`. If takes fail: check the marker ids exist (hooks env),
  the keyboard-dismiss `\n` step, and `textInput_generateButton` hittability.
- **macOS XPC bench-ui J1 — CLOSED (2026-07-02).** Root cause: 12 s warm flush
  timeout vs long takes still generating after player bar; fix in
  `VocelloMacBenchUITests.telemetryFlushTimeout` + hard fail on flush timeout;
  inline `await` app JSONL write when hooks on. Verified:
  `bench-ui-xpc-bench-20260702-155134` → 29/29/29/29 PASS.

## 4. Where everything lives (quick index)


| Need                                  | Location                                                                            |
| ------------------------------------- | ----------------------------------------------------------------------------------- |
| Build/test commands                   | `AGENTS.md` §8                                                                      |
| Testing lanes + gates                 | `docs/reference/testing-runbook.md`, `macos-testing.md`, `ios-device-testing.md`    |
| Deterministic measurement             | `scripts/uitest_measure.sh` (header = manual)                                       |
| Device interference probe             | `scripts/ios_device.sh device-state`; lib `scripts/lib/ios_device_state.sh`         |
| Agent-driven UI smoke procedure       | `docs/reference/ui-smoke-runbooks.md`                                               |
| Identifier catalog (generated)        | `docs/reference/ui-test-surface.md` (`python3 scripts/generate_ui_test_surface.py`) |
| Bench procedure + like-for-like rules | `docs/reference/benchmarking-procedure.md` §7                                       |
| Bench baselines                       | `benchmarks/baselines/*.json` (machine) + `benchmarks/baseline-*.md` (human)        |
| iOS engine posture + records          | `docs/reference/ios-engine-optimization.md`                                         |
| MCP pilot state                       | `docs/reference/computer-use-mcp-pilot-log.md`                                      |


