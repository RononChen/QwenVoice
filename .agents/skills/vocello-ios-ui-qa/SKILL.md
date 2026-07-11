---
name: vocello-ios-ui-qa
description: Run explicit Vocello iOS frontend or release acceptance on a paired physical iPhone through the bundled Computer Use plugin and Apple's iPhone Mirroring app, with device telemetry, screenshots, reports, and attestations verified by repository scripts. Use when the user requests iOS UI journeys, visual review, physical-device generation smokes, UI benchmarks, or iOS archive/TestFlight acceptance. Impact output is advisory during ordinary development and does not trigger this skill by itself.
---

# Vocello iOS UI QA

Drive the mirrored physical iPhone only through the installed `computer-use` skill. Use
`scripts/ios_agent_ui.sh` for lifecycle, device identity, telemetry, reports, and attestations.

## Active helper block

Do not invoke `quick`, `full`, or `benchmark` with Computer Use helper
`26.708.1000366 (1000366)`, UUID `61C0…9236`. That shared helper has a reproducible
accessibility bounds trap during Vocello macOS capture and has not earned normal-suite trust for
iPhone Mirroring. Read
[`docs/reference/computer-use-failure-analysis.md`](../../../docs/reference/computer-use-failure-analysis.md)
and the [upstream differential](https://github.com/openai/codex/issues/32293#issuecomment-4940886542).

If explicitly requested for diagnosis, perform at most one passive iPhone Mirroring observation:

1. Confirm the plugin is installed and enabled, start a fresh task, and require its Computer Use
   server and skill to be available.
2. Record the helper version/UUID/hash, sole supported runtime process, and crash-report baseline.
3. Observe `com.apple.ScreenContinuity` once with `disableDiff: true`.
4. Stop after the response or native-pipe closure. Do not click, type, navigate, launch a harness
   run, retry, generate, benchmark, or attest.

Normal suites remain blocked until the failure analysis' complete resumption protocol passes and
that document is updated. The remaining sections describe the normal workflow after unblocking.

## Select the suite

Do not invoke this skill merely to commit, push, open a pull request, or satisfy ordinary CI.
During development, `impact` reports later frontend scope only. Use the selected suites when
frontend acceptance is explicitly requested or before iOS archive/TestFlight.

- Use `quick` for navigation, layout, copy, and ordinary iOS view changes.
- Use `full` for Studio coordination, generation, persistence, models, Settings, or release work.
- Use `benchmark` for the ordered 29-take UI matrix.

Inspect requirements with:

```sh
scripts/ios_agent_ui.sh impact
```

Requirements are independent. Full does not satisfy benchmark; benchmark does not satisfy full.

## Bootstrap Computer Use

1. Verify the bundled plugin is installed and enabled and start a new Codex task. Confirm the task
   exposes both its Computer Use server and skill. These states are separate from a live helper
   process. Then read the installed OpenAI `computer-use` skill completely.
2. Derive its current plugin root from the skill path. In Node REPL, load the plugin-owned
   `scripts/computer-use-client.mjs` wrapper exactly as that skill instructs.
3. Confirm the expected `sky` API and call `sky.list_apps()`.
   When the plugin declares `bundledContentVariant=node-repl`, that enabled Node REPL entry is the
   active server; the disabled manifest-shaped Computer Use entry is an inert mirror and must not
   be enabled as a second route.
   The versioned plugin-cache app is the installed source. For the currently audited Desktop build,
   the observed desktop-managed runtime copy is `~/.codex/computer-use/Codex Computer Use.app`.
   The audit requires matching signed identities and exactly one live service at the build-scoped
   expected path. Plugin-cache fallback, duplicate/unknown helpers, or a new helper crash report
   blocks the run without claiming that routing caused the crash.
4. Run `scripts/ios_agent_ui.sh routing-audit`, then
   `scripts/ios_agent_ui.sh doctor --suite <suite> --json`. Continue only when
   `repositoryReady`, `deviceReady`, `computerUseServiceRunning`,
   `computerUseServicePathVerified`, and `readyForSession` are true.
5. Run `scripts/ios_agent_ui.sh start --suite <suite>`. It launches
   `com.patricedery.vocello` on the paired device and returns the run directory.
6. Call `sky.get_app_state({app: "com.apple.ScreenContinuity", disableDiff: true})`. Require the
   iPhone Mirroring window text, a screenshot URL, and visible physical-device Vocello content.
   A connection/error screen is not readiness. Record this as the first scenario checkpoint.

Stop before scenario execution when any capability check fails. Do not fall back to another MCP,
an XCTest UI runner, AppleScript input, or a repository coordinate bridge.

## Drive from live screenshots

The mirroring accessibility tree exposes window chrome, not the iPhone app's internal elements.
Screenshot-derived clicks are therefore the expected Computer Use mechanism.

For every logical action:

1. Call `get_app_state` for `com.apple.ScreenContinuity`.
2. Read the current screenshot.
3. Locate the target visually and click its current center in app-local screenshot coordinates.
4. Call `get_app_state` again and verify the semantic result from the new screenshot.
5. Save proof at named review states and failures beneath the run's `screenshots/` directory.

Never reuse coordinates from an earlier state, hardcode a coordinate table, assume a window
position, or transform coordinates in a shell script. Use the mirroring shortcuts `super+1` (Home), `super+2`
(App Switcher), and `super+3` (Spotlight) only as documented by the installed Computer Use state.

Use `type_text`, `press_key`, and `scroll` only after the latest screenshot shows the appropriate
focused field or scroll surface. Avoid `drag` for scrolling. Record blockers when a target cannot
be identified confidently; do not guess.

Record scenario status:

```sh
scripts/ios_agent_ui.sh checkpoint --scenario <id> --status pass \
  --message "<observed result>" --evidence "<run>/screenshots/<name>.png"
```

Before any generation, complete `model-readiness` through the visible Settings and Saved Voices
screens. Custom, Design, and Clone Speed must report installed/ready, a clone reference must be
visible, and Generate must be enabled. There is no headless model-inventory launch/pull fallback,
and a previous successful take is not current readiness evidence. If any state is missing, stop the
run, repair outside it, and begin a fresh visible readiness check before generating.

## Verify generations

Capture time immediately before activating Generate:

```sh
SINCE="$(scripts/ios_agent_ui.sh now)"
```

After the completed player is visible, require device telemetry:

```sh
scripts/ios_agent_ui.sh verify-generation \
  --since "$SINCE" --mode custom --text "<exact fixture>"
```

This pulls the app-container diagnostics mirror and requires a matching terminal engine row with no
hard audio-QC failure. A screenshot, player, or History row alone is not completion proof.

## Run the benchmark

```sh
scripts/ios_agent_ui.sh benchmark-manifest
scripts/ios_agent_ui.sh benchmark-take --index <n> --phase begin
# Drive the returned mode and exact text through Computer Use.
scripts/ios_agent_ui.sh verify-generation --since "<take since>" \
  --mode <mode> --text "<text>"
scripts/ios_agent_ui.sh benchmark-take --index <n> --phase complete
```

Run all takes in order. Each completion requires a new passing telemetry verification. Never edit
the report or manufacture take results outside the harness.

## Review and finish

Inspect Studio, Voices, History, Settings, sheets, loading states, and completed-player states for
clipping, truncation, copy, hierarchy, contrast, touch targets, and enabled state. Pixel equality is
not a gate. Never include personal content in saved screenshots.

Finish and attest:

```sh
scripts/ios_agent_ui.sh finish --status pass
scripts/ios_agent_ui.sh validate-report --suite <suite>
scripts/ios_agent_ui.sh attest --suite <suite>
```

Use `fail` or `blocked` when appropriate. Only a passing current report may be attested. Raw
screenshots and telemetry remain ignored under `build/ios/agent-ui/`; the compact attestation is
tracked.

Computer Use confirmation policy still applies. Deletion, model removal/download, permission
changes, file uploads, and system-setting changes require the applicable action-time confirmation;
these actions are outside quick, full, and benchmark unless the user explicitly authorizes them.
