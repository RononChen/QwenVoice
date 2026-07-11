# Testing runbook (Vocello / QwenVoice)

Authority is `Sources/` → `project.yml` → repository scripts → this document. Bundled Computer Use
is the sole frontend driver on macOS and iOS; scripts and typed artifacts remain the strict
frontend/release gate interface.

## Development publishing policy

Commits, pushes, pull requests, ordinary merges, and ordinary CI require deterministic verification
only. Missing Computer Use, model, paired-device, or UI-attestation evidence must never block
preserving or sharing development work. The two `impact` commands report advisory future frontend
scope; strict validation is opt-in for explicit acceptance and unconditional only for the platform
artifact being released.

## Platform model

| Platform | Deterministic development proof | Strict frontend/release gate |
| --- | --- | --- |
| macOS | `scripts/macos_test.sh test` + `./scripts/build.sh build` | `$vocello-macos-ui-qa` + `scripts/macos_test.sh gate` |
| iOS | `./scripts/check_project_inputs.sh` + `./scripts/build_foundation_targets.sh ios` | `$vocello-ios-ui-qa` through iPhone Mirroring + `scripts/ios_device.sh gate` |
| Website | Site build/tests | OpenAI Browser review when explicitly requested/releasing |

Neither platform uses an XCTest UI runner. The iOS Simulator is unsupported.

## macOS deterministic development

```sh
scripts/macos_test.sh test
./scripts/build.sh build
scripts/macos_agent_ui.sh impact  # advisory only
```

## macOS explicit frontend/release acceptance

```sh
# Invoke $vocello-macos-ui-qa full when required; it verifies Settings visibly.
# Then run telemetry-overhead when listed; it refuses without current full evidence.
# Run benchmark independently when required.
scripts/macos_test.sh gate
```

Use `scripts/macos_test.sh models ensure` only as explicit repair/bootstrap when the visible
Settings check fails, then start a fresh UI run. Normal gates never download, link, or enroll model
fixtures automatically.

macOS reports join History, WAV, XPC/backend probes, executable, source, build-input, toolchain,
cleanup, and semantic UI evidence.

## iOS deterministic development

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh ios
scripts/ios_agent_ui.sh impact  # advisory only
```

## iOS explicit frontend/release acceptance

```sh
scripts/ios_device.sh preflight
# Computer Use verifies the three Speed models in iOS Settings before generation.
scripts/ios_agent_ui.sh impact
# Invoke every required $vocello-ios-ui-qa suite.
scripts/ios_device.sh test
scripts/ios_device.sh bench-ui
scripts/ios_device.sh review
scripts/ios_device.sh gate
```

iOS Computer Use acts through `com.apple.ScreenContinuity` and derives every click from the current
screenshot. The harness pulls on-device engine telemetry after UI generation and stores raw evidence
under `build/ios/agent-ui/`.

## Compile safety

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
./scripts/build.sh build
```

CI builds the iOS app against `generic/platform=iOS` but cannot claim attended Computer Use UI
acceptance. Ordinary CI records both impact reports for information without validating the current
attestations.

## Platform-specific release enforcement

- macOS signing/notarization requires `scripts/macos_test.sh release-readiness`, including fresh
  macOS `full` and `benchmark` evidence and required runtime checks.
- iOS signing/archive/TestFlight requires `scripts/ios_agent_ui.sh release-check`, including fresh
  iOS evidence.
- macOS evidence does not gate iOS artifacts, and iOS evidence does not gate macOS artifacts.

## Shared XcodeBuildMCP

OpenAI Build iOS Apps supplies the one shared server and Build macOS Apps consumes it. Call
`session_show_defaults`, select `macos` or `ios-device`, set physical-device identity only at
runtime, and return to scripts for final proof. No Simulator profile or second server is allowed.

## Artifacts and triage

| Evidence | Location / tool |
| --- | --- |
| macOS UI | `build/macos/agent-ui/`, `qa/macos-ui-attestation.json` |
| iOS UI | `build/ios/agent-ui/`, `qa/ios-ui-attestation.json` |
| iOS telemetry/crashes | `build/ios-diagnostics/` |
| Crash review | Xcode Organizer; optional `xcsym` |
| Performance | Instruments / `xcrun xctrace`; optional `xcprof` |
| Workflow selection | `$axiom-tools` guidance |

## CI impact comparison

These base rules make the advisory reports describe the complete change range. Ordinary CI does
not pass `--check` and does not validate UI attestations.

- Pull request: `github.event.pull_request.base.sha`.
- Push: `github.event.before`.
- Manual dispatch: explicit resolvable base input.

Deep references: [`macos-testing.md`](macos-testing.md),
[`ios-device-testing.md`](ios-device-testing.md),
[`ui-smoke-runbooks.md`](ui-smoke-runbooks.md), and
[`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md).
