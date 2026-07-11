# Codex frontend acceptance index

Bundled Computer Use is the only UI driver for Vocello. Repository skills define live interaction;
repository scripts own build, lifecycle, telemetry, reports, and attestations.

This index is for explicitly requested frontend acceptance and release QA. Ordinary development,
commits, pushes, pull requests, merges, and CI use deterministic checks only. The `impact` commands
are advisory until acceptance begins. Missing Computer Use, models, a paired phone, or an
attestation never blocks preserving or sharing development work.

## Current frontend block

Computer Use helper `26.708.1000366 (1000366)`, UUID `61C0…9236`, is known-bad for normal
Vocello suites after four identical accessibility bounds traps. macOS and iOS
quick/full/benchmark execution is blocked. Only one explicitly requested passive target observation
is allowed, with no retry, UI action, generation, or attestation. See the authoritative
[`computer-use-failure-analysis.md`](computer-use-failure-analysis.md) and
[openai/codex#32293](https://github.com/openai/codex/issues/32293#issuecomment-4940886542).

Plugin availability, installation, enablement, server/skill availability in a fresh task, and the
live helper process are distinct checks. A running service or successful Finder capture does not
prove that a task is ready, and neither clears the known-helper block.

The helper block prevents frontend acceptance and the matching platform's release; it does not
block deterministic development or Git operations.

## macOS

Use `$vocello-macos-ui-qa` against the exact absolute `build/Vocello.app` path.

```sh
scripts/macos_agent_ui.sh routing-audit
scripts/macos_agent_ui.sh impact
scripts/macos_agent_ui.sh doctor --suite full --json
# Invoke every required quick, full, and/or benchmark suite.
scripts/macos_test.sh ui-report --suite full
scripts/macos_test.sh gate
```

Run the suite commands only after the failure analysis' resumption criteria pass. Before any
generation, Settings must visibly show Custom, Design, and Clone Speed installed/ready, Generate
enabled, and the required clone voice present. Model repair commands are bootstrap tools, not
frontend evidence.

Computer Use acts on the native accessibility tree and current screenshot. The shell harness joins
History, WAV, XPC, backend telemetry, cleanup, source, build-input, toolchain, and executable proof.

## iOS

Use `$vocello-ios-ui-qa` against `com.apple.ScreenContinuity`. The skill operates the paired
physical iPhone shown by Apple's iPhone Mirroring app.

```sh
scripts/ios_agent_ui.sh routing-audit
scripts/ios_agent_ui.sh impact
scripts/ios_agent_ui.sh doctor --suite full --json
# Invoke every required quick, full, and/or benchmark suite.
scripts/ios_device.sh ui-test --suite full
scripts/ios_device.sh bench-ui
scripts/ios_device.sh review
scripts/ios_device.sh gate
```

These iOS commands remain the supported interface but do not start normal Computer Use acceptance
while the shared helper block is active. A diagnostic is limited to one passive iPhone Mirroring
observation after live plugin, route, identity, process, and crash-baseline checks.

The mirror exposes macOS window chrome through accessibility while the device UI is visual.
Therefore the skill derives each app-local click from the latest screenshot and immediately
re-observes. It never uses a saved coordinate table, window-position assumption, shell coordinate
conversion, alternate desktop-control MCP, or mobile automation server.

The iOS harness and skill:

- verify that the app-bundled source, plugin-cache source, and Desktop-managed runtime copy have
  matching signed identities, and require the sole live service to use the path observed for the
  audited Desktop build;
- start the run before frontend verification, then make a live iPhone Mirroring accessibility and
  screenshot observation the first scenario;
- launches `com.patricedery.vocello` with CoreDevice;
- stores screenshots under `build/ios/agent-ui/<run>/`;
- pulls `engine/generations.jsonl` after UI generation;
- requires terminal generation and audio-QC proof;
- validates and attests independent quick, full, and benchmark reports.

`scripts/ios_device.sh ui-test`, `test`, `bench-ui`, and `review` validate those reports. They do
not start an XCTest UI runner.

## Website

Read `website/AGENTS.md`, start the documented localhost server, and use the OpenAI Browser plugin.
Browser verification never replaces build or test commands.

## Unsupported routes

- XCTest UI runners on either platform;
- iOS Simulator or Simulator Browser;
- standalone desktop-control or mobile-automation MCP servers;
- OCR daemons and hardcoded coordinate bridges;
- a live plugin-cache fallback, duplicate service, or service outside the current build-scoped
  routing expectation.
