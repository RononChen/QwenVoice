# The `vocello` CLI

`vocello` is a headless macOS command-line surface over the same in-process MLX engine the app uses.
It serves two roles:

- **User-facing generation** — synthesize speech from the terminal (Custom Voice / Voice Design /
  Voice Cloning), one clip or many, scriptable with JSON output and stdin piping.
- **Deterministic benchmark/test driver** — drive the perf/quality matrix in-process (cold/warm
  controlled exactly via load/unload, no UI waits), aggregate telemetry, and append a perf-ledger row.
  This replaced computer-use UI-driving for anything scripted.

It links the engine frameworks directly (no XPC), **ships no model weights and no Python**, and runs
**in place** beside its MLX metallib bundle. Models download from Hugging Face on first use, exactly
like the app. The `review` command (agy listening pass) is a **dev/benchmark workflow only** — it
hands dev clips to an external model and is never part of the shipped product; user audio stays
on-device.

## Build & run

```sh
./scripts/build.sh cli                 # build build/vocello (single config, -Onone)
./scripts/build.sh cli generate --text "Hello." --variant speed   # build + run with args
build/vocello <command> [options]      # run the already-built binary
```

`build/vocello` is a symlink to the real binary under `build/DerivedData/…`; macOS resolves it so the
adjacent MLX shader bundle (`default.metallib`) stays reachable. **Don't copy the binary elsewhere** —
it must run in place. The contract (`qwenvoice_contract.json`) is bundled into the tool, and is also
discovered repo-relative, so the CLI works from the repo root or any subdirectory; pass `--manifest`
to override.

By default the CLI uses the app's runtime data directory
(`~/Library/Application Support/QwenVoice`, or `QwenVoice-Debug` when `QWENVOICE_DEBUG` is truthy);
`--data-dir <path>` overrides it. `bench` defaults to the debug-isolated folder (which holds the full
model set) and forces telemetry on.

## Conventions

- **stdout is machine-readable** (an output path, one per line, or a JSON object); **stderr carries
  human progress notes**. Pipe stdout to capture results cleanly.
- `--json` switches stdout to a structured JSON object/array (on `generate`, `batch`, `voices list`,
  `speakers list`, `models`).
- `--quiet` suppresses the stderr notes; `--verbose` adds per-step detail.
- Exit codes: `0` success · `1` error · `2` usage / unknown command · `130` interrupted (Ctrl-C).

## Commands

### `generate` — synthesize one clip

```sh
vocello generate --mode custom|design|clone --variant speed|quality \
                 (--text "…" | --text-file <path> | piped stdin) [--out <path>] [options]
```

| Option | Meaning |
|---|---|
| `--mode` | `custom` (default) · `design` · `clone` |
| `--variant` | `speed` (default, 4-bit) · `quality` (8-bit) |
| `--text` / `--text-file` | inline text or a file (`-` reads stdin); with neither, piped stdin is used |
| `--speaker` | (custom) speaker id; default = contract default (see `vocello speakers list`) |
| `--voice-brief` | (design) plain-language voice description |
| `--voice` / `--reference` / `--transcript` | (clone) a saved voice name/id, or a reference `.wav` + optional transcript |
| `--delivery` | optional delivery style |
| `--out` | output `.wav` path; default → `<data>/outputs/cli/` |
| `--stream` | streaming synthesis; reports first-chunk latency (TTFC) |
| `--play` | play the result with `afplay` when done |
| `--json` | emit a JSON result object instead of the bare path |

Prints the output WAV path on stdout (or a JSON object: `audioPath`, `durationSeconds`, `wallSeconds`,
`realtimeFactor`, `finishReason`, `mode`, `variant`, `modelID`, and `firstChunkMS` when `--stream`).

### `batch` — synthesize many clips with a single model load

```sh
vocello batch --file <path|-> --mode … --variant … \
              [--speaker <id> | --voice <name> | --voice-brief "…"] [--out-dir <dir>] [options]
```

