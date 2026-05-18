# Contributing

Thanks for helping with QwenVoice/Vocello. This repo is in a macOS-first release track, so contributor work should keep the next public macOS release clean while keeping iPhone compile-safe.

## Source Of Truth

When facts disagree, trust:

1. `Sources/`
2. `project.yml`
3. `scripts/`
4. maintained docs under `docs/reference/`
5. other prose docs

`Sources/Resources/qwenvoice_contract.json` is the source of truth for model, speaker, variant, output, Hugging Face revision, and required-file metadata.

Current model-selection policy:

- macOS exposes both `Speed / 4-bit` and `Quality / 8-bit` variants for Custom Voice, Voice Design, and Voice Cloning.
- 8 GB/floor Macs default to and recommend Speed; mid/high-memory Macs default to and recommend Quality.
- Mac users may select either installed variant per generation mode.
- iPhone remains Speed-only.
- Legacy base model IDs resolve to the hardware-recommended variant; variant-specific IDs own model status, download, repair, delete, and install metadata.

## Workflow

- Work on `main` unless the maintainer asks for a branch.
- Edit `project.yml` for project-structure changes, then run `./scripts/regenerate_project.sh`.
- Do not reintroduce a repo-owned Python backend, Python setup path, or standalone CLI surface.
- Keep macOS release behavior aligned with `Vocello.app` and `Vocello-macos26.dmg`.
- Keep iPhone compile-safe, but do not treat iPhone release proof as blocking for the current milestone.

## Useful Checks

Start with the static validator:

```sh
./scripts/check_project_inputs.sh
```

Then run the relevant build proof:

```sh
./scripts/build_foundation_targets.sh macos
./scripts/build_foundation_targets.sh ios
```

Behavioral testing is local-only. The repo has no CI and no XCTest targets as of May 2026, but it does maintain a Claude Code–driven smoke/bench harness in `scripts/uitest.sh` plus the runbooks under `docs/reference/`. For Debug behavior, launch with `./scripts/build.sh run` or `scripts/uitest.sh prep`; Debug uses the persistent `QwenVoice-Debug` store so models and history survive rebuilds. For fresh local release behavior, launch `build/Release/Vocello.app` only after `./scripts/release.sh`; each packaged local Release app receives its own clean app-support folder and preferences suite. Any new test framework, CI workflow, QA shell surface, or parallel benchmark harness should be a deliberate, scoped decision.

For current macOS release signoff, the maintained local loop is documented in `docs/reference/release-readiness.md`.

## Runtime Boundaries

- `Sources/QwenVoiceCore/` owns shared engine semantics.
- `Sources/QwenVoiceEngineService/` hosts the active macOS XPC runtime.
- `Sources/QwenVoiceNative/` owns the macOS app-facing engine proxy/store/client layer.
- `Sources/iOSEngineExtension/` keeps heavy iPhone generation work outside the iPhone UI process.
