# Smoke Runbook: History surface renders, searches, plays

Lightweight functional smoke that exercises the History screen: at least one row visible after a seed generation, search-filter narrows the visible rows, and clicking the row's play affordance triggers playback.

Companion reference: [`ui-test-surface.md`](ui-test-surface.md).

## Prerequisites

- Debug build present.
- macOS Accessibility permission granted to Claude.
- At least one row in `history.sqlite` `generations` table. This runbook seeds one if empty, so no external setup needed.

## Seed strategy

Before testing, ensure ≥ 1 generation row exists. The runbook does this by running one short Custom Voice generation inline (~3 s) if needed.

## Fixed inputs

| Field | Value |
|---|---|
| Seed prompt (if needed) | `Hello world.` (short — fast to generate) |
| Search fragment | `Hello` (matches the seed) |

## Steps

1. **Precondition**: `scripts/uitest.sh smoke-check custom`. Abort on non-zero — we can't seed without a Custom Voice model.
2. **Reset**: `scripts/uitest.sh reset` (clears existing generations + outputs so this run is repeatable).
3. **Artifacts + log capture**:
   ```sh
   ART=$(scripts/uitest.sh artifacts-dir)
   (scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)
   LOG_PID=$!
   ```
4. **Launch**: `scripts/uitest.sh prep`.
5. **Access**: `mcp__computer-use__request_access(applications: ["Vocello"])`.
6. **Seed one generation** via Custom Voice:
   - `read SW SH < <(scripts/uitest.sh screen-size)`.
   - `scaled-locate sidebar_customVoice 1456 816` → click.
   - `scaled-locate textInput_textEditor 1456 816` → click → type `Hello world.` → `cmd+return`.
   - `python3 -c "import datetime as dt; ..." > /tmp/uitest_bench_t0` is not needed here; the alternative is `bench-wait --since <ts>` but for this smoke we just sleep ~5 s and verify the DB row.
   - Wait ~5 s, then `scripts/uitest.sh db "SELECT count(*) FROM generations"` should be ≥ 1. If not, retry the generation once.
7. **Navigate to History**:
   - `scaled-locate sidebar_history 1456 816` → click.
   - Verify with `scripts/uitest.sh locate screen_history` (exit 0).
   - `/usr/sbin/screencapture -x "$ART/pre.png"`.
8. **Verify a row is visible**:
   - Read the seeded generation's id: `GEN_ID=$(scripts/uitest.sh db "SELECT id FROM generations ORDER BY createdAt DESC LIMIT 1")`.
   - `scripts/uitest.sh locate historyRow_$GEN_ID` should return non-empty coords — that anchors the row by canonical id.
9. **Use the search field**:
   - `scaled-locate history_searchField 1456 816` → click.
   - Type `Hello` (no `cmd+return` — search filters live).
   - Wait 1 s, screenshot — the row should still be visible (search matched).
10. **Clear search and verify all rows return**:
    - Click search field → `cmd+a` → `delete`.
    - Screenshot — all rows should be back.
11. **Click play on the (first) row**:
    - `scripts/uitest.sh locate historyRow_play_$GEN_ID` → `mcp__computer-use__left_click(coordinate=[cx,cy])`.
    - Verify playback by checking the Player section in the sidebar shows the seeded prompt text.
12. **Post-screenshot + tear down**: `/usr/sbin/screencapture -x "$ART/post.png"`, then `kill "$LOG_PID" 2>/dev/null || true`.
13. **Write `$ART/result.json`** with:
    - `pass`: true if (a) `historyRow_<id>` and `historyRow_play_<id>` both resolve, (b) search-filter narrows visible rows, (c) play affordance launches the audio player
    - `screen`: `history`
    - `rows_before_search`, `rows_after_search`: counts (from screenshot or DB query)
    - `timestamp`
14. **Report** $ART/ and pass/fail to the user.

## Notes

- The seeded generation uses Custom Voice for speed/simplicity. If Custom Voice models aren't installed, the runbook aborts at step 1.
- This is a happy-path smoke. It does NOT test delete, multi-row sorting under load, or rapid filtering edge cases.
- Row-level + per-row-action AX ids are now canonical (`historyRow_<id>`, `historyRow_play_<id>`, `historyRow_saveAs_<id>`, `historyRow_delete_<id>`, `historyRow_saveVoice_<id>`). Visual fallback is no longer expected — if `locate` fails for a known id, treat that as a regression.
