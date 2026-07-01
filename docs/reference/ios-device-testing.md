# iOS on-device testing — the hybrid method

> **Canonical testing doc:** [`testing-runbook.md`](testing-runbook.md) — on-device
> XCUITest model, CI compile lane, and determinism rules. This file is the **device
> lanes** deep-dive (headless harness, `scripts/ios_device.sh`, quality lanes).

The **automated/headless** on-device methods. They complement interactive UI review over
iPhone Mirroring for UI-driven operations + UI design/review. Two automated tools, neither of
which drives the UI by pixels:

1. **Headless generation harness** — the on-device analog of `vocello bench`. Launch
   the app over `devicectl` with an autorun spec; the in-app `IOSAutorunHarness` runs
   one generation with **no UI interaction**, writes telemetry + a completion sentinel
   into the App-Group container, and `scripts/ios_device.sh` pulls them back and
   summarizes. This is the real on-device entitlement/memory/RTF proof.
2. **XCUITest UI tests** (`VocelloiOSUITests`) — deterministic, self-driving UI regression
   on a **paired physical iPhone** only (real in-process MLX engine). See
   [`testing-runbook.md`](testing-runbook.md).

Why this exists: on-device generation is the path that exercises real Jetsam, real model
download, and the in-process engine + increased-memory entitlement. GitHub CI runs
**compile-only** for iOS; the real UI gate is `scripts/ios_device.sh gate` locally.
iPhone Mirroring is **not** the right tool for *scripted generation* (focus races, disconnects, engine-busy rejections, no headless
trigger) — the headless harness is. See also: generation runs **in-process in the app** (since
commit `7822a8a`) — a non-UI ExtensionKit extension is Jetsam-capped at a tiny per-process
budget the entitlement does **not** raise, so it could never load the model; the app process
*does* get the raised limit. The dead extension target was removed entirely (it never ran on
hardware; git history preserves it).

---

## Prerequisites

- **Xcode 26** (`devicectl` / CoreDevice).
- **A paired iPhone 15 Pro or newer** (iPhone 17 Pro preferred when multiple devices are
  paired), **Developer Mode ON**, Mac trusted (USB). Verify on the device itself the first time.
- `export QWENVOICE_DEVELOPMENT_TEAM=<your-apple-team-id>` — matches `project.yml`'s
  `$(QWENVOICE_DEVELOPMENT_TEAM)`. **Never commit the team id.**
- Optional `export QVOICE_IOS_DEVICE_ID=<id|name|udid>` to pin the target device;
  otherwise the driver auto-discovers the single connected device.
- **Device models (lane-dependent):** the default ui-test gate (`Smoke` + `Sheet` +
  `OnDeviceDownload`) does **not** require a pre-installed model — `OnDeviceDownload`
  uninstalls `pro_custom` in `setUp` to exercise the cancel path. **`--cold`**, **`bench`**,
  and **`profile`** require Custom Voice (Speed) installed once on the iPhone (Settings →
  Model Downloads). Run `scripts/ios_device.sh models check` for the matrix; the Mac cannot
  verify App Group files remotely.

