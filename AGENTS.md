# AGENTS.md — Vocello (QwenVoice)

> Durable onboarding for Codex. **Code wins over docs.** When scope, platform, or gate expectations are unclear, **ask before editing**.
>
> **Active progress:** [`docs/development-progress.md`](docs/development-progress.md) · **Project map:** [`docs/project-map.html`](docs/project-map.html) · **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · **Role playbooks:** [`.agents/`](.agents/)

## What this is

**Vocello** (`QwenVoice` repo): local-first TTS on Apple Silicon — **Qwen3-TTS + MLX**, Swift 6, macOS/iOS 26+. No bundled weights; models download from Hugging Face. Also ships the `vocello` CLI, `scripts/`, benchmarks, and `website/`.

macOS **2.1.0** released; iOS is on-device-capable on `main`, not publicly distributed yet.

## Source of truth

`Sources/` → `project.yml` → `scripts/` → `.github/workflows/release.yml` → `AGENTS.md` → other prose.

Model/speaker schema: [`Sources/Resources/qwenvoice_contract.json`](Sources/Resources/qwenvoice_contract.json). **If code invalidates a doc, update the doc in the same change.**

## Before you edit

1. **Resume active work** — read [`docs/development-progress.md`](docs/development-progress.md) when it exists, then confirm its checkpoint against the current checkout.
2. **Pick a role** — read [`.agents/<role>.md`](.agents/) (backend, iOS, macOS, release-qa, website).
3. **Inspect capabilities** — for relevant tasks, inspect the installed OpenAI plugin and skill inventory before choosing optional tooling. Read every selected skill before use.
4. **Minimal diff** — no drive-by refactors; preserve module boundaries and stable `accessibilityIdentifier` values.
5. **Ask** when the target platform or test scope is ambiguous. Commit/push policy is not
   ambiguous: deterministic verification is sufficient to preserve and share development work.

### After a Codex reinstall

1. Restore a clean `main` from `origin/main`; never discard a dirty tree without reviewing it.
2. Install **and enable** the bundled Computer Use plugin, start a new Codex task, and grant
   attended macOS Accessibility plus Screen & System Audio Recording permissions. Plugin
   installation, plugin enablement, server/skill availability in the new task, and a live helper
   process are separate readiness checks. The same bundled service drives the macOS app and the
   physical iPhone through iPhone Mirroring.
3. Do not manually add a second Computer Use transport. When the installed plugin declares
   `bundledContentVariant=node-repl`, the enabled Node REPL entry is the active server and a
   disabled manifest-matched Computer Use record is an expected inert mirror. Enabling that mirror,
   or retaining stale commands, older helper paths, or conflicting definitions, is invalid.
   Repository scripts and `.agents/skills/` define the project workflow; `~/.codex` remains
   user-scoped state.
4. Run `scripts/macos_agent_ui.sh routing-audit`, `impact`, and the required
   `doctor --suite … --json` checks before frontend acceptance. Full resume sequence:
   [`docs/development-progress.md`](docs/development-progress.md).

> **Active Computer Use block:** helper `26.708.1000366 (1000366)`, UUID `61C0…9236`, is
> known-bad for normal Vocello frontend suites. Do not start macOS or iOS quick/full/benchmark work
> with that helper. Only the single-observation diagnostic in
> [`computer-use-failure-analysis.md`](docs/reference/computer-use-failure-analysis.md) is allowed
> until its resumption criteria pass.

## Hard rules

