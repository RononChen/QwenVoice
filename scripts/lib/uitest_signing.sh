# Shared code-signing args for macOS XCUITest lanes (VocelloMacUITests).
#
# The UI test runner must be signed with a stable Apple Development identity —
# not ad-hoc — so TCC Accessibility grants survive rebuilds. See
# docs/reference/macos-testing.md § UI test machine setup.
#
# shellcheck shell=bash

# shellcheck source=dev_signing.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dev_signing.sh"

# Derive team OU from the Apple Development cert (same rule as ios_device.sh).
uitest_derive_team() {
    if [[ -n "${QWENVOICE_DEVELOPMENT_TEAM:-}" ]]; then
        printf '%s' "$QWENVOICE_DEVELOPMENT_TEAM"
        return 0
    fi
    local t
    t="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | grep -oE 'OU=[A-Z0-9]+' | head -1 | cut -d= -f2)"
    [[ -n "$t" ]] || return 1
    export QWENVOICE_DEVELOPMENT_TEAM="$t"
    printf '%s' "$t"
}

# Print signing identity for macOS UI tests; falls back to ad-hoc with a warning.
uitest_resolve_signing_identity() {
    resolve_dev_signing_identity
}

# Locate the built UI test runner (xctest bundle) under DerivedData.
uitest_find_runner_bundle() {
    local derived="${1:-}"
    [[ -n "$derived" ]] || return 1
    find "$derived/Build/Products" -name '*-Runner.app' -type d 2>/dev/null | head -1
}

# Emit xcodebuild setting overrides for a signed macOS UI test run (one KEY=VALUE per line).
uitest_xcodebuild_signing_args() {
    local identity team
    identity="$(uitest_resolve_signing_identity)"
    if [[ "$identity" == "-" ]]; then
        printf '%s\n' \
            'CODE_SIGN_STYLE=Manual' \
            'CODE_SIGN_IDENTITY=-' \
            'ENABLE_HARDENED_RUNTIME=NO' \
            'CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES'
        return 0
    fi
    team="$(uitest_derive_team 2>/dev/null || true)"
    if [[ -n "$team" ]]; then
        printf '%s\n' \
            "CODE_SIGN_STYLE=Manual" \
            "CODE_SIGN_IDENTITY=$identity" \
            "DEVELOPMENT_TEAM=$team" \
            'ENABLE_HARDENED_RUNTIME=NO' \
            'CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES'
    else
        printf '%s\n' \
            "CODE_SIGN_STYLE=Manual" \
            "CODE_SIGN_IDENTITY=$identity" \
            'ENABLE_HARDENED_RUNTIME=NO' \
            'CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES'
    fi
}

# Populates UITEST_XCODEBUILD_SIGNING_ARGS (bash 3.2-safe; no mapfile).
UITEST_XCODEBUILD_SIGNING_ARGS=()

load_uitest_signing_args() {
    UITEST_XCODEBUILD_SIGNING_ARGS=()
    local _line
    while IFS= read -r _line; do
        UITEST_XCODEBUILD_SIGNING_ARGS+=("$_line")
    done < <(uitest_xcodebuild_signing_args)
}