The increased-memory entitlement is enabled + verified on the app's App ID (the engine is
in-process — there is no extension App ID) — see
[`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md).

- **Screen mirroring (observation, on by default):** device commands auto-start macOS **iPhone Mirroring**
  so you watch the live app on the Mac while the phone stays **locked + screen-dark (OLED burn-in safe)**.
  iPhone Mirroring also keeps a *locked* device reachable to `devicectl` (a locked phone without mirroring
  goes "unavailable"). **Lock the phone once** per session (Apple exposes no Mac-side lock CLI; it then stays
  locked while mirroring) or rely on Auto-Lock — iPhone Mirroring reconnects when the phone auto-locks. Opt
  out with `QVOICE_IOS_NO_MIRROR=1`; start it manually with `scripts/ios_device.sh mirror`.

- **Unlock vs lock:** `bench`, `launch`, and `pull` work with a **locked** phone (mirroring
  keeps CoreDevice reachable). **`ui-test` requires the iPhone unlocked once** at the start of
  the run so XCUITest can complete the automation auth handshake (`Unlock iPhone … to Continue`
  / `SFAuthenticationErrorCodeApproveFailedToPost` when locked). Lock again after the handshake
  if you prefer; mirroring keeps the tunnel up.

---

## 1. Headless generation harness

### `scripts/ios_device.sh`

A small `devicectl` driver. The signing team comes from `$QWENVOICE_DEVELOPMENT_TEAM`;
the device is auto-discovered or pinned via `$QVOICE_IOS_DEVICE_ID` (neither committed).

Every device verb below first runs an **auto-mirror preflight** (`ensure_mirror`): it starts
macOS iPhone Mirroring and waits for the device to be `devicectl`-reachable, so you watch
on the Mac with the phone locked + screen-dark (OLED-safe). Opt out with `QVOICE_IOS_NO_MIRROR=1`.

| Verb | What it does |
|------|--------------|
| `doctor` | Environment + device preflight (Xcode, team env, device, built-app entitlement). |
| `build` | Signed device build, `-Onone`, automatic signing (`-allowProvisioningUpdates`) → `build/ios/…/Vocello.app` (one shared iOS tree). |
| `install` | `devicectl device install app` the built app. |
| `launch [spec]` | Launch via `devicectl`. With a spec → sets the autorun + telemetry env; prints the generated `runID` on stdout. Without → a plain launch. |
| `console [spec]` | Attached `--console` launch — streams the app's `[autorun]` stdout live (best for diagnosing a failed run). |
| `mirror` | Start macOS iPhone Mirroring + confirm the device is reachable (the preflight, runnable on its own). |
| `shot [path]` | `screencapture` the macOS iPhone Mirroring window → a real device screenshot (default `build/device-shot.png`). Brings Mirroring frontmost first. |
| `pull [dest]` | `devicectl device copy from --domain-type appDataContainer --source Library/Caches/Vocello/diagnostics` (the app's pullable mirror — the App-Group container is NOT devicectl-readable). Default dest `build/ios-diagnostics`. |
| `bench [spec] [--label "note"]` | The full loop: `build → install → launch-with-autorun → poll the sentinel → pull diagnostics → summarize`. Exits non-zero if the generation failed. |
| `ui-test [--all\|--cold] [target]` | Run `VocelloiOSUITests` on the device (see §2). **Default:** Smoke + Sheet + OnDeviceDownload. `--cold` runs cold generation only (`ui-test` alone: **skips** when Speed model missing). `--all` runs every class (debug). Optional `target` scopes further. |
| `preflight [--cold]` | One-shot readiness check (mirror + device reachable + signing + app + dSYM) + unlock advisory. `--cold` adds device-model install advisory. |
| `uitest-doctor [--enable-gate1]` | Mac Gate 1 + device doctor + iPhone unlock/passcode guidance for unattended ui-test. |
| `models` | `models check` — which ui-test/bench tiers need Speed on device (Mac cannot verify App Group files). |
| `test [--all\|--cold] [target]` | `ui-test` wrapper + verdict artifacts. **`test --cold` fails** if ColdGeneration was skipped for missing Speed model (post-xcresult check). Default gate needs **no** pre-installed model. |
| `crashes [--test]` | Pull + `xcsym`-symbolicate MetricKit crash/hang diagnostics (see §3). `--test` deliberately crashes to verify the lane. |
| `debug [spec]` | `get-task-allow` build + attached launch + the LLDB attach command. |
| `logs [spec]` | Attached launch teeing stdout/stderr → `build/ios-logs/<run>.log`. |
| `profile [spec]` | Instruments/xctrace trace of an autorun generation → `build/ios/profile-<ts>.trace`. |
| `review [--baseline]` | On-device UI capture tour + baseline pairs (see §3); `--baseline` seeds `docs/ios-review-baselines/`. |
| `gate` | One-command pre-merge gate: preflight → test → crashes → verdict (`build/ios/gate-<run>/`). |

```sh
export QWENVOICE_DEVELOPMENT_TEAM=<team-id>
scripts/ios_device.sh doctor
scripts/ios_device.sh bench "custom:speed:Hello from Vocello on device" --label "in-process engine"
```

`bench` prints the single-run headline (status / mode / model / audio-sec · wall · RTF /
finish / output path / device) from the sentinel, then the full
`summarize_generation_telemetry.py` table (engine decode breakdown, RTF, `audioQC`, RAM)
from the pulled `diagnostics/engine/generations.jsonl`.

### Autorun spec + environment

The harness (`Sources/iOS/IOSAutorunHarness.swift`) fires **only** when
`QVOICE_IOS_AUTORUN` is present and non-empty in the launch environment — a normal user
launch never sets it, so it ships completely inert (no `#if DEBUG` needed; it follows
the same runtime-gate philosophy as `TelemetryGate`).

