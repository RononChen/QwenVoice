# benchmarks/

Compact, human-readable benchmark **summaries** may be committed here. This directory exists because
benchmark result logs are now permitted in the repo — but **bounded**, so they never blow out repo size.

## What may live here

- **`HISTORY.md`** — the running ledger: one compact row per benchmark run (date · git SHA · cell ·
  RTF · tok/s · TTFC · physFoot · trims · note), for watching the trend over time. Append a row with
  `python3 scripts/summarize_generation_telemetry.py --ledger-row --label "what changed" >> benchmarks/HISTORY.md`.
- A saved full summary table from `summarize_generation_telemetry.py --label "<note>"` (`.md` / `.txt`)
  for a milestone — auto-stamped with the date + short SHA so numbers tie to a commit.
- A small `.json` of headline numbers (RTF, tokens/s, TTFC, peak RAM/GPU) for a dated run.

Name milestone files by date + context, e.g. `2026-05-30-floor8gb-quality.md`. Compare runs with
`git diff` (or ask the agent) — there's no auto-compared baseline gate, by design.

## Rules (enforced by `scripts/check_project_inputs.sh`)

- **No raw `*.jsonl`.** The per-generation diagnostics JSONL is large and lives on disk under
  `~/Library/Application Support/QwenVoice[-Debug]/diagnostics/` (gitignored, and auto-pruned to a size
  budget by `GenerationTelemetryJSONLSink`). Commit a distilled summary, not the raw stream.
- **Each committed file ≤ 256 KB.** Keep it a summary, not a dump.
- Still **no** auto-compared baseline manifest and **no** benchmark script harness — those remain
  retired (the guard's existing denylist is unchanged). These are reference logs, not a CI gate.

See [`docs/reference/telemetry-and-benchmarking.md`](../docs/reference/telemetry-and-benchmarking.md)
for how the telemetry is captured and how to run the reusable benchmark.
