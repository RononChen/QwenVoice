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
couldn't run headlessly. See also: generation runs **in-process in the app** (since commit
`7822a8a`) — a non-UI ExtensionKit extension is Jetsam-capped at a tiny per-process budget
the entitlement does **not** raise, so it could never load the model; the app process *does*
get the raised limit. The dead extension target was removed entirely (it never ran on
hardware; git history preserves it).

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

The increased-memory entitlement is enabled + verified on the app's App ID (the engine is
in-process — there is no extension App ID) — see
[`ios-increased-memory-entitlement-request.md`](ios-increased-memory-entitlement-request.md).

- **Screen mirroring (observation, on by default):** device commands auto-start macOS **iPhone Mirroring**
  so you watch the live app on the Mac while the phone stays **locked + screen-dark (OLED burn-in safe)**.
  iPhone Mirroring also keeps a *locked* device reachable to `devicectl` (a locked phone without mirroring
  goes "unavailable"). **Lock the phone once** per session (Apple exposes no Mac-side lock CLI; it then stays
  locked while mirroring) or rely on Auto-Lock — iPhone Mirroring reconnects when the phone auto-locks. Opt
  out with `QVOICE_IOS_NO_MIRROR=1`; start it manually with `scripts/ios_device.sh mirror`.

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
| `pull [dest]` | `devicectl device copy from --domain-type appDataContainer --source Library/Caches/Vocello/diagnostics` (the app's pullable mirror — the App-Group container is NOT devicectl-readable). Default dest `build/ios-diagnostics`. |
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

Always pass `-derivedDataPath build/ios` so device + simulator builds share **one**
tree (one `SourcePackages`) and don't pollute the global `~/Library/Developer/Xcode/DerivedData`:

```sh
# Simulator
xcodebuild test -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/ios

# Device
export QWENVOICE_DEVELOPMENT_TEAM=<team-id>
xcodebuild test -project QwenVoice.xcodeproj -scheme VocelloiOS \
  -destination 'id=<device-udid>' -derivedDataPath build/ios -allowProvisioningUpdates
```

The UI-test target is wired into the `VocelloiOS` scheme's `test` action (and built only
for `test`, so the foundation compile-safety build stays focused on the app). On the
simulator the app uses `IOSSimulatorTTSEngine` (a fake), so the smoke needs no model and
no Metal — the IA + identifiers are what's under test.

`accessibilityIdentifier`s are stable surface area (CLAUDE.md "Conventions") — keep them
through refactors; the smoke + any agent UI checks depend on them.

---

## 3. Simulator UI review (the fake engine)

For **visual UI work** (layout, chrome, flows, keyboard behavior) the Simulator is the right
tool — no device, no signing, no models, no Metal/MLX. On the simulator the app swaps to
`IOSSimulatorTTSEngine` at compile time (`#if targetEnvironment(simulator)` in
`IOSAppBootstrap`), a fake that fabricates real per-mode WAV audio and drives the full
generation lifecycle. (Generation *quality* still needs the device harness above — the fake
is for exercising the UI, not the model.)

### `scripts/ios_sim.sh` — the simulator counterpart to `ios_device.sh`

No `QWENVOICE_DEVELOPMENT_TEAM` needed (unsigned). Shares the one `build/ios` tree.

| Verb | What it does |
|------|--------------|
| `doctor` | Xcode + simulator preflight; resolves the target sim; turns the **software keyboard on** (disconnects the hardware keyboard so the on-screen keyboard + the Studio "Done" accessory bar render). |
| `build` | Build for the `iphonesimulator` SDK (`-Onone`, `CODE_SIGNING_ALLOWED=NO`); greps the log for `** BUILD SUCCEEDED **`. |
| `install` | Boot the sim + `open -a Simulator` + `simctl install` the built app. |
| `run [--no-seed] [--rebuild]` | `build-if-stale → boot → install → launch SEEDED`, then open the Simulator window. **Seeded** = fake models installed (Studio shows "Generate", not "Install") + sample voices + history, so every surface is populated. `--no-seed` launches the empty / onboarding state. |
| `shot [path]` | `simctl io … screenshot` the booted sim (default `build/ios-sim-shot.png`). |
| `ui-test` | Run the `VocelloiOSUITests` smoke (§2) on the sim. |

```sh
scripts/ios_sim.sh run            # build + launch the seeded app; Simulator opens for clicking
scripts/ios_sim.sh shot out.png   # capture what's on screen
scripts/ios_sim.sh ui-test        # the launch/navigation smoke
```

Target a specific sim with `QVOICE_IOS_SIM=<name|udid>` (else it auto-picks a booted iPhone,
then the newest-iOS iPhone, preferring Pro). Tune the seed with the env the fake engine reads:

| Env var | Effect |
|---------|--------|
| `QVOICE_SIM_FAKE_MODELS` | `all` (default) / `custom` / `design` / `clone` / `<ids>` / `none` — which models report installed. |
| `QVOICE_SIM_SEED_DATA` | `voices,history` (default) — seed a saved voice + a History entry. |
| `QVOICE_SIM_BACKEND_SCENARIO` | `success` (default) / `slow` (watch progress UI) / `fail` (error-state UI). |
| `QVOICE_SIM_BACKEND_DELAY_MS` | Override the fake generation delay. |

**Software keyboard:** the `ConnectHardwareKeyboard=false` default takes effect on the next
Simulator launch — if Simulator is already open, quit + relaunch it (or toggle I/O ▸ Keyboard ▸
Connect Hardware Keyboard off) so the on-screen keyboard appears.

### Agent-driven UI checks (Claude)

To verify a UI change myself I can drive the sim two ways, both reusing `build/ios`:
- **CLI**: `scripts/ios_sim.sh run` then `scripts/ios_sim.sh shot <path>` and read the screenshot.
- **`xcodebuildmcp` MCP**: `build_run_sim` → `screenshot` / `snapshot_ui` (the accessibility tree
  with `elementRef`s) → `tap` / `type_text` to drive a flow. Use real taps — the SwiftUI a11y
  tree is virtualized (e.g. `textInput_textEditor` only materializes after a focus tap). This is
  the sanctioned iOS UI-driving path; **driving the real device via iPhone Mirroring stays
  deprecated** (see [`ui-driving.md`](ui-driving.md)) — *Simulator* driving is fine.

---

## Verification ladder

| Level | Command | Proves |
|-------|---------|--------|
| Compile (app) | `scripts/build_foundation_targets.sh ios` | the in-process engine + harness compile |
| Compile (UI test) | `xcodebuild build-for-testing -scheme VocelloiOS -destination 'platform=iOS Simulator,…' -derivedDataPath build/ios` | the test target compiles + is wired |
| UI smoke | `xcodebuild test -scheme VocelloiOS -destination … -derivedDataPath build/ios` (or `scripts/ios_sim.sh ui-test`) | launch + IA reachable |
| Sim UI review | `scripts/ios_sim.sh run` + `scripts/ios_sim.sh shot` | the full UI renders + is navigable with the fake engine (visual review — no device) |
| On-device proof | `scripts/ios_device.sh bench "custom:speed:…"` | real generation, entitlement/memory headroom, RTF/`audioQC` |

## Still deferred

A signed-IPA / TestFlight distribution lane (needs the iOS Distribution cert + an
`archive-ios` CI job). On-device proof is **not** a public-release blocker (macOS-first;
see CLAUDE.md "Release & iPhone status").
