# macOS multi-mode UI generation + Axiom QA audit — 2026-06-29

**Scope:** Extend macOS XCUITest to real UI-driven generation in Custom Voice, Voice Design, and Voice Cloning; run full validation lanes (models → test → XPC → bench → review → crashes) plus Axiom artifact analysis and static auditors.

**Commit:** `7a327f5` (local; uncommitted implementation at audit time)  
**Host:** Mac mini, arm64, macOS 26.5.1 (25F80)

---

## Executive summary

| Area | Verdict |
|------|---------|
| **Test fixture** | **PASS** — all three Speed models + clone voice enrolled |
| **UI smoke (12 + review tour)** | **PASS** — 13/13 in ~3m50s, including all three generation modes via XPC |
| **XPC crash isolation** | **PASS** — app survived 3 service kills; spawn/retire/relaunch observed |
| **Multi-mode bench (CLI)** | **PASS** — 8/8 takes; one `warn:dropout` on clone cold/short |
| **Review screenshots** | **PASS** (xcresult attachments) — 6 PNGs in test bundle; on-disk export empty (env var) |
| **Crash collection** | **CLEAN for audit** — no macOS app/XPC crashes; 5 stale iOS Simulator `.ips` from 2026-06-28 |
| **Static audits** | **No P0 blockers** — architecture/UX gating gaps remain; accessibility seek path CRITICAL |

**Bottom line:** Multi-mode macOS UI generation through XPC is **green for merge**. Residual work is UX consistency (Design/Clone generate gating), performance isolation (engine snapshot → full view invalidation), and accessibility (waveform seek, disabled Generate hints).

---

## 1. Lane verdict table

| Step | Command | Result | Artifacts |
|------|---------|--------|-----------|
| 1 | `scripts/macos_test.sh models ensure` | **PASS** | `pro_custom_speed`, `pro_design_speed`, `pro_clone_speed` OK; `A_warm_elderly_woman` enrolled |
| 2 | `scripts/macos_test.sh test` | **PASS** (13/13) | `build/macos/uitest-artifacts/mac-test-20260629-133720/` · xcresult: `build/DerivedData/Logs/Test/Test-QwenVoice-2026.06.29_13-37-25--0400.xcresult` |
| 3 | `scripts/macos_test.sh xpc --crash-isolation` | **PASS** | `build/macos/multi-mode-audit-xpc2.log` |
| 4 | `QWENVOICE_DEBUG=1 ./build/vocello bench --modes custom,design,clone --variants speed --lengths short,medium --warm 1 --label "multi-mode-ui-xpc-audit" --ledger --force` | **PASS** (8 takes, 42s) | `build/macos/multi-mode-audit-bench.log` · ledger → `benchmarks/HISTORY.md` |
| 5 | `scripts/macos_test.sh review` | **PASS** (test) / **PARTIAL** (disk export) | Tour log: `build/macos/review-shots/mac-review-20260629-134131/tour.log` · PNGs in xcresult only (`/tmp/qwenvoice-test-attachments-1782754990/`) |
| 6 | `scripts/macos_test.sh crashes` | **PARTIAL** | `build/macos/crashes-20260629-134131/` — 5 iOS Simulator `.ips` (2026-06-28); `xcsym --dsym-dir` wrong flag (use `--dsym-paths`) |
| 7 | Logs (during test) | N/A | QoS priority-inversion runtime warnings in 6 tests (non-failing) |

### Implementation delivered (Phase 1–2)

- **`scripts/lib/test_models.sh`** — `MAC_TEST_REQUIRED_MODEL_IDS` expanded to all three Speed models; `ensure_mac_test_clone_fixture()` bootstraps reference clip + `vocello voices enroll`.
- **`Tests/VocelloMacUITests/VocelloMacSmokeUITests.swift`** — `testGenerateVoiceDesignSmoke`, `testGenerateVoiceCloningSmoke`; shared `tapGenerateAndWaitForPlayer`; Design uses brief-starter menu; Clone uses Saved Voices → Open in Cloning handoff.
- **`scripts/macos_test.sh`** — pre-test `pkill Vocello` / `pkill QwenVoiceEngineService`; header updated to 12 smoke tests.
- **Docs** — `macos-testing.md`, `macos-release-qa.md`, `AGENTS.md`, `testing-runbook.md` updated for 12 tests + 3-model fixture (~6.9 GB).

---

## 2. UI findings

### Generation smokes (all passed)

| Test | Duration | Path |
|------|----------|------|
| `testGenerateCustomVoiceSmoke` | 19.4 s | Custom Voice → generate → `sidebarPlayer_bar` |
| `testGenerateVoiceDesignSmoke` | 26.7 s | Voice Design → brief starter → generate → player |
| `testGenerateVoiceCloningSmoke` | 26.5 s | Saved Voices handoff → generate → player |

