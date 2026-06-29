# Telemetry & Benchmarks Harness Review

> **Date:** 2026-06-15  
> **Scope:** Vocello’s per-generation telemetry stack (`Sources/QwenVoiceCore`), benchmark/analysis scripts (`scripts/`), and committed benchmark records (`benchmarks/`).  
> **Lens:** The five recently authored reference docs — `mlx-guide.md`, `qwen3-tts-guide.md`, `swift-performance-guide.md`, `mimi-codec-guide.md`, `metal-guide.md` — plus the canonical `telemetry-and-benchmarking.md`.

## Executive summary

The current telemetry/benchmarks harness is **mature and lightweight**: telemetry is runtime-gated to zero overhead when off, the hot path is pure in-memory stage marks, and file I/O happens only at generation boundaries. It already captures the high-level signals that drove recent optimization work — wall-clock decode breakdown, process/GPU memory peaks, per-chunk substage timing, and reference-free audio QC.

Against the new reference docs, however, the harness **under-captures the MLX/Metal runtime internals** that are now the highest-value optimization levers: async-vs-sync eval scheduling, command-buffer completion, cache/pool pressure, KV-cache shape and footprint, per-codec-frame Mimi timing, and thermal/performance-limiter state. The benchmark pipeline also lacks statistical rigor: it reports medians only, ignores its own `chunkTimeline` field, does not read the merged telemetry log, and has no automated regression gate.

This review documents the blind spots, ranks them, and proposes a **P0/P1/P2 improvement backlog**. The top P0 items are documentation corrections and a small set of telemetry additions (thermal state, GPU working-set ratio, MLX policy notes) that are cheap to capture and directly support ongoing optimization work. Deeper MLX/Metal instrumentation is ranked P1/P2 because it requires touching the vendored Qwen3-TTS/Mimi code paths.

### Severity summary

| Severity | Count | Theme |
|---|---|---|
| P0 | 4 | Documentation drift, missing thermal/GPU-ratio/policy telemetry. |
| P1 | 6 | Lazy-eval ambiguity, missing KV/cache shape, benchmark statistical rigor. |
| P2 | 7 | Per-frame codec timing, signpost mirroring, sink durability, audioQC enhancements. |

---

## 1. Architecture snapshot

```
App / CLI          Engine runtime          Backend (vendored mlx-audio-swift)
   │                      │                              │
   │  submit request      │  prepareGeneration()         │
   ├─────────────────────►│  create recorder + sampler   │
   │                      │         │                    │
   │                      ▼         ▼                    │
   │              stage marks   memory samples            │
   │                      │         │                    │
   │                      ▼         ▼                    │
   │         GenerationTelemetryRecord (per layer)        │
   │                      │                              │
   │                      ▼                              │
   │         GenerationTelemetryJSONLSink                 │
   │                      │                              │
   │                      ▼                              │
   │    diagnostics/<layer>/generations.jsonl             │
   │                      │                              │
   │                      ▼                              │
   │    scripts/summarize_generation_telemetry.py         │
   │                      │                              │
   │                      ▼                              │
   │    benchmarks/HISTORY.md + baseline markdown         │
```

**What is gated off entirely:** `TelemetryGate.resolvedEnabled` controls whether the recorder, sampler, and JSONL sink do any work. The gate itself is resolved once per process and never compiled out, so shipped binaries run identical code paths.

**What runs unconditionally:** `OSSignposter` intervals and `os_log` warnings are Instruments-only and are not gated by the telemetry flag.

**Key design strengths worth preserving:**
- Per-layer rows share a `generationID`, so app/engine-service/engine logs join cleanly.
- The sampler and recorder share the same `ProcessInfo.systemUptime` start clock, so memory samples can be decorated with the active stage.
- `chunkTimeline`, `mlxMemoryByStage`, and verbose raw sidecars are opt-in, keeping the default log compact.

---

## 2. Findings by subsystem

### 2.1 Telemetry recorder — `Sources/QwenVoiceCore/NativeTelemetry.swift`

