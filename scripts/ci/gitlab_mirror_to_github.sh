#!/usr/bin/env bash
# One-way push mirror: GitLab (primary) -> github.com/PowerBeef/QwenVoice
# Requires GitLab CI variable GITHUB_MIRROR_TOKEN (fine-grained PAT or classic with repo scope).
set -euo pipefail

: "${GITHUB_MIRROR_TOKEN:?missing GITHUB_MIRROR_TOKEN}"

git config user.email "gitlab-ci@vocello.app"
git config user.name "Vocello GitLab CI"

MIRROR_URL="https://oauth2:${GITHUB_MIRROR_TOKEN}@github.com/PowerBeef/QwenVoice.git"

if [ -n "${CI_COMMIT_TAG:-}" ]; then
  git push "$MIRROR_URL" "$CI_COMMIT_SHA:refs/tags/${CI_COMMIT_TAG}" --force
fi

if [ "${CI_COMMIT_BRANCH:-}" = "main" ]; then
  git push "$MIRROR_URL" "HEAD:main" --force
  git push "$MIRROR_URL" --tags --force
fi

echo "GitHub mirror updated."
