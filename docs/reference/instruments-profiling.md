# Instruments-Level Engine Profiling

This is the next layer below the cross-layer wall-clock probe (commits
`958567d`, `b46b2d7`, `37c21c3`). When `infer_ms` per-chunk numbers
have been fully attributed to engine sub-stages but you still need to
know *what the GPU is actually doing inside each stage*, this is the
tool.

## When To Use Instruments vs The Bench Helper

| Question | Right tool |
|---|---|
| "How long does the user wait between Cmd+Return and audio playback?" | `scripts/bench_ui_generation.sh` (desktop-UI bench, full pipeline) |
| "How does that wall break down across engine / XPC / UI layers?" | `[Probe.Engine|Transport|UI]` lines in the bench log |
| "How does per-chunk `infer_ms` break down across talker / code predictor / decoder / eval cadence?" | Phase 1 + Phase 2a fields in the same probe |
| "Inside `talker_forward_ms`, which Metal kernels run, and is the GPU saturated or idle-waiting?" | **Instruments / `xctrace`** (this doc) |
| "Where does CPU time actually go inside the per-token loop?" | Time Profiler, captured in the same trace |
| "Is `eval(audioChunk)` waiting on a GPU command buffer, or is it actual compute?" | Metal System Trace, in the same trace |

The probe stops at wall-clock attribution. Instruments crosses into
GPU-kernel-level visibility.

## Signposts In Place

Five `os_signpost` intervals fire on every per-token iteration of the
streaming generation, all under subsystem `com.qwenvoice.engine.qwen3`,
category `generation`:

| Signpost | What it brackets | Source |
|---|---|---|
| `Talker Forward` | `talker(inputEmbeds, cache: cache)` — the LLM forward pass per token | `Qwen3TTS.swift` per-token loop |
| `Code Predictor Loop` | The 7-iteration multi-codebook prediction loop | same |
| `Step Eval Flush` | The `eval(inputEmbeds, isEOS)` synchronous flush at policy `.full` | same |
| `Audio Decoder` | `speechTokenizer.decoder.streamingStep(...)` | same |
| `Audio Chunk Eval` | The `eval(audioChunk)` after each streaming decoder run | same |

Coarser intervals already exist in `NativeStreamingSynthesisSession.swift`
under subsystem `com.qwenvoice.engine` (category `generation`):
`Native Generation Stream`, `Native First Audio Chunk`,
`Native Final WAV Finish`. Both subsystems show up together when the
"os_signpost" instrument is added in Instruments.

## Capture A Trace

```sh
./scripts/bench_instruments_trace.sh
```

Default: 30-second System Trace (CPU + Metal + signposts), output to
`build/instruments-traces/vocello-YYYYMMDD-HHMMSS.trace`. Override:

```sh
./scripts/bench_instruments_trace.sh --seconds 60 \
    --output /tmp/long-vc-trace.trace
```

Workflow:

1. The script kills any running Vocello, resets defaults to land on
   Custom Voice with Smooth OFF, and relaunches a fresh debug build.
2. After the engine is Ready, the script starts `xctrace record` with
   the `System Trace` template and your chosen time window.
3. While recording, the operator triggers ONE generation in the
   Vocello UI: paste a script, hit Cmd+Return.
4. When the trace stops, the script `open`s the `.trace` bundle in
   Instruments.

The trace captures the entire system, so the bundled
`QwenVoiceEngineService.xpc` helper (where the engine actually runs)
is captured alongside the Vocello main process.

## Reading The Trace

In Instruments:

1. **Add the "os_signpost" instrument** if not already present
   (View → Instruments Library, drag the os_signpost instrument onto
   the trace).
2. **Filter** by subsystem: `com.qwenvoice.engine.qwen3` for the
   per-token markers, or `com.qwenvoice.engine` for the coarser
   generation-lifecycle markers.
3. **Stack tracks vertically** so the os_signpost lane sits between
   the Time Profiler and the Metal GPU lane. This makes alignment
   instant.

What to look for:

- **`Talker Forward` with GPU idle** — kernel launch overhead, sampling,
  embed lookup happening on CPU. Could potentially overlap with the
  next prep step.
- **`Code Predictor Loop` with 7 sequential GPU bursts** — confirms the
  multi-codebook prediction is unbatched. A single multi-codebook
  dispatch could collapse those 7 bursts into one.
- **`Audio Chunk Eval` much longer than `Audio Decoder`** — the
  decoder kernel runs fast but `eval(audioChunk)` waits on it +
  flushes. Could pipeline with the next forward pass.
- **`Step Eval Flush` with substantial GPU activity** — confirms the
  eval flush IS doing real work (not just synchronizing). The Phase 2a
  finding about `.deferred` not being a wall-clock win comes from
  here: the GPU work is happening regardless of which sync point
  triggers it.
- **GPU idle gaps between engine stages** — these are pipeline
  opportunities. Anywhere the GPU sits idle while CPU works on
  housekeeping (sampling, list construction, MLX expression building)
  is amortizable.

## Phase 2b Investigation Track

Phase 2a delivered wall-clock attribution. Phase 2b uses Instruments
traces to identify kernel-level slack. Concrete next steps once a
clean trace is in hand:

1. **Code Predictor batching.** If the 7 codebook-token predictions
   show as 7 distinct GPU bursts in the trace, file a Phase 2b commit
   to batch them as a single multi-codebook tensor op.
2. **Decoder pipelining.** If `Audio Chunk Eval` shows long GPU sync
   wait while the next forward pass could already be queued, file a
   commit that issues the next forward dispatch BEFORE eval'ing the
   audio chunk.
3. **Sampling on CPU vs GPU.** `sampleToken(...)` includes top-p,
   top-k, repetition penalty — all small ops. If they show up as
   per-token CPU-side work between GPU dispatches, batching or moving
   them to Metal could overlap with kernel launches.

If the trace shows the GPU is *fully saturated* during the per-token
loop (no idle gaps), the conclusion is that the M1's GPU is the
bottleneck and further wall-clock optimization requires either model
quantization (already at 4-bit Speed) or hardware (M2/M3/M4 with more
GPU cores).

## Patch Note

`Qwen3TTS.swift` gains an `import os` and a private `Qwen3Signposts`
namespace. The signpost calls live in the per-token loop inside
`generateVoiceDesign(...)` (the inner generation function). This is a
local patch on top of the vendored MLXAudioTTS — preserve on rebase.
See [`mlx-audio-swift-patching.md`](mlx-audio-swift-patching.md) for
the patch baseline.
