#!/usr/bin/env bash
# One-shot GitLab cutover helper for Vocello (QwenVoice).
#
# Requires:
#   - GITLAB_TOKEN  GitLab PAT with api + write_repository (export before running)
#   - gh            authenticated (for GitHub import token + optional mirror PAT)
#
# Usage:
#   export GITLAB_TOKEN='glpat-...'
#   ./scripts/gitlab_setup_all.sh
#
# Optional:
#   SKIP_IMPORT=1     project already exists; only push + CI var names
#   SET_CI_VARS=1     also push Apple signing vars (values must exist in env; see below)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Optional local secrets file (never commit .gitlab-ci-secrets.env)
if [[ -f "$ROOT/.gitlab-ci-secrets.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.gitlab-ci-secrets.env"
  set +a
fi

GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-VocelloApp}"
PROJECT_PATH="${GITLAB_NAMESPACE}/QwenVoice"
API="https://${GITLAB_HOST}/api/v4"

: "${GITLAB_TOKEN:?Set GITLAB_TOKEN (GitLab PAT with api + write_repository). Create at: https://${GITLAB_HOST}/-/user_settings/personal_access_tokens}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI required (mise install gh)" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "gh not authenticated — run: gh auth login" >&2
  exit 1
fi

auth_header=(--header "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

project_http="$(curl -s "${auth_header[@]}" "${API}/projects/${PROJECT_PATH//\//%2F}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('http_url_to_repo', d.get('message', '')))
" 2>/dev/null || true)"

if [[ "$project_http" == "404 Project Not Found" || -z "$project_http" ]]; then
  if [[ "${SKIP_IMPORT:-0}" == "1" ]]; then
    echo "Project not found and SKIP_IMPORT=1 — create ${PROJECT_PATH} on GitLab first." >&2
    exit 1
  fi
  echo "==> Importing PowerBeef/QwenVoice from GitHub into ${PROJECT_PATH}..."
  GITHUB_TOKEN="$(gh auth token)"
  REPO_ID="$(gh api repos/PowerBeef/QwenVoice --jq .id)"
  IMPORT_RESP="$(curl -s "${auth_header[@]}" --form "personal_access_token=${GITHUB_TOKEN}" \
    --form "repo_id=${REPO_ID}" \
    --form "target_namespace=${GITLAB_NAMESPACE}" \
    --form "new_name=QwenVoice" \
    "${API}/import/github")"
  IMPORT_ID="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" <<<"$IMPORT_RESP")"
  if [[ -z "$IMPORT_ID" ]]; then
    echo "Import request failed: $IMPORT_RESP" >&2
    exit 1
  fi
  echo "Import started (id=${IMPORT_ID}). Waiting..."
  for _ in $(seq 1 120); do
    STATUS="$(curl -s "${auth_header[@]}" "${API}/import/${IMPORT_ID}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('import_status',''), d.get('failed_reason',''))
")"
    state="${STATUS%% *}"
    reason="${STATUS#* }"
    echo "  status: ${state}${reason:+ — $reason}"
    case "$state" in
      finished|completed|none) break ;;
      failed) echo "Import failed: $reason" >&2; exit 1 ;;
    esac
    sleep 10
  done
  project_http="$(curl -s "${auth_header[@]}" "${API}/projects/${PROJECT_PATH//\//%2F}" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('http_url_to_repo',''))
")"
fi

if [[ -z "$project_http" || "$project_http" == *"Not Found"* ]]; then
  echo "Could not resolve GitLab project URL for ${PROJECT_PATH}" >&2
  exit 1
fi

echo "==> GitLab project: $project_http"

# Remotes: GitLab = origin, GitHub = github
if git remote get-url origin 2>/dev/null | grep -q github.com/PowerBeef; then
  git remote rename origin github
fi
if ! git remote | grep -qx github; then
  git remote add github "https://github.com/PowerBeef/QwenVoice.git"
fi
git remote set-url origin "$project_http"

# Authenticate git HTTPS pushes via glab if available
GLAB=""
for candidate in glab "/Users/patricedery/.local/share/mise/installs/glab/1.105.0/bin/glab"; do
  if command -v "$candidate" >/dev/null 2>&1; then
    GLAB="$candidate"
    break
  fi
  if [[ -x "$candidate" ]]; then
    GLAB="$candidate"
    break
  fi
done
if [[ -n "$GLAB" ]]; then
  "$GLAB" auth login --hostname "$GITLAB_HOST" --token "$GITLAB_TOKEN" --git-protocol https 2>/dev/null || true
fi

echo "==> Pushing main + tags to GitLab..."
git push -u origin main
git push origin --tags

if [[ "${SET_CI_VARS:-0}" == "1" ]]; then
  echo "==> Setting GitLab CI variables (from current shell env)..."
  PROJECT_ID="$(curl -s "${auth_header[@]}" "${API}/projects/${PROJECT_PATH//\//%2F}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")"
  set_ci_var() {
    local key="$1" val="$2"
    [[ -n "$val" ]] || { echo "  skip $key (empty)"; return 0; }
    curl -s "${auth_header[@]}" --request POST \
      --form "key=${key}" --form "value=${val}" \
      --form "masked=true" --form "protected=true" \
      "${API}/projects/${PROJECT_ID}/variables" >/dev/null \
      && echo "  set $key" || echo "  failed $key (may already exist)"
  }
  set_ci_var APPLE_DEV_ID_APP_P12_BASE64 "${APPLE_DEV_ID_APP_P12_BASE64:-}"
  set_ci_var APPLE_DEV_ID_APP_P12_PASSWORD "${APPLE_DEV_ID_APP_P12_PASSWORD:-}"
  set_ci_var APPLE_NOTARY_KEY_ID "${APPLE_NOTARY_KEY_ID:-}"
  set_ci_var APPLE_NOTARY_PRIVATE_KEY_P8 "${APPLE_NOTARY_PRIVATE_KEY_P8:-}"
  set_ci_var APPLE_NOTARY_ISSUER_ID "${APPLE_NOTARY_ISSUER_ID:-}"
  set_ci_var APPLE_TEAM_ID "${APPLE_TEAM_ID:-}"
  # Mirror: reuse gh token if it has repo push (PowerBeef/QwenVoice owner)
  set_ci_var GITHUB_MIRROR_TOKEN "${GITHUB_MIRROR_TOKEN:-$(gh auth token)}"
fi

echo ""
echo "Done. Next (manual dashboard):"
echo "  1. GitLab → Settings → CI/CD → Variables — copy Apple signing secrets if SET_CI_VARS was not used"
echo "  2. Add GITHUB_MIRROR_TOKEN (fine-grained PAT with push to PowerBeef/QwenVoice) if not set"
echo "  3. Vercel → connect GitLab project, root website/ — see docs/reference/vercel-gitlab-cutover.md"
echo "  4. Cursor → Integrations → Sync Repos → VocelloApp/QwenVoice"
echo ""
echo "Verify: curl -s ${API}/projects/${PROJECT_PATH//\//%2F} | python3 -m json.tool | head"
