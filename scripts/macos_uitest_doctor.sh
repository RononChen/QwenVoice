#!/usr/bin/env bash
# macOS XCUITest / UI-automation readiness checks (Accessibility, automation mode, signing).
#
# Complements scripts/permissions_doctor.sh (mic/speech TCC). Read-only except --open-accessibility.
#
# usage:
#   scripts/macos_uitest_doctor.sh                  # diagnose
#   scripts/macos_uitest_doctor.sh --open-accessibility  # open System Settings pane

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/uitest_signing.sh
. "$ROOT_DIR/scripts/lib/uitest_signing.sh"

DERIVED="${ROOT_DIR}/build/DerivedData"
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[0;32m[ok]\033[0m %s\n' "$*" >&2; }

usage() {
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

section_automation_mode() {
    echo "==> UI Automation mode (Authorization Services)"
    if ! command -v automationmodetool >/dev/null 2>&1; then
        warn "automationmodetool not found"
        return 0
    fi
    local out
    out="$(automationmodetool 2>&1 || true)"
    echo "$out" | sed 's/^/    /'
    if grep -q 'DOES NOT REQUIRE user authentication' <<<"$out"; then
        ok "Gate 1: no password required to enable UI Automation"
    elif grep -q 'requires user authentication' <<<"$out"; then
        cat >&2 <<'EOF'
    ⚠ Gate 1 OPEN: XCTest will ask for your login password each run.
      One-time fix (admin password once):
        sudo /usr/bin/automationmodetool enable-automationmode-without-authentication
EOF
    fi
}

section_signing() {
    echo "==> Code signing (app + UI test runner)"
    local identity team
    identity="$(uitest_resolve_signing_identity)"
    team="$(uitest_derive_team 2>/dev/null || true)"
    echo "    resolved identity: $identity"
    [[ -n "$team" ]] && echo "    development team:  $team"
    if [[ "$identity" == "-" ]]; then
        warn "ad-hoc signing — UITest runner TCC grants will not survive rebuilds"
        echo "    Install Apple Development cert: Xcode → Settings → Accounts → Manage Certificates"
    else
        ok "stable Apple Development identity available"
    fi
    local runner
    runner="$(uitest_find_runner_bundle "$DERIVED" || true)"
    if [[ -n "$runner" && -d "$runner" ]]; then
        echo "    runner: $runner"
        echo "    designated requirement:"
        codesign -d -r- "$runner" 2>/dev/null | grep designated | sed 's/^/      /' || true
        if codesign -dvv "$runner" 2>&1 | grep -q 'Signature=adhoc'; then
            warn "runner is ad-hoc — re-run scripts/macos_test.sh test after signing fix"
        else
            ok "runner is certificate-signed"
        fi
    else
        echo "    (no *-Runner.app under $DERIVED yet — run scripts/macos_test.sh test once)"
    fi
}

decode_auth() {
    case "$1" in
        0) echo "denied" ;;
        2) echo "allowed" ;;
        *) echo "auth=$1" ;;
    esac
}

section_accessibility_tcc() {
    echo "==> TCC Accessibility (Gate 2 — manual toggles in System Settings)"
    local clients=(
        'com.apple.dt.Xcode'
        'com.apple.dt.Xcode-Helper'
        'com.qwenvoice.app.uitests.xctrunner'
        'com.qwenvoice.app.uitests'
    )
    if [[ ! -r "$TCC_DB" ]]; then
        cat <<'EOF'
    (cannot read ~/Library/Application Support/com.apple.TCC/TCC.db —
     grant your terminal Full Disk Access to inspect rows, or check manually)
EOF
    else
        local found=0 row
        for c in "${clients[@]}"; do
            row="$(sqlite3 "$TCC_DB" \
                "SELECT auth_value FROM access WHERE service='kTCCServiceAccessibility' AND client='$c' LIMIT 1;" \
                2>/dev/null || true)"
            if [[ -n "$row" ]]; then
                found=1
                printf '    %-40s %s\n' "$c" "$(decode_auth "$row")"
            fi
        done
        (( found )) || echo "    (no Accessibility rows yet — run a UI test and approve prompts)"
    fi
    cat <<'EOF'
    Enable manually (one-time per machine):
      System Settings → Privacy & Security → Accessibility
        • Xcode
        • Xcode Helper
        • VocelloMacUITests-Runner (appears after first UI test build)
    Or: scripts/macos_uitest_doctor.sh --open-accessibility
EOF
}

section_keychain() {
    echo "==> Keychain / codesign (Gate 3)"
    local identity
    identity="$(uitest_resolve_signing_identity)"
    if [[ "$identity" == "-" ]]; then
        echo "    (skipped — ad-hoc signing)"
        return 0
    fi
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$identity"; then
        ok "signing identity present in keychain"
    else
        warn "identity not found in keychain search list"
    fi
    cat <<'EOF'
    If codesign prompts every build, click "Always Allow" once, or run:
      security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" \
        ~/Library/Keychains/login.keychain-db
    (requires your login keychain password — cannot be scripted without it)
EOF
}

open_accessibility() {
    note "Opening Accessibility privacy pane…"
    open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility" \
        2>/dev/null \
        || open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" \
        2>/dev/null \
        || open /System/Library/PreferencePanes/Security.prefPane
    cat <<'EOF'
Enable:
  • Xcode
  • Xcode Helper
  • VocelloMacUITests-Runner (after first test build)
Then run: scripts/macos_test.sh test
EOF
}

main() {
    case "${1:-}" in
        --open-accessibility) open_accessibility ;;
        -h|--help|help) usage ;;
        "")
            section_automation_mode
            section_signing
            section_accessibility_tcc
            section_keychain
            echo "==> Next: scripts/macos_test.sh test"
            ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage
            exit 2
            ;;
    esac
}

main "$@"
