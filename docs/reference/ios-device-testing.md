# iOS on-device testing — the hybrid method

The durable replacement for the deprecated screen-mirror UI-driving approach (see
[`ui-driving.md`](ui-driving.md) → "iOS via iPhone Mirroring — DEPRECATED"). Two
complementary tools, neither of which drives the UI by pixels:

1. **Headless generation harness** — the on-device analog of `vocello bench`. Launch
   the app over `devicectl` with an autorun spec; the in-app `IOSAutorunHarness` runs
   one generation with **no UI interaction**, writes telemetry + a completion sentinel
   into the App-Group container, and `scripts/ios_device.sh` pulls them back and
   summarizes. This is the real on-device entitlement/memory/RTF proof.
2. **Thin XCUITest UI-flow smoke** (`VocelloiOSUITests`) — asserts the app launches and
   the 4-tab IA + Studio composer/mode-control are reachable, off the stable
   `accessibilityIdentifier`s. Runs on a simulator (fast, no signing) or the device.

Why this exists: on-device generation is the never-CI-tested path (real Jetsam, real
model download, the in-process engine + increased-memory entitlement). iPhone Mirroring
+ computer-use was flaky for it (focus races, disconnects, engine-busy rejections) and
couldn't run headlessly. See also: generation moved **in-process in the app** (commit
`7822a8a`) because the `VocelloEngineExtension` non-UI extension is Jetsam-capped and the
entitlement does **not** raise that cap — the app process does get the raised limit.

---

## Prerequisites

- **Xcode 26** (`devicectl` / CoreDevice).
- **A paired iPhone 15 Pro or newer**, **Developer Mode ON**, Mac trusted (USB). Verify
  on the device itself the first time.
- `export QWENVOICE_DEVELOPMENT_TEAM=<your-apple-team-id>` — matches `project.yml`'s
  `$(QWENVOICE_DEVELOPMENT_TEAM)`. **Never commit the team id.**
- Optional `export QVOICE_IOS_DEVICE_ID=<id|name|udid>` to pin the target device;
  otherwise the driver auto-discovers the single connected device.
- The **Speed model must be downloaded on the device once** (Settings → Model
  Downloads, or just run the app and install it) — the harness loads it; it does not
  download. A missing model surfaces as a clean sentinel error, not a hang.

The increased-memory entitlement is enabled + verified on both App IDs — see
[`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md).

---

## 1. Headless generation harness

### `scripts/ios_device.sh`

A small `devicectl` driver. The signing team comes from `$QWENVOICE_DEVELOPMENT_TEAM`;
the device is auto-discovered or pinned via `$QVOICE_IOS_DEVICE_ID` (neither committed).

| Verb | What it does |
|------|--------------|
| `doctor` | Environment + device preflight (Xcode, team env, device, built-app entitlement). |
| `build` | Signed device build, `-Onone`, automatic signing (`-allowProvisioningUpdates`) → `build/ios-device/…/Vocello.app`. |
| `install` | `devicectl device install app` the built app. |
| `launch [spec]` | Launch via `devicectl`. With a spec → sets the autorun + telemetry env; prints the generated `runID` on stdout. Without → a plain launch. |
| `pull [dest]` | `devicectl device copy from --domain-type appGroupDataContainer` the `diagnostics/` tree (default `build/ios-diagnostics`). |
| `bench [spec] [--label "note"]` | The full loop: `build → install → launch-with-autorun → poll the sentinel → pull diagnostics → summarize`. Exits non-zero if the generation failed. |

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
memory-conscious), so a clone autorun may fail until clone-in-process is enabled — that
failure is recorded, not crashed.

### Where the data lives + how it's pulled

Both the engine telemetry and the sentinel land in the **App-Group container**
(`AppPaths.appSupportDir` = `group.com.patricedery.vocello.shared`), under `diagnostics/`.
`pull`/`bench` copy it with:

```sh
xcrun devicectl device copy from --device <id> \
  --domain-type appGroupDataContainer \
  --domain-identifier group.com.patricedery.vocello.shared \
  --source diagnostics --destination build/ios-diagnostics
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

## 2. Thin XCUITest UI-flow smoke

`Tests/VocelloiOSUITests/VocelloiOSSmokeUITests.swift` (target `VocelloiOSUITests`, host
`VocelloiOS`). Intentionally shallow — it does **not** generate audio (that's the harness
above). It launches, dismisses onboarding if present, and asserts:

- the 4 tabs navigate (`rootTab_studio|voices|history|settings` → their screens);
- the Studio composer (`textInput_textEditor`) + Custom/Design/Clone mode control
  (`generateSectionPicker`, `generateSection_custom|design|clone`) are present.

Run on a simulator (fast, no signing) or the device:

```sh
# Simulator
xcodebuild test -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Device
export QWENVOICE_DEVELOPMENT_TEAM=<team-id>
xcodebuild test -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'id=<device-udid>' -allowProvisioningUpdates
```

The UI-test target is wired into the `VocelloiOS` scheme's `test` action (and built only
for `test`, so the foundation compile-safety build stays focused on the app). On the
simulator the app uses `IOSSimulatorTTSEngine` (a fake), so the smoke needs no model and
no Metal — the IA + identifiers are what's under test.

`accessibilityIdentifier`s are stable surface area (CLAUDE.md "Conventions") — keep them
through refactors; the smoke + any agent UI checks depend on them.

---

## Verification ladder

| Level | Command | Proves |
|-------|---------|--------|
| Compile (app) | `scripts/build_foundation_targets.sh ios` | the in-process engine + harness compile |
| Compile (UI test) | `xcodebuild build-for-testing -scheme VocelloiOS -destination 'platform=iOS Simulator,…'` | the test target compiles + is wired |
| UI smoke | `xcodebuild test -scheme VocelloiOS -destination …` | launch + IA reachable |
| On-device proof | `scripts/ios_device.sh bench "custom:speed:…"` | real generation, entitlement/memory headroom, RTF/`audioQC` |

## Still deferred

A signed-IPA / TestFlight distribution lane (needs the iOS Distribution cert + an
`archive-ios` CI job). On-device proof is **not** a public-release blocker (macOS-first;
see CLAUDE.md "Release & iPhone status").
