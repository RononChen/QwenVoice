# iOS Simulator UI review — fake backend reference

Supplementary lane for **layout, navigation, and UI state** review without a paired iPhone,
signing, MLX, or Hugging Face downloads. The on-device harness in
[`ios-device-testing.md`](ios-device-testing.md) §2 remains the **release gate** for real
URLSession downloads, cold MLX generation, and entitlement behavior.

Driver: `scripts/ios_sim.sh` (unsigned, shares `build/ios` with device builds).

## Quick start

```sh
scripts/ios_sim.sh doctor
scripts/ios_sim.sh run --preset studio-seeded   # Studio shows Generate
scripts/ios_sim.sh shot build/ios-sim-shot.png
scripts/ios_sim.sh ui-test                      # scoped fake-backend smoke
```

## Run presets

| Preset | Effect |
| --- | --- |
| `studio-seeded` (default) | `QVOICE_SIM_FAKE_MODELS=all`, seed voices + history |
| `settings-fresh` | `QVOICE_SIM_FAKE_MODELS=none` — Install rows, onboarding-friendly |
| `download-slow` | `none` + `QVOICE_SIM_DOWNLOAD_SCENARIO=slow` |
| `generation-fail` | `all` + `QVOICE_SIM_BACKEND_SCENARIO=fail` |

```sh
scripts/ios_sim.sh run --preset download-slow
scripts/ios_sim.sh run --no-seed                # empty / onboarding
```

Presets export `SIMCTL_CHILD_QVOICE_SIM_*` for `simctl launch`. Override any var by exporting
it before `run`.

## Environment variables (`QVOICE_SIM_*`)

| Variable | Values | Layer | Effect |
| --- | --- | --- | --- |
| `QVOICE_SIM_FAKE_MODELS` | `all`, `custom`, `design`, `clone`, comma-separated ids, `none` | Install registry seed | Which catalog models report `.installed` at launch |
| `QVOICE_SIM_SEED_DATA` | `voices`, `history` (comma-separated) | Fake engine | Seed saved voice + History row for sheet/player review |
| `QVOICE_SIM_BACKEND_SCENARIO` | `success`, `slow`, `fail`, `cancel_mid`, `clone_missing_ref` | `IOSSimulatorTTSEngine` | Generation timing/outcome for Studio UI |
| `QVOICE_SIM_DOWNLOAD_SCENARIO` | `success`, `slow`, `fail_mid`, `fail_verify` | `IOSSimulatedModelDownloadBackend` | Download progress, mid-fail, verify-fail UI |
| `QVOICE_SIM_BACKEND_DELAY_MS` | `0`–`30000` | Both backends | Override default per-chunk / generation delay (ms) |
| `QVOICE_SIM_CLONE_CAPABLE` | `0`/`1`, `false`/`true` | Feature gate (sim only) | Force clone mode off/on for Settings/Studio gating review |
| `QVOICE_SIM_DOWNLOAD_RESUME_ON_LAUNCH` | `1` | Delivery actor | Reserved for relaunch-resume experiments (persisted install state) |

After a **simulated install**, `IOSModelDeliveryActor` calls
`IOSSimulatorFakeInstallRegistry.markInstalled`; delete/cancel call `clear` so Settings rows
match disk state even when the launch seed was `all`.

## Default `ui-test` scope

`scripts/ios_sim.sh ui-test` runs (sequentially, build-for-testing first):

1. `VocelloiOSSmokeUITests`
2. `VocelloiOSSheetUITests`
3. `VocelloiOSDownloadManagerUITests` (simulator-only)
4. `VocelloiOSSimulatorGenerationUITests` (simulator-only)

Excluded by default (device release gate):

- `VocelloiOSOnDeviceDownloadUITests` — real URLSession
- `VocelloiOSColdGenerationUITests` — real MLX cold generation

Pass `--all` to run the full target; device-only classes still `XCTSkip` on sim.

## Common review flows

| Goal | Command / env |
| --- | --- |
| Studio with Generate enabled | `run --preset studio-seeded` |
| Settings Install buttons | `run --preset settings-fresh` |
| Slow download progress | `run --preset download-slow` → Settings → Install |
| Download error mid-flight | `QVOICE_SIM_DOWNLOAD_SCENARIO=fail_mid` + Settings install |
| Verify failure banner | `QVOICE_SIM_DOWNLOAD_SCENARIO=fail_verify` |
| Generation error UI | `run --preset generation-fail` |
| Cancel during slow gen | `QVOICE_SIM_BACKEND_SCENARIO=cancel_mid` |
| Clone gated off | `QVOICE_SIM_CLONE_CAPABLE=0` |

## What sim does **not** prove

- Hugging Face download integrity or SHA verification (sim skips real verify unless `fail_verify` UI path)
- MLX/Metal audio quality, RTF, or memory/Jetsam behavior
- Code signing, TCC, or App Group container paths identical to device

Always run `scripts/ios_device.sh ui-test` before merge when UI touches downloads or generation.