| # | Observation | Risk / blind spot | Evidence | Recommended fix |
|---|---|---|---|---|
| R1 | Clock is `ProcessInfo.processInfo.systemUptime` truncated to `Int` milliseconds. | Sub-millisecond events collapse or invert; high-frequency probes (per-frame codec, command-buffer completion) cannot be resolved. | `NativeTelemetry.swift:57-64` | Add an optional high-resolution mode using `ContinuousClock` / `DispatchTime` for sub-ms probes, or record nanosecond offsets in a separate verbose field. |
| R2 | `snapshot()` sorts by `tMS`, then alphabetically by `stage` when tied. | Same-millisecond marks can be reordered, making causality ambiguous. | `NativeTelemetry.swift:44-51` | Preserve insertion order as a secondary key (sequence number) or record monotonic nanosecond timestamps. |
| R3 | Metadata is `[String: String]` only. | Numeric metadata (chunk index, token count, memory bytes) must be stringified and parsed downstream; lossy and fragile. | `NativeTelemetry.swift:6`, `NativeTelemetry.swift:33` | Introduce a typed metadata variant (e.g., `MetadataValue` enum with `.string`, `.int`, `.double`, `.bool`) while keeping Codable backward compatibility. |
| R4 | Stage marks are not correlated with `os_signpost` intervals. | Automated benchmark analysis cannot see the Instruments intervals that engineers use for root-cause analysis. | `NativeStreamingSynthesisSession.swift:1229-1234` vs. Instruments intervals at lines 977, 1230, 1356 | Mirror the most expensive signpost boundaries into `stageMarks` when telemetry is enabled (see P2 item). |

### 2.2 Memory sampler — `Sources/QwenVoiceCore/NativeTelemetrySampler.swift`

| # | Observation | Risk / blind spot | Evidence | Recommended fix |
|---|---|---|---|---|
| S1 | Samples capture only process memory and GPU allocation size. | No thermal state, CPU/GPU utilization, Jetsam trajectory, or Metal command-buffer data. | `TelemetrySample:5-15`, `TelemetrySummary:42-55` | Add `thermalState` (at start/end/change) and `gpuWorkingSetUsageRatioPeak` to `TelemetrySummary`; consider optional command-buffer depth counters in verbose mode. |
| S2 | `timeToPeakMS` is derived from the resident-size peak only. | GPU or physFootprint peaks may occur at different times; the current metric can mislead tuning. | `NativeTelemetrySampler.swift:162-194` | Compute `timeToPeakMS` for `physFootprintPeakMB` and `gpuAllocatedPeakMB` separately, or report the time of each peak. |
| S3 | `threadCount()` silently returns `0` if `task_threads` fails. | A zero thread count in telemetry could be misread as “no threads” rather than “measurement failed.” | `NativeTelemetrySampler.swift:211-228` | Return `nil` on failure and make `TelemetrySample.threads` optional, or add a `threadCountFailed` flag. |
| S4 | Cadence is driven by `Task.sleep(nanoseconds:)`. | Sleep can drift under heavy CPU/GPU load; samples are not evenly spaced in time. | `NativeTelemetrySampler.swift:107-121` | Record actual elapsed time per sample and compute drift statistics in verbose mode. |
| S5 | `chunkIndex` decoration depends on a string metadata key. | Typo-prone and inconsistent with typed stage marks. | `NativeTelemetrySampler.swift:152-154` | Add a typed `chunkIndex` field to `NativeTelemetryStageMark`. |

### 2.3 Memory snapshot — `Sources/QwenVoiceCore/IOSMemorySnapshot.swift`

