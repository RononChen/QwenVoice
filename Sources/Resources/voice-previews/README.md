# Voice preview samples

This directory holds short (~2-3 s) per-voice WAV samples played by the iOS
Voice Picker sheet when the user taps a row's preview button.
`IOSVoicePreviewPlayer` (`Sources/iOS/Sheets/IOSVoicePreviewPlayer.swift`)
loads `Bundle.main.url(forResource: voiceID, withExtension: "wav",
subdirectory: "voice-previews")`.

## Required files

One WAV per speaker id from `Sources/Resources/qwenvoice_contract.json`:

- `aiden.wav` — English, male
- `ryan.wav` — English, male
- `vivian.wav` — Chinese, female
- `serena.wav` — Chinese, female

Add more files as new speakers join the contract — `IOSVoicePreviewPlayer`
matches on `voiceID`, so dropping a new WAV in is the only step.

## Format

- 24 kHz mono Int16 PCM (the engine's canonical format —
  `Qwen3TTSRuntimeProfile.canonicalSampleRate`)
- ~2-3 s duration
- `afinfo {file}.wav` to verify before commit

## Generation recipe

For each speaker, generate one sample via the macOS Vocello.app (Debug
build) in **Custom Voice** mode:

| Speaker | Mode | Delivery | Prompt |
|---|---|---|---|
| aiden, ryan | Custom | Neutral | `Hello, this is a sample of my voice.` |
| vivian, serena | Custom | Neutral | `你好，这是我的声音预览样本。` |

After each generation, find the WAV in
`~/Library/Application Support/QwenVoice-Debug/outputs/` (Debug builds)
or via the inline player's Save / right-click context menu, then rename
and copy:

```bash
cp ~/.../outputs/{generated}.wav \
   Sources/Resources/voice-previews/aiden.wav
```

XcodeGen's `buildPhase: resources` rule in `project.yml` for the
`VocelloiOS` target's `voice-previews` path picks the WAVs up
automatically on the next `scripts/regenerate_project.sh`.

When the WAVs land, the voice picker's per-row play button will Just Work.
Until then, taps no-op (the player logs a Debug warning).
