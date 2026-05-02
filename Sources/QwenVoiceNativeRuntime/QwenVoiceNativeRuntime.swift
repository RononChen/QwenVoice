// QwenVoiceNativeRuntime module re-export shim. The QwenVoiceNativeRuntime
// target itself is a retained compatibility surface (see CLAUDE.md
// "Architecture Boundaries") and is slated for retirement once its legacy
// regression tests are migrated to QwenVoiceCore equivalents. Do not extend.
@_exported import QwenVoiceEngineSupport
