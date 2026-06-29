# Generation performance investigation — 2026-06-29

**Scope:** macOS Vocello.app feels slower on local `main` vs shipped v2.1.0 DMG.  
**Method:** `vocello bench` (in-process MLX stack, custom/speed/warm/medium, 3 warm reps) at matched `-Onone` and `-O` builds; v2.1.0 tag `c60dd08` vs HEAD `8a4205a`. Investigation data dir: `build/perf-investigation/data` (models symlinked from app support). Only one Vocello.app instance allowed on the host during app-lane checks (`scripts/perf_investigation.sh quit`).

## Results matrix (headline cell: custom/pro_custom_speed/warm/medium)

| revision | opt | debug | RTF | tok/s | physFoot MB | vs v2.1.0 -O |
|----------|-----|-------|-----|-------|-------------|--------------|
| HEAD `8a4205a` | **-Onone** | on | **1.03** | 12.91 | 2536 | −38% slower |
| HEAD `8a4205a` | **-Onone** | off | **1.04** | 13.00 | 2850 | −38% slower |
| HEAD `8a4205a` | **-O** | on | **1.72** | 21.49 | 2857 | +3% faster |
| HEAD `8a4205a` | **-O** | off | **1.70** | 21.22 | 2860 | +2% faster |
| v2.1.0 `c60dd08` | **-Onone** | on | **0.97** | 12.15 | 4237 | −42% slower |
| v2.1.0 `c60dd08` | **-O** | on | **1.67** | 20.90 | 4288 | baseline |

**Optimization lift (-O vs -Onone, same revision):**

| revision | RTF -Onone | RTF -O | speedup |
|----------|------------|--------|---------|
| HEAD | 1.03 | 1.72 | **~67%** |
| v2.1.0 | 0.97 | 1.67 | **~72%** |

**Debug telemetry overhead:** ≤2% RTF (HEAD -Onone 1.03 vs 1.04; HEAD -O 1.72 vs 1.70). Not a meaningful confounder.

## Root cause

**Primary: build optimization confounder (`scripts/build.sh` → `-Onone` vs shipped DMG / `scripts/release.sh` → `-O`).**

Local dev builds compile the Release config unoptimized for fast iteration. The v2.1.0 DMG is compiled with `-O` whole-module optimization. The MLX decode hot path is Swift + Metal bound; this gap alone explains the perceived “regression since v2.1.0” with **zero engine logic change**.

**Not confirmed:**

- Engine regression on `main` — at `-O`, HEAD is **slightly faster** than v2.1.0 (RTF 1.70 vs 1.67).
- `f3e1369` engine/XPC teardown — bisect not warranted; no warm-path RTF regression at `-O`.
- Debug telemetry (`QWENVOICE_DEBUG=1` / Settings 7-tap) — negligible on CLI bench.
- iOS download refactors / CLI streaming-default — out of scope for macOS app path.

## Phase 3 (XPC / app) — not required

Plan gate: deep XPC checks only if regression persists at `-O`. It does not. At matched `-O`, HEAD ≥ v2.1.0 on the shared engine stack.

**App-path note:** CLI bench is in-process; the macOS app uses XPC. Both paths share the same compiled engine code and the same `-Onone`/`-O` split between `build.sh` and `release.sh`, so the confounder applies equally to app generations. No evidence that XPC session teardown (`f3e1369`) introduces a warm-path regression beyond the optimization gap.

## Phase 4 — bisect skipped

No objective warm/medium RTF regression at `-O` between `v2.1.0` and HEAD. Git bisect and `f3e1369` profiling deferred.

## Recommendations

1. **Expectation:** `./scripts/build.sh run` is not perf-representative of the shipped DMG. Use `./scripts/build.sh release` (or `./scripts/release.sh`) when validating generation speed before release.
2. **Optional:** Add a note to `AGENTS.md` / dev onboarding that local `-Onone` can look ~40–70% slower than `-O` on warm generation.
3. **No code fix** required for engine performance.

## Reproduce

```sh
./scripts/perf_investigation.sh quit          # ensure single app instance
./scripts/perf_investigation.sh build-onone
./scripts/perf_investigation.sh bench "HEAD-onone-debug" 1
./scripts/perf_investigation.sh build-o
./scripts/perf_investigation.sh bench "HEAD-O-nodebug" 0
# checkout v2.1.0 and repeat build-onone / build-o + bench
```

Raw logs: `build/perf-investigation/*.log`  
Ledger rows: `build/perf-investigation/ledger-rows.txt`
