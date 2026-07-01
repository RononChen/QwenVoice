#!/usr/bin/env bash
# Rewire git remotes after GitLab import: GitLab = origin, GitHub = github (mirror).
# Run from repo root once gitlab.com/VocelloApp/QwenVoice exists.
set -euo pipefail

GITLAB_URL="${GITLAB_REMOTE:-https://gitlab.com/VocelloApp/QwenVoice.git}"
GITHUB_URL="${GITHUB_REMOTE:-https://github.com/PowerBeef/QwenVoice.git}"

if git remote get-url origin 2>/dev/null | grep -q 'github.com/PowerBeef/QwenVoice'; then
  git remote rename origin github
  echo "Renamed origin → github"
fi

if ! git remote | grep -qx origin; then
  git remote add origin "$GITLAB_URL"
  echo "Added origin → $GITLAB_URL"
fi

git remote -v

echo ""
echo "Next: git fetch origin && git push -u origin main --tags"
echo "Install GitLab CLI: brew install glab && glab auth login --hostname gitlab.com"
