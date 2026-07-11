---
name: vocello-macos-ui-qa
description: Run explicit macOS frontend or release acceptance for Vocello through Codex Computer Use, with deterministic history, WAV, XPC transport, backend telemetry, report, and attestation checks. Use when the user requests macOS UI journeys, semantic visual/accessibility review, XPC UI recovery, UI-driven generation benchmarks, or macOS release acceptance. Impact output is advisory during ordinary development and does not trigger this skill by itself.
---

# Vocello macOS UI QA

Drive the frontend only through the installed `computer-use` skill. Use
`scripts/macos_agent_ui.sh` for lifecycle and truth below the UI.

## Active helper block

Do not invoke `quick`, `full`, `benchmark`, or `destructive` with Computer Use helper
`26.708.1000366 (1000366)`, UUID `61C0…9236`. Four controlled Vocello captures produced the same
accessibility bounds trap. A passing doctor, live service, or Finder capture does not clear this
normal-suite block. Read
[`docs/reference/computer-use-failure-analysis.md`](../../../docs/reference/computer-use-failure-analysis.md)
and the [upstream differential](https://github.com/openai/codex/issues/32293#issuecomment-4940886542).

That helper may be used only for one explicitly requested diagnostic observation:

1. Confirm the plugin is installed and enabled, then start a fresh task and require its Computer
   Use server and skill to be available.
2. Record the helper version/UUID/hash, sole supported runtime process, and crash-report baseline.
3. Capture Finder once.
4. Run `scripts/macos_agent_ui.sh warm-diagnostic --phase prepare --initial-screen history
   --acknowledge-known-bad-helper`. It refuses a pre-existing app and launches only the exact path.
5. Require one stable window, then observe the exact path once.
6. While the returned screenshot file still exists, record only its hash/size and the non-sensitive
   AX/window counts with `warm-diagnostic --phase record-observation`; never store the AX text or
   temporary screenshot path.
7. Run `scripts/macos_agent_ui.sh warm-diagnostic --phase verify` once. Stop after the response or
   native-pipe closure. Do not retry, interact, relaunch, call a display name or bundle ID, start a
   harness run, generate, or attest.
8. Target Finder, then run `scripts/macos_agent_ui.sh warm-diagnostic --phase abort`. Require
   separate passing `verificationVerdict` and `cleanupVerdict`; cleanup never erases a failure.

Normal suites remain blocked until the failure analysis' complete resumption protocol passes and
that document is updated. The remaining sections describe the normal workflow after unblocking.

## Select the suite

Do not invoke this skill merely to commit, push, open a pull request, or satisfy ordinary CI.
During development, `impact` reports later frontend scope only. Use the selected suites when
frontend acceptance is explicitly requested or before a macOS release.

- Use `quick` for ordinary macOS view, copy, or layout changes.
- Use `full` for generation coordination, playback, persistence, XPC,
  accessibility, models, the QA harness, or release work.
- Use `benchmark` for the UI-driven generation matrix.
- Use `destructive` only when explicitly requested. Pass
  `--allow-destructive` and still obtain action-time confirmations required by
  the Computer Use policy.

Inspect the requirement when uncertain:

```sh
scripts/macos_agent_ui.sh impact
```

Read both `requiredSuites` and `requiredRuntimeChecks`. Requirements are sets:

- `quick` is satisfied by a current quick or full entry.
- `full` requires an actual full entry.
- `benchmark` requires an actual benchmark entry and never substitutes for full.
- Mixed changes require every listed suite. Run each independently against the
  same final source, build-input, and toolchain fingerprints.

## Start safely

1. Read `config/macos-ui-scenarios.json` completely.
2. Verify the bundled plugin is installed and enabled and start a new Codex task. Confirm the task
   exposes both its Computer Use server and skill. These states are separate from a live helper
   process. Then read the installed OpenAI `computer-use` skill completely and derive the plugin
   root from that skill's current absolute path; never hardcode a cache version.
3. In the installed Node REPL, load the plugin-owned `scripts/computer-use-client.mjs` wrapper as
   instructed by the installed skill. Confirm the expected `sky` API, then call
   `sky.list_apps()`.
   When the plugin manifest declares `bundledContentVariant=node-repl`, the enabled Node REPL is
   the active server and a disabled manifest-shaped Computer Use entry is an inert plugin mirror.
   Never enable that mirror; the routing audit treats it as a conflicting second transport.
   The plugin-cache app is the installed source. For ChatGPT Desktop `26.707.41301`, the observed
   desktop-managed runtime copy is `~/.codex/computer-use/Codex Computer Use.app`. After bootstrap,
   the routing audit requires the app-bundled source, installed plugin source, and runtime copy to
   have matching identifiers, versions, signatures, requirements, and executable hashes, and
   requires the sole live service to use the build-scoped expected path. A live plugin-cache helper
   is a session-fatal fallback route, but is not by itself declared the native crash's root cause.
   macOS may show a separate **bypass the system private window picker** consent even when
   **Privacy & Security > Screen & System Audio Recording > Codex Computer Use** is already on.
   Treat each newly launched Computer Use helper as an attended authorization checkpoint:
   ask the user to click **Allow/Autoriser**, then retry from one fresh Node REPL session. Do not
   toggle the persistent Screen Recording permission, repeatedly restart the helper, or loop on
   `get_app_state` while the consent is outstanding. If the same consent immediately recurs after
   approval, stop the suite as a plugin/macOS capability failure and record the service version;
   repeated retries only reproduce the prompt.
4. Run `scripts/build.sh build` if `build/Vocello.app` is stale or absent.
5. Run `scripts/macos_agent_ui.sh routing-audit`, then
   `scripts/macos_agent_ui.sh doctor --suite <suite> --json`. Continue only when the audit passes
   and `repositoryReady`, `appReady`, `appRegistrationReady`, `computerUseServiceRunning`,
   `computerUseServicePathVerified`, and `readyForSession` are true.
   `vocelloLaunchServicesRegistrations` must include the exact `build/Vocello.app`. Duplicate
   registrations remain diagnostic because Computer Use retains them even after physical isolation;
   never select by display name or bundle identifier. Duplicate or wrong-path *running processes*
   remain session-fatal. Never unregister or delete an installed app or build product automatically.
6. Call `sky.get_app_state({ app: "Finder" })` to move any active capture away from Vocello, then
   run `scripts/macos_agent_ui.sh start --suite <suite>`. Retain its `runID`, `runDirectory`, and
   exact `appPath`.
7. Call `sky.get_app_state()` with the exact absolute app path and require non-empty accessibility
   text plus a screenshot URL. Record this live observation in the run's first scenario. If the
   bundled service closes its native pipe, stop the suite, record every running `Vocello`
   executable path, and clean up. Do not retry by display name or bundle identifier: Launch
   Services may resolve either selector to another registered build and open a second app instance.
8. Use the exact absolute `build/Vocello.app` path for every later Computer Use call. Before each
   scenario and after every cold relaunch, require exactly one running `Vocello` process and require
   its executable to be `build/Vocello.app/Contents/MacOS/Vocello`.

Every checkpoint and deterministic verification rechecks the desktop-managed helper and the run's
`SkyComputerUseService` crash-report delta. Stop after either failure; do not relaunch Vocello or
retry through another selector.

Before any harness action that terminates or cold-relaunches Vocello, first call
`sky.get_app_state({ app: "Finder" })`. This moves Computer Use's active capture away from the
Vocello window so window teardown does not invalidate the native pipe. Apply the same rule before
`start`, cleanup, and each cold `benchmark-take --phase begin`. After relaunch, verify the sole
exact-path process before targeting Vocello again.

Stop before scenario execution if bootstrap, application discovery, accessibility text, screenshot
capture, exact-path identity, or service-path verification fails. A doctor result based only on
repository contracts is never sufficient.

Before the first generation, open Settings and complete the required `model-readiness` scenario.
Custom, Design, and Clone Speed must visibly report installed/ready, Generate must be enabled, and
a saved clone voice must be visible. `scripts/macos_test.sh models ensure` is repair/bootstrap only;
normal suites never download or silently repair models. A prior take, filesystem inventory, or
headless check cannot replace the visible observation. If readiness fails, stop the run, repair
outside it, then begin a fresh run and inspect the visible states again before generating.

If the run is interrupted, call `scripts/macos_agent_ui.sh cleanup` before any
new start.

Non-destructive runs snapshot debug preferences and saved voices; `finish` and
`cleanup` restore both. A destructive run must use `--allow-destructive`; the
harness creates a disposable `QWENVOICE_APP_SUPPORT_DIR` beneath the run
directory and refuses production, debug-shared, or symlinked model/voice roots.
Never execute destructive scenarios without the user's explicit request and
the action-time Computer Use confirmations.

## Drive each scenario

For every logical action:

1. Call `get_app_state` using the exact app selector established during bootstrap.
2. Find the target by current accessibility identifier and derive a fresh
   `element_index`.
3. Perform one logical action.
4. Call `get_app_state` again and verify the expected semantic state.
5. Never reuse an element index obtained before the latest observation.

Prefer accessibility-element actions. Use screenshot or coordinate fallback
only when the accessibility tree cannot expose the control, then record a minor
automation issue:

```sh
scripts/macos_agent_ui.sh issue --scenario <id> --severity minor \
  --category automation --summary "Coordinate fallback" \
  --expected "Accessible target" --actual "Target absent from AX tree"
```

Record scenario progress with `checkpoint`. Continue independent scenarios after
minor or note findings. Stop dependent work after blocker or major findings. Stop
the run after an environment-wide blocker.

For the benchmark suite, obtain the harness-owned take definitions and run them
in order:

```sh
scripts/macos_agent_ui.sh benchmark-manifest
scripts/macos_agent_ui.sh benchmark-take --index <n> --phase begin
# Drive the returned mode and exact fixture text through Computer Use.
scripts/macos_agent_ui.sh verify-generation --since "<returned since>" \
  --mode <returned mode> --text "<returned text>"
scripts/macos_agent_ui.sh benchmark-take --index <n> --phase complete
```

`begin` stamps the run ID and take metadata used by durable telemetry and relaunches the
exact app path for the two cold cells. `complete` refuses to advance without a
matching database row and readable WAV assertion. Never manufacture the matrix
or edit `/tmp/vocello-bench-current-take.json` outside the harness. A failed
attempt may be begun again at the same index; later cells remain locked until
that take passes.

## Verify generated results

Capture the timestamp immediately before activating Generate:

```sh
SINCE="$(scripts/macos_agent_ui.sh now)"
```

After the visible player state appears, prove the generation outside the UI:

```sh
scripts/macos_agent_ui.sh verify-generation \
  --since "$SINCE" --mode custom --text "<exact fixture text>"
scripts/macos_agent_ui.sh verify-probes
```

Do not accept a player, History row, app marker, or screenshot alone as backend
completion. `verify-generation` requires a matching database row and readable
WAV. `verify-probes` requires correlated engine and engine-service rows with
compatible terminal state and no transport gaps.

For XPC recovery, invoke `xpc-kill` only after a generation has spawned the
service, verify the app remains present, drive another generation, then require
both visible recovery and passing probes.

## Review semantically

At each named review state, inspect both the accessibility tree and screenshot.
Check clipping, truncation, copy, hierarchy, enabled state, focusability, labels,
and error presentation. Pixel equality is not a gate.

Save screenshots beneath the run's `screenshots/` directory and reference their
paths in checkpoints or issues. Never include user content or real library data;
the harness launches the debug-data sandbox.

## Finish and attest

Always execute cleanup, even after failure:

```sh
scripts/macos_agent_ui.sh verify-probes
scripts/macos_agent_ui.sh finish --status pass
scripts/macos_agent_ui.sh validate-report --suite <suite>
scripts/macos_agent_ui.sh attest --suite <suite>
```

Use `fail` or `blocked` instead of `pass` when appropriate. `finish` converts a
requested pass to failure if probes, cleanup, or blocker or major severity fails.
Only attest a passing, current report. Full evidence stays under
`build/macos/agent-ui/`; the compact non-sensitive attestation is tracked.

Schema-v2 attestation stores independent `quick`, `full`, and `benchmark`
entries. Attesting one suite preserves another only when source, build-input,
and toolchain identities match. Local validation also checks the raw SHA-256 of
the exact executable Computer Use drove. CI rebuilds `build/Vocello.app`,
recomputes source/build identity from tracked plus non-ignored untracked files,
and requires an internally valid toolchain identity from the same Xcode/Swift
major generations. Point-release drift between the local Mac and hosted runner
is accepted. CI intentionally does not compare its ad-hoc-signed executable
hash with the locally signed executable.

When `requiredRuntimeChecks` contains `telemetry-overhead`, run this after the
current full UI attestation and before final release readiness:

```sh
scripts/macos_test.sh telemetry-overhead
```

It runs one warm-up plus five seeded Custom/Speed/medium warm takes in off,
lightweight, and verbose modes. PCM must match exactly; median RTF and TTFC
regressions are capped at 5% and 10%. The compact verdict is merged into the
schema-v2 attestation without replacing valid suite entries. The command refuses
to generate unless the current full attestation already proves the visible
`model-readiness` scenario and performs only a read-only model integrity check.
