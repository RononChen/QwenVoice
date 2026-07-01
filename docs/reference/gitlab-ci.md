# GitLab CI/CD (primary)

> **GitLab is the primary forge** for Vocello (`gitlab.com/VocelloApp/QwenVoice`).
> [GitHub](https://github.com/PowerBeef/QwenVoice) is a **read-only mirror** for discoverability while the account is reinstated — do not open issues or PRs there.

Pipeline definition: [`.gitlab-ci.yml`](../../.gitlab-ci.yml) at repo root. Legacy reference: [`.github/workflows/`](../.github/workflows/) (no longer triggered).

## Pipelines

| Job | Stage | Trigger | Purpose |
| --- | --- | --- | --- |
| `ios-tier-a-ui` | test | push/MR to `main` | Tier-A fake-backend iOS Simulator UI (`QVOICE_FAKE_ENGINE=1`) |
| `package` | release | **manual** on version tag (`v*`) or web pipeline | Signed + notarized macOS DMG |
| `compile-ios` | release | tag / web | iOS compile-safety (non-blocking) |
| `release-publish` | release | version tag | Attach DMG to GitLab Release |
| `mirror_to_github` | deploy | `main` push / tag | One-way push to GitHub (needs `GITHUB_MIRROR_TOKEN`) |

Runners: **macOS** jobs use `tags: [saas-macos-medium-m1]` (GitLab SaaS). Tier-A budgets ~45 min; release ~90 min.

## CI/CD variables (Settings → CI/CD → Variables)

Copy from the former GitHub Actions secrets:

| Variable | Used by |
| --- | --- |
| `APPLE_DEV_ID_APP_P12_BASE64` | `package` |
| `APPLE_DEV_ID_APP_P12_PASSWORD` | `package` |
| `APPLE_NOTARY_KEY_ID` | `package` |
| `APPLE_NOTARY_PRIVATE_KEY_P8` | `package` |
| `APPLE_NOTARY_ISSUER_ID` | `package` |
| `APPLE_TEAM_ID` | `package` |
| `GITHUB_MIRROR_TOKEN` | `mirror_to_github` (optional until mirror enabled) |

Mark Apple signing variables **masked** and **protected**. Optional: `RELEASE_OUTPUT_NAME` (default `Vocello-macos26`).

## Release workflow (macOS)

1. Tag on `main`: `git tag v2.1.1 && git push origin v2.1.1`
2. GitLab → **Build → Pipelines** → open the tag pipeline
3. Run **`package`** manually → wait for DMG artifact
4. **`release-publish`** attaches assets to the GitLab Release
5. **`mirror_to_github`** syncs tag + `main` to GitHub (if token set)

Release notes live in [`docs/releases/`](../releases/). Download page: project **Deploy → Releases**.

## Local remotes

```sh
git remote -v
# origin  https://gitlab.com/VocelloApp/QwenVoice.git (fetch/push)
# github  https://github.com/PowerBeef/QwenVoice.git (fetch only; CI pushes mirror)
```

Day-to-day: `glab` for MRs/issues/releases (`brew install glab && glab auth login`).

## Vercel + Cursor

- **Vercel:** connect the project to GitLab (`VocelloApp/QwenVoice`, root `website/`, branch `main`).
- **Cursor:** [Integrations](https://cursor.com/dashboard/integrations) → GitLab → **Sync Repos** after the project exists. Cloud Agents/Bugbot on GitLab require **Premium/Ultimate**.

See also: [`testing-runbook.md`](testing-runbook.md), [`macos-release-qa.md`](macos-release-qa.md), [`gitlab-project-setup.md`](gitlab-project-setup.md).
