# GitLab project setup (one-time)

Complete these steps **before** the first push to `origin` (GitLab). The agent-side migration
(`.gitlab-ci.yml`, URL sweep, remotes) is already on `main`; GitLab just needs a project shell
and your credentials.

## One-command setup (after creating a GitLab PAT)

Create a token at **GitLab → Preferences → Access tokens** with scopes **`api`**
and **`write_repository`**, then either:

```sh
export GITLAB_TOKEN='glpat-...'   # paste once; do not commit
./scripts/gitlab_setup_all.sh
```

Or copy [`scripts/gitlab-ci-secrets.env.example`](../scripts/gitlab-ci-secrets.env.example)
to **`.gitlab-ci-secrets.env`** (gitignored), fill `GITLAB_TOKEN`, and run:

```sh
./scripts/gitlab_setup_all.sh
# With Apple signing + mirror vars in the same file:
SET_CI_VARS=1 ./scripts/gitlab_setup_all.sh
```

This script uses your existing **`gh`** login to import **`PowerBeef/QwenVoice`**
from GitHub, rewire remotes, and push **`main` + tags**. Optional:

```sh
# Skip import if you already created the project manually
SKIP_IMPORT=1 ./scripts/gitlab_setup_all.sh

# Also upload CI variables whose values are already in your shell env
SET_CI_VARS=1 ./scripts/gitlab_setup_all.sh
```

Apple signing secret **values** are not readable from GitHub Actions via CLI — copy them
from your password manager into GitLab **Settings → CI/CD → Variables** (names listed in
[`gitlab-ci.md`](gitlab-ci.md)). For the GitHub mirror, add **`GITHUB_MIRROR_TOKEN`**
(fine-grained PAT with push to `PowerBeef/QwenVoice` only).

## 1. Create the project (manual alternative)

**Option A — Import from GitHub (recommended; preserves tags/releases):**

1. Log in as [**@VocelloApp**](https://gitlab.com/VocelloApp) on gitlab.com.
2. **New project → Import project → GitHub** (authorize if prompted).
3. Select **`PowerBeef/QwenVoice`**.
4. Name: **QwenVoice** · Namespace: **VocelloApp** · Visibility: **Public**.
5. Enable **import branches, tags, and releases**.

**Option B — Blank project + push:**

1. **New project → Create blank project** → path **`QwenVoice`** under **VocelloApp**.
2. Do **not** initialize with a README (repo already has one).

Target URL: **`https://gitlab.com/VocelloApp/QwenVoice`**

## 2. Rewire remotes (if not already done)

```sh
cd /path/to/QwenVoice
./scripts/gitlab_bootstrap_remotes.sh
# origin → gitlab.com/VocelloApp/QwenVoice.git
# github → github.com/PowerBeef/QwenVoice.git
```

## 3. Authenticate and push

```sh
# HTTPS (Personal Access Token with write_repository)
glab auth login --hostname gitlab.com   # after: brew install glab

git push -u origin main
git push origin --tags
```

Or set SSH: `git remote set-url origin git@gitlab.com:VocelloApp/QwenVoice.git` and add your
GitLab SSH key under **Preferences → SSH Keys**.

## 4. CI/CD variables

GitLab → **Settings → CI/CD → Variables** — copy Apple signing secrets from the former GitHub
Actions secrets and add optional **`GITHUB_MIRROR_TOKEN`**. Full list:
[`gitlab-ci.md`](gitlab-ci.md).

## 5. Vercel + Cursor

[`vercel-gitlab-cutover.md`](vercel-gitlab-cutover.md)

## Verification

- [ ] `curl -s https://gitlab.com/api/v4/projects/VocelloApp%2FQwenVoice` returns project JSON (not 404)
- [ ] `git remote -v` shows GitLab as `origin`
- [ ] GitLab pipeline on `main` runs **`ios-tier-a-ui`**
- [ ] After `GITHUB_MIRROR_TOKEN` is set, **`mirror_to_github`** updates GitHub `main`