| # | Observation | Risk / blind spot | Evidence | Recommended fix |
|---|---|---|---|---|
| M1 | `capture()` defaults `device:` to `MTLCreateSystemDefaultDevice()`. | Callers that forget to pass a cached device allocate a new Metal device per sample. | `IOSMemorySnapshot.swift:136-139` | Remove the default and force callers to provide a cached device; already done correctly by `NativeTelemetrySampler` at line 97. |
| M2 | `band(for:)` falls back to `totalDeviceRAM - usedBytes` on macOS. | This is a coarse “headroom” proxy that does not reflect macOS memory pressure accurately. | `IOSMemorySnapshot.swift:314-333` (not read in full, but referenced in subagent audit) | Document the fallback as macOS-only and avoid using it for pressure-band telemetry on macOS; rely on `physFootprint` and `gpuAllocated` instead. |
| M3 | No GPU working-set ratio stored in the telemetry row. | The ratio is computed for admission decisions but not persisted for post-hoc analysis. | `IOSMemorySnapshot.swift:158-159`, `NativeMemoryPolicyResolver.swift:186-193` | Add `gpuWorkingSetUsageRatioPeak` to `TelemetrySummary` and log `cacheLimitBytes` / `memoryLimitBytes` in `notes`. |

### 2.4 JSONL sink — `Sources/QwenVoiceCore/GenerationTelemetryJSONLSink.swift`

| # | Observation | Risk / blind spot | Evidence | Recommended fix |
|---|---|---|---|---|
| J1 | A crash mid-generation loses the in-memory row. | No durable telemetry is emitted for runs that crash, which are exactly the runs you most want data from. | `GenerationTelemetryJSONLSink.swift:36-64` | Optionally flush a partial row on memory-pressure warning or on a periodic timer during very long generations. |
| J2 | Write failures only `print`; callers are not notified. | Telemetry gaps go undetected by the benchmark harness. | `GenerationTelemetryJSONLSink.swift:61-63`, `99-101` | Propagate write failures as stage marks or log them to `native-events.jsonl` so the summarizer can report missing rows. |
| J3 | Verbose sidecar is built entirely in memory before atomic write. | Very long verbose runs can create a large transient `Data` object. | `GenerationTelemetryJSONLSink.swift:87-93` | Stream-encode samples to a temporary file and atomically move it into place. |
| J4 | Pruning reads the whole log into memory. | Acceptable at the 8 MB cap but not zero-cost. | `GenerationTelemetryJSONLSink.swift:128-148` | Document the cost; consider a bounded circular buffer or file rotation for very high-volume logs. |

### 2.5 Telemetry gate — `Sources/QwenVoiceCore/TelemetryGate.swift`

| # | Observation | Risk / blind spot | Evidence | Recommended fix |
|---|---|---|---|---|
| G1 | `applyHandshakeMode(.off)` is ignored (one-way latch). | Once an engine process learns telemetry is on, it cannot be turned off via handshake. | `TelemetryGate.swift:42-49` | Document this as intentional; if dynamic off is needed, add a separate “disable” handshake message. |
| G2 | `isEnabled` is a `static let` resolved once at launch. | Runtime env changes after launch are ignored. | `TelemetryGate.swift:24` | Document the launch-time resolution; if dynamic reconfiguration is required, move to a computed property with a small performance cost. |

### 2.6 Backend probe insertion points — `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`

| # | Observation | Risk / blind spot | Evidence | Recommended fix |
|---|---|---|---|---|
| B1 | `firstChunk` stage mark is emitted **after** `samples.asArray(Float.self)` has materialized the chunk on CPU. | TTFC measures “first usable PCM,” not “first decoded audio,” depending on the goal. | `NativeStreamingSynthesisSession.swift:1229-1234` | Add an earlier `firstChunkDecoded` mark right after the decoder yields `MLXArray`, and keep `firstChunkMaterialized` for the current semantics. |
| B2 | `streamCompleted` is emitted **after** `finalWriter.finish()` and the post-generation memory snapshot. | The `streamStartup → streamCompleted` span includes WAV finalization, inflating `decodeWallSeconds` fallback. | `NativeStreamingSynthesisSession.swift:1353-1356`, `1694-1712` | Emit a separate `streamGenerationEnded` mark before final I/O, and use it for `decodeWallSeconds`. |
| B3 | `computeDerivedMetrics` falls back to stage-mark span only if `info.generateTime <= 0`. | For failed/cancelled runs the span can be zero or negative, losing RTF. | `NativeStreamingSynthesisSession.swift:1705-1712` | Defensive clamp: if `endMS <= startMS`, record `decodeWallSeconds` as `nil` and flag the record with a `derivedMetricsIncomplete` note. |
| B4 | `chunkTimeline` is only populated for streaming; quality-first path sets it to `nil`. | Non-streaming benchmark runs (the CLI default) cannot be decomposed by chunk. | `NativeStreamingSynthesisSession.swift:1012`, `1403` | Document this limitation in `telemetry-and-benchmarking.md`; consider pseudo-chunk marks for quality-first runs. |
| B5 | `audioQC` thresholds are hardcoded. | No per-model-variant or per-sample-rate calibration. | `NativeStreamingSynthesisSession.swift:1557-1674` (threshold builder) | Move thresholds into a `AudioQCProfile` struct keyed by sample rate and model variant, or at least record the active thresholds in `notes`. |
| B6 | Vendored `ChunkSubstageTimings` are a black box. | If the vendored code misses a substage (token sampling, KV-cache update), telemetry cannot see it. | `GenerationTelemetryRecord.swift:175-184` | Audit the vendored `Qwen3TTS.swift` diagnostics path and add explicit stage marks for any substage not already captured. |

