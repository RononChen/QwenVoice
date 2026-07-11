# iOS physical-device testing with Computer Use

Vocello iOS runtime and frontend acceptance run on a paired physical iPhone only. Ordinary
development also has a deterministic physical-device SDK compile lane that needs no connected
phone. Bundled Computer Use is the sole UI driver and operates the phone through Apple's iPhone
Mirroring app. The MLX engine remains in-process on Metal; Simulator workflows are unsupported.

## Ownership

| Layer | Owner | Evidence |
| --- | --- | --- |
| UI actions and semantic review | `$vocello-ios-ui-qa` + bundled Computer Use | Live mirror screenshots |
| Device build/install/launch | `scripts/ios_device.sh` / optional shared XcodeBuildMCP | CoreDevice and build logs |
| UI lifecycle and attestation | `scripts/ios_agent_ui.sh` | `build/ios/agent-ui/<run>/` + `qa/ios-ui-attestation.json` |
| Generation proof | `ios_agent_ui.sh verify-generation` | Pulled terminal engine telemetry and audio QC |
| Headless performance/language | `ios_device.sh bench|lang-bench|profile` | Device diagnostics and traces |
| Explicit frontend / iOS release | `ios_device.sh gate` | Project inputs, device readiness, UI attestation, generation, crashes |

No XCTest UI target or UI runner is active.

## Deterministic development workflow

Commits, pushes, pull requests, ordinary merges, and ordinary CI do not require a paired phone,
models, Computer Use, or an iOS UI attestation:

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh ios
scripts/ios_agent_ui.sh impact  # advisory only
```

## Explicit frontend / iOS release workflow

```sh
scripts/ios_device.sh preflight
# Open Settings through Computer Use and verify Custom, Design, and Clone Speed are installed.
scripts/ios_agent_ui.sh routing-audit
scripts/ios_agent_ui.sh impact
# Invoke $vocello-ios-ui-qa for every required suite.
scripts/ios_device.sh test
scripts/ios_device.sh review
scripts/ios_device.sh gate
```

`test`, `ui-test`, `bench-ui`, and `review` validate Computer Use reports; they do not themselves
click the phone. The selected skill owns the live UI session.

The strict device commands are required when iOS frontend acceptance is explicitly requested and
before iOS archive/TestFlight. They are not prerequisites for preserving or sharing development
work, and iOS evidence never blocks a macOS package.

## Computer Use readiness

The skill reads the installed `computer-use` skill and loads its current plugin-owned Node wrapper.
Before a run, `scripts/ios_agent_ui.sh routing-audit` and `doctor --suite <suite> --json` require:

- exactly one `SkyComputerUseService` process;
- a signed-identity match across the app-bundled source, installed plugin source, and Desktop-managed
  runtime copy, with the sole process executing from the path observed for the audited Desktop build;
- no stale command-configured transport, stale notify path, or conflicting transport definition;
- no plugin-cache fallback, duplicate process, or new helper crash report;
- CoreDevice sees a paired physical iPhone.

The run starts before frontend verification. Its first scenario calls `sky.list_apps()`, observes
`com.apple.ScreenContinuity`, and requires current accessibility plus screenshot evidence containing
the mirrored device. The doctor reports `computerUseServiceProcesses`,
`computerUseServiceRunning`, `desktopManagedRuntimeRunning`, `pluginFallbackRunning`,
`computerUseServicePathVerified`, and `readyForSession`; it never
treats repository contracts as frontend proof.

## Interaction contract

iPhone Mirroring exposes window chrome, not Vocello's internal accessibility elements. The skill
therefore uses the current screenshot as the semantic source for each click:

1. Observe the mirror.
2. Locate the target in the current screenshot.
3. Click its current visual center in app-local screenshot coordinates.
4. Re-observe and verify the new state.
5. Save the proof screenshot under the active run.

Coordinates are ephemeral observations, never committed tables. Window geometry must not be
assumed. `super+1`, `super+2`, and `super+3` may be used only when the
installed Computer Use state documents those mirror shortcuts.

## Suite map

| Suite | Scope |
| --- | --- |
| quick | Launch/navigation, Studio modes, named visual review |
| full | quick + Custom/Design/Clone generation, History, Voices, models, reversible Settings |
| benchmark | Ordered 29-take Custom/Design/Clone matrix with per-take telemetry proof |

Full and benchmark are independent.

## Generation and benchmark proof

Before Generate:

```sh
SINCE="$(scripts/ios_agent_ui.sh now)"
```

After the completed player is visible:

```sh
scripts/ios_agent_ui.sh verify-generation --since "$SINCE" \
  --mode custom --text "<fixture>"
```

The verifier pulls the app-container diagnostics mirror and requires a terminal engine row with no
hard audio-QC failure. The 29-take benchmark uses `benchmark-manifest` and `benchmark-take`; a take
cannot complete without a new verification.

## Shared XcodeBuildMCP

OpenAI Build iOS Apps supplies the one shared XcodeBuildMCP server. It may assist physical-device
discovery, build, install, launch, logs, and LLDB. Before use, call `session_show_defaults`, select
`ios-device`, and set the device ID at runtime. Never select a Simulator workflow. Repository
scripts remain final proof.

## Native triage

| Failure | Route |
| --- | --- |
| Build/signing | `ios_device.sh preflight`, exact `xcodebuild` output, Xcode Signing & Capabilities |
| Runtime | `ios_device.sh logs` / `debug`, LLDB, device console |
| Crash | `ios_device.sh crashes`, Xcode Organizer, optional `xcsym` on `PATH` |
| Performance | `ios_device.sh profile`, Instruments / `xcrun xctrace`, optional `xcprof` |
| Workflow choice | `$axiom-tools` guidance; no Axiom MCP is assumed |

## Hardware and engine invariants

- Supported hardware begins at iPhone 15 Pro.
- `increased-memory-limit` remains required.
- Cancellation is cooperative; cancelled results never enter History.
- Clone uses the entitled-memory-aware load profile.
- Thermal and memory evidence from the physical device are authoritative.
- iOS batch remains intentionally absent.

See [`ios-ui-reference.md`](ios-ui-reference.md), [`ios-device-probe.md`](ios-device-probe.md),
and [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md).
