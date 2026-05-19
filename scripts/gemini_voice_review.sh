#!/usr/bin/env bash
# Deprecation shim — Gemini CLI is being retired by Google; the voice-review
# pipeline now runs through Antigravity CLI (`agy`). This file exists only so
# stale shell history and external doc links keep working for one release.
# Forwards every argument to scripts/antigravity_voice_review.sh.
#
# Remove in a follow-up once nothing external references this path. See
# docs/reference/antigravity-cli-probe.md for the migration rationale.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "deprecation: scripts/gemini_voice_review.sh has been replaced by scripts/antigravity_voice_review.sh — forwarding." >&2
exec "$SCRIPT_DIR/antigravity_voice_review.sh" "$@"