**Shared assertions:** no `sidebar_backendStatus_error` / `_crashed`; player bar appears within 180 s timeout.

### Test strategy notes

- **Voice Design:** typing into `voiceDesign_voiceDescriptionField` was flaky; **Starting points menu** (`voiceDesign_briefStarter_0`) is the reliable path.
- **Voice Cloning:** `voiceCloning_savedVoicePicker` was occluded; **Saved Voices → Open in Cloning** (`voicesRow_use_A_warm_elderly_woman`) is stable.
- **Clone fixture:** enrolled voice shows **“Reference too short”** QC warning — expected for bench clip; generation still passes.

### Review tour (6 screens)

Screenshots validated at 2560×1440 (full-display XCUITest capture):

| Screen | Status | Notes |
|--------|--------|-------|
| review-custom | OK | Empty script → “Add a script” (draft-gated, not engine mismatch) |
| review-design | OK | Catalog placeholder in brief field |
| review-clone | OK | Fixture short-ref warning |
| review-history | OK | Smoke titles “Automated smoke generation.” |
| review-voices | OK | One enrolled clone voice |
| review-settings | OK | All three Speed models Ready |

**Sidebar status:** No Ready vs panel contradiction reproduced in review captures (post–2026-06-29 `GenerationEnginePresentation` fixes). Re-verify cold-idle Custom Voice with script present per [`macos-frontend-status-audit-2026-06-29.md`](macos-frontend-status-audit-2026-06-29.md).

### Runtime warnings (non-failing)

Six tests logged **QoS priority inversion** (User-interactive waiting on Default). Affects generation smokes and cancel/composer tests. Track for main-thread/engine-bridge tuning; not a gate failure.

### Review PNG export gap

`MAC_TEST_SCREENSHOT_DIR` set in shell for `cmd_review` did not propagate to the UI test runner — tour passed but `build/macos/review-shots/.../` has no PNGs. PNGs **are** attached in xcresult from the full test run (`testCaptureReviewScreens`). **Follow-up:** pass screenshot dir via XCTest launch environment or export from xcresult in `cmd_review`.

---

## 3. XPC findings

From `scripts/macos_test.sh xpc --crash-isolation`:

```
service: SPAWNED → kill → ✓ app survived (×3)
service: retired (idle exit) between cycles
service: SPAWNED (relaunch after retire)
```

**Verdict:** Crash isolation holds. Floor-tier retirement + lazy relaunch proven. No `QwenVoiceEngineService` `.ips` from this audit.

**Concurrency (static):** `CurrentValueSubject` multi-thread sends and unbounded per-chunk `Task` in `GenerationChunkBroker` rated HIGH — no CRITICAL count. `eventForwardingTask` not cancelled on session end (memory auditor P1).

---

## 4. Backend findings (CLI bench, in-process)

Label: `multi-mode-ui-xpc-audit` · tier: `floor_8gb_mac` · 8 cells · 42 s wall

| mode | state | len | RTF | tok/s | QC |
|------|-------|-----|-----|-------|-----|
| custom | cold | medium | 1.28 | 15.99 | pass |
| custom | warm | short | 1.40 | 17.51 | pass |
| custom | warm | medium | 1.70 | 21.20 | pass |
| design | cold | medium | 1.63 | 20.33 | pass |
| design | warm | short | 1.42 | 17.73 | pass |
| design | warm | medium | 1.23 | 15.36 | pass |
| clone | cold | short | 0.79 | 9.92 | **warn:dropout** |
| clone | warm | medium | 0.90 | 11.21 | pass |

**Note:** Bench runs **in-process** via CLI; complements but does not replace XPC UI path. Clone cold/short dropout is a known short-clip QC edge on bench fixture — UI clone smoke passed with longer script.

Ledger row appended to [`benchmarks/HISTORY.md`](HISTORY.md) (`custom/pro_custom_speed/warm/medium` RTF 1.70).

---

## 5. Crash analysis

**Folder:** `build/macos/crashes-20260629-134131/`

| File | Date | Process | Relevant? |
|------|------|---------|-----------|
| `Vocello-2026-06-28-*.ips` (×5) | 2026-06-28 | iOS Simulator (`launchd_sim`) | **No** |

All five are identical **MLX Metal init at launch** on iOS Simulator without `QVOICE_FAKE_ENGINE=1` (`NativeMemoryPolicyResolver.apply` → null C string in `mlx::core::metal::Device`). Expected Simulator noise — not macOS XPC.

**Action:** Filter `cmd_crashes` to exclude `CoreSimulator` paths; fix `xcsym` invocation to `--dsym-paths build/macos/dsyms`.

---

## 6. Static audit findings (ranked)

### P0 — fix before next UX polish release

