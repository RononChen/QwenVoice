#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
PROJECT_FILE="$ROOT_DIR/QwenVoice.xcodeproj"
MATRIX_PATH="$ROOT_DIR/config/apple-platform-capability-matrix.json"
export MATRIX_PATH
ARTIFACT_ROOT="$ROOT_DIR/build/Debug/ios-device"
RUNS_ROOT="$ARTIFACT_ROOT/runs"
DERIVED_DATA_PATH="$ARTIFACT_ROOT/DerivedData"
LAST_RUN_FILE="$ARTIFACT_ROOT/.last-run"
SCHEME="VocelloiOS"
CONFIGURATION="Debug"
SCREEN_MIRROR_BUNDLE_ID="com.apple.ScreenContinuity"
DEFAULT_TEAM_ID="FK2D8X36G2"
DEFAULT_IOS_CATALOG_URL="bundle://vocello/ios/catalog/v1/models.json"

# shellcheck source=scripts/lib/shared.sh
. "$SCRIPT_DIR/lib/shared.sh"

IOS_APP_BUNDLE_ID="$(matrix_read "iOS/app/bundleIdentifier")"
DEFAULT_DEVICE_APP_GROUP="$(matrix_read "iOS/app/applicationGroups" | head -n 1)"
SHIPPING_IOS_APP_GROUP="$DEFAULT_DEVICE_APP_GROUP"

DEVICE_ID_OVERRIDE="${QVOICE_IOS_DEVICE_ID:-}"
RUN_ID="${QVOICE_IOS_DEVICE_RUN_ID:-}"
CATALOG_URL="${QVOICE_IOS_MODEL_CATALOG_URL:-}"
ALLOWED_HOSTS="${QVOICE_IOS_MODEL_ALLOWED_HOSTS:-}"
FORCE_MEMORY_BAND="${QVOICE_IOS_MEMORY_GUARD_FORCE_BAND:-}"
FORCE_CRITICAL_ONCE="${QVOICE_IOS_MEMORY_GUARD_FORCE_CRITICAL_ONCE:-}"
ENABLE_PROACTIVE_PREFETCH="${QVOICE_IOS_ENABLE_PROACTIVE_PREFETCH:-0}"
MLX_MEMORY_LIMIT_MB="${QVOICE_IOS_MLX_MEMORY_LIMIT_MB:-}"
MLX_CACHE_LIMIT_MB="${QVOICE_IOS_MLX_CACHE_LIMIT_MB:-}"
TEAM_ID="${QVOICE_IOS_TEAM_ID:-${QWENVOICE_DEVELOPMENT_TEAM:-${APPLE_TEAM_ID:-$DEFAULT_TEAM_ID}}}"
APP_GROUP_OVERRIDE="${QVOICE_IOS_APP_GROUP_ID:-}"
IOS_APP_GROUP="${APP_GROUP_OVERRIDE:-$DEFAULT_DEVICE_APP_GROUP}"
ENABLE_INCREASED_MEMORY_LIMIT="${QVOICE_IOS_ENABLE_INCREASED_MEMORY_LIMIT:-0}"
SEED_CUSTOM_TEXT="${QVOICE_IOS_TEST_CUSTOM_TEXT:-}"
SKIP_ONBOARDING="${QVOICE_IOS_SKIP_ONBOARDING:-1}"
IOS_APP_ENTITLEMENTS=""
IOS_EXTENSION_ENTITLEMENTS=""

RUN_DIR=""
DEVICE_ID=""
DEVICE_UDID=""
DEVICE_NAME=""
DEVICE_MARKETING_NAME=""
DEVICE_OS_VERSION=""
DEVICE_OS_BUILD=""
SCREEN_VIEWING_URL=""
APP_PATH=""
POSITIONAL=()

