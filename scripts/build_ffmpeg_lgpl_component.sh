#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_PATH="$PROJECT_DIR/config/ffmpeg-lgpl-component.json"

# shellcheck source=lib/build_paths.sh
. "$SCRIPT_DIR/lib/build_paths.sh"

APP_BUNDLE=""
RELEASE_ASSET_DIR=""
OFFLINE=false

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: ./scripts/build_ffmpeg_lgpl_component.sh [--app-bundle /path/to/Vocello.app] [--release-assets /path/to/directory] [--offline]

Builds the pinned arm64 LGPL-only ffmpeg-vocello helper from official FFmpeg
source. Optional destinations install the helper/notices into a macOS app and
copy the exact corresponding source, signature, and build manifest into the
release asset directory.
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --app-bundle)
            [ $# -ge 2 ] || usage
            APP_BUNDLE="$2"
            shift 2
            ;;
        --release-assets)
            [ $# -ge 2 ] || usage
            RELEASE_ASSET_DIR="$2"
            shift 2
            ;;
        --offline)
            OFFLINE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

config_value() {
    python3 - "$CONFIG_PATH" "$1" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("/"):
    value = value[part]
print(value)
PY
}

file_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

download_verified() {
    local url="$1"
    local expected_sha="$2"
    local destination="$3"
    local label="$4"

    if [ -f "$destination" ]; then
        local cached_sha
        cached_sha="$(file_sha256 "$destination")"
        [ "$cached_sha" = "$expected_sha" ] \
            || fail "$label cache digest mismatch at $destination (remove the cache entry and retry)"
        return
    fi
    $OFFLINE && fail "$label is absent from the verified cache while --offline is active: $destination"

    local temporary
    temporary="$(mktemp "$QVOICE_FFMPEG_LGPL_CACHE/.download.XXXXXX")"
    if ! curl --fail --location --retry 5 --retry-all-errors --output "$temporary" "$url"; then
        rm -f "$temporary"
        fail "could not download $label from $url"
    fi
    local actual_sha
    actual_sha="$(file_sha256 "$temporary")"
    if [ "$actual_sha" != "$expected_sha" ]; then
        rm -f "$temporary"
        fail "$label digest mismatch: expected $expected_sha, got $actual_sha"
    fi
    mv "$temporary" "$destination"
}

python3 "$SCRIPT_DIR/verify_ffmpeg_lgpl_component.py" --config "$CONFIG_PATH" check-config >/dev/null

[ "$(uname -s)" = "Darwin" ] || fail "ffmpeg-vocello release component can only be built on macOS"
[ "$(uname -m)" = "arm64" ] || fail "ffmpeg-vocello release component must be built natively on arm64"
command -v xcrun >/dev/null || fail "xcrun is required"
command -v make >/dev/null || fail "make is required"
command -v curl >/dev/null || fail "curl is required"

VERSION="$(config_value version)"
SOURCE_URL="$(config_value source/url)"
SOURCE_SHA="$(config_value source/sha256)"
SOURCE_NAME="$(config_value source/archiveName)"
SOURCE_RELEASE_NAME="$(config_value source/releaseAssetName)"
SIGNATURE_URL="$(config_value signature/url)"
SIGNATURE_SHA="$(config_value signature/sha256)"
SIGNATURE_NAME="$(config_value signature/archiveName)"
SIGNATURE_RELEASE_NAME="$(config_value signature/releaseAssetName)"
EXECUTABLE_NAME="$(config_value executableName)"
APP_EXECUTABLE_PATH="$(config_value appRelativeExecutablePath)"
APP_NOTICE_DIRECTORY="$(config_value appRelativeNoticeDirectory)"
BUILD_INFO_NAME="$(config_value releaseBuildInfoName)"

mkdir -p "$QVOICE_FFMPEG_LGPL_CACHE"
SOURCE_ARCHIVE="$QVOICE_FFMPEG_LGPL_CACHE/$SOURCE_NAME"
SIGNATURE_ARCHIVE="$QVOICE_FFMPEG_LGPL_CACHE/$SIGNATURE_NAME"
download_verified "$SOURCE_URL" "$SOURCE_SHA" "$SOURCE_ARCHIVE" "FFmpeg source archive"
download_verified "$SIGNATURE_URL" "$SIGNATURE_SHA" "$SIGNATURE_ARCHIVE" "FFmpeg detached signature"

