# macOS UI review baselines

Committed PNG baselines for macOS UI review (Phase 5 of the macOS testing overhaul). Each
file is a screenshot of one sidebar screen, captured by
`VocelloMacReviewTourUITests.testCaptureReviewScreens` and named with a stable key.

## Workflow

```sh
# 1. Capture the current macOS UI into build/macos/review-shots/<run>/ (XCUITest tour).
scripts/macos_test.sh review

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

`review-custom`, `review-design`, `review-clone`, `review-history`, `review-voices`,
`review-settings`.

## Rules

- macOS is the host — screenshots are direct XCUITest `app.screenshot()` (no iPhone
  Mirroring chrome, no OLED burn-in concern).
- `accessibilityIdentifier`s are stable surface area — the tour drives the `sidebar_*`
  buttons; a screen identifier change is a test-breaking change.
