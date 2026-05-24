# iOS Device Screen-Mirror Testing

Validate the real iPhone app on owned hardware while controlling the UI through Apple's iPhone Mirroring app. This path covers model downloads, engine-extension behavior, memory guardrail evidence, and real MLX generation once Apple's increased-memory entitlement is available. Simulator review remains covered by [`ios-simulator-testing.md`](ios-simulator-testing.md).

## Quick Start

```sh
scripts/ios_device.sh doctor
scripts/ios_device.sh start
```

`start` creates a focused evidence bundle under `build/Debug/ios-device/runs/<utc-run-id>/`, builds `VocelloiOS` Debug for the paired physical iPhone, installs it with CoreDevice, launches `com.patricedery.vocello` with lightweight native telemetry enabled, and opens iPhone Mirroring.

Defaults:

- device: the paired physical iPhone 17 Pro, currently `iPhone de Patrice`
- build: Debug, direct install, automatic signing
- catalog: bundled production iPhone catalog, with model artifacts downloaded from pinned Hugging Face revisions
- signing team resolution: `QVOICE_IOS_TEAM_ID`, `QWENVOICE_DEVELOPMENT_TEAM`, `APPLE_TEAM_ID`, then `FK2D8X36G2`
- app data: preserved across runs unless you manually uninstall or clear the app; the May 2026 identity rename intentionally reset pre-release data by moving to `group.com.patricedery.vocello.shared`
- proactive iPhone prefetch: disabled by default; explicit generation owns model load/warm work

Useful overrides:

```sh
scripts/ios_device.sh start --device <device-id-or-udid>
scripts/ios_device.sh start --run-id memory-guard-custom
scripts/ios_device.sh start --catalog-url https://example.com/ios/catalog/v1/models.json
scripts/ios_device.sh start --allowed-hosts downloads.example.com,cdn.example.com
scripts/ios_device.sh start --enable-proactive-prefetch
scripts/ios_device.sh start --mlx-memory-limit-mb 2800 --mlx-cache-limit-mb 64
```

`--enable-proactive-prefetch` is only for backend experiments. Stable hardware validation keeps it off because ExtensionKit may interrupt idle/prewarm-heavy extension work more aggressively than macOS XPC services.

The same values can be supplied with environment variables for repeatable local runs: `QVOICE_IOS_DEVICE_ID`, `QVOICE_IOS_DEVICE_RUN_ID`, `QVOICE_IOS_MODEL_CATALOG_URL`, `QVOICE_IOS_MODEL_ALLOWED_HOSTS`, `QVOICE_IOS_MEMORY_GUARD_FORCE_BAND`, `QVOICE_IOS_MEMORY_GUARD_FORCE_CRITICAL_ONCE`, `QVOICE_IOS_MLX_MEMORY_LIMIT_MB`, and `QVOICE_IOS_MLX_CACHE_LIMIT_MB`. `scripts/ios_device.sh start` sets `QWENVOICE_NATIVE_TELEMETRY_MODE=lightweight` for Debug evidence capture.

`QVOICE_IOS_MLX_MEMORY_LIMIT_MB` is a process-lifetime Debug experiment for the launched app/extension process. Relaunch the app with a different value when sweeping limits.

## Codex Control

