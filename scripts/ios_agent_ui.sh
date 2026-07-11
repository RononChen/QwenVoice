#!/usr/bin/env bash
# Deterministic lifecycle and evidence interface for Codex Computer Use on iPhone Mirroring.
# Computer Use owns every UI action; this script owns device identity, telemetry, reports,
# fingerprints, and attestations.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT_DIR/scripts/lib/ios_agent_ui.py" "$@"