| Rule | Detail / verify |
| --- | --- |
| **iOS runtime/UI = physical device + Computer Use** | Never use Simulator. `$vocello-ios-ui-qa` drives the paired iPhone only through bundled Computer Use and iPhone Mirroring; scripts provide deterministic device/telemetry proof. The generic physical-device SDK compile needs no phone. `scripts/ios_device.sh gate` is strict explicit acceptance/release proof. |
| **`project.yml`, not pbxproj** | After edit: `./scripts/regenerate_project.sh` + `./scripts/check_project_inputs.sh`. iOS resources: `sources:` + `buildPhase: resources` (not `resources:`). |
| **Release-only config** | Debug via `DebugMode.isEnabled` (`QWENVOICE_DEBUG=1`); `#if DEBUG` for test/sim scaffolding only. |
| **MLX pins in lockstep** | `mlx-swift` + `mlx-swift-lm` together; no Core ML. → [`.agents/backend-mlx.md`](.agents/backend-mlx.md) |
| **Engine invariants** | Prewarm slots, event streams, cancellation, memory policy → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| **Privacy** | No PII in tracked user-facing files. |
| **All UI = bundled Computer Use** | `$vocello-macos-ui-qa` drives `build/Vocello.app`; `$vocello-ios-ui-qa` drives the paired iPhone through `com.apple.ScreenContinuity`. No XCTest UI runner, alternate desktop-control MCP, or coordinate bridge is active. Scripts validate typed evidence and attestations. |
| **One shared XcodeBuildMCP** | OpenAI Build iOS Apps supplies the shared server; Build macOS Apps consumes it. Call `session_show_defaults`, select `macos` or `ios-device`, and set a physical-device ID only at runtime. Never configure a second server. Repository scripts remain the final gate. |
| **Codex/ChatGPT Desktop only** | This repository has no compatibility layer for another agent IDE. Codex/ChatGPT Desktop, installed OpenAI plugins, repository skills, and repository scripts are the supported development environment. |
| **Development publishing is deterministic-only** | Commits, pushes, pull requests, and ordinary merges require deterministic verification only. Missing Computer Use, model, physical-device, or UI-attestation evidence must never block preserving or sharing development work. UI impact is advisory until explicit frontend QA or a platform-specific release. |

Every active invariant must live here, in a role playbook, or in an authoritative reference document.

## Workflows

### Implement a change

```sh
./scripts/regenerate_project.sh      # if project.yml changed
./scripts/check_project_inputs.sh
./scripts/build.sh build             # macOS compile check
./scripts/build_foundation_targets.sh ios   # iOS-only compile safety
```

**Verify:** exit 0 (build is the typecheck; no formatter/linter).

### Development verification — macOS

```sh
scripts/macos_test.sh test            # Core + XPC transport + owned Qwen3 runtime tests
./scripts/build.sh build
scripts/macos_agent_ui.sh impact      # advisory frontend scope; does not validate attestations
```

**Verify:** deterministic commands exit 0. This is enough to commit, push, open a pull request,
and merge ordinary development work. Do not invoke or wait for Computer Use solely to publish a
development checkpoint.

### Development verification — iOS

```sh
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh ios   # physical-device SDK compile safety; no device/UI
scripts/ios_agent_ui.sh impact              # advisory frontend scope
```

**Verify:** deterministic commands exit 0. A paired phone, installed models, Computer Use, and an
iOS UI attestation are not development-publishing prerequisites.

### Explicit frontend acceptance

Run these strict lanes only when the user explicitly requests frontend/device acceptance or when
preparing the corresponding platform release:

```sh
# macOS: run every suite reported by impact, then validate the strict acceptance gate.
scripts/macos_agent_ui.sh impact
scripts/macos_test.sh gate

# iOS: paired physical iPhone + Computer Use through iPhone Mirroring.
scripts/ios_agent_ui.sh impact
scripts/ios_device.sh preflight
scripts/ios_device.sh gate
```

These `gate` commands intentionally remain strict. They are acceptance/release proof, not commit,
push, pull-request, or ordinary-merge checks.

Computer Use generation is additionally gated by visible Settings state: Custom, Design, and
Clone Speed must show installed/ready, Generate must be enabled, and the required clone voice must
be visible before any take. `models ensure` is explicit repair/bootstrap, never a substitute for
that observation. Because `telemetry-overhead` performs real seeded generation, it now refuses to
start unless a current `full` Computer Use attestation proves the visible `model-readiness`
scenario passed; it uses only the read-only model integrity check and never runs `models ensure`.

