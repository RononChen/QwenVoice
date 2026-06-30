# macOS UI review baselines

Committed PNG baselines for macOS UI review. Each file is a screenshot captured by
`VocelloMacReviewUITests` (catalog-driven; resting and post-generation states) and named with a
stable key.

## Workflow

```sh
# 1. Capture the current macOS UI into build/macos/review-shots/<run>/ (catalog tour).
scripts/macos_test.sh review                        # full catalog
scripts/macos_test.sh review --subset resting       # fast PR pass (resting screens only)

# 2. Seed/update the committed baselines from a known-good run, then review + commit.
scripts/macos_test.sh review --baseline
git add docs/macos-review-baselines && git commit
```

On a normal `review` run, the verb prints each capture with its baseline pair (or `NEW`
when no baseline exists yet). The **perceptual diff** is a vision-MCP step — run it on
each `(baseline, actual)` pair:

- the **`screenshot-validator`** Axiom subagent (`/axiom:audit screenshots`), or
- the `axiom:screenshot-validator` agent / `impeccable` skill for a deeper UI pass.

Update a baseline only when the UI change is intentional; a diff that flags an
unintended delta is the signal that caught a regression.

## Capture keys

**Resting subset** (`--subset resting`):

- `review-custom-resting`
- `review-design-ready` (brief filled)
- `review-voices-list`
- `review-settings-models`

**Full catalog** (adds post-generation / populated states):

- `review-custom-ready` — script typed, readiness `ready=true`
- `review-custom-postgen` — player visible after generation
- `review-clone-reference` — handoff from `A_warm_elderly_woman`
- `review-history-populated` — history after at least one generation

Legacy keys (`review-custom`, `review-design`, …) from the old sidebar-only tour may still
exist in older baselines; re-seed with `--baseline` after intentional UI changes.

## Rules

- macOS is the host — screenshots are direct XCUITest `app.screenshot()` (no iPhone
  Mirroring chrome, no OLED burn-in concern).
- `accessibilityIdentifier`s are stable surface area — the catalog drives `sidebar_*`
  buttons and waits on `mainWindow_activeScreen` / readiness markers; identifier changes
  are test-breaking changes.
