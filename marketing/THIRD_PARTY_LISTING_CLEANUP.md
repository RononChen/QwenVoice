# Vocello Third-Party Listing Cleanup

Last checked: 2026-05-26

Use this pack when requesting updates to stale directory pages, repo mirrors, or generated listings. Keep the wording bounded: Vocello is local after model download, not fully offline from first launch.

## Canonical Correction Pack

- Product name: Vocello, formerly QwenVoice
- Category: local AI voice studio for Mac
- Canonical website: https://vocello.vercel.app
- Repository: https://github.com/PowerBeef/QwenVoice
- Latest release: https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0
- Stable release line: Vocello 2.0.0 for macOS 26 and Apple Silicon
- Legacy release line: QwenVoice 1.2.3 for macOS 15
- License: MIT app code
- Install trust: signed and Apple-notarized DMG
- Runtime: native Swift + MLX, no Python setup
- Locality: generation runs locally after model packages are downloaded from Hugging Face
- Voice cloning policy: use only voices you own or have permission to use

## Short Description

Vocello, formerly QwenVoice, is a local AI voice studio for Apple Silicon Macs. It is a Qwen3-TTS Mac app for Custom Voice, Voice Design, and Voice Cloning workflows. After model packages download from Hugging Face, generation runs locally in the app with no Python setup, no subscription meter, and local app storage for scripts, history, saved voices, and generated audio.

## Claims To Avoid

- Do not say "fully offline" without the Hugging Face model-download caveat.
- Do not say "no telemetry" unless the current app privacy/storage implementation has been separately verified.
- Do not say "best," "first," "only," or "unlimited."
- Do not imply the iPhone app is public yet.
- Do not describe the current 2.0 line as beta.

## Listing Status

| Surface | URL | Problem | Action |
| --- | --- | --- | --- |
| Desktop Insights | https://desktopinsights.com/apps/qwenvoice | Stale generated metadata can report old runtime details such as Python, v1.2.3, or old package size. | Request a rescan using the canonical correction pack. |
| Trendshift | https://trendshift.io/repositories/26679 | May still describe the project as public beta despite Vocello 2.0.0 being the stable release. | Request refresh or wait for sync; recheck after the next crawl. |
| AlternativeTo | https://alternativeto.net/software/qwenvoice/ | Product identity may still be QwenVoice-first. | Submit rename, description, homepage, release, and screenshot updates. |
| OpenAlt | https://openalt.pro/en/tools/qwenvoice-4d27456d | May contain stale stats or unsupported absolutes such as fully offline/no telemetry. | Submit correction if editable; otherwise classify as generated/stale. |
| Apple Podcasts / Kana & Mari | https://podcasts.apple.com/us/podcast/powerbeef-qwenvoice/id1828921092?i=1000767273122 | Generated/third-party mention tied to old QwenVoice name. | Classify as stale/generated unless a clear creator edit path appears. |
| AIAI Hub | https://aiai-news.com/ai-repo/qwenvoice/ | Currently useful as a discovery/indexing surface. | Monitor only unless it drifts from Vocello 2.0.0 facts. |

## Suggested Submission Note

Hello - I maintain the project listed here. QwenVoice has been rebranded as Vocello for the 2.0 release line.

Please update the listing to:

- Name: Vocello, formerly QwenVoice
- Website: https://vocello.vercel.app
- Repository: https://github.com/PowerBeef/QwenVoice
- Latest release: https://github.com/PowerBeef/QwenVoice/releases/tag/v2.0.0
- Description: Vocello is a local AI voice studio for Apple Silicon Macs. It is a Qwen3-TTS Mac app for Custom Voice, Voice Design, and Voice Cloning. After model packages download from Hugging Face, generation runs locally with no Python setup and no subscription meter.
- Requirements: macOS 26+, Apple Silicon. QwenVoice 1.2.3 remains the macOS 15 fallback.
- License: MIT app code.

Please avoid wording such as "fully offline" unless it includes the model-download caveat, and please do not list the current Vocello 2.0.0 release as beta.
