# Vocello development progress and Codex resume checkpoint

> **Active maintainer checkpoint — 2026-07-10.** Read this after
> [`AGENTS.md`](../AGENTS.md) and before resuming the current cross-platform QA work.
> This is a development checkpoint, **not** a release-readiness declaration.

## Checkpoint identity

| Field | Value |
| --- | --- |
| Branch | `main`, tracking `origin/main` |
| Starting base | `d79044387c655f634cd966fd0b1b74d96dbf7bbf` |
| Resume commit | Pending: the transition is still an intentionally preserved dirty working tree on `main` |
| Active objective | Complete the Codex-only transition with deterministic development publishing and platform-specific release UI gates |
| Release status | **Not ready** — each platform still needs its own fresh release evidence before that platform ships |

The current working tree contains the transition implementation, tests, harness, contracts,
guidance, and this tracker. It is not yet a checkpoint commit. Preserve and review the dirty tree;
do not reset it to `origin/main` or claim that a clean checkout contains this work until it is
intentionally committed.

## Current status

| Workstream | Status | Durable source / evidence |
| --- | --- | --- |
| macOS frontend driver | **Implemented** | `$vocello-macos-ui-qa`; no macOS XCUITest target or hidden UI-test surface |
| iOS frontend driver | **Implemented and live-verified** | `$vocello-ios-ui-qa`; bundled Computer Use drove the paired physical phone through iPhone Mirroring from Settings to Studio |
| Retired development tooling | **Removed** | No legacy IDE configuration tree, alternate desktop-control MCP, device OCR bridge, coordinate bridge, or XCTest UI target remains active |
| Bundled Computer Use consolidation | **ROUTING VERIFIED; HELPER KNOWN-BAD** | After reinstall and restart, the fresh task exposes plugin `1.0.1000366`, its skill and wrapper, and the active Node REPL transport. The disabled manifest-shaped Computer Use entry is an inert plugin mirror, not a missing server; enabling it would create a competing route. One canonical Desktop-managed helper remained at PID `63045`, with no plugin-cache fallback, duplicate, unknown path, stale client, or zombie. Helper `26.708.1000366 (1000366)`, UUID `61C0…9236`, remains blocked after four identical historical accessibility bounds traps. See the [failure analysis](reference/computer-use-failure-analysis.md). |
| Scenario and impact contracts | **Implemented** | Schema v2 in `config/macos-ui-scenarios.json` and `config/macos-test-impact.json` |
| Independent attestations | **Implemented** | Schema v2 `quick`, `full`, and `benchmark` entries in `qa/macos-ui-attestation.json` |
| Typed XPC and backend probes | **Implemented and tested** | Core, XPC integration, probe validator, and Qwen3 runtime test targets |
| Corrected-report risk spine | **Implemented for the tracked first tranche** | `config/backend-risk-spine.json`; every implemented item resolves to executable tests |
| Telemetry overhead/parity | **PREVIOUS PASS; CURRENT EVIDENCE STALE** | The prior seeded PCM/threshold run passed, but current source/build fingerprints changed. The command now refuses generation until a current full Computer Use attestation proves visible Settings model readiness, and uses read-only model integrity rather than automatic `models ensure`. No take began during the guarded release-readiness verification. |
| macOS deterministic lane | **PASS** | Native bundle build plus Core, XPC transport, seeded owned Qwen3 runtime, and harness contracts on 2026-07-10 |
| Exact macOS app build | **PASS** | `./scripts/build.sh build`; current signed bundle is `build/Vocello.app` |
| Harness regressions | **PASS** | 25 routing tests plus 36 macOS harness tests on 2026-07-10 |
| Project-input/document drift | **PASS** | `./scripts/check_project_inputs.sh` on 2026-07-10 |
| iOS shared compile safety | **PASS** | `./scripts/build_foundation_targets.sh ios` with the physical-device SDK on 2026-07-10 |
| Development publishing policy | **IMPLEMENTED; CI RUN PENDING** | Commits, pushes, pull requests, ordinary merges, and ordinary CI use deterministic checks only. macOS/iOS impact reports are advisory; missing Computer Use, models, device, or attestations do not block preserving or sharing this work. |
| macOS duplicate-app isolation | **RULED OUT AS REQUIRED CAUSE** | After restart, Finder capture passed. Both non-target Vocello bundles were then physically quarantined, leaving `build/Vocello.app` as the only physical target; Computer Use retained three cached inventory entries, and the first exact-path observation still crashed the Desktop-managed helper. The apps were restored afterward. Registration duplicates remain diagnostic; duplicate/wrong-path running processes remain fatal. |
| Bounded warm History diagnostic | **PASS; NON-ATTESTABLE** | On 2026-07-10, Finder returned accessibility text and a screenshot, then one exact-path observation of debug-pinned History returned a complete 1,815-character accessibility tree and screenshot. The helper stayed on canonical PID `63045`, the sole Vocello PID stayed `81259`, no `.ips` delta appeared, the one-observation budget was consumed, capture returned to Finder, and cleanup left zero Vocello processes. This isolates a stable warm History surface; it does not validate Settings or unblock suites. [Upstream differential](https://github.com/openai/codex/issues/32293#issuecomment-4941236462). |
| iOS Computer Use doctor | **NORMAL SUITES BLOCKED** | iOS uses the same known-bad helper. At most one explicitly requested passive iPhone Mirroring observation is allowed after live plugin/routing/crash checks; no navigation, generation, benchmark, or attestation resumes until the [shared resumption criteria](reference/computer-use-failure-analysis.md#remediation-and-resumption) pass. |
| GitHub checkpoint run | **Previous policy failure; replacement run pending** | The previous run passed deterministic macOS tests, exact-path app build, and iOS device-SDK compile, then failed only because ordinary CI required stale UI evidence. Ordinary CI no longer validates attestations; the next run should report impact only. |
| Computer Use full suites | **Blocked by helper crash; development unaffected** | Do not begin macOS `quick`, `full`, destructive, or generation work—or iOS `quick`, `full`, or generation work—with helper build `1000366`. This blocks frontend/release evidence, not deterministic CI or Git publishing. The controlled reproduction is [openai/codex#32293](https://github.com/openai/codex/issues/32293); the [bounds-trap comment](https://github.com/openai/codex/issues/32293#issuecomment-4940886542) contains the normalized stack, `x21=5` / `x8=4`, and accessibility-thread correlation. |
| Computer Use benchmarks | **Blocked** | The independent macOS and iOS `benchmark` reports remain release requirements, but routing and target-capture stability are hard prerequisites. |
| Destructive suite | **Implemented, not executed** | Static authorization and disposable-root safeguards only; attended opt-in required |
| Broader corrected-report matrix | **Deferred** | Explicit `deferredMatrix` in `config/backend-risk-spine.json` |

Development publishing never requires a Computer Use suite. For release, macOS requires independent
macOS `full` and `benchmark` suites plus `telemetry-overhead`; iOS archive/TestFlight requires its
independent iOS release evidence. Impact classification is advisory until explicit acceptance, and
one platform's frontend evidence cannot satisfy or block the other platform's artifact.

## Resume after a Codex cleanup or reinstall

### 1. Restore repository truth

Do not copy an old working tree over the checkpoint and do not run destructive Git cleanup.

```sh
git switch main
git fetch origin
git pull --ff-only
git status --short --branch
git rev-parse HEAD
```

Expected after this transition is intentionally committed: `main` tracks `origin/main`, the
worktree is clean, and the reported commit contains this document. Until then, preserve the dirty
tree and compare its base before any fetch/pull operation. Installed models and saved voices are
not reconstructed from Git.

### 2. Restore Codex capabilities

1. Install and enable the bundled **Computer Use** plugin in Codex. Treat marketplace availability,
   installation, enablement, server/skill availability in a new task, and the live helper process as
   separate states; a running service does not prove the task has callable Computer Use tools.
2. Do **not** manually add a second Computer Use transport. For the current plugin's
   `bundledContentVariant=node-repl`, the enabled Node REPL entry is the active server and the
   disabled manifest-matched Computer Use entry is an expected inert mirror. Enabling that mirror,
   or adding a stale command, older path, or conflicting transport, is invalid.
3. Start a **new Codex task** after installing or enabling the plugin so its skills and tools are
   loaded into the task.
4. In macOS System Settings → Privacy & Security, allow Codex Computer Use under Accessibility and
   Screen & System Audio Recording when prompted. Permission enrollment and system dialogs are
   attended setup, not autonomous test steps.
5. Treat `~/.codex/config.toml`, plugin enablement, and macOS privacy grants as user-scoped state.
   They are not repository guidance and must not be copied into tracked files.

Repository guidance follows OpenAI's durable customization split: conventions in
[`AGENTS.md`](https://developers.openai.com/codex/concepts/customization#agents-guidance), the
repeatable frontend workflow in the repository
[`skill`](https://developers.openai.com/codex/concepts/customization#skills), and live desktop
control through the installed plugin/MCP capability rather than prose-only claims.

### 3. Re-enter frontend acceptance when needed

Skip this Computer Use bootstrap for deterministic development, Git operations, and ordinary CI.
Use it only for explicitly requested frontend acceptance or preparation of the matching platform
release.

Read, in order:

1. [`AGENTS.md`](../AGENTS.md)
2. this tracker
3. the applicable [role playbook](../.agents/)
4. [`project-map.html`](project-map.html)
5. [`reference/macos-testing.md`](reference/macos-testing.md) for this active workstream

Then verify the local harness without changing application state:

```sh
scripts/macos_agent_ui.sh impact
scripts/macos_agent_ui.sh doctor --suite full --json
scripts/macos_agent_ui.sh doctor --suite benchmark --json
```

Both doctor calls must report `repositoryReady`, `appReady`, `appRegistrationReady`,
`computerUseServiceRunning`, `computerUseServicePathVerified`, and `readyForSession` as true.
`vocelloLaunchServicesRegistrations` must include the exact `build/Vocello.app`; other records are
diagnostic and must never be targeted by name or bundle ID. The first
scenario then records live exact-path accessibility and screenshot proof. If Computer Use is
unavailable, preserve diagnostics and fix plugin/runtime health; never weaken the gate or retry
after a new helper crash.

These checks describe the normal route but do not override the active helper block. Build `1000366`
may run only the one-observation diagnostic in
[`reference/computer-use-failure-analysis.md`](reference/computer-use-failure-analysis.md). A
passing doctor or Finder capture is not permission to start a suite.

## Remaining release-acceptance work — run in order

The tracked implementation is deterministic-test clean and may be committed, pushed, reviewed, and
merged without frontend evidence. Frontend execution—and therefore the matching platform's release
acceptance—is blocked by the known helper accessibility crash. Duplicate Launch Services records
remain diagnostic and are not a required cause. Resolve the helper prerequisite before semantic
evidence so fingerprints describe the exact checkout being accepted.

1. The one permitted warm History observation passed without a new crash. Do not repeat it in the
   same helper session or treat it as suite evidence. Preserve the existing crash evidence and
   keep frontend suites blocked until a different signed helper or a validated app-side workaround
   passes the [resumption protocol](reference/computer-use-failure-analysis.md#remediation-and-resumption).
   Helper `1000366` is diagnostic-only: one observation, no retry, interaction, or generation.

2. Require `build/Vocello.app` to be present in the Launch Services diagnostics and require
   `appRegistrationReady: true`. Other registered copies are diagnostic only. Always target the
   absolute build path and require a sole exact-path running process before and after capture.

3. Confirm the machine is idle. Once Computer Use is unblocked, inspect Settings and Saved Voices
   before any generation: Custom, Design, and Clone Speed must visibly show installed/ready,
   Generate must be enabled, and the benchmark clone voice must be visible. If not, stop the run,
   invoke `scripts/macos_test.sh models ensure` only as explicit repair/bootstrap, then start a fresh
   run and repeat the visual readiness check.

4. Confirm or rebuild the exact app Computer Use will drive. The checkpoint was built
   successfully, but a fresh checkout or cleaned `build/` directory needs this step again:

   ```sh
   ./scripts/build.sh build
   test -d build/Vocello.app
   ```

5. Before the full suite, repeat Finder and exact-path Vocello observations twice and after an idle
   interval. Abort on any helper crash. Do not use helper build `1000366` for this acceptance
   sequence unless a documented app-side workaround has already passed the complete resumption
   protocol. If stable, invoke `$vocello-macos-ui-qa full`. It must
   complete within 40 minutes, restore preferences and saved voices, exercise XPC kill/recovery,
   and finish with matching History, WAV, and typed-probe evidence.

6. Validate and attest the full report:

   ```sh
   scripts/macos_test.sh ui-report --suite full
   scripts/macos_test.sh review
   ```

7. Invoke `$vocello-macos-ui-qa benchmark`. Computer Use must drive the ordered 29-take
   Custom/Design/Clone × length × cold/warm matrix; the shell harness owns timestamps,
   deterministic verification, and aggregation.

8. Validate and attest the benchmark report:

   ```sh
   scripts/macos_test.sh ui-report --suite benchmark
   scripts/macos_test.sh bench-ui
   ```

9. Run final deterministic checks, then only the gate for the platform being accepted:

   ```sh
   ./scripts/check_project_inputs.sh
   scripts/macos_test.sh test
   scripts/macos_test.sh crashes
   ./scripts/build_foundation_targets.sh ios

   # macOS frontend/release acceptance:
   scripts/macos_test.sh gate
   scripts/macos_test.sh release-readiness

   # iOS frontend/archive-TestFlight acceptance (independent of macOS):
   scripts/ios_device.sh gate
   scripts/ios_agent_ui.sh release-check
   ```

Acceptance requires fresh matching source/build/toolchain fingerprints, successful cleanup, no
blocker or major findings, a passing probe verdict, and no new crash report. A local app SHA is
checked against the exact executable Computer Use drove; CI rebuilds independently and does not
compare its differently signed binary byte-for-byte with the local app.

## Safety and scope boundaries

- **macOS frontend:** bundled Computer Use only. Static accessibility-catalog validation remains
  allowed; no competing frontend driver is supported.
- **iOS frontend:** bundled Computer Use drives the paired physical iPhone through iPhone
  Mirroring. Never use Simulator, an XCTest UI runner, or another UI-driving MCP.
- **Destructive macOS suite:** never starts implicitly. It needs `--allow-destructive`, a disposable
  app-support root, and action-time confirmation for deletion, repair, download, file upload, or
  permission-sensitive UI actions.
- **Evidence:** raw screenshots, telemetry, WAVs, databases, and reports stay ignored under
  `build/macos/agent-ui/`. Only the compact non-sensitive attestation is tracked.
- **Privacy:** probes record lengths, enums, bounded metrics, and stable digests—not scripts,
  transcripts, imported paths, or voice descriptions.
- **Research evidence:** preserve `QwenVoice_MLXAudio_Corrected_Report_Series_2026-07-10/`
  unchanged. Automation consumes the compact risk spine instead of parsing prose reports.

## Completion definition

This checkpoint can be committed, pushed, reviewed, and merged once deterministic verification is
green. A macOS release candidate additionally needs fresh macOS `full` and `benchmark` evidence,
the runtime check, `review`, `bench-ui`, and `release-readiness`. An iOS archive/TestFlight candidate
independently needs fresh iOS evidence and `ios_agent_ui.sh release-check`. Until the applicable
release lane passes, retain the **Not ready** status for that platform.
