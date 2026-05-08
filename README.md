# Vocello Preview

Vocello is the next local, private voice-generation app for Mac. It turns text into natural speech on your Apple Silicon Mac, with Custom Voice, Voice Design, and Voice Cloning built around a native Mac experience.

The app is in transition from the current public name, **QwenVoice**, to the next major Mac release, **Vocello**. The project is active, but the safe public download today is still QwenVoice v1.2.3.

> **Safe download today:** download [QwenVoice v1.2.3](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3). The experimental 2.0 RC1 / Vocello build has been withdrawn because voice quality and reliability needed more work. A new Vocello release will be published only after those issues are resolved.

## Preview

<img width="1868" height="1676" alt="QwenVoice screenshot" src="https://github.com/user-attachments/assets/311ea30b-9196-4f36-93f4-5db439c5a2ba" />

## Project Status

| Status | What it means for you |
|---|---|
| **Available now: QwenVoice v1.2.3 for Mac** | This is the current stable public download. Use it if you want a working app today. |
| **Coming next: Vocello for macOS 26** | Vocello is the next major Mac version. It is being rebuilt with stronger voice quality, clearer English diction, and more reliable full-length output before another public download appears. |
| **In development: Vocello for iPhone** | The iPhone app is maintained in this repository, but it is not a public download yet. When ready, it will ship through the App Store or TestFlight, not GitHub Releases. |

## Download QwenVoice Today

Download the current public release from [QwenVoice v1.2.3](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3).

Choose the DMG that matches your Mac:

- `QwenVoice-macos26.dmg` for macOS 26
- the legacy macOS 15 package on the release page if you are not on macOS 26 yet

Then open the DMG, drag the app to `/Applications`, open the app, download a voice model from the Models screen, and generate speech.

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

## What Is Changing

QwenVoice v1.2.3 remains the stable public app. Vocello is the next name and direction for the Mac app.

The removed 2.0 RC1 build was an early Vocello-branded prerelease. It showed the direction of the project, but it was not good enough for normal users: some outputs had quality, cadence, pronunciation, or truncation problems. That release has been withdrawn so people do not accidentally download a build that can disappoint them.

The next public Vocello build will focus on:

- natural tone and English diction
- complete output with no missing words
- reliable model downloads and playback
- a simpler, native Mac workflow

## Requirements

For the current stable QwenVoice v1.2.3 release, use the release notes and DMG names on the [v1.2.3 release page](https://github.com/PowerBeef/QwenVoice/releases/tag/v1.2.3) as the source of truth.

For the in-development Vocello code on `main`:

- macOS 26.0+
- Apple Silicon
- Xcode 26.0
- XcodeGen

## For Developers

The `main` branch contains the in-development Vocello codebase. It is useful for contributors and testers, but normal users should use the stable v1.2.3 release until the next public Vocello build is published.

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
