# Vocello Beta 1 for macOS 26

Vocello is a local, private voice-generation app for Apple Silicon Macs. It turns text into natural speech on your Mac, with Custom Voice, Voice Design, and Voice Cloning built around a native macOS experience.

Vocello 2.0.0 beta 1 is now available as a public macOS 26 beta. QwenVoice v1.2.3 remains the stable fallback for users who need macOS 15 support or do not want beta software.

> **Public beta:** download [Vocello 2.0.0 beta 1](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0-beta.1) for macOS 26.
>
> **Stable fallback:** need macOS 15 support or a non-beta build? Download [QwenVoice v1.2.3](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3).

## Preview

<img width="1868" height="1676" alt="QwenVoice screenshot" src="https://github.com/user-attachments/assets/311ea30b-9196-4f36-93f4-5db439c5a2ba" />

## Project Status

| Status | What it means for you |
|---|---|
| **Public beta: Vocello 2.0.0 beta 1 for macOS 26** | This is the new Vocello beta for Apple Silicon Macs on macOS 26. Use it if you want to test the next local-first generation stack. |
| **Stable fallback: QwenVoice v1.2.3 for Mac** | This remains the stable public download, especially for macOS 15 users. |
| **In development: Vocello for iPhone** | The iPhone app is maintained in this repository, but it is not a public download yet. When ready, it will ship through the App Store or TestFlight, not GitHub Releases. |

## Download Vocello Beta 1

Download the public beta from [Vocello 2.0.0 beta 1](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0-beta.1).

Choose:

- `Vocello-macos26.dmg` for the macOS 26 public beta
- `Vocello-macos26.dmg.sha256` if you want to verify the download checksum

Then open the DMG, drag `Vocello.app` to `/Applications`, open the app, install the voice models you want from Settings -> Model downloads, and generate speech.

If you need macOS 15 support, use [QwenVoice v1.2.3](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3) instead.

## What You Can Do

### Custom Voice

Pick a built-in speaker and choose the delivery style. This is the fastest way to turn a script into speech with a consistent voice.

### Voice Design

Describe the voice you want in natural language. For example, you can ask for a warm narrator, a calm guide, or an energetic presenter, then generate your text in that designed voice.

### Voice Cloning

Create speech from a short reference clip. Voice Cloning can use WAV, MP3, AIFF, M4A, FLAC, or OGG input, plus an optional transcript for better accuracy. Only clone voices you own or have permission to use.

## Why Local-First Matters

QwenVoice and Vocello are built for people who want voice generation to happen on their own Mac.

- Speech generation runs on-device after models are installed.
- Your generated audio and history stay in local app storage.
- There is no cloud credit meter for generation.
- You can choose where generated audio files are saved.

Model downloads come from Hugging Face when you install a voice model, but the generation workflow itself is local.

## Beta Notes

Vocello 2.0.0 beta 1 is public beta software. It is suitable for testers who want the new macOS 26 app and understand that voice quality, tone control, model downloads, and performance may still be refined before a stable 2.0 release.

The withdrawn 2.0 RC1 build is not restored or advertised. Beta 1 is a newer public beta with backend hardening, clearer model management, Speed/Quality selection on generation screens, and targeted delivery-control fixes.

QwenVoice v1.2.3 remains available for people who prefer the stable macOS 15-compatible line.

## Requirements

For Vocello 2.0.0 beta 1:

- macOS 26.0+
- Apple Silicon
- voice models installed from Settings -> Model downloads

For the stable QwenVoice v1.2.3 release, use the release notes and DMG names on the [v1.2.3 release page](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3) as the source of truth.

For source builds on `main`:

- Xcode 26.0
- XcodeGen

## For Developers

The `main` branch contains the current Vocello codebase. The public beta release is tagged as [`v2.0.0-beta.1`](https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0-beta.1).

```sh
git clone https://github.com/PowerBeef/QwenVoice.git
cd QwenVoice
./scripts/regenerate_project.sh
open QwenVoice.xcodeproj
```

Useful checks:

```sh
./scripts/check_project_inputs.sh
./scripts/qa.sh validate
./scripts/qa.sh test --layer contract
./scripts/qa.sh test --layer swift
```

More technical details live in the maintained docs:

- [`docs/README.md`](docs/README.md) - documentation index
- [`docs/reference/current-state.md`](docs/reference/current-state.md) - current repo facts
- [`docs/reference/release-readiness.md`](docs/reference/release-readiness.md) - release policy and signoff gates
- [`docs/reference/privacy-storage.md`](docs/reference/privacy-storage.md) - local storage and deletion details
- [`docs/qwen_tone.md`](docs/qwen_tone.md) - tone and prompt-writing guidance
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - contributor workflow

## License

QwenVoice is available under the [MIT License](LICENSE).

## Credits

QwenVoice and Vocello build on:

- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- [MLX](https://github.com/ml-explore/mlx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