### 2.7 AudioQC / `PCM16StreamLimiter` — `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift:533-679`

| # | Observation | Risk / blind spot | Evidence | Recommended fix |
|---|---|---|---|---|
| Q1 | Only aggregate counts are reported. | Defect localization (first non-finite sample, first clip, longest silence position) is missing. | `PCM16StreamLimiter.Metrics:534-546`, `makeAudioQCReport:1557-1674` | Add `firstNonFiniteSample`, `firstClipSample`, `longestSilenceStartMS` to the report. |
| Q2 | Silence floor is absolute (`0.001`). | Low-level but intentional speech can be misclassified. | `PCM16StreamLimiter` silence floor inferred from `makeAudioQCReport` | Use a relative floor (e.g., −60 dB relative to local peak/RMS) or make it configurable per model. |
| Q3 | No per-chunk QC. | Early corruption or drift is invisible until the final clip. | `makeAudioQCReport` is called once at `streamCompleted` | Compute incremental per-chunk metrics and emit a `chunkQC` array in verbose mode. |
| Q4 | No frequency-domain checks. | Codec degradation (robotic artifacts, harmonic loss) is not caught. | `AudioQCReport:120-169` | Add optional lightweight spectral checks (spectral centroid, high-frequency energy ratio) in verbose mode. |

### 2.8 Benchmark scripts

#### `scripts/summarize_generation_telemetry.py`

| # | Observation | Risk / blind spot | Evidence | Recommended fix |
|---|---|---|---|---|
| P1 | Reports median only; no variance, IQR, CIs, or outlier rejection. | Run-to-run thermal/noise is invisible; a single bad take silently skews the cell. | `summarize_generation_telemetry.py:317-319`, `:456` | Add IQR/MAD per cell, flag outliers (>1.5× IQR), and optionally report a trimmed mean. |
| P2 | `chunkTimeline` is emitted by the engine but never aggregated. | First-chunk and stall-localization insights require manual parsing. | `GenerationTelemetryRecord.swift:59-65`, summarizer does not reference `chunkTimeline` | Add a chunk-timeline summary section (mean chunk arrival, steady-state vs cold-start breakdown). |
| P3 | `generations-merged.jsonl` is ignored. | The cross-layer view (app + engine-service + engine) is not used for automated analysis. | `GenerationTelemetryMerger.swift` exists but summarizer reads only `engine/generations.jsonl` and `app/generations.jsonl` | Optionally ingest `generations-merged.jsonl` and report cross-layer latency (submit→first chunk→first audible). |
| P4 | No regression alerting against a baseline. | `HISTORY.md` is append-only prose; regressions are detected by eye. | `benchmarks/HISTORY.md` | Add `--compare-baseline <file>` mode that computes percent deltas and highlights cells beyond a threshold. |
| P5 | Length-bucket thresholds are hardcoded in both producer and consumer. | Changing thresholds requires edits in two places. | `summarize_generation_telemetry.py:178` vs. `BenchCommand.lenBucket` (not read) | Share a single JSON/YAML threshold definition consumed by both Swift and Python. |
| P6 | Full JSONL files are loaded into memory. | Large verbose logs can stall the summarizer. | `summarize_generation_telemetry.py` reads via `read_jsonl` returning a list | Stream-aggregate using `ijson` or a line-by-line generator for the common-case metrics. |

