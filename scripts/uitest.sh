#!/usr/bin/env bash
# Foundation for autonomous UI-driven testing of the Vocello Debug build.
#
# A Claude Code session uses the computer-use MCP to drive Vocello like a
# person; this script provides the deterministic pieces that don't make
# sense to do via screenshots — launch, state reset, AXIdentifier lookup,
# log tailing, DB queries, artifact directory creation.
#
# usage: scripts/uitest.sh <command> [options]   (see `help`)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"

APP_NAME="Vocello"
DEBUG_APP_BUNDLE="$ROOT_DIR/build/DerivedData/Build/Products/Debug/$APP_NAME.app"
DEBUG_DATA_DIR="$HOME/Library/Application Support/QwenVoice-Debug"
HISTORY_DB="$DEBUG_DATA_DIR/history.sqlite"
CONTRACT_JSON="$ROOT_DIR/Sources/Resources/qwenvoice_contract.json"

# shellcheck source=lib/build_cache.sh
. "$SCRIPT_DIR/lib/build_cache.sh"

usage() {
    cat <<EOF
usage: scripts/uitest.sh <command> [options]

commands:
  prep                  Launch the Debug build into a fresh window. Quits any running
                        Vocello first, errors out if the Debug build is not present.
                        Prints the PID.

  reset [--include-voices|--full]
                        Quit Vocello, then bring runtime state to a known baseline.
                        Default: clear the generations table from history.sqlite and
                          delete every file under outputs/<mode>/.
                        --include-voices also rm -rfs the voices/ subdirectory.
                        --full rm -rfs the entire Debug data folder (forces model
                          re-download on next launch).

  locate <ax-id>        Look up a SwiftUI accessibilityIdentifier in Vocello's front
                        window and print "cx cy w h" — center coordinates and size —
                        in macOS logical-points space. See docs/reference/ui-test-surface.md
                        for the screenshot-pixel scaling caveat. Exits non-zero if not found.

  screen-size           Print the screen's logical-point dimensions as "W H". Use with
                        the locate output to scale to your screenshot's image pixels.

  logs [--predicate <p>]
                        Tail \`log stream --info --style compact\` for Vocello, defaulting
                        to predicate: subsystem == "com.qwenvoice.app".

  db <sql>              Run a read-only SELECT against history.sqlite and print CSV.

  artifacts-dir         Create build/uitest/<timestamp>/ and print its absolute path.

  smoke-check           Confirm at least one Custom Voice model variant is installed.
                        Exit 0 if ready, 1 with a clear message otherwise.

  help                  Show this message.
EOF
}

cmd_prep() {
    if [ ! -d "$DEBUG_APP_BUNDLE" ]; then
        echo "error: Debug build not found at $DEBUG_APP_BUNDLE" >&2
        echo "       run: scripts/build.sh debug" >&2
        exit 1
    fi
    quit_app_if_running
    /usr/bin/open -na "$DEBUG_APP_BUNDLE"
    local pid=""
    for _ in {1..40}; do
        pid="$(pgrep -x "$APP_NAME" | head -n 1)"
        if [ -n "$pid" ]; then
            break
        fi
        sleep 0.25
    done
    if [ -z "$pid" ]; then
        echo "error: $APP_NAME did not appear in the process list after launch" >&2
        exit 1
    fi
    # Give SwiftUI a beat to lay out the first window.
    sleep 1
    echo "$pid"
}

cmd_reset() {
    local mode="default"
    case "${1:-}" in
        "") ;;
        --include-voices) mode="include-voices" ;;
        --full)           mode="full" ;;
        *)
            echo "error: unknown reset option '$1'" >&2
            usage
            exit 2
            ;;
    esac

    quit_app_if_running

    if [ "$mode" = "full" ]; then
        if [ -d "$DEBUG_DATA_DIR" ]; then
            echo "==> Removing $DEBUG_DATA_DIR"
            rm -rf "$DEBUG_DATA_DIR"
        else
            echo "==> Nothing to remove ($DEBUG_DATA_DIR does not exist)"
        fi
        return 0
    fi

    if [ -f "$HISTORY_DB" ]; then
        echo "==> Clearing generations table in $HISTORY_DB"
        /usr/bin/sqlite3 "$HISTORY_DB" "DELETE FROM generations;" 2>/dev/null || \
            echo "warn: could not clear generations (table missing or db locked)" >&2
    fi

    local outputs_dir="$DEBUG_DATA_DIR/outputs"
    if [ -d "$outputs_dir" ]; then
        echo "==> Deleting files under $outputs_dir"
        /usr/bin/find "$outputs_dir" -type f -delete
    fi

    if [ "$mode" = "include-voices" ]; then
        local voices_dir="$DEBUG_DATA_DIR/voices"
        if [ -d "$voices_dir" ]; then
            echo "==> Removing $voices_dir"
            rm -rf "$voices_dir"
        fi
    fi
}

cmd_locate() {
    local ax_id="${1:-}"
    if [ -z "$ax_id" ]; then
        echo "error: locate requires an accessibility identifier" >&2
        echo "usage: scripts/uitest.sh locate <ax-id>" >&2
        exit 2
    fi

    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "error: $APP_NAME is not running — run \`scripts/uitest.sh prep\` first" >&2
        exit 1
    fi

    /usr/bin/osascript - "$ax_id" <<'APPLESCRIPT'
on run argv
    set targetID to item 1 of argv
    tell application "System Events"
        tell process "Vocello"
            try
                set frontWin to front window
            on error
                error "no front window for Vocello" number 2
            end try
            set everything to entire contents of frontWin
            repeat with itm in everything
                try
                    if (value of attribute "AXIdentifier" of itm) is targetID then
                        set pos to position of itm
                        set sz to size of itm
                        set cx to (item 1 of pos) + ((item 1 of sz) div 2)
                        set cy to (item 2 of pos) + ((item 2 of sz) div 2)
                        return (cx as text) & " " & (cy as text) & " " & ((item 1 of sz) as text) & " " & ((item 2 of sz) as text)
                    end if
                end try
            end repeat
            error ("accessibility identifier not found: " & targetID) number 3
        end tell
    end tell
end run
APPLESCRIPT
}

cmd_logs() {
    local predicate='subsystem == "com.qwenvoice.app"'
    if [ "${1:-}" = "--predicate" ]; then
        if [ $# -lt 2 ]; then
            echo "error: --predicate requires a value" >&2
            exit 2
        fi
        predicate="$2"
    fi
    # --signpost is required to capture OSSignposter events. The app's key
    # generation milestones (Final File Ready, Autoplay Start, Preview To
    # First Chunk) are signposts under category "performance" — they do
    # NOT appear in a plain `log stream --info` stream.
    exec /usr/bin/log stream --info --signpost --style compact --predicate "$predicate"
}

cmd_db() {
    local sql="${1:-}"
    if [ -z "$sql" ]; then
        echo "error: db requires a SQL statement" >&2
        echo "usage: scripts/uitest.sh db \"SELECT ...\"" >&2
        exit 2
    fi
    if [ ! -f "$HISTORY_DB" ]; then
        echo "error: history.sqlite not found at $HISTORY_DB" >&2
        echo "       launch the app once to materialize the DB" >&2
        exit 1
    fi
    /usr/bin/sqlite3 -readonly -separator , "$HISTORY_DB" "$sql"
}

cmd_screen_size() {
    # Use osascript with "Finder window of desktop" — its bounds equal the
    # screen's logical-points rect. Print "<width> <height>".
    /usr/bin/osascript -e 'tell application "Finder" to set b to bounds of window of desktop
return ((item 3 of b) - (item 1 of b)) & " " & ((item 4 of b) - (item 2 of b))' 2>/dev/null \
        | /usr/bin/tr ',' ' ' \
        | /usr/bin/awk '{print $1, $2}'
}

cmd_artifacts_dir() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local dir="$ROOT_DIR/build/uitest/$ts"
    mkdir -p "$dir"
    echo "$dir"
}

cmd_smoke_check() {
    if [ ! -f "$CONTRACT_JSON" ]; then
        echo "error: contract not found at $CONTRACT_JSON" >&2
        exit 1
    fi
    if [ ! -d "$DEBUG_DATA_DIR/models" ]; then
        echo "smoke-check FAIL: no models directory at $DEBUG_DATA_DIR/models" >&2
        echo "                 launch the app and install Custom Voice models in Settings." >&2
        exit 1
    fi

    local installed
    installed="$(/usr/bin/python3 - "$CONTRACT_JSON" "$DEBUG_DATA_DIR/models" <<'PY'
import json
import sys
from pathlib import Path

contract = json.loads(Path(sys.argv[1]).read_text())
models_dir = Path(sys.argv[2])

custom = next((m for m in contract["models"] if m.get("mode") == "custom"), None)
if custom is None:
    print("CONTRACT_MISSING_CUSTOM", file=sys.stderr)
    sys.exit(1)

candidates = []
base_folder = custom.get("folder")
if base_folder:
    candidates.append((base_folder, "base"))
for variant in custom.get("variants", []):
    folder = variant.get("folder")
    if folder:
        candidates.append((folder, variant.get("id", "variant")))

found = []
for folder, label in candidates:
    safetensors = models_dir / folder / "model.safetensors"
    if safetensors.is_file() and safetensors.stat().st_size > 0:
        found.append(label)

if not found:
    print("NONE_INSTALLED")
else:
    print(",".join(found))
PY
)"

    case "$installed" in
        "")
            echo "smoke-check FAIL: contract inspection failed" >&2
            exit 1
            ;;
        NONE_INSTALLED)
            echo "smoke-check FAIL: no Custom Voice model variant is installed under $DEBUG_DATA_DIR/models" >&2
            echo "                 launch the app and install at least one (Settings -> Model Downloads -> Custom Voice)." >&2
            exit 1
            ;;
        *)
            echo "smoke-check OK: Custom Voice variant(s) installed: $installed"
            ;;
    esac
}

main() {
    local command="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi
    case "$command" in
        prep)            cmd_prep "$@" ;;
        reset)           cmd_reset "$@" ;;
        locate)          cmd_locate "$@" ;;
        screen-size)     cmd_screen_size ;;
        logs)            cmd_logs "$@" ;;
        db)              cmd_db "$@" ;;
        artifacts-dir)   cmd_artifacts_dir ;;
        smoke-check)     cmd_smoke_check ;;
        help|-h|--help)  usage ;;
        *)
            echo "error: unknown command '$command'" >&2
            usage
            exit 2
            ;;
    esac
}

main "$@"