`bench` / `launch <spec>` set three launch env vars (via
`devicectl device process launch -e '{…}'`):

| Env var | Purpose |
|---------|---------|
| `QVOICE_IOS_AUTORUN` | The spec: `<mode>:<variant>:<text>`. `mode ∈ custom\|design\|clone`, `variant ∈ speed\|quality` (iPhone resolves speed-only), text is everything after the 2nd `:`. Forgiving: bare `1`/`on`, a bare mode, or a partial spec fall back to defaults. |
| `QWENVOICE_DEBUG=1` | Lights up `TelemetryGate` so the engine appends its decode/RTF/`audioQC` row to `diagnostics/engine/generations.jsonl`. **Runtime-gated, not `#if DEBUG`** — works in the Release build the device runs. |
| `QVOICE_IOS_DEVICE_RUN_ID=<runID>` | Tags the run; the completion sentinel lands at `diagnostics/<runID>/autorun-done.json`. |

The harness drives the same in-process `TTSEngineStore.generate(_:)` the UI uses
(resolving the model the same way: `ModelDescriptor.model(for: mode)`), then writes the
sentinel:

```jsonc
// diagnostics/<runID>/autorun-done.json
{ "status": "ok", "mode": "custom", "variant": "speed", "modelID": "…",
  "generationID": "…", "durationSeconds": 5.1, "wallSeconds": 13.7,
  "realtimeFactor": 0.37, "finishReason": "…", "audioPath": "…",
  "deviceModel": "iPhone", "systemVersion": "26.x", … }
```

`clone` autorun needs a saved voice on the device (else a clean sentinel error). Note
clone generation in-app currently uses `.iOSProductionDefault` (= `withoutCloneEncoders`,
memory-conscious). A clone autorun needs the iOS clone-encoders capability enabled
(`.fullCapabilities` load profile); if the device is on the memory-conscious profile, the
run records a clean sentinel error rather than crashing.

### Where the data lives + how it's pulled

At runtime the engine telemetry and the sentinel are written to the **App-Group container**
(`AppPaths.appSupportDir` = `group.com.patricedery.vocello.shared`), under `diagnostics/`. But
`devicectl` **cannot** read an app-group container, so the autorun harness also **mirrors** them into
the app's own data container at `Library/Caches/Vocello/diagnostics` (which `devicectl` *can* read).
`pull`/`bench` copy from that mirror:

```sh
xcrun devicectl device copy from --device <id> \
  --domain-type appDataContainer \
  --domain-identifier com.patricedery.vocello \
  --source Library/Caches/Vocello/diagnostics --destination build/ios-diagnostics
```

The summarizer reads the pulled tree directly:

```sh
python3 scripts/summarize_generation_telemetry.py build/ios-diagnostics/diagnostics --label "…"
```

On iOS (in-process, no XPC) only `engine/generations.jsonl` is populated — the summarizer
iterates engine rows and joins `app/` rows when present, so TTFC may be blank while RTF /
tokens/s / decode breakdown / `audioQC` / RAM all come through. `engine/generations.jsonl`
is append-only + size-capped (auto-pruned oldest-first), so it accumulates across runs;
the sentinel is the authoritative single-run record.