#### `scripts/bench_delivery_prosody.py` / `scripts/analyze_prosody.py` / `scripts/prosody_quality_gate.py`

| # | Observation | Risk / blind spot | Evidence | Recommended fix |
|---|---|---|---|---|
| D1 | Neutral reference selection uses a single warm take; no averaging. | Neutral variance contaminates the instructed-vs-neutral delta. | `scripts/bench_delivery_prosody.py` (subagent audit) | Average across all available warm neutral takes for the same cell. |
| D2 | F0 is simple normalized autocorrelation; no sub-harmonic rejection beyond octave gate. | Can double/halve on breathy or noisy speech. | `scripts/analyze_delivery.py` (subagent audit) | Document the limitation; consider a more robust pitch estimator (e.g., RAPT/YIN) if delivery analysis becomes a shipped gate. |
| D3 | Prosody thresholds are conservative defaults, not calibrated. | False positives/negatives are likely for non-target speakers. | `scripts/prosody_quality_gate.py` | Add a calibration note and require per-speaker/delivery-style validation before using the gate for pass/fail decisions. |

---
## 3. Cross-reference gap matrix

This table maps the insights in each technology reference doc to a concrete probe or metric that is missing or under-captured in the current harness.

| Reference doc | Key insight | Current state | Missing probe / metric | Files affected |
|---|---|---|---|---|
| `mlx-guide.md` §2.3, §4.3 | Async eval lets the CPU overlap graph construction with GPU execution. | `qwen_stream_step_eval_total` is a single wall-clock number around `eval()`. | Separate `eval_enqueue_ms` vs `eval_wait_ms`; asyncEval schedule-to-completion latency. | vendored Qwen3-TTS, `NativeStreamingSynthesisSession.swift` |
| `mlx-guide.md` §5.1, §5.4 | Cache-limit and memory-limit settings strongly affect allocation pressure. | `mlxMemoryByStage` records `active`/`cache`/`peak`; policy bytes are not in the row. | `mlx_cache_limit_mb`, `mlx_memory_limit_mb`, `clear_cache_ms`, cache-hit/miss pressure signal. | `NativeMemoryPolicyResolver.swift`, `GenerationTelemetryRecord.swift` |
| `mlx-guide.md` §7.1, §8.1 | Eval overhead is not GPU time; wall-clock conflates graph flush with kernel execution. | Decode breakdown warns it measures wall-clock around lazy ops. | True GPU time via Metal command-buffer completion handlers or `MTLCapture`. | vendored Qwen3-TTS, `metal-guide.md` path |
| `mlx-guide.md` §2.2, §4.5 | CPU↔GPU transfers (`.item()`, `.asArray()`) are expensive sync points. | Only EOS readback is timed (`qwen_stream_step_eos_read_total`). | Count and time all `.item()` / `asArray()` / `asMTLBuffer()` readbacks. | vendored Qwen3-TTS, `NativeStreamingSynthesisSession.swift` |
| `qwen3-tts-guide.md` §3.2, §3.3 | Talker attention/FFN/projection and Code Predictor per-pass cost are distinct. | Talker is a single bucket; CP has loop total only. | `talker_attention_ms`, `talker_ffn_ms`, `talker_projection_ms`, `talker_rope_ms`; CP per-pass distribution. | vendored Qwen3-TTS |
| `qwen3-tts-guide.md` §3.2 | KV cache is the dominant long-sequence memory consumer. | Only `qwen_talker_kv_cache_offset` is captured. | KV-cache footprint MB, shape `[layers, batch, heads, seq, head_dim]`, effective seq length per token. | vendored Qwen3-TTS, `GenerationTelemetryRecord.swift` |
| `qwen3-tts-guide.md` §3.5, §8 | Speaker/clone conditioning has real cost. | Clone preparation timings exist as load-side diagnostics; per-generation apply cost is not isolated. | `clone_conditioning_apply_ms`, `speaker_embedding_apply_ms`. | `NativeEngineRuntime.swift`, vendored Qwen3-TTS |
| `swift-performance-guide.md` §3.5 | Task priority / QoS affects scheduling. | Generation uses `.userInitiated`, sampler uses `.utility`, but priority is not recorded. | `taskPriority` / `qosClass` in engine row; prewarm-slot wait time. | `NativeStreamingSynthesisSession.swift`, `NativeEngineRuntime.swift`, `NativeTelemetrySampler.swift` |
| `swift-performance-guide.md` §3.3, §9.4 | Actor contention can stall generation. | `NativeEngineRuntime` actor gates prewarm slot; no timing for contention. | Prewarm-slot acquisition wait time; actor suspension heuristic. | `NativeEngineRuntime.swift` |
| `swift-performance-guide.md` §8.1 | `os_signpost` intervals are the richest source but Instruments-only. | Signposts exist but are not persisted to JSONL. | Mirror key intervals (`Native Quality-First Generation`, `Step Eval Flush`) into `stageMarks`/`timingsMS`. | `NativeStreamingSynthesisSession.swift`, `NativeEngineRuntime.swift` |
| `mimi-codec-guide.md` §3.2, §6.3 | SEANet vs transformer cost is separable. | Decoder is aggregated per chunk (`audioDecoderMS`). | `decoder_transformer_ms`, `decoder_seanet_ms`, `decoder_quantizer_lookup_ms` per frame. | vendored Mimi/Qwen3-TTS |
| `mimi-codec-guide.md` §4.4, §5.2, §5.3 | Streaming buffer state determines continuity. | No logging of `CausalConv1d.streamBuffer` or transformer KV cache sizes. | `input_context_samples`, `stream_buffer_samples`, `transformer_kv_cache_frames`. | vendored Mimi/Qwen3-TTS |
| `mimi-codec-guide.md` §7.3 | PCM length should match code count × upsample ratio. | Length mismatch detection is manual (`qwen3TTS12HzValidationFailure`). | Automatic `audio_pcm_frames_expected` vs `audio_pcm_frames_actual` check. | `NativeStreamingSynthesisSession.swift` |
| `metal-guide.md` §5.2, §8.1 | GPU working-set ratio is a key pressure signal. | Ratio is used for admission but not stored in the telemetry row. | `gpuWorkingSetUsageRatioPeak` in `TelemetrySummary`. | `IOSMemorySnapshot.swift`, `NativeTelemetrySampler.swift`, `GenerationTelemetryRecord.swift` |
| `metal-guide.md` §6.4, §7.4 | Command-buffer completion gives true GPU busy time. | No completion handlers attached. | `gpuBusyMS` via `addCompletedHandler` on the dominant command buffer(s). | vendored MLX / Metal layer |
| `metal-guide.md` §8.2 | Thermal throttling changes RTF and memory behavior. | `ProcessInfo.thermalState` is observed in the iOS app but not recorded per generation. | Capture thermal state at generation start/end and on change; add to `TelemetrySummary`. | `NativeTelemetrySampler.swift`, `GenerationTelemetryRecord.swift`, `Sources/iOS/QVoiceiOSApp.swift` |