SCRATCH_ROOT="$QVOICE_SCRATCH_TRANSIENT/ffmpeg-lgpl"
SOURCE_ROOT="$SCRATCH_ROOT/source"
BUILD_ROOT="$SCRATCH_ROOT/build"
rm -rf "$SCRATCH_ROOT"
mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT"
tar -xf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT" --strip-components 1
[ -x "$SOURCE_ROOT/configure" ] || fail "FFmpeg source archive did not contain an executable configure script"
[ -f "$SOURCE_ROOT/COPYING.LGPLv2.1" ] || fail "FFmpeg source archive is missing COPYING.LGPLv2.1"
[ -f "$SOURCE_ROOT/LICENSE.md" ] || fail "FFmpeg source archive is missing LICENSE.md"

CONFIGURE_ARGUMENTS=()
while IFS= read -r argument; do
    CONFIGURE_ARGUMENTS+=("$argument")
done < <(python3 - "$CONFIG_PATH" <<'PY'
import json
import sys

for argument in json.load(open(sys.argv[1], encoding="utf-8"))["configureArguments"]:
    print(argument)
PY
)

echo "==> Configuring FFmpeg $VERSION (LGPL-only, arm64, WAV/PCM/atempo)..."
(
    cd "$BUILD_ROOT"
    "$SOURCE_ROOT/configure" "${CONFIGURE_ARGUMENTS[@]}"
)

JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
case "$JOBS" in
    ''|*[!0-9]*) JOBS=4 ;;
esac
echo "==> Building ffmpeg-vocello with $JOBS jobs..."
make -C "$BUILD_ROOT" -j"$JOBS"

ARTIFACT_ROOT="$QVOICE_ARTIFACTS_MACOS/ffmpeg-lgpl/$VERSION"
BINARY_PATH="$ARTIFACT_ROOT/$EXECUTABLE_NAME"
BUILD_INFO_PATH="$ARTIFACT_ROOT/$BUILD_INFO_NAME"
mkdir -p "$ARTIFACT_ROOT"
install -m 755 "$BUILD_ROOT/ffmpeg" "$BINARY_PATH"
python3 "$SCRIPT_DIR/verify_ffmpeg_lgpl_component.py" --config "$CONFIG_PATH" manifest \
    --binary "$BINARY_PATH" \
    --source "$SOURCE_ARCHIVE" \
    --signature "$SIGNATURE_ARCHIVE" \
    --output "$BUILD_INFO_PATH" >/dev/null

if [ -n "$APP_BUNDLE" ]; then
    [ -d "$APP_BUNDLE/Contents" ] || fail "macOS app bundle is missing Contents: $APP_BUNDLE"
    APP_BINARY="$APP_BUNDLE/$APP_EXECUTABLE_PATH"
    NOTICE_DIR="$APP_BUNDLE/$APP_NOTICE_DIRECTORY"
    mkdir -p "$(dirname "$APP_BINARY")" "$NOTICE_DIR"
    install -m 755 "$BINARY_PATH" "$APP_BINARY"
    install -m 644 "$PROJECT_DIR/ThirdPartyNotices/FFmpeg/NOTICE.txt" "$NOTICE_DIR/NOTICE.txt"
    install -m 644 "$SOURCE_ROOT/COPYING.LGPLv2.1" "$NOTICE_DIR/COPYING.LGPLv2.1"
    install -m 644 "$SOURCE_ROOT/LICENSE.md" "$NOTICE_DIR/LICENSE.md"
    install -m 644 "$BUILD_INFO_PATH" "$NOTICE_DIR/BUILD-INFO.json"
fi

if [ -n "$RELEASE_ASSET_DIR" ]; then
    mkdir -p "$RELEASE_ASSET_DIR"
    install -m 644 "$SOURCE_ARCHIVE" "$RELEASE_ASSET_DIR/$SOURCE_RELEASE_NAME"
    install -m 644 "$SIGNATURE_ARCHIVE" "$RELEASE_ASSET_DIR/$SIGNATURE_RELEASE_NAME"
    install -m 644 "$BUILD_INFO_PATH" "$RELEASE_ASSET_DIR/$BUILD_INFO_NAME"
fi

echo "==> FFmpeg LGPL-only component verified."
echo "    binary: $BINARY_PATH"
[ -z "$APP_BUNDLE" ] || echo "    app:    $APP_BUNDLE/$APP_EXECUTABLE_PATH"
[ -z "$RELEASE_ASSET_DIR" ] || echo "    assets: $RELEASE_ASSET_DIR"
