#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
TTS_ROOT = PROJECT_DIR / "third_party_patches" / "mlx-audio-swift" / "Sources" / "MLXAudioTTS"
MODELS_ROOT = TTS_ROOT / "Models"
CONTRACT_PATH = PROJECT_DIR / "Sources" / "Resources" / "qwenvoice_contract.json"
TTS_MODEL_PATH = TTS_ROOT / "TTSModel.swift"

REMOVED_MODEL_DIRS = [
    "Chatterbox",
    "EchoTTS",
    "FishSpeech",
    "Llama",
    "Marvis",
    "PocketTTS",
    "Qwen3",
    "Soprano",
    "StyleTTS2",
]

FORBIDDEN_SWITCH_MARKERS = [
    '"echo_tts"',
    '"fish_speech"',
    '"fish_qwen3_omni"',
    '"llama_tts"',
    '"llama3_tts"',
    '"orpheus"',
    '"csm"',
    '"sesame"',
    '"soprano_tts"',
    '"pocket_tts"',
    '"chatterbox"',
    '"kitten_tts"',
    '"kokoro"',
]

CRITICAL_QWEN3_REQUIRED_PATHS = {
    "config.json",
    "generation_config.json",
    "merges.txt",
    "model.safetensors",
    "model.safetensors.index.json",
    "preprocessor_config.json",
    "speech_tokenizer/config.json",
    "speech_tokenizer/configuration.json",
    "speech_tokenizer/model.safetensors",
    "speech_tokenizer/preprocessor_config.json",
    "tokenizer_config.json",
    "vocab.json",
}

EXPECTED_MODE_FAMILY = {
    "custom": "customvoice",
    "design": "voicedesign",
    "clone": "base",
}


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_removed_model_dirs() -> None:
    for dirname in REMOVED_MODEL_DIRS:
        path = MODELS_ROOT / dirname
        if path.exists():
            fail(f"non-Qwen3-TTS vendored model directory is present: {path.relative_to(PROJECT_DIR)}")


def validate_tts_model_switch() -> None:
    try:
        source = TTS_MODEL_PATH.read_text()
    except FileNotFoundError:
        fail(f"missing TTS model entrypoint: {TTS_MODEL_PATH.relative_to(PROJECT_DIR)}")

    for marker in FORBIDDEN_SWITCH_MARKERS:
        if marker in source:
            fail(f"generic TTS model switch marker remains in TTSModel.swift: {marker}")


def validate_contract() -> None:
    try:
        contract = json.loads(CONTRACT_PATH.read_text())
    except FileNotFoundError:
        fail(f"missing model contract: {CONTRACT_PATH.relative_to(PROJECT_DIR)}")

    for model in contract.get("models", []):
        validate_contract_entry(model, model.get("id", "<unknown>"))
        for variant in model.get("variants", []):
            variant_with_mode = dict(variant)
            variant_with_mode["mode"] = model.get("mode")
            validate_contract_entry(
                variant_with_mode,
                f"{model.get('id', '<unknown>')}.{variant.get('id', '<unknown>')}"
            )


def validate_contract_entry(entry: dict, label: str) -> None:
    folder = entry.get("folder", "")
    repo = entry.get("huggingFaceRepo", "")
    mode = entry.get("mode")
    required_paths = set(entry.get("requiredRelativePaths", []))
    if "Qwen3-TTS" not in folder:
        fail(f"{label} does not use a Qwen3-TTS folder: {folder}")
    if "Qwen3-TTS" not in repo:
        fail(f"{label} does not use a Qwen3-TTS repository: {repo}")
    if mode in EXPECTED_MODE_FAMILY:
        expected_family = EXPECTED_MODE_FAMILY[mode]
        if expected_family not in folder.lower() and expected_family not in repo.lower():
            fail(f"{label} mode {mode} does not match Qwen3-TTS family {expected_family}: {folder} / {repo}")
    missing_paths = sorted(CRITICAL_QWEN3_REQUIRED_PATHS - required_paths)
    if missing_paths:
        fail(f"{label} is missing Qwen3-TTS requiredRelativePaths: {', '.join(missing_paths)}")


def main() -> int:
    validate_removed_model_dirs()
    validate_tts_model_switch()
    validate_contract()
    print("==> Qwen3-TTS backend exclusivity is clean.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
