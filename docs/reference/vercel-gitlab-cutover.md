# Vercel + Cursor cutover (manual)

After `gitlab.com/VocelloApp/QwenVoice` exists and `main` is pushed:

## Vercel

1. [Vercel dashboard](https://vercel.com) → project **vocello** → **Settings → Git**.
2. Disconnect GitHub; **Connect GitLab** → authorize → select **`VocelloApp/QwenVoice`**.
3. Root directory: **`website/`** · production branch: **`main`**.
4. Trigger a production deploy; confirm assets load, e.g.  
   `https://vocello.vercel.app/assets/screens/ios-studio.png`

If CLI deploy is needed before GitLab webhook is live:

```sh
cd website && vercel login && vercel deploy --prod
```

## Cursor

1. [Cursor Integrations](https://cursor.com/dashboard/integrations) — GitLab should already show **@VocelloApp**.
2. **Manage → Sync Repos** → enable **`VocelloApp/QwenVoice`**.
3. **Cloud Agents / Bugbot on GitLab** require GitLab **Premium/Ultimate** (project access tokens). On Free, local Cursor + `glab` MR workflow is the primary path.

## GitLab CI variables (one-time)

Settings → CI/CD → Variables — copy Apple signing secrets from the former GitHub Actions secrets and add optional `GITHUB_MIRROR_TOKEN` for the mirror job. See [`gitlab-ci.md`](gitlab-ci.md).