usage() {
    cat <<EOF
usage: scripts/ios_device.sh <command> [options]

commands:
  doctor                  Check CoreDevice, signing inputs, iPhone Mirroring, device state, and catalog reachability.
  build                   Build VocelloiOS Debug for the selected physical iPhone.
  install                 Install the latest device Debug build on the selected iPhone.
  launch                  Launch $IOS_APP_BUNDLE_ID with device-run diagnostics enabled.
  mirror                  Open the selected iPhone in Apple's iPhone Mirroring app.
  start                   doctor + build + install + launch + mirror.
  screenshot <label>      Capture the Mac screen into the current run's screenshots folder.
  pull                    Pull focused app-group diagnostics/history/output evidence into the current run.
  help                    Show this message.

options:
  --device <id>           CoreDevice identifier, UDID, serial, device name, or DNS name. Defaults to paired iPhone 17 Pro.
  --run-id <id>           Reuse or create a specific run id. Defaults to UTC timestamp.
  --catalog-url <url>     Launch-time QVOICE_IOS_MODEL_CATALOG_URL override.
  --allowed-hosts <csv>   Launch-time QVOICE_IOS_MODEL_ALLOWED_HOSTS override.
  --team-id <id>          Signing team override. Defaults QVOICE_IOS_TEAM_ID, QWENVOICE_DEVELOPMENT_TEAM, APPLE_TEAM_ID, then $DEFAULT_TEAM_ID.
  --app-group <id>        Debug device App Group. Defaults QVOICE_IOS_APP_GROUP_ID, then $DEFAULT_DEVICE_APP_GROUP.
  --enable-increased-memory-limit
                          Include the restricted increased-memory-limit entitlement. Requires an approved Apple profile.
  --seed-custom-text <t>  Debug-only launch seed for the Custom Voice prompt.
  --show-onboarding       Do not set the Debug launch env that skips onboarding.
  --force-band <band>     Debug-only QVOICE_IOS_MEMORY_GUARD_FORCE_BAND override. Supported app value: guarded.
  --force-critical-once   Debug-only one-shot active-generation critical memory injection.
  --enable-proactive-prefetch
                          Debug-only iPhone proactive warm/prefetch. Disabled by default for stable device runs.
  --mlx-memory-limit-mb <mb>
                          Debug-only QVOICE_IOS_MLX_MEMORY_LIMIT_MB active-allocation experiment.
  --mlx-cache-limit-mb <mb>
                          Debug-only QVOICE_IOS_MLX_CACHE_LIMIT_MB cache-limit experiment.

examples:
  scripts/ios_device.sh doctor
  scripts/ios_device.sh start
  scripts/ios_device.sh start --catalog-url https://example.com/ios/catalog/v1/models.json
  scripts/ios_device.sh start --force-band guarded
  scripts/ios_device.sh start --force-critical-once
  scripts/ios_device.sh start --mlx-memory-limit-mb 2800 --mlx-cache-limit-mb 64
  scripts/ios_device.sh screenshot custom-generated
  scripts/ios_device.sh pull
EOF
}

parse_common_options() {
    POSITIONAL=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --device)
                DEVICE_ID_OVERRIDE="${2:?--device requires a value}"
                shift 2
                ;;
            --run-id)
                RUN_ID="${2:?--run-id requires a value}"
                shift 2
                ;;
            --catalog-url)
                CATALOG_URL="${2:?--catalog-url requires a value}"
                shift 2
                ;;
            --allowed-hosts)
                ALLOWED_HOSTS="${2:?--allowed-hosts requires a value}"
                shift 2
                ;;
            --team-id)
                TEAM_ID="${2:?--team-id requires a value}"
                shift 2
                ;;
            --app-group)
                APP_GROUP_OVERRIDE="${2:?--app-group requires a value}"
                IOS_APP_GROUP="$APP_GROUP_OVERRIDE"
                shift 2
                ;;
            --enable-increased-memory-limit)
                ENABLE_INCREASED_MEMORY_LIMIT="1"
                shift
                ;;
            --seed-custom-text)
                SEED_CUSTOM_TEXT="${2:?--seed-custom-text requires a value}"
                shift 2
                ;;
            --show-onboarding)
                SKIP_ONBOARDING="0"
                shift
                ;;
            --force-band)
                FORCE_MEMORY_BAND="${2:?--force-band requires a value}"
                shift 2
                ;;
            --force-critical-once)
                FORCE_CRITICAL_ONCE="1"
                shift
                ;;
            --enable-proactive-prefetch)
                ENABLE_PROACTIVE_PREFETCH="1"
                shift
                ;;
            --mlx-memory-limit-mb)
                MLX_MEMORY_LIMIT_MB="${2:?--mlx-memory-limit-mb requires a value}"
                shift 2
                ;;
            --mlx-cache-limit-mb)
                MLX_CACHE_LIMIT_MB="${2:?--mlx-cache-limit-mb requires a value}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                POSITIONAL+=("$1")
                shift
                ;;
        esac
    done
}