---

## 4. Prioritized improvement backlog

### P0 — Done

| # | Item | Rationale | Primary files | Estimated effort |
|---|---|---|---|---|
| P0.1 | Correct iOS process-model statement in `telemetry-and-benchmarking.md` | **Done** — doc now states macOS XPC out-of-process, iOS in-process (ExtensionKit removed). | `docs/reference/telemetry-and-benchmarking.md` | Small |
| P0.2 | Add `ProcessInfo.thermalState` to the telemetry summary | Thermal throttling is a top driver of RTF/memory variance and is already observed in the iOS app (`Sources/iOS/QVoiceiOSApp.swift:68-72`). | `NativeTelemetrySampler.swift`, `TelemetrySummary`, `GenerationTelemetryRecord.swift` | Small |
| P0.3 | Add `gpuWorkingSetUsageRatioPeak` and MLX cache/memory-limit notes | Directly supports the Metal/MLX optimization programs; ratio is already computed for admission. | `IOSMemorySnapshot.swift`, `NativeTelemetrySampler.swift`, `GenerationTelemetryRecord.notes` | Small |
| P0.4 | Label `QVOICE_IOS_MLX_MEMORY_LIMIT_MB` as dev-only in `telemetry-and-benchmarking.md` | **Done** — env table at line 81 labels it "Dev-only / do not ship." | `docs/reference/telemetry-and-benchmarking.md` | Tiny |