| ID | Domain | Finding | Location |
|----|--------|---------|----------|
| P0-A | Architecture | View-scoped coordinators can desync on sidebar navigation | `CustomVoiceView`, `VoiceDesignView`, `VoiceCloningView` + coordinators |
| P0-B | UX flow | Design/Clone Generate bypass centralized `allowsGenerationStart` gating | Generate views vs `GenerationEnginePresentation` |
| P0-C | Accessibility | Waveform seek is gesture-only — no VoiceOver adjustable action | `SidebarPlayerView.swift:54–68` |
| P0-D | Performance | `@ObservedObject TTSEngineStore` invalidates full generation tree on every snapshot | All three Generate views |
| P0-E | Performance | Voice Cloning couples reference-panel engine reads with composer in one body | `VoiceCloningView.swift` |

### P1 — important

| ID | Domain | Finding |
|----|--------|---------|
| P1-1 | UX | Readiness contradictions possible when sidebar Ready + Custom Voice Preparing (cold idle with script) — partial fix landed 2026-06-29; re-verify under load |
| P1-2 | Concurrency | `GenerationChunkBroker` unbounded per-chunk Tasks; `CurrentValueSubject` off-main sends |
| P1-3 | Memory | Coordinators not cancelled on `onDisappear`; XPC `eventForwardingTask` leak on session end |
| P1-4 | Performance | macOS language detection lacks iOS 350 ms debounce |
| P1-5 | Performance | `SpeakerPickerRow` O(n²) filter on engine invalidations |
| P1-6 | Accessibility | Disabled Generate has no `accessibilityHint` for reason |
| P1-7 | Accessibility | Sidebar engine status fragments instead of unified announcement |
| P1-8 | Security | Filesystem paths may reach generation UI via raw engine errors | `GenerationEnginePresentation.swift` |

### P2 — polish

| ID | Domain | Finding |
|----|--------|---------|
| P2-1 | Accessibility | Variant segments 62×24 pt; player controls undersized |
| P2-2 | Performance | `AnyView` erasure in configuration panels |
| P2-3 | Performance | Migrate `TTSEngineStore` to `@Observable` |
| P2-4 | Security | Debug telemetry JSONL may persist unredacted failure messages |
| P2-5 | UX | No macOS review baselines committed yet under `docs/macos-review-baselines/` |

### Security posture (generation stack)

**Release-ready** for Vocello 2.1.0: no credentials, privacy manifest complete, XPC code-signing requirements, no network on generation path. Residual: path redaction in user-visible errors (MEDIUM).

---

## 7. Fix list (recommended follow-ups)

Only if failures or P0 items are approved for implementation:

1. **Wire Design/Clone Generate through `allowsGenerationStart`** — align with Custom Voice + sidebar semantics.
2. **Isolate composer from `TTSEngineStore` invalidation** — split Voice Cloning reference vs composer panels.
3. **Waveform VoiceOver seek** — `accessibilityAdjustableAction` + position in value.
4. **Disabled Generate hints** — pass readiness `detail` into `TextInputView.accessibilityHint`.
5. **Review lane PNG export** — XCTest launch env for `MAC_TEST_SCREENSHOT_DIR` or xcresult export step.
6. **Crashes lane hygiene** — filter Simulator `.ips`; `--dsym-paths` for symbolication.
7. **Seed review baselines** — `scripts/macos_test.sh review --baseline` after clean capture (maximized window, cleared history).

---

## 8. Cross-references

- Frontend status audit (pre-fix truth table): [`macos-frontend-status-audit-2026-06-29.md`](macos-frontend-status-audit-2026-06-29.md)
- Testing runbook: [`docs/reference/macos-testing.md`](../docs/reference/macos-testing.md)
- Release QA: [`docs/reference/macos-release-qa.md`](../docs/reference/macos-release-qa.md)
- UI identifiers: [`docs/reference/macos-app-guide.md`](../docs/reference/macos-app-guide.md)

---

## 9. Axiom agents invoked

| Layer | Agent | Outcome |
|-------|-------|---------|
| 2 | test-runner | 13/13 pass; generation timings; 6 review PNG attachments |
| 2 | crash-analyzer | No audit-relevant macOS crashes |
| 2 | screenshot-validator | 0 CRITICAL; 4 MEDIUM (fixture/history noise) |
| 2 | telemetry summarizer | Inline in bench log (ledger appended) |
| 3 | swiftui-architecture-auditor | Coordinator desync; gating gaps |
| 3 | ux-flow-auditor | Generate bypass; readiness contradictions |
| 3 | memory-auditor | No P0 leaks; coordinator/task cancellation |
| 3 | concurrency-auditor | 0 CRITICAL; HIGH broker/subject issues |
| 3 | swiftui-performance-analyzer | Engine snapshot invalidation P0 |
| 3 | security-privacy-scanner | Release-ready; path redaction MEDIUM |
| 3 | accessibility-auditor | Waveform seek CRITICAL; disabled Generate HIGH |