ensure_run_dir() {
    if [ -z "$RUN_ID" ]; then
        RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
    fi
    RUN_DIR="$RUNS_ROOT/$RUN_ID"
    mkdir -p "$RUN_DIR"
    printf '%s\n' "$RUN_ID" > "$LAST_RUN_FILE"
}

load_current_run_dir() {
    if [ -z "$RUN_ID" ]; then
        if [ ! -f "$LAST_RUN_FILE" ]; then
            fail "No current iOS device run. Start one with scripts/ios_device.sh start."
        fi
        RUN_ID="$(cat "$LAST_RUN_FILE")"
    fi
    RUN_DIR="$RUNS_ROOT/$RUN_ID"
    [ -d "$RUN_DIR" ] || fail "Run directory not found: $RUN_DIR"
    if [ -z "$APP_GROUP_OVERRIDE" ] && [ -f "$RUN_DIR/run-manifest.json" ]; then
        local manifest_app_group
        manifest_app_group="$(/usr/bin/python3 - "$RUN_DIR/run-manifest.json" <<'PY'
import json
import sys

try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("app_group", ""))
except Exception:
    print("")
PY
)"
        if [ -n "$manifest_app_group" ]; then
            IOS_APP_GROUP="$manifest_app_group"
        fi
    fi
}

load_or_create_run_dir() {
    if [ -z "$RUN_ID" ] && [ -f "$LAST_RUN_FILE" ]; then
        load_current_run_dir
    else
        ensure_run_dir
    fi
}

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

configure_signing_inputs() {
    if is_truthy "$ENABLE_INCREASED_MEMORY_LIMIT"; then
        IOS_APP_ENTITLEMENTS="Sources/iOS/VocelloiOS.entitlements"
        IOS_EXTENSION_ENTITLEMENTS="Sources/iOSEngineExtension/VocelloEngineExtension.entitlements"
    else
        IOS_APP_ENTITLEMENTS="Sources/iOS/VocelloiOSLocalDevice.entitlements"
        IOS_EXTENSION_ENTITLEMENTS="Sources/iOSEngineExtension/VocelloEngineExtensionLocalDevice.entitlements"
    fi
}

select_device() {
    if [ -z "$RUN_DIR" ]; then
        load_or_create_run_dir
    fi
    local devices_json="$RUN_DIR/devices.json"
    local devices_log="$RUN_DIR/devices.log"

    xcrun devicectl \
        --json-output "$devices_json" \
        --log-output "$devices_log" \
        list devices >/dev/null

    local selected_env="$RUN_DIR/selected-device.env"
    DEVICE_ID_OVERRIDE="$DEVICE_ID_OVERRIDE" /usr/bin/python3 - "$devices_json" > "$selected_env" <<'PY'
import json
import os
import shlex
import sys

path = sys.argv[1]
override = os.environ.get("DEVICE_ID_OVERRIDE", "").strip()
data = json.load(open(path))
devices = data.get("result", {}).get("devices", [])

def value(device, *keys):
    current = device
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current

def matches_override(device):
    if not override:
        return False
    candidates = [
        device.get("identifier"),
        value(device, "hardwareProperties", "udid"),
        value(device, "hardwareProperties", "serialNumber"),
        value(device, "deviceProperties", "name"),
    ]
    candidates.extend(value(device, "connectionProperties", "potentialHostnames") or [])
    return override in [str(candidate) for candidate in candidates if candidate]

selected = None
if override:
    for device in devices:
        if matches_override(device):
            selected = device
            break
else:
    for device in devices:
        if (
            value(device, "hardwareProperties", "marketingName") == "iPhone 17 Pro"
            and value(device, "connectionProperties", "pairingState") == "paired"
            and str(value(device, "hardwareProperties", "reality")).lower() == "physical"
        ):
            selected = device
            break
    if selected is None:
        for device in devices:
            if (
                value(device, "hardwareProperties", "deviceType") == "iPhone"
                and value(device, "connectionProperties", "pairingState") == "paired"
                and str(value(device, "hardwareProperties", "reality")).lower() == "physical"
            ):
                selected = device
                break

if selected is None:
    raise SystemExit("No paired physical iPhone found. Connect and unlock the device, then retry.")

fields = {
    "DEVICE_ID": selected.get("identifier", ""),
    "DEVICE_UDID": value(selected, "hardwareProperties", "udid") or "",
    "DEVICE_NAME": value(selected, "deviceProperties", "name") or "",
    "DEVICE_MARKETING_NAME": value(selected, "hardwareProperties", "marketingName") or "",
    "DEVICE_OS_VERSION": value(selected, "deviceProperties", "osVersionNumber") or "",
    "DEVICE_OS_BUILD": value(selected, "deviceProperties", "osBuildUpdate") or "",
    "SCREEN_VIEWING_URL": value(selected, "deviceProperties", "screenViewingURL") or "",
}
for key, field_value in fields.items():
    print(f"{key}={shlex.quote(str(field_value))}")
PY

    # shellcheck disable=SC1090
    . "$selected_env"
    APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/Vocello.app"
}