### Language-path verification (Phases 1–3)

```sh
scripts/macos_test.sh core-test                              # Phase 1 — macOS unit tests (no models)
python3 scripts/test_check_language_hints.py                 # offline hint-gate fixtures
python3 scripts/test_check_language_output.py                # offline output-gate fixtures
scripts/macos_test.sh lang-bench --subset quick              # Phase 2 — macOS CLI hint gate (needs models)
scripts/ios_device.sh lang-bench --subset quick --label "…"  # Phases 2–3 — on-device hint + output (needs Speed)
scripts/ios_device.sh lang-bench --subset full --label "…"   # full 19-cell matrix (hint + output gates)
```

**Verify:** core-test + offline fixtures exit 0. iOS lang-bench must print **`hint_gate=PASS`**
and **`output_gate=PASS`** (quick: 6/6 output cells; full: 18/18 — negative control is hint-only).
`check_language_hints.py` matches `notes.languageHint` to `config/language-bench-matrix.json`.
Phase 3 adds locale-locked ASR via `check_language_output.py`. **DE/ES/ZH/JA output cells**
require on-device Speech assets — setup: [`language-bench.md`](docs/reference/language-bench.md)
§ Phase 3 prerequisites (dictation languages + Wi‑Fi download on the phone).

### Release QA

Release acceptance is platform-specific and unconditional for the artifact being shipped:

- macOS packaging requires fresh macOS `full` and `benchmark` Computer Use evidence plus
  deterministic/runtime proof through `scripts/macos_test.sh release-readiness`.
- iOS archive/TestFlight requires fresh iOS frontend evidence through
  `scripts/ios_agent_ui.sh release-check` before signing or archiving.
- macOS UI evidence never blocks an iOS archive, and iOS UI evidence never blocks a macOS package.

```sh
QWENVOICE_DEBUG=1 ./build/vocello bench --modes clone --variants speed \
  --lengths short,medium,long --warm 3 --voice <voice> --label "release-QA" --ledger
```

**Verify:** the applicable platform release check, listening pass, and telemetry compare succeed →
[`docs/reference/benchmarking-procedure.md`](docs/reference/benchmarking-procedure.md).

## Key paths

| Path | Purpose |
| --- | --- |
| `Sources/QwenVoiceCore/` | Engine, download, generation semantics |
| `Sources/QwenVoiceBackendCore/` | MLX/audio primitives |
| `Sources/QwenVoiceNative/`, `EngineService/`, `EngineSupport/` | macOS XPC stack |
| `Sources/iOS/`, `iOSSupport/` | iOS app |
| `Sources/SharedSupport/` | Shared player, persistence, transcriber |
| `scripts/*.sh` | Build, test, release |
| `config/language-bench-*.json` | Language hint bench corpus + matrix |
| `.agents/skills/vocello-macos-ui-qa/` | Sole macOS frontend-driving workflow (Codex Computer Use) |
| `.agents/skills/vocello-ios-ui-qa/` | Sole iOS frontend-driving workflow (Computer Use + iPhone Mirroring) |
| `scripts/macos_agent_ui.sh`, `config/macos-*.json` | Session/evidence harness, scenario and impact contracts |
| `scripts/ios_agent_ui.sh`, `config/ios-*.json` | iOS Computer Use session/evidence harness and contracts |
| `Tests/VocelloCoreTests/`, `Tests/VocelloEngineIntegrationTests/` | Deterministic Core/output/telemetry and XPC transport tests |
| `docs/project-map.html` | Canonical interactive feature, component, dependency, and workflow map |
| `docs/development-progress.md` | Active checkpoint, verified work, pending gates, and Codex reinstall/resume route |
| `website/` | Marketing → [`website/AGENTS.md`](website/AGENTS.md) |