---

## 2. XCUITest — on-device only

See [`testing-runbook.md`](testing-runbook.md) for commands, launch env vars, and CI.

| Backend | Where | Suites |
| --- | --- | --- |
| Real in-process MLX engine | **Paired iPhone only** | Smoke, Sheet, OnDeviceDownload, ColdGeneration, ReviewTour |

Run UI tests on hardware with **`scripts/ios_device.sh ui-test`**
(`build-for-testing` → install host app → `xcodebuild test-without-building`). Pass
`[target]` to scope further, e.g.
`scripts/ios_device.sh ui-test VocelloiOSUITests/VocelloiOSSheetUITests`.

| Command | Classes | Notes |
|---------|---------|-------|
| `scripts/ios_device.sh ui-test` | Smoke, Sheet, OnDeviceDownload | Default (~1–2 min). Real engine; **OnDeviceDownload uninstalls `pro_custom` in setUp** — do not pre-install for this gate. |
| `scripts/ios_device.sh ui-test --cold` | ColdGeneration | Real cold launch; **skips** when Speed model not installed on device. |
| `scripts/ios_device.sh test --cold` | ColdGeneration (via wrapper) | Same suite as `--cold`, but **fails the run** if ColdGeneration skipped for missing Speed model. |
| `scripts/ios_device.sh ui-test --all` | All classes | Debug/soak only. Cold gen skips without model unless using `test --cold`. |

**Preflight:** `ui-test` runs `ios_uitest_doctor` (Mac Gate 1 check), then `ensure_device_ready`
(mirroring up to 60s, devicectl reachability, unlock guidance). Retries once on unlock/auth log
patterns (including French authentication errors).

### Unattended / agent-driven ui-test setup

Two **independent** security layers block on-device XCUITest. Conflating them is the common mistake.

| Gate | Where | Symptom | Fix |
|------|-------|---------|-----|
| **1 — Mac Authorization Services** | This Mac | Login password to “Enable UI Automation” | **One-time:** `scripts/enable_unattended_uitest.sh` (sudo admin password once; persists across reboots) |
| **2 — iPhone unlock handshake** | Paired iPhone | “device was not unlocked”, auth error 12, `Failed to initialize for UI testing` | Wake + **unlock the phone once** when the runner attaches; it may auto-lock again after |
| **3 — iPhone passcode (iOS 15+)** | Paired iPhone | Passcode/Touch ID to authorize UI automation (~daily) | **No supported bypass** with passcode ON — see options below |

Diagnose everything:

```sh
scripts/ios_device.sh uitest-doctor
scripts/ios_device.sh uitest-doctor --enable-gate1   # same as enable_unattended_uitest.sh
```

**Fully unattended ui-test** on local hardware (Apple’s constraints):

1. Close **Mac Gate 1** (`enable_unattended_uitest.sh`).
2. On a **dedicated desk test iPhone**, remove the device passcode (Settings → Face ID & Passcode) — the CI device-farm pattern Apple engineers describe on the forums. Re-enable passcode when the phone leaves the desk.
3. Keep Developer Mode + “Enable UI Automation” (Settings → Developer) on, iPhone Mirroring connected, phone **awake and unlocked** when `ui-test` starts.

If company policy forbids removing the passcode, the realistic options are: unlock the phone once before the first ui-test of the day (~daily Apple prompt), or use **`scripts/ios_device.sh bench`** for unattended real-engine validation (headless autorun — no XCUITest auth).

`ui-test` fails fast when Mac Gate 1 is still open (unless `--skip-uitest-doctor`). Cross-link macOS Accessibility gates: [`macos-testing.md`](macos-testing.md) § UI test machine setup.

