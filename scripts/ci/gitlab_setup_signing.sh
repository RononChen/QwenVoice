#!/usr/bin/env bash
# Import Developer ID cert + notary API key for GitLab macOS release jobs.
# Expects GitLab CI/CD variables (same names as the former GitHub Actions secrets):
#   APPLE_DEV_ID_APP_P12_BASE64, APPLE_DEV_ID_APP_P12_PASSWORD
#   APPLE_NOTARY_KEY_ID, APPLE_NOTARY_PRIVATE_KEY_P8, APPLE_NOTARY_ISSUER_ID, APPLE_TEAM_ID
set -euo pipefail

: "${APPLE_DEV_ID_APP_P12_BASE64:?missing APPLE_DEV_ID_APP_P12_BASE64}"
: "${APPLE_DEV_ID_APP_P12_PASSWORD:?missing APPLE_DEV_ID_APP_P12_PASSWORD}"
: "${APPLE_NOTARY_KEY_ID:?missing APPLE_NOTARY_KEY_ID}"
: "${APPLE_NOTARY_PRIVATE_KEY_P8:?missing APPLE_NOTARY_PRIVATE_KEY_P8}"
: "${APPLE_NOTARY_ISSUER_ID:?missing APPLE_NOTARY_ISSUER_ID}"
: "${APPLE_TEAM_ID:?missing APPLE_TEAM_ID}"

KEYCHAIN_PATH="${CI_PROJECT_DIR:-/tmp}/vocello-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"
CERT_PATH="${CI_PROJECT_DIR:-/tmp}/cert.p12"
KEY_PATH="${CI_PROJECT_DIR:-/tmp}/AuthKey_${APPLE_NOTARY_KEY_ID}.p8"

echo "$APPLE_DEV_ID_APP_P12_BASE64" | base64 --decode > "$CERT_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

security import "$CERT_PATH" \
  -P "$APPLE_DEV_ID_APP_P12_PASSWORD" \
  -A -t cert -f pkcs12 \
  -k "$KEYCHAIN_PATH"
rm -f "$CERT_PATH"

security list-keychain -d user -s "$KEYCHAIN_PATH" $(security list-keychain -d user | tr -d '"')
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" > /dev/null

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
  | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in imported cert" >&2; exit 1; }
echo "Resolved signing identity: $IDENTITY"

printf '%s' "$APPLE_NOTARY_PRIVATE_KEY_P8" > "$KEY_PATH"
chmod 600 "$KEY_PATH"
head -1 "$KEY_PATH" | grep -q "BEGIN PRIVATE KEY" \
  || { echo "APPLE_NOTARY_PRIVATE_KEY_P8 is not PKCS#8" >&2; exit 1; }

export QWENVOICE_CODESIGN_KEYCHAIN="$KEYCHAIN_PATH"
export QWENVOICE_SIGNING_IDENTITY="$IDENTITY"
export APPLE_API_KEY_PATH="$KEY_PATH"
export APPLE_API_KEY_ID="$APPLE_NOTARY_KEY_ID"
export APPLE_API_ISSUER_ID="$APPLE_NOTARY_ISSUER_ID"
export APPLE_TEAM_ID="$APPLE_TEAM_ID"
