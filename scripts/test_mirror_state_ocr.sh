#!/usr/bin/env bash
# Offline smoke for mirror_state_ocr.swift classify-text keyword sets.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FIXTURES="$ROOT_DIR/Tests/DeviceProbeFixtures"
HELPER_SRC="$ROOT_DIR/scripts/lib/mirror_state_ocr.swift"
HELPER_BIN="$ROOT_DIR/build/cache/mirror_state_ocr"

mkdir -p "$(dirname "$HELPER_BIN")"
xcrun swiftc -O -o "$HELPER_BIN" "$HELPER_SRC" -framework AppKit -framework Vision

classify_fixture() {
  local name="$1" expect="$2"
  local got
  got="$("$HELPER_BIN" classify-text < "$FIXTURES/text-$name.txt" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')"
  if [[ "$got" != "$expect" ]]; then
    echo "FAIL text-$name.txt: expected $expect got $got" >&2
    return 1
  fi
  echo "OK text-$name.txt → $got"
}

classify_fixture phone-in-use PHONE_IN_USE
classify_fixture call-active CALL_ACTIVE
classify_fixture mirror-connecting MIRROR_CONNECTING
classify_fixture mirror-active MIRROR_ACTIVE

echo "mirror_state_ocr classify-text: all fixtures passed"