`Tests/VocelloiOSUITests/` (target `VocelloiOSUITests`, host `VocelloiOS`):
- `VocelloUITestApp.swift` — shared warm-app coordinator (real engine); resets to Studio between cases.
- `VocelloUITestObserver.swift` — target-level retain/release across warm suites.
- `VocelloiOSSmokeUITests` — launch + 4-tab reachability + Custom/Design/Clone segments.
- `VocelloiOSSheetUITests` — sheet regressions: voice select-and-close, preview-keeps-open,
  language select-and-close, brief confirm-closes.
- `VocelloiOSOnDeviceDownloadUITests` — real URLSession download cancel
  (short paths only; no full ~2.3 GB soak). Self-launches a fresh app instance.
- `VocelloiOSColdGenerationUITests` — cold-launch real-generation test. Kills
  the warm session, launches a fresh app, types in Custom mode, and waits for actual audio
  generation to complete (or skips when the model is missing).
- `VocelloiOSReviewTourUITests` — on-device UI capture tour for baseline diffing.

Smoke and Sheet suites do **not** exercise real audio generation — IA, identifiers, and
sheet behaviour are what's under test. ColdGeneration and OnDeviceDownload prove the real
engine and download stack on hardware.

> The full per-element app map + the canonical driving flows live in
> [`ios-app-guide.md`](ios-app-guide.md); the Studio-specific essentials + gotchas are below.

**Driving identifiers (important):** the Studio surface uses `screenPresenceMarker("screen_generateStudio")`
— a 1pt leaf marker (`Sources/iOS/IOSAccessibility.swift`) so the screen-level id is
queryable **without shadowing** descendant ids. Query `studioChip_*`, `textInput_*`, and
`textInput_generateButton` directly. Inside bottom-sheet overlays the elements keep their
own ids (`bottomSheet_close`, `voicePickerRow_*`, `voicePickerPreview_*`, `languagePicker_*`,
`voiceBrief_editor`, `voiceBrief_confirm`). Tab buttons (`rootTab_*`) expose an `isSelected`
trait. See `VocelloiOSSheetUITests.swift` for the helper patterns.

Run via the script (preferred) or directly — always pass `-derivedDataPath build/ios`:

Always pass `-derivedDataPath build/ios` so builds reuse **one**
tree (one `SourcePackages`) and don't pollute the global `~/Library/Developer/Xcode/DerivedData`:

```sh
# Device — default trio (Smoke + Sheet + OnDeviceDownload):
export QWENVOICE_DEVELOPMENT_TEAM=<team-id>
scripts/ios_device.sh ui-test
# Cold generation soak (skips when Speed model not installed):
scripts/ios_device.sh ui-test --cold
# Direct xcodebuild (after build-for-testing + install):
xcodebuild test-without-building -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'id=<device-udid>' -derivedDataPath build/ios -allowProvisioningUpdates
```

The UI-test target is wired into the `VocelloiOS` scheme's `test` action (and built only
for `test`, so the foundation compile-safety build stays focused on the app).

`accessibilityIdentifier`s are stable surface area (`.agents/ios-engineer.md` "Conventions") — keep them
through refactors; the XCUITest suites depend on them.

---

## 3. On-device quality lanes (testing overhaul)

The driver is organized into lanes — one verb each — built on the headless harness + the
warm-app XCUITest coordinator. All on-device, observed via iPhone Mirroring (OLED-safe).

**Lane → tool map**

| Lane | Verb | Captures / proves | Deeper analysis |
|------|------|-------------------|-----------------|
| Test | `test` / `ui-test` | Smoke + Sheet + OnDeviceDownload on device | `axiom:test-runner` on the `.xcresult` |
| Crash | `crashes` | MetricKit crash/hang diagnostics (in-app `IOSCrashObserver`) | `axiom:crash-analyzer` / `xcsym` vs the build dSYM |
| Debug | `debug` / `logs` | attached stdout + the LLDB attach command (`get-task-allow` build) | `./scripts/ios_device.sh debug`; Axiom `build-fixer` |
| Profile | `profile` | Instruments/xctrace trace over the engine's `OSSignpost` intervals | `axiom:performance-profiler` / `xcprof analyze` |
| Review | `review` | XCUITest screenshot tour of the key screens | `screenshot-validator` subagent / manual diff vs `docs/ios-review-baselines/` |
| Gate | `gate` | preflight → test → crashes → single verdict | — |