iPhone Mirroring exposes a visual Mac window, not the app's iOS accessibility identifiers. Use Computer Use against the `iPhone Mirroring` / `Recopie de l'iPhone` window by visible labels, tab icons, text fields, and buttons. If focus drifts, run:

```sh
scripts/ios_device.sh mirror
```

Then refresh Computer Use state for the mirroring app and continue. Use screenshots at milestones:

```sh
scripts/ios_device.sh screenshot settings-ready
scripts/ios_device.sh screenshot custom-complete
```

## Smoke Scenarios

Run these from the mirrored iPhone UI after `start`:

- Settings: verify each Speed model row can download or is already installed. First-time runs use the bundled catalog and require normal internet access to Hugging Face artifact URLs.
- Custom Voice: install the Custom model if needed, enter a short prompt, generate, listen briefly, and capture a screenshot after completion.
- Voice Design: enter a short voice brief and prompt, generate, confirm the inline player appears, and capture a screenshot.
- Voice Cloning: record or select a 10-20 second reference, enter a prompt, generate, confirm playback starts, and capture a screenshot.

For memory guardrails, collect one normal run plus the two Debug-only synthetic scenarios:

```sh
scripts/ios_device.sh start --run-id memory-baseline
scripts/ios_device.sh start --run-id guarded-probe --force-band guarded
scripts/ios_device.sh start --run-id critical-once-probe --force-critical-once
```

`--force-band guarded` should block proactive warm/prefetch work while still allowing foreground generation. `--force-critical-once` should cancel the first active generation sample, abort live preview, request a full unload, and disarm until the app is relaunched.

Run the first hardware pass without MLX memory/cache limits. After that baseline is pulled, run the same Custom -> Design -> Clone path with a limit probe:

```sh
scripts/ios_device.sh start --run-id mlx-2800 --mlx-memory-limit-mb 2800 --mlx-cache-limit-mb 64
```

The MLX limit probe is diagnostic only: it sets Debug launch env vars so runaway active allocations fail earlier than jetsam while Release/TestFlight policy remains unchanged.

Physical iOS defaults to final-file playback rather than live chunk playback: inline preview PCM is skipped and Release builds do not publish extension events. To test live debug chunks without inline PCM over XPC, launch with `QVOICE_IOS_EXTENSION_ENABLE_EVENT_SINK=1`, `QWENVOICE_STREAMING_OUTPUT_POLICY=file`, and `QWENVOICE_STREAMING_PREVIEW_DATA=off`.

## Evidence Capture

After each run:

```sh
scripts/ios_device.sh pull
```

The run directory contains:

- `run-manifest.json`, selected device metadata, build/install/launch JSON, and CoreDevice logs
- `screenshots/*.png` captured from the Mac screen
- `pulled/diagnostics/memory-contexts.jsonl`, `pulled/diagnostics/native-events.jsonl`, and `pulled/diagnostics/manifest.json` when the app ran with lightweight telemetry
- combined app+extension footprint fields and aggregate pressure bands in each memory-context record
- `runtime-load-model-preswitch-cache-clear` native events when an iPhone run switches from one loaded model ID to another before the next load peak
- focused App Group evidence: `history.sqlite`, generated `outputs/`, and saved `voices/`

On Xcode/CoreDevice builds that reject direct `appGroupDataContainer` copies with a path-validation error, `pull` falls back to the Debug-only app-container mirror for memory diagnostics. History/output/voice evidence remains App Group best-effort.

Diagnostics memory records intentionally omit prompt text and audio bytes. The pulled history database and output files are local evidence artifacts for manual review.

## Recovery

- Device not found: unlock the iPhone, keep it on the same network or connected by cable, and rerun `scripts/ios_device.sh doctor`.
- Mirroring window unavailable: open `/System/Applications/iPhone Mirroring.app` manually once, then rerun `scripts/ios_device.sh mirror`.
- Signing failure: confirm the Apple Developer account for the selected team is available in Xcode Settings, then rerun `scripts/ios_device.sh build`.
- Increased-memory entitlement failure: `scripts/ios_device.sh build --enable-increased-memory-limit` requires Apple approval for `com.apple.developer.kernel.increased-memory-limit`. Without that entitlement, Debug installs remain useful for UI, downloads, transport, and diagnostics, but real MLX generation may be blocked by memory admission or jetsam risk.
- Model downloads fail: rerun `doctor` and check `catalog-check.stderr` in the run directory. Use `--catalog-url <url>` only when testing a staging catalog override.

This workflow is local-only. TestFlight archive/export remains owned by `scripts/release_ios_testflight.sh`.
