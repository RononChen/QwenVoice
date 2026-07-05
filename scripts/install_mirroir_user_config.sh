#!/usr/bin/env bash
# Install user-global mirroir-mcp config from the committed Vocello project templates.
#
# Usage: scripts/install_mirroir_user_config.sh [--merge-settings]
#
# Writes:
#   ~/.mirroir-mcp/permissions.json  (from project template)
#   ~/.mirroir-mcp/settings.json     (--merge-settings merges OCR keys; preserves mirroringProcessName)
#
# Restart Cursor after running so the mirroir MCP server reloads permissions (~25 tools, not ~11).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/.mirroir-mcp"
DEST="$HOME/.mirroir-mcp"
MERGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --merge-settings) MERGE=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }

[[ -f "$SRC/permissions.json" ]] || { echo "missing $SRC/permissions.json" >&2; exit 1; }

mkdir -p "$DEST"
cp "$SRC/permissions.json" "$DEST/permissions.json"
note "installed $DEST/permissions.json"

if [[ "$MERGE" -eq 1 && -f "$SRC/settings.json" ]]; then
  python3 - "$SRC/settings.json" "$DEST/settings.json" <<'PY'
import json, sys
src, dest = sys.argv[1], sys.argv[2]
incoming = json.load(open(src))
existing = {}
if __import__("os").path.exists(dest):
    existing = json.load(open(dest))
merged = {**existing, **incoming}
with open(dest, "w") as fh:
    json.dump(merged, fh, indent=2)
    fh.write("\n")
print(dest)
PY
  note "merged OCR settings into $DEST/settings.json (mirroringProcessName preserved if set)"
else
  note "skipped settings merge (pass --merge-settings to merge OCR keys into ~/.mirroir-mcp/settings.json)"
fi

note "Restart Cursor (Cmd+Q) so mirroir exposes tap/type_text/measure tools"