**Crash lane.** `IOSCrashObserver` (`Sources/iOSSupport/Services/IOSCrashObserver.swift`)
subscribes to MetricKit crash/hang diagnostics + an `NSException` handler and writes them
to the pullable diagnostics dir; `build` preserves the `.dSYM` under `build/ios/dsyms/`;
`crashes` pulls + symbolicates via `xcsym` (or the `axiom:crash-analyzer` agent).
`crashes --test` deliberately crashes (`QVOICE_IOS_CRASH_TEST`) to verify capture +
symbolication end-to-end. (MetricKit delivers on its periodic cycle, so the self-test may
need a short wait, or fall back to Xcode → Window → Devices and Simulators → Device Logs.)

**Debug lane.** `VocelloiOS.entitlements` carries `get-task-allow` (dev only — drop before
App Store), so `debug` can attach LLDB (`process attach --name Vocello --device <udid>`, or
Xcode → Debug → Attach to Process). `logs` retains the attached-launch stdout
(incl. `[autorun]`/`[QVoiceiOSApp]` prints) to `build/ios-logs/<run>.log`.

**Profile lane.** `profile [spec]` records an Instruments/xctrace trace (default `Time
Profiler`; override via `QVOICE_IOS_PROFILE_TEMPLATE` / `QVOICE_IOS_PROFILE_DURATION`)
while `IOSAutorunHarness` runs one generation, then cross-references the in-app telemetry.
The engine emits `OSSignpost` intervals under `com.qwenvoice.engine` /
`com.patricedery.vocello` — use a signpost-bearing template to capture them.

**Review lane.** `VocelloiOSReviewTourUITests` navigates the key screens + a sheet and
screenshots each (XCUITest `app.screenshot()` — no Mirroring chrome). `review` gathers the
captures + prints each baseline pair for a vision-MCP diff; `review --baseline` seeds the
committed `docs/ios-review-baselines/`. The tour doubles as an a11y reachability pass
(every screen reached via a hittable, identified control).

**Burn-in policy (hard constraint).** iPhone Mirroring is kept on so the device screen
stays dark/locked — headless lanes (`bench`/`profile`/`crashes`/`logs`) never light it.
The UI-review tour is **capture-and-dismiss**: each sheet is opened only long enough to
screenshot, then closed — never dwell on a static high-contrast screen.

---

## Verification ladder

| Level | Command | Proves |
|-------|---------|--------|
| Compile (app) | `scripts/build_foundation_targets.sh ios` | the in-process engine + harness compile |
| Compile (UI test) | `xcodebuild build-for-testing -scheme VocelloiOS -destination 'generic/platform=iOS'` (CI) or `-destination 'id=<udid>'` (device) | the test target compiles + is wired |
| CI compile check | `.github/workflows/ci.yml` `ios-compile-check` job | VocelloiOS + VocelloiOSUITests compile on push/PR |
| UI smoke (device gate) | `scripts/ios_device.sh ui-test` (or `test`) | Smoke + Sheet + OnDeviceDownload on hardware |
| UI review | `scripts/ios_device.sh review` | screenshot tour vs `docs/ios-review-baselines/` |
| Pre-merge gate | `scripts/ios_device.sh gate` | preflight → test → crashes → single verdict |
| Interactive UI review | `scripts/ios_device.sh launch` + `scripts/ios_device.sh shot <path>` | the full UI renders over iPhone Mirroring for visual review |
| On-device proof | `scripts/ios_device.sh bench "custom:speed:…"` | real generation, entitlement/memory headroom, RTF/`audioQC` |

## Still deferred

A signed-IPA / TestFlight distribution lane (needs the iOS Distribution cert + an
`archive-ios` CI job). On-device proof is **not** a public-release blocker (macOS-first;
see `AGENTS.md`).
