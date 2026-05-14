#!/usr/bin/env bash
# Unified local build entrypoint for QwenVoice / Vocello.
#
# Skips XcodeGen regen when project.yml hasn't changed and skips
# SwiftPM resolve when Package.resolved hasn't changed, so back-to-back
# Debug builds drop straight into xcodebuild.
#
# usage:
#   scripts/build.sh debug
#   scripts/build.sh run [--logs|--telemetry|--verify|--debug]
#   scripts/build.sh release [release.sh args...]
#   scripts/build.sh clean
#   scripts/build.sh help

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"

APP_NAME="Vocello"
SCHEME_NAME="QwenVoice"
BUNDLE_ID="com.qwenvoice.app"
DESTINATION="platform=macOS,arch=arm64"

DEBUG_DERIVED_DATA="$ROOT_DIR/build/DerivedData"
DEBUG_APP_BUNDLE="$DEBUG_DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
DEBUG_APP_BINARY="$DEBUG_APP_BUNDLE/Contents/MacOS/$APP_NAME"

# shellcheck source=lib/build_cache.sh
. "$SCRIPT_DIR/lib/build_cache.sh"

usage() {
    cat <<EOF
usage: scripts/build.sh <command> [options]

commands:
  debug                 Fast incremental Debug build. No launch.
  run [--logs|--telemetry|--verify|--debug]
                        Debug build, then launch $APP_NAME.app. Mode flags mirror build_and_run.sh.
  release [args...]     Run scripts/release.sh with the shared regen/SPM cache active.
  clean                 Remove build/ (DerivedData, foundation builds, caches, DMG output).
  help                  Show this message.

caches live in build/.cache/ and self-heal — delete the directory to force a full rebuild.
EOF
}

build_debug() {
    ensure_project_regenerated
    ensure_spm_resolved "$DEBUG_DERIVED_DATA" "" debug

    echo "==> Building $SCHEME_NAME (Debug, $DESTINATION)..."
    xcb_run \
        -project "$ROOT_DIR/QwenVoice.xcodeproj" \
        -scheme "$SCHEME_NAME" \
        -configuration Debug \
        -destination "$DESTINATION" \
        -derivedDataPath "$DEBUG_DERIVED_DATA" \
        -onlyUsePackageVersionsFromResolvedFile \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        build

    if [ ! -d "$DEBUG_APP_BUNDLE" ]; then
        echo "error: built app bundle not found at $DEBUG_APP_BUNDLE" >&2
        exit 1
    fi
    if [ ! -x "$DEBUG_APP_BINARY" ]; then
        echo "error: built app binary not found at $DEBUG_APP_BINARY" >&2
        exit 1
    fi
    echo "==> Debug build ready: $DEBUG_APP_BUNDLE"
    prune_stale_debug_builds
}

kill_running_app() {
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    for _ in {1..40}; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done
}

verify_launch() {
    sleep 1
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "error: $APP_NAME did not appear in the process list after launch" >&2
        exit 1
    fi
    echo "==> $APP_NAME launched"
}

stream_logs() {
    local predicate="$1"
    echo "==> Streaming logs for predicate: $predicate"
    /usr/bin/log stream --info --style compact --predicate "$predicate"
}

cmd_run() {
    local mode="${1:-run}"
    kill_running_app
    build_debug
    case "$mode" in
        run|"")
            /usr/bin/open -na "$DEBUG_APP_BUNDLE"
            ;;
        --debug|debug)
            exec lldb -- "$DEBUG_APP_BINARY"
            ;;
        --logs|logs)
            /usr/bin/open -na "$DEBUG_APP_BUNDLE"
            verify_launch
            stream_logs "process == \"$APP_NAME\""
            ;;
        --telemetry|telemetry)
            /usr/bin/open -na "$DEBUG_APP_BUNDLE"
            verify_launch
            stream_logs "subsystem == \"$BUNDLE_ID\""
            ;;
        --verify|verify)
            /usr/bin/open -na "$DEBUG_APP_BUNDLE"
            verify_launch
            ;;
        *)
            echo "error: unknown run mode '$mode'" >&2
            usage
            exit 2
            ;;
    esac
}

cmd_release() {
    exec "$SCRIPT_DIR/release.sh" "$@"
}

cmd_clean() {
    if [ -d "$ROOT_DIR/build" ]; then
        echo "==> Removing $ROOT_DIR/build"
        rm -rf "$ROOT_DIR/build"
    else
        echo "==> Nothing to clean ($ROOT_DIR/build does not exist)"
    fi
}

main() {
    local command="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi

    case "$command" in
        debug)
            build_debug
            ;;
        run)
            cmd_run "$@"
            ;;
        release)
            cmd_release "$@"
            ;;
        clean)
            cmd_clean
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "error: unknown command '$command'" >&2
            usage
            exit 2
            ;;
    esac
}

main "$@"