One non-empty line per clip; all clips share the same voice/mode/variant, so the engine runs them
through **one loaded model** — far faster than repeated `generate` calls. Reads stdin when `--file` is
omitted or `-`. Prints one output WAV path per line (or a JSON summary with `--json`).

### `voices` — manage saved clone voices

```sh
vocello voices list [--json]
vocello voices enroll --name <name> --audio <wav> [--transcript "…"]
vocello voices delete --id <id>
```

### `speakers` — list built-in Custom Voice speakers

```sh
vocello speakers list [--json]
```

Lists the built-in Qwen3 speaker presets (id, display name, language; the contract default is marked)
so you don't have to guess `--speaker` ids. Read-only — doesn't boot the engine, so it returns
instantly.

### `models` — inventory installed/available models (read-only)

```sh
vocello models list [--json]
vocello models status [<id>] [--json]      # adds missing-file detail
```

Shows each model's install state, on-disk size, and (for `status`) any missing required files. No
download machinery — installing models is done from the app's Settings. Variant-scoped ids
(`…_speed` / `…_quality`) are what `generate --variant` selects.

### `bench` — drive the perf/quality matrix + aggregate

```sh
vocello bench [--modes custom,design,clone] [--variants speed,quality] \
              [--lengths short,medium,long] [--warm 3] [options]
```

Per cell: 1 cold (medium) for Custom/Design + N warm per length; Voice Cloning is warm-only. Telemetry
is forced on; results land in `<data>/diagnostics` and are summarized by
`scripts/summarize_generation_telemetry.py`.

| Option | Meaning |
|---|---|
| `--modes` / `--variants` / `--lengths` | matrix axes (comma lists) |
| `--warm` | warm reps per (cell × length); default 3 |
| `--voice` / `--voice-brief` | clone voice name / design brief |
| `--label "<note>"` | stamp a note on the summary / ledger row |
| `--ledger` | append a one-line row to `benchmarks/HISTORY.md` (the perf-over-time ledger) |
| `--force-class` | run a constrained tier on any Mac: `8gb` · `16gb` · `high` · `iphone` (stamps `notes.deviceClass`) |
| `--telemetry` | `lightweight` (default) · `verbose` (raw per-sample sidecars) |
| `--keep` / `--force` | append to existing diagnostics / allow clearing even the real app data dir |
| `--no-summary` | skip running the aggregator |
| `--review` | after aggregating, have agy listen to flagged clips (dev-only; needs `agy` + `afconvert`) |

### `review` — adjudicate flagged clips by ear (dev-only)

```sh
vocello review --clip <wav> [--text "…"] [--flags dropout:469ms]
vocello review --diag <diagnostics-dir>      # review all flagged clips from a bench run
```

Transcodes each flagged clip to m4a and hands it to `agy` (multimodal) to judge real-defect vs
false-positive (e.g. a natural comma pause). **Dev/benchmark workflow only** — agy receives dev clips,
never shipped user audio. Verdicts land in `<diag>/review/review.jsonl`.

## Examples

```sh
# Custom Voice, speed, save to a path
vocello generate --mode custom --variant speed --text "The train left at dawn." --out /tmp/clip.wav

# Pipe a script in, stream it, get JSON with first-chunk latency
echo "Hello there." | vocello generate --variant speed --stream --json

# Voice Design from a brief
vocello generate --mode design --voice-brief "A warm, calm narrator" --text "Once upon a time…"

# Bulk: one model load for many lines
vocello batch --file lines.txt --mode custom --variant speed --out-dir /tmp/batch

# Discover what's available (instant — no engine boot)
vocello speakers list
vocello models list

# One-command benchmark: forced 8 GB tier, labelled, append a ledger row
vocello bench --modes custom --variants speed --lengths short,medium,long --warm 3 \
              --label "my change" --ledger --force-class 8gb
```

## See also

- [`telemetry-and-benchmarking.md`](telemetry-and-benchmarking.md) — the telemetry schema, the bench
  matrix in depth, the `audioQC` gate, and the listening pass.
- [`ui-driving.md`](ui-driving.md) — computer-use for visual/UX review (what the CLI doesn't cover).