Interactive feature/module map: [`docs/project-map.html`](docs/project-map.html). Deeper lifecycle
narrative: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Commands (common)

```sh
./scripts/build.sh run
./scripts/build.sh cli --help
scripts/macos_test.sh core-test
scripts/macos_test.sh lang-bench --subset quick
scripts/macos_test.sh test
scripts/macos_test.sh telemetry-overhead
scripts/macos_test.sh ui-report --suite quick|full|benchmark
scripts/ios_device.sh test
scripts/ios_device.sh lang-bench --subset quick
scripts/macos_test.sh review [--report <run>]
scripts/ios_device.sh review [--baseline]
```

Full lanes: [`docs/reference/macos-testing.md`](docs/reference/macos-testing.md), [`docs/reference/ios-device-testing.md`](docs/reference/ios-device-testing.md).

## Codex tool routing

**Scripts first** for build/test and deterministic proof. macOS frontend acceptance is the explicit
exception: the repository Computer Use skill drives the real UI while the shell harness supplies
typed, reproducible evidence. Before using a skill/plugin, read its instructions and keep actions
inside the selected role's ownership boundary. User-scoped Codex configuration and plugin state
are never repository sources of truth.

| Work | Start here / use |
| --- | --- |
| MLX / engine | `.agents/backend-mlx.md`, `docs/reference/mlx-guide.md`, shell scripts |
| iOS | `.agents/ios-engineer.md`, `docs/reference/ios-app-guide.md`, `scripts/ios_device.sh` on a physical device only |
| macOS / XPC | `.agents/macos-engineer.md`, `docs/reference/macos-app-guide.md`, macOS Codex skills where relevant |
| Scripts / CI / GitHub | `.agents/release-qa-engineer.md`, shell scripts, installed GitHub integration |
| Website | `.agents/website-engineer.md`, Browser for localhost verification |
| macOS frontend QA | `$vocello-macos-ui-qa quick|full|benchmark|destructive` + `scripts/macos_agent_ui.sh`; exact `build/Vocello.app` only |
| iOS frontend QA | `$vocello-ios-ui-qa quick|full|benchmark` + `scripts/ios_agent_ui.sh`; physical iPhone through iPhone Mirroring |
| External systems and current APIs | Relevant installed Codex skill/plugin or connector; use authoritative documentation |

## Active / deep reading

| Doc | When |
| --- | --- |
| [`docs/development-progress.md`](docs/development-progress.md) | **Active checkpoint** — resume state, verified work, and remaining gates |
| [`docs/reference/ios-ui-reference.md`](docs/reference/ios-ui-reference.md) | iOS screen map, stable identifiers, states, and physical-device review expectations |
| [`docs/reference/ui-smoke-runbooks.md`](docs/reference/ui-smoke-runbooks.md) | Codex-native macOS, iOS, and website frontend acceptance index |
| [`docs/reference/computer-use-failure-analysis.md`](docs/reference/computer-use-failure-analysis.md) | **Active Computer Use block** — helper fingerprint, evidence, diagnostic-only route, and suite-resumption criteria |
| [`docs/reference/language-bench.md`](docs/reference/language-bench.md) | language hint + output bench (Phases 1–3) |
| [`docs/reference/benchmarking-procedure.md`](docs/reference/benchmarking-procedure.md) | bench protocol |
| [`docs/reference/ios-device-probe.md`](docs/reference/ios-device-probe.md) | layered device-state / mirror probe |
| [`docs/reference/`](docs/reference/) | subsystem guides |

## Release & security (summary)

- **macOS:** GitHub release → notarized DMG ([`.github/workflows/release.yml`](.github/workflows/release.yml)).
- **iOS:** optional TestFlight archive in CI; version in `project.yml`.
- **Website:** Vercel from `website/`.
- **Security:** macOS sandbox off (MLX); iOS App Group + increased memory limit; local-first data.

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md).