capture_device_details() {
    select_device
    xcrun devicectl \
        --json-output "$RUN_DIR/device-details.json" \
        --log-output "$RUN_DIR/device-details.log" \
        device info details \
        --device "$DEVICE_ID" >/dev/null || true
}

write_run_manifest() {
    local status="$1"
    local manifest_path="$RUN_DIR/run-manifest.json"
    configure_signing_inputs
    mkdir -p "$RUN_DIR"
    RUN_ID="$RUN_ID" \
    RUN_DIR="$RUN_DIR" \
    DEVICE_ID="$DEVICE_ID" \
    DEVICE_UDID="$DEVICE_UDID" \
    DEVICE_NAME="$DEVICE_NAME" \
    DEVICE_MARKETING_NAME="$DEVICE_MARKETING_NAME" \
    DEVICE_OS_VERSION="$DEVICE_OS_VERSION" \
    DEVICE_OS_BUILD="$DEVICE_OS_BUILD" \
    TEAM_ID="$TEAM_ID" \
    CATALOG_URL="$CATALOG_URL" \
    ALLOWED_HOSTS="$ALLOWED_HOSTS" \
    FORCE_MEMORY_BAND="$FORCE_MEMORY_BAND" \
    FORCE_CRITICAL_ONCE="$FORCE_CRITICAL_ONCE" \
    ENABLE_PROACTIVE_PREFETCH="$ENABLE_PROACTIVE_PREFETCH" \
    MLX_MEMORY_LIMIT_MB="$MLX_MEMORY_LIMIT_MB" \
    MLX_CACHE_LIMIT_MB="$MLX_CACHE_LIMIT_MB" \
    SEED_CUSTOM_TEXT="$SEED_CUSTOM_TEXT" \
    SKIP_ONBOARDING="$SKIP_ONBOARDING" \
    APP_PATH="$APP_PATH" \
    IOS_APP_BUNDLE_ID="$IOS_APP_BUNDLE_ID" \
    IOS_APP_GROUP="$IOS_APP_GROUP" \
    SHIPPING_IOS_APP_GROUP="$SHIPPING_IOS_APP_GROUP" \
    ENABLE_INCREASED_MEMORY_LIMIT="$ENABLE_INCREASED_MEMORY_LIMIT" \
    IOS_APP_ENTITLEMENTS="$IOS_APP_ENTITLEMENTS" \
    IOS_EXTENSION_ENTITLEMENTS="$IOS_EXTENSION_ENTITLEMENTS" \
    STATUS="$status" \
    /usr/bin/python3 - "$manifest_path" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

manifest = {
    "run_id": os.environ["RUN_ID"],
    "status": os.environ["STATUS"],
    "updated_at_utc": datetime.now(timezone.utc).isoformat(),
    "run_dir": os.environ["RUN_DIR"],
    "bundle_id": os.environ["IOS_APP_BUNDLE_ID"],
    "app_group": os.environ["IOS_APP_GROUP"],
    "shipping_app_group": os.environ["SHIPPING_IOS_APP_GROUP"],
    "team_id": os.environ["TEAM_ID"],
    "signing": {
        "increased_memory_limit_enabled": os.environ["ENABLE_INCREASED_MEMORY_LIMIT"],
        "app_entitlements": os.environ["IOS_APP_ENTITLEMENTS"],
        "extension_entitlements": os.environ["IOS_EXTENSION_ENTITLEMENTS"],
    },
    "device": {
        "core_device_id": os.environ["DEVICE_ID"],
        "udid": os.environ["DEVICE_UDID"],
        "name": os.environ["DEVICE_NAME"],
        "marketing_name": os.environ["DEVICE_MARKETING_NAME"],
        "os_version": os.environ["DEVICE_OS_VERSION"],
        "os_build": os.environ["DEVICE_OS_BUILD"],
    },
    "launch_environment": {
        "QWENVOICE_NATIVE_TELEMETRY_MODE": "lightweight",
        "QVOICE_IOS_DEVICE_RUN_ID": os.environ["RUN_ID"],
        "QVOICE_IOS_MODEL_CATALOG_URL": os.environ["CATALOG_URL"] or None,
        "QVOICE_IOS_MODEL_ALLOWED_HOSTS": os.environ["ALLOWED_HOSTS"] or None,
        "QVOICE_IOS_MEMORY_GUARD_FORCE_BAND": os.environ["FORCE_MEMORY_BAND"] or None,
        "QVOICE_IOS_MEMORY_GUARD_FORCE_CRITICAL_ONCE": os.environ["FORCE_CRITICAL_ONCE"] or None,
        "QVOICE_IOS_ENABLE_PROACTIVE_PREFETCH": os.environ["ENABLE_PROACTIVE_PREFETCH"] if os.environ["ENABLE_PROACTIVE_PREFETCH"] not in ("", "0") else None,
        "QVOICE_IOS_MLX_MEMORY_LIMIT_MB": os.environ["MLX_MEMORY_LIMIT_MB"] or None,
        "QVOICE_IOS_MLX_CACHE_LIMIT_MB": os.environ["MLX_CACHE_LIMIT_MB"] or None,
        "QVOICE_IOS_TEST_CUSTOM_TEXT": os.environ["SEED_CUSTOM_TEXT"] or None,
        "QVOICE_IOS_SKIP_ONBOARDING": os.environ["SKIP_ONBOARDING"] or None,
    },
    "app_path": os.environ["APP_PATH"],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

check_catalog_readiness() {
    local url="$CATALOG_URL"
    if [ -z "$url" ]; then
        url="$(plist_read "$ROOT_DIR/Sources/iOS/Info.plist" "QVoiceModelCatalogURL" || true)"
    fi
    # shellcheck disable=SC2016
    if [[ "$url" == *'$('* ]]; then
        url="$DEFAULT_IOS_CATALOG_URL"
    fi

    if [ -z "$url" ]; then
        echo "catalog: no URL configured"
        return 0
    fi

    echo "catalog: $url"
    if command -v jq >/dev/null 2>&1; then
        if "$SCRIPT_DIR/check_ios_catalog.sh" --url "$url" > "$RUN_DIR/catalog-check.json" 2> "$RUN_DIR/catalog-check.stderr"; then
            echo "catalog check: ok"
        else
            echo "catalog check: warning; see $RUN_DIR/catalog-check.stderr"
        fi
    else
        if curl -fsSL --max-time 20 "$url" -o "$RUN_DIR/catalog-response.json"; then
            echo "catalog fetch: ok"
        else
            echo "catalog fetch: warning; first-time model downloads may fail"
        fi
    fi
}

do_doctor() {
    ensure_run_dir
    configure_signing_inputs
    capture_device_details
    {
        echo "=== Vocello iPhone Device Doctor ==="
        echo "run:    $RUN_ID"
        echo "dir:    $RUN_DIR"
        echo "device: $DEVICE_NAME / $DEVICE_MARKETING_NAME / iOS $DEVICE_OS_VERSION ($DEVICE_OS_BUILD)"
        echo "id:     $DEVICE_ID"
        echo "udid:   $DEVICE_UDID"
        echo "team:   $TEAM_ID"
        echo "group:  $IOS_APP_GROUP"
        echo "ents:   app=$IOS_APP_ENTITLEMENTS"
        echo "        extension=$IOS_EXTENSION_ENTITLEMENTS"
        if is_truthy "$ENABLE_INCREASED_MEMORY_LIMIT"; then
            echo "memory: increased-memory-limit requested"
        else
            echo "memory: increased-memory-limit disabled for local Debug signing"
        fi
        if [ -n "$MLX_MEMORY_LIMIT_MB" ] || [ -n "$MLX_CACHE_LIMIT_MB" ]; then
            echo "mlx:    memory-limit-mb=${MLX_MEMORY_LIMIT_MB:-default} cache-limit-mb=${MLX_CACHE_LIMIT_MB:-default}"
        fi
        if [ "$IOS_APP_GROUP" != "$SHIPPING_IOS_APP_GROUP" ]; then
            echo "note:   using local Debug App Group; shipping profile still expects $SHIPPING_IOS_APP_GROUP"
        fi
        echo ""
        echo "xcodebuild: $(xcodebuild -version | tr '\n' ' ')"
        echo "devicectl:  $(xcrun devicectl --version 2>/dev/null || echo available)"
        if [ -d "/System/Applications/iPhone Mirroring.app" ]; then
            echo "mirror:    /System/Applications/iPhone Mirroring.app"
        else
            echo "mirror:    warning; iPhone Mirroring.app not found"
        fi
        if [ -n "$SCREEN_VIEWING_URL" ]; then
            echo "screen:    $SCREEN_VIEWING_URL"
        else
            echo "screen:    warning; CoreDevice did not report a screenViewingURL"
        fi
        echo ""
        check_catalog_readiness
    } | tee "$RUN_DIR/doctor.txt"
    write_run_manifest "doctor"
}

explain_build_failure() {
    local log_path="$RUN_DIR/xcodebuild-device.log"
    [ -f "$log_path" ] || return 0
    if grep -E "Application Group|Provisioning profile|increased-memory|entitlement" "$log_path" >/dev/null 2>&1; then
        cat <<EOF

Signing note:
  The device build failed while Xcode was creating or matching signing profiles.
  This run used App Group '$IOS_APP_GROUP' and app entitlements '$IOS_APP_ENTITLEMENTS'.

  If Apple reports the App Group is unavailable, retry with a unique value:
    scripts/ios_device.sh start --app-group group.<your-domain>.vocello.shared

  If you enabled increased-memory-limit, the Apple Developer profile must already
  have that restricted entitlement approved. Local Debug runs leave it disabled
  by default so the app can still be installed for workflow and diagnostics smoke.
EOF
    fi
}

do_build() {
    ensure_run_dir
    configure_signing_inputs
    capture_device_details
    mkdir -p "$ARTIFACT_ROOT"
    echo "==> Regenerating Xcode project"
    "$SCRIPT_DIR/regenerate_project.sh"
    echo "==> Building $SCHEME $CONFIGURATION for $DEVICE_NAME"
    rm -rf "$RUN_DIR/vocello-ios-device-build.xcresult"
    set +e
    QWENVOICE_DEVELOPMENT_TEAM="$TEAM_ID" \
    xcodebuild \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "id=$DEVICE_UDID" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -resultBundlePath "$RUN_DIR/vocello-ios-device-build.xcresult" \
        -resultBundleVersion 3 \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        QVOICE_IOS_APP_GROUP_IDENTIFIER="$IOS_APP_GROUP" \
        QVOICE_IOS_APP_ENTITLEMENTS="$IOS_APP_ENTITLEMENTS" \
        QVOICE_IOS_EXTENSION_ENTITLEMENTS="$IOS_EXTENSION_ENTITLEMENTS" \
        build 2>&1 | tee "$RUN_DIR/xcodebuild-device.log"
    local build_status="${PIPESTATUS[0]}"
    set -e
    if [ "$build_status" -ne 0 ]; then
        explain_build_failure
        return "$build_status"
    fi

    [ -d "$APP_PATH" ] || fail "Expected built app is missing: $APP_PATH"
    printf '%s\n' "$APP_PATH" > "$RUN_DIR/app-path.txt"
    write_run_manifest "built"
    echo "Built app: $APP_PATH"
}

do_install() {
    load_or_create_run_dir
    capture_device_details
    if [ ! -d "$APP_PATH" ] && [ -f "$RUN_DIR/app-path.txt" ]; then
        APP_PATH="$(cat "$RUN_DIR/app-path.txt")"
    fi
    [ -d "$APP_PATH" ] || fail "Device Debug app not found. Run scripts/ios_device.sh build first."

    echo "==> Installing $APP_PATH on $DEVICE_NAME"
    xcrun devicectl \
        --json-output "$RUN_DIR/install.json" \
        --log-output "$RUN_DIR/install.log" \
        device install app \
        --device "$DEVICE_ID" \
        "$APP_PATH"
    write_run_manifest "installed"
}

write_launch_environment() {
    RUN_ID="$RUN_ID" \
    CATALOG_URL="$CATALOG_URL" \
    ALLOWED_HOSTS="$ALLOWED_HOSTS" \
    FORCE_MEMORY_BAND="$FORCE_MEMORY_BAND" \
    FORCE_CRITICAL_ONCE="$FORCE_CRITICAL_ONCE" \
    ENABLE_PROACTIVE_PREFETCH="$ENABLE_PROACTIVE_PREFETCH" \
    MLX_MEMORY_LIMIT_MB="$MLX_MEMORY_LIMIT_MB" \
    MLX_CACHE_LIMIT_MB="$MLX_CACHE_LIMIT_MB" \
    SEED_CUSTOM_TEXT="$SEED_CUSTOM_TEXT" \
    SKIP_ONBOARDING="$SKIP_ONBOARDING" \
    /usr/bin/python3 - "$RUN_DIR/launch-env.json" <<'PY'
import json
import os
import sys

env = {
    "QWENVOICE_NATIVE_TELEMETRY_MODE": "lightweight",
    "QVOICE_IOS_DEVICE_RUN_ID": os.environ["RUN_ID"],
}
optional = {
    "QVOICE_IOS_MODEL_CATALOG_URL": os.environ.get("CATALOG_URL", ""),
    "QVOICE_IOS_MODEL_ALLOWED_HOSTS": os.environ.get("ALLOWED_HOSTS", ""),
    "QVOICE_IOS_MEMORY_GUARD_FORCE_BAND": os.environ.get("FORCE_MEMORY_BAND", ""),
    "QVOICE_IOS_MEMORY_GUARD_FORCE_CRITICAL_ONCE": os.environ.get("FORCE_CRITICAL_ONCE", ""),
    "QVOICE_IOS_ENABLE_PROACTIVE_PREFETCH": os.environ.get("ENABLE_PROACTIVE_PREFETCH", ""),
    "QVOICE_IOS_MLX_MEMORY_LIMIT_MB": os.environ.get("MLX_MEMORY_LIMIT_MB", ""),
    "QVOICE_IOS_MLX_CACHE_LIMIT_MB": os.environ.get("MLX_CACHE_LIMIT_MB", ""),
    "QVOICE_IOS_TEST_CUSTOM_TEXT": os.environ.get("SEED_CUSTOM_TEXT", ""),
    "QVOICE_IOS_SKIP_ONBOARDING": os.environ.get("SKIP_ONBOARDING", ""),
}
for key, value in optional.items():
    if value:
        env[key] = value

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(env, handle, sort_keys=True)
PY
}

do_launch() {
    load_or_create_run_dir
    capture_device_details
    write_launch_environment
    local launch_env
    launch_env="$(cat "$RUN_DIR/launch-env.json")"
    echo "==> Launching $IOS_APP_BUNDLE_ID on $DEVICE_NAME"
    xcrun devicectl \
        --json-output "$RUN_DIR/launch.json" \
        --log-output "$RUN_DIR/launch.log" \
        device process launch \
        --device "$DEVICE_ID" \
        --terminate-existing \
        --activate \
        --environment-variables "$launch_env" \
        "$IOS_APP_BUNDLE_ID"
    write_run_manifest "launched"
}

do_mirror() {
    load_or_create_run_dir
    capture_device_details
    if [ -n "$SCREEN_VIEWING_URL" ]; then
        /usr/bin/open "$SCREEN_VIEWING_URL" \
            || /usr/bin/open -a "/System/Applications/iPhone Mirroring.app" \
            || /usr/bin/open -b "$SCREEN_MIRROR_BUNDLE_ID"
    else
        /usr/bin/open -a "/System/Applications/iPhone Mirroring.app" \
            || /usr/bin/open -b "$SCREEN_MIRROR_BUNDLE_ID"
    fi
    /usr/bin/osascript -e "tell application id \"$SCREEN_MIRROR_BUNDLE_ID\" to activate" >/dev/null 2>&1 || true
    write_run_manifest "mirror_opened"
    echo "Opened iPhone Mirroring for $DEVICE_NAME."
}

do_screenshot() {
    load_current_run_dir
    local label="${1:-screen}"
    local safe_label
    safe_label="$(printf '%s' "$label" | tr -c '[:alnum:]_-' '_')"
    local screenshot_dir="$RUN_DIR/screenshots"
    mkdir -p "$screenshot_dir"
    local path
    path="$screenshot_dir/$(date -u +"%Y%m%dT%H%M%SZ")_${safe_label}.png"
    /usr/sbin/screencapture -x "$path"
    echo "$path"
}

copy_from_domain() {
    local domain_type="$1"
    local domain_identifier="$2"
    local source="$3"
    local destination="$4"
    local name="$5"
    mkdir -p "$(dirname "$destination")"
    if xcrun devicectl \
        --json-output "$RUN_DIR/pull-${name}.json" \
        --log-output "$RUN_DIR/pull-${name}.log" \
        device copy from \
        --device "$DEVICE_ID" \
        --domain-type "$domain_type" \
        --domain-identifier "$domain_identifier" \
        --source "$source" \
        --destination "$destination" >/dev/null; then
        echo "pulled: $source -> $destination"
        return 0
    fi

    echo "warning: could not pull $source; see $RUN_DIR/pull-${name}.log"
    return 1
}

copy_from_app_group() {
    local source="$1"
    local destination="$2"
    local name="$3"
    copy_from_domain appGroupDataContainer "$IOS_APP_GROUP" "$source" "$destination" "$name"
}

copy_from_app_container() {
    local source="$1"
    local destination="$2"
    local name="$3"
    copy_from_domain appDataContainer "$IOS_APP_BUNDLE_ID" "$source" "$destination" "$name"
}

do_pull() {
    load_current_run_dir
    capture_device_details
    local pull_dir="$RUN_DIR/pulled"
    mkdir -p "$pull_dir"

    xcrun devicectl \
        --json-output "$RUN_DIR/apps.json" \
        --log-output "$RUN_DIR/apps.log" \
        device info apps \
        --device "$DEVICE_ID" \
        --bundle-id "$IOS_APP_BUNDLE_ID" >/dev/null || true
    xcrun devicectl \
        --json-output "$RUN_DIR/processes.json" \
        --log-output "$RUN_DIR/processes.log" \
        device info processes \
        --device "$DEVICE_ID" >/dev/null || true

    copy_from_app_group "Vocello/diagnostics/$RUN_ID" "$pull_dir/diagnostics" "diagnostics" \
        || copy_from_app_container "Library/Caches/Vocello/diagnostics/$RUN_ID" "$pull_dir/diagnostics" "diagnostics-app-container" \
        || true
    copy_from_app_group "Vocello/history.sqlite" "$pull_dir/history.sqlite" "history" || true
    copy_from_app_group "Vocello/outputs" "$pull_dir/outputs" "outputs" || true
    copy_from_app_group "Vocello/voices" "$pull_dir/voices" "voices" || true

    write_run_manifest "pulled"
    echo "Evidence bundle: $RUN_DIR"
}

command="${1:-help}"
if [ $# -gt 0 ]; then
    shift
fi

case "$command" in
    doctor)
        parse_common_options "$@"
        do_doctor
        ;;
    build)
        parse_common_options "$@"
        do_build
        ;;
    install)
        parse_common_options "$@"
        do_install
        ;;
    launch)
        parse_common_options "$@"
        do_launch
        ;;
    mirror)
        parse_common_options "$@"
        do_mirror
        ;;
    start)
        parse_common_options "$@"
        do_doctor
        do_build
        do_install
        do_launch
        do_mirror
        echo "Run ready: $RUN_DIR"
        ;;
    screenshot)
        parse_common_options "$@"
        do_screenshot "${POSITIONAL[0]:-screen}"
        ;;
    pull)
        parse_common_options "$@"
        do_pull
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        echo "Unknown command: $command" >&2
        usage >&2
        exit 2
        ;;
esac