> **P0 status:** Completed in commit `8b04179` on branch `feat/telemetry-harness-improvements`. macOS and iOS foundation builds passed; `check_project_inputs.sh` passed.

### P1 — High value, moderate effort

| # | Item | Rationale | Primary files | Estimated effort |
|---|---|---|---|---|
| P1.1 | Split `streamStepEvalMS` into enqueue/wait or attach Metal completion handler for true GPU time | Resolves the lazy-eval vs wall-clock ambiguity that the current script comments warn about. | vendored Qwen3-TTS, `NativeStreamingSynthesisSession.swift` | Medium |
| P1.2 | Log KV-cache footprint, shape, and effective sequence length | Enables memory optimization and validates the “KV cache is large” assumption. | vendored Qwen3-TTS, `GenerationTelemetryRecord.swift` | Medium |
| P1.3 | Surface `chunkTimeline` in the summarizer and add variance / outlier handling | Transforms narrative benchmarks into statistical guardrails. | `scripts/summarize_generation_telemetry.py`, `benchmarks/HISTORY.md` | Medium |
| P1.4 | Add `taskPriority`/`qosClass` and prewarm-slot wait time to the engine row | Supports Swift-performance tuning and explains scheduling anomalies. | `NativeStreamingSynthesisSession.swift`, `NativeEngineRuntime.swift` | Small |
| P1.5 | Harden JSONL sink: propagate write failures and optional in-memory row rescue | Improves observability reliability; crashes are the most important events to capture. | `GenerationTelemetryJSONLSink.swift` | Medium |
| P1.6 | Add a `--compare-baseline` mode to the summarizer | Enables automated regression detection against committed baselines. | `scripts/summarize_generation_telemetry.py` | Medium |

> **P1 Python status:** Completed in commits on branch `feat/telemetry-harness-improvements`. `scripts/tests/` now has 34 passing tests covering IQR/MAD/outliers, chunk-timeline aggregation, merged-telemetry cross-layer latency, and baseline regression gating.

### P2 — Valuable but deeper / optional

| # | Item | Rationale | Primary files | Estimated effort |
|---|---|---|---|---|
| P2.1 | Add per-frame / pipeline-stage Mimi decoder timings in verbose mode | Isolates codec regressions; requires vendored code changes. | vendored Mimi/Qwen3-TTS, `GenerationTelemetryRecord.swift` | Large |
| P2.2 | Mirror key `os_signpost` intervals into JSONL `stageMarks` / `timingsMS` | Lets automated analysis see what Instruments sees. | `NativeStreamingSynthesisSession.swift`, `NativeEngineRuntime.swift` | Medium |
| P2.3 | Add typed metadata (`int`/`double`/`bool`) to `NativeTelemetryStageMark` | Removes string parsing fragility downstream. | `NativeTelemetry.swift`, `GenerationTelemetryRecord.swift`, summarizer | Medium |
| P2.4 | Use high-resolution clock for sub-millisecond probes | Enables per-frame codec and command-buffer timing. | `NativeTelemetry.swift` | Small |
| P2.5 | Add audioQC defect localization and per-chunk QC | Speeds root-cause analysis for defects. | `NativeStreamingSynthesisSession.swift` | Medium |
| P2.6 | Stream-aggregate the summarizer instead of loading full JSONL | Scales to large verbose logs. | `scripts/summarize_generation_telemetry.py` | Medium |
| P2.7 | Calibrate prosody thresholds against a labeled corpus | Required before prosody gates can be used for pass/fail decisions. | `scripts/prosody_quality_gate.py`, `scripts/delivery_adherence.py` | Large |

