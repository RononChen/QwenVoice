#!/usr/bin/env bash
# Verify the vendor tree, TTSModel.swift, and contract still describe a
# Qwen3-TTS-only backend. Replaces the retired Python check_qwen3_backend_only.py.
#
# Exits 0 on success and 1 on any failure (printing "error: ..." to stderr).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
TTS_ROOT="$PROJECT_DIR/third_party_patches/mlx-audio-swift/Sources/MLXAudioTTS"
MODELS_ROOT="$TTS_ROOT/Models"
CONTRACT_PATH="$PROJECT_DIR/Sources/Resources/qwenvoice_contract.json"
TTS_MODEL_PATH="$TTS_ROOT/TTSModel.swift"

REMOVED_MODEL_DIRS=(
  Chatterbox EchoTTS FishSpeech Llama Marvis PocketTTS Qwen3 Soprano StyleTTS2
)

# Switch markers that would indicate a generic multi-model TTS surface; the
# Qwen3-only backend must not contain any of them.
FORBIDDEN_SWITCH_MARKERS=(
  '"echo_tts"'
  '"fish_speech"'
  '"fish_qwen3_omni"'
  '"llama_tts"'
  '"llama3_tts"'
  '"orpheus"'
  '"csm"'
  '"sesame"'
  '"soprano_tts"'
  '"pocket_tts"'
  '"chatterbox"'
  '"kitten_tts"'
  '"kokoro"'
)

CRITICAL_QWEN3_REQUIRED_PATHS=(
  "config.json"
  "generation_config.json"
  "merges.txt"
  "model.safetensors"
  "model.safetensors.index.json"
  "preprocessor_config.json"
  "speech_tokenizer/config.json"
  "speech_tokenizer/configuration.json"
  "speech_tokenizer/model.safetensors"
  "speech_tokenizer/preprocessor_config.json"
  "tokenizer_config.json"
  "vocab.json"
)

fail() {
  echo "error: $*" >&2
  exit 1
}

validate_removed_model_dirs() {
  for dirname in "${REMOVED_MODEL_DIRS[@]}"; do
    if [[ -d "$MODELS_ROOT/$dirname" ]]; then
      fail "non-Qwen3-TTS vendored model directory is present: ${MODELS_ROOT#$PROJECT_DIR/}/$dirname"
    fi
  done
}

validate_tts_model_switch() {
  if [[ ! -f "$TTS_MODEL_PATH" ]]; then
    fail "missing TTS model entrypoint: ${TTS_MODEL_PATH#$PROJECT_DIR/}"
  fi
  for marker in "${FORBIDDEN_SWITCH_MARKERS[@]}"; do
    if grep -qF -- "$marker" "$TTS_MODEL_PATH"; then
      fail "generic TTS model switch marker remains in TTSModel.swift: $marker"
    fi
  done
}

validate_contract() {
  if [[ ! -f "$CONTRACT_PATH" ]]; then
    fail "missing model contract: ${CONTRACT_PATH#$PROJECT_DIR/}"
  fi

  # jq emits one line per (label, folder, repo, mode, joined-required-paths)
  # tuple covering both top-level models and their variants.
  while IFS=$'\t' read -r label folder repo mode required_csv; do
    if [[ "$folder" != *"Qwen3-TTS"* ]]; then
      fail "$label does not use a Qwen3-TTS folder: $folder"
    fi
    if [[ "$repo" != *"Qwen3-TTS"* ]]; then
      fail "$label does not use a Qwen3-TTS repository: $repo"
    fi

    case "$mode" in
      custom) expected_family="customvoice" ;;
      design) expected_family="voicedesign" ;;
      clone)  expected_family="base" ;;
      *)      expected_family="" ;;
    esac
    if [[ -n "$expected_family" ]]; then
      folder_lower="$(echo "$folder" | tr '[:upper:]' '[:lower:]')"
      repo_lower="$(echo "$repo" | tr '[:upper:]' '[:lower:]')"
      if [[ "$folder_lower" != *"$expected_family"* ]] && [[ "$repo_lower" != *"$expected_family"* ]]; then
        fail "$label mode $mode does not match Qwen3-TTS family $expected_family: $folder / $repo"
      fi
    fi

    # Required paths missing from this entry. Use a comma-padded grep so this
    # works on stock macOS bash 3.2 without associative arrays.
    padded_csv=",${required_csv},"
    missing=()
    for required in "${CRITICAL_QWEN3_REQUIRED_PATHS[@]}"; do
      if ! printf '%s' "$padded_csv" | grep -qF -- ",${required},"; then
        missing+=("$required")
      fi
    done
    if (( ${#missing[@]} > 0 )); then
      joined="$(printf '%s, ' "${missing[@]}")"
      fail "$label is missing Qwen3-TTS requiredRelativePaths: ${joined%, }"
    fi
  done < <(jq -r '
    .models[]?
    | . as $m
    | (
        [
          ($m.id // "<unknown>"),
          ($m.folder // ""),
          ($m.huggingFaceRepo // ""),
          ($m.mode // ""),
          (($m.requiredRelativePaths // []) | join(","))
        ] | @tsv
      ),
      (
        $m.variants[]?
        | [
            (($m.id // "<unknown>") + "." + (.id // "<unknown>")),
            (.folder // ""),
            (.huggingFaceRepo // ""),
            ($m.mode // ""),
            ((.requiredRelativePaths // []) | join(","))
          ] | @tsv
      )
  ' "$CONTRACT_PATH")
}

validate_removed_model_dirs
validate_tts_model_switch
validate_contract
echo "==> Qwen3-TTS backend exclusivity is clean."