---

## 5. Documentation corrections needed

The following were small inaccuracies or inconsistencies between `telemetry-and-benchmarking.md` and the current code/architecture. **Fixed (2026-06-28)** as part of P0.1 and P0.4; retained as audit history.

1. **iOS process model:** **Fixed** — doc now states macOS XPC out-of-process, iOS in-process (ExtensionKit removed).
2. **Retired `engine-extension` layer:** **Fixed** — surrounding prose updated for consistency.
3. **Env-var labels:** **Fixed** — `QVOICE_IOS_MLX_MEMORY_LIMIT_MB` labeled dev-only / do not ship in the env table.
4. **Handshake function name:** **Fixed** — doc references `TelemetryGate.applyHandshakeMode(_:)`.
5. **`QWENVOICE_NATIVE_TELEMETRY_MODE` values:** **Fixed** — gate accepts `light`, `full`, `deep` aliases.

---

## 6. What the harness does well

It is worth preserving these strengths while adding probes:

- **Zero-cost gating.** `TelemetryGate.resolvedEnabled` keeps the hot path identical in shipped builds; nothing is compiled out.
- **Shared start clock.** The sampler and recorder use the same `ProcessInfo.systemUptime` origin, so memory samples join cleanly to stage marks.
- **Layered, joinable rows.** App / engine-service / engine / merged layers share `generationID`, enabling cross-layer analysis.
- **Opt-in verbosity.** Raw per-sample sidecars live in separate files, so the default log stays compact.
- **Reference-free audio QC.** `PCM16StreamLimiter` catches NaN/Inf, clipping, chunk-boundary clicks, and mid-utterance dropouts without requiring golden references.
- **Punctuation-aware pause budget.** The audioQC builder avoids false positives on legitimate prosodic pauses.
- **Crash-safe file semantics.** The sink uses atomic writes and oldest-first pruning, even if some edge cases (crash mid-generation) remain unhandled.

---

## 7. Conclusion and next steps

The telemetry/benchmarks harness is a solid foundation, but it is currently optimized for **coarse, high-level optimization** (RTF, memory peaks, wall-clock stage attribution). The new reference docs identify the next layer of optimization levers as **MLX/Metal runtime internals**: async eval scheduling, cache pressure, KV-cache shape, command-buffer completion, thermal state, and per-frame codec timing.

The recommended path forward:

1. **Land the P0 items** (doc corrections + thermal state + GPU working-set ratio + MLX policy notes). These are cheap, safe, and immediately useful.
2. **Pick one P1 item at a time** for implementation, starting with either:
   - **P1.1** (split `streamStepEvalMS`) if the next optimization push is decode-loop GPU attribution, or
   - **P1.3** (summarizer variance + `chunkTimeline`) if the next push is benchmark automation / regression gating.
3. **Scope P2 items** only after the P0/P1 backlog is in place; they require vendored code changes and should each get their own implementation plan.

No production telemetry code changes are required to adopt this review; the backlog can be treated as a roadmap and implemented incrementally.

---

*Review produced by auditing `Sources/QwenVoiceCore/NativeTelemetry*.swift`, `GenerationTelemetryRecord.swift`, `GenerationTelemetryJSONLSink.swift`, `IOSMemorySnapshot.swift`, `NativeMemoryPolicyResolver.swift`, `NativeMemoryPressureMonitor.swift`, `NativeStreamingSynthesisSession.swift`, `scripts/summarize_generation_telemetry.py`, `scripts/bench_delivery_prosody.py`, `scripts/analyze_delivery.py`, `scripts/analyze_prosody.py`, `scripts/prosody_quality_gate.py`, `benchmarks/OPTIMIZATION.md`, `benchmarks/HISTORY.md`, and the technology reference docs listed in the header.*
