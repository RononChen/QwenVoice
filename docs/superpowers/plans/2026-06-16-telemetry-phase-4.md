# Phase 4 Telemetry Harness Improvements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining telemetry/benchmark blind spots identified in `docs/reference/telemetry-harness-review.md`: per-frame Mimi decoder attribution, signpost-to-JSONL mirroring, typed stage-mark metadata, high-resolution clocks, audioQC defect localization, streaming summarizer aggregation, and prosody calibration.

**Architecture:** Keep all changes additive and runtime-gated. Reuse the existing `GenerationTelemetryRecord`/`GenerationTelemetryJSONLSink` pipeline, bump `currentSchemaVersion` to 5 for new optional fields, and preserve backward-compatible decoding. Vendored backend changes stay behind telemetry callbacks so the hot path is zero-cost when telemetry is off.

**Tech Stack:** Swift 6, MLX Swift, `OSSignposter`, `ContinuousClock`/`mach_absolute_time`, Python 3 + numpy for bench/prosody scripts.

---

## Task 1: Mirror os_signpost intervals into JSONL (P2.2)

**Files:**
- Modify: `Sources/QwenVoiceCore/NativeTelemetry.swift`
- Modify: `Sources/QwenVoiceCore/NativeEngineRuntime.swift`
- Modify: `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`
- Test: `./scripts/build_foundation_targets.sh` + `python -m pytest scripts/tests/`

- [ ] **Step 1: Add a signpost-mirror helper**

In `NativeTelemetry.swift`, add:

```swift
public struct NativeTelemetrySignpostInterval {
    public let name: String
    public let timingKey: String
}

public func withMirroredSignpost<T>(
    _ interval: NativeTelemetrySignpostInterval,
    signposter: OSSignposter,
    recorder: NativeTelemetryRecorder?,
    timings: inout [String: Int],
    operation: () async throws -> T
) async rethrows -> T {
    let signpostID = signposter.makeSignpostID()
    signposter.beginInterval(interval.name, id: signpostID)
    let startedAt = ContinuousClock.now
    recorder?.mark(stage: "signpost_begin", metadata: ["interval": interval.name])
    defer {
        let ms = startedAt.elapsedMilliseconds
        signposter.endInterval(interval.name, id: signpostID)
        recorder?.mark(stage: "signpost_end", metadata: ["interval": interval.name])
        timings[interval.timingKey] = ms
    }
    return try await operation()
}
```

- [ ] **Step 2: Wrap engine-runtime intervals**

In `NativeEngineRuntime.swift`, wrap these signposts and add the returned keys to `timingOverridesMS`:

| Signpost name | Timing key | Approximate location |
|---|---|---|
| `Native Prepare Generation` | `native_prepare_generation_ms` | `prepareGeneration()` |
| `Native Model Load` | `native_model_load_ms` | `loadModel(...)` |
| `Native Clone Conditioning` | `native_clone_conditioning_ms` | `resolveCloneConditioning(...)` |
| `Native Explicit Prewarm` | `native_explicit_prewarm_ms` | `ensureWarmStateIfNeeded(...)` |

- [ ] **Step 3: Wrap session/streaming intervals**

In `NativeStreamingSynthesisSession.swift`, add a local `signpostTimingsMS` dict and wrap:

| Signpost name | Timing key |
|---|---|
| `Native Quality-First Generation` | `native_quality_first_generation_ms` |
| `Native Generation Stream` | `native_generation_stream_ms` |
| `Native Final WAV Finish` | `native_final_wav_finish_ms` |

Merge `signpostTimingsMS` into `finalTimingsMS` before writing the engine row.

- [ ] **Step 4: Build and test**

```bash
./scripts/build_foundation_targets.sh
python -m pytest scripts/tests/ -q
```

Expected: macOS + iOS builds succeed; 34 Python tests pass.

---

## Task 2: High-resolution clock mode (P2.4)

**Files:**
- Modify: `Sources/QwenVoiceCore/TimingExtensions.swift`
- Modify: `Sources/QwenVoiceCore/NativeTelemetry.swift`
- Modify: `Sources/QwenVoiceCore/NativeTelemetrySampler.swift`
- Modify: `Sources/QwenVoiceCore/GenerationTelemetryRecord.swift`
- Modify: `Sources/QwenVoiceCore/NativeEngineRuntime.swift`
- Modify: `Sources/SharedSupport/Telemetry/AppGenerationTimeline.swift`
- Modify: `Sources/QwenVoiceEngineService/EngineServiceHost.swift`
- Test: `./scripts/build_foundation_targets.sh` + `python -m pytest scripts/tests/`

- [ ] **Step 1: Add a shared high-resolution clock helper**

In `TimingExtensions.swift`, add:

```swift
public struct NativeTelemetryClock: Sendable {
    public let startUptimeSeconds: TimeInterval
    public let startMachAbs: UInt64

    public init(
        startUptimeSeconds: TimeInterval = ProcessInfo.processInfo.systemUptime,
        startMachAbs: UInt64 = mach_absolute_time()
    ) {
        self.startUptimeSeconds = startUptimeSeconds
        self.startMachAbs = startMachAbs
    }

    public func now() -> (ms: Int, ns: UInt64) {
        let ms = Int((ProcessInfo.processInfo.systemUptime - startUptimeSeconds) * 1_000)
        let ns = mach_absolute_time() - startMachAbs
        return (ms, ns)
    }
}
```

Add a nanosecond timebase conversion helper if `mach_absolute_time` units are not nanoseconds (use `mach_timebase_info`).

- [ ] **Step 2: Extend stage marks and samples**

In `NativeTelemetry.swift`:

```swift
public struct NativeTelemetryStageMark: Hashable, Codable, Sendable {
    public let tMS: Int
    public let tNS: UInt64?
    public let sequence: Int?
    public let stage: String
    public let metadata: [String: String]
}
```

In `NativeTelemetrySampler.swift`, add `tNS: UInt64?` and `actualElapsedNS: UInt64?` to `TelemetrySample`.

- [ ] **Step 3: Use the shared clock in recorder + sampler**

Replace `startUptimeSeconds` with `NativeTelemetryClock` in `NativeTelemetryRecorder` and `NativeTelemetrySampler`. `mark()` records `(tMS, tNS, sequence)`. `captureSample()` records `(tMS, tNS)`.

In `NativeEngineRuntime.prepareGeneration`, create one `NativeTelemetryClock` and pass it to both recorder and sampler (and the load coordinator if needed).

- [ ] **Step 4: Update durable schema**

In `GenerationTelemetryRecord.swift`:

```swift
public static let currentSchemaVersion = 5
public let clockSource: String? = "mach_absolute_time"
```

Add `arrivalNS: UInt64?` to `GenerationChunkTelemetry` with backward-compatible decoding defaulting to `nil`.

In `AppGenerationTimeline.swift` and `EngineServiceHost.swift`, emit nanosecond-span keys alongside the existing millisecond keys (`submitToFirstChunkNS`, `chunkForwardingSpanNS`).

- [ ] **Step 5: Build and test**

```bash
./scripts/build_foundation_targets.sh
python -m pytest scripts/tests/ -q
```

---

## Task 3: Stream-aggregate summarizer (P2.6)

**Files:**
- Modify: `scripts/summarize_generation_telemetry.py`
- Modify: `scripts/tests/test_summarize_generation_telemetry.py`
- Test: `python -m pytest scripts/tests/test_summarize_generation_telemetry.py -q`

- [ ] **Step 1: Replace full JSONL load with a streaming generator**

```python
def iter_jsonl(path):
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue
```

Keep `read_jsonl(path)` as `list(iter_jsonl(path))` for external callers.

- [ ] **Step 2: Stream `load_runs` with a lightweight app index**

First pass: stream `app/generations.jsonl` and build `app_index: dict[generationID, dict]` with only joined fields.
Second pass: stream `engine/generations.jsonl`, look up app row, build run dict, append to result list.

- [ ] **Step 3: Add a `CellAccumulator` for full aggregation**

```python
@dataclass
class CellAccumulator:
    key: tuple
    rtfs: list = field(default_factory=list)
    tokpss: list = field(default_factory=list)
    ttfcs: list = field(default_factory=list)
    decode_loop_ms: list = field(default_factory=list)
    peak_gpu_mb: list = field(default_factory=list)
    phys_foot_mb: list = field(default_factory=list)
    trims: list = field(default_factory=list)
    worst_trims: list = field(default_factory=list)
    ui_stalls: list = field(default_factory=list)
    ui_max_stalls: list = field(default_factory=list)
    qc_verdicts: list = field(default_factory=list)
    qc_flags: set = field(default_factory=set)
    chunk_substage_values: dict = field(default_factory=lambda: defaultdict(list))

    def add_run(self, run: dict) -> None: ...
    def finalize(self) -> dict: ...
```

- [ ] **Step 4: Wire `aggregate_runs` into `main()`**

Add `aggregate_runs(diag_dir)` that returns `(cells, delivery_cells)` already mapped to finalized summary dicts. Update `main()` to use it. Preserve `--save-baseline` / `--compare-baseline` output format.

- [ ] **Step 5: Add tests**

- `test_iter_jsonl_is_generator` — confirms lazy loading.
- `test_cell_accumulator_matches_grouping` — compare `aggregate_runs` medians with the old `load_runs` path on existing fixtures.

- [ ] **Step 6: Run tests**

```bash
python -m pytest scripts/tests/test_summarize_generation_telemetry.py scripts/tests/test_compare_baseline.py -q
```

---

## Task 4: Typed metadata for stage marks (P2.3)

**Files:**
- Modify: `Sources/QwenVoiceCore/NativeTelemetry.swift`
- Modify: `Sources/QwenVoiceCore/NativeTelemetrySampler.swift`
- Modify: `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`
- Modify: `Sources/QwenVoiceCore/GenerationTelemetryRecord.swift`
- Modify: `docs/reference/telemetry-and-benchmarking.md`

- [ ] Define `NativeTelemetryMetadataValue` enum with `.string`, `.int`, `.double`, `.bool` and a primitive JSON Codable implementation.
- [ ] Change `NativeTelemetryStageMark.metadata` to `[String: NativeTelemetryMetadataValue]`.
- [ ] Keep a `[String: String]` overload on `NativeTelemetryRecorder.mark` so existing callers compile unchanged.
- [ ] Update `NativeTelemetrySampler.decorate` to read `chunk_index` from the typed value.
- [ ] Change the `.firstChunk` mark to emit `["chunk_index": .int(chunkIndex)]`.
- [ ] Bump `currentSchemaVersion` to 5 and update docs.

---

## Task 5: Per-frame Mimi decoder timings (P2.1)

**Files:**
- Modify: `third_party_patches/mlx-audio-swift/Sources/MLXAudioCodecs/Mimi/Qwen3TTSSpeechTokenizer.swift`
- Modify: `third_party_patches/mlx-audio-swift/Sources/MLXAudioCore/Generation/GenerationTypes.swift`
- Modify: `third_party_patches/mlx-audio-swift/Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift`
- Modify: `Sources/QwenVoiceCore/GenerationTelemetryRecord.swift`
- Modify: `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`
- Modify: `scripts/summarize_generation_telemetry.py`

- [ ] Add coarse pipeline-stage split fields to `ChunkSubstageTimings` and `GenerationChunkTelemetry` (`audioDecoderQuantizerMS`, `audioDecoderTransformerMS`, `audioDecoderUpsampleMS`, `audioDecoderSeanetMS`, `audioDecoderOutputMS`).
- [ ] In `Qwen3TTSSpeechTokenizerDecoder.streamingStep`, add an optional diagnostics sink and measure each major stage.
- [ ] In `Qwen3TTS.swift`, accumulate stage totals per chunk and populate the new `ChunkSubstageTimings` fields.
- [ ] In verbose mode, write per-frame `DecoderFrameTelemetry` rows to a `decoder-frames-<id>.jsonl` sidecar.
- [ ] Update the summarizer to aggregate and display the new decoder-stage columns.

---

## Task 6: audioQC defect localization + per-chunk QC (P2.5)

**Files:**
- Modify: `Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`
- Modify: `Sources/QwenVoiceCore/GenerationTelemetryRecord.swift`
- Modify: `scripts/summarize_generation_telemetry.py`

- [ ] Extend `AudioQCReport` with optional first-occurrence fields (`firstNonFiniteSampleMS`, `firstClippedSampleMS`, `firstHotSampleMS`, `firstClickSampleMS`, `longestSilenceStartMS`, `longestSilenceEndMS`).
- [ ] Add `AudioQCChunkReport` struct for per-chunk QC in verbose mode.
- [ ] Update `PCM16StreamLimiter` to track first-offset sample indices for each defect.
- [ ] Update `makeAudioQCReport` to convert offsets to ms and populate the new fields.
- [ ] In streaming mode, snapshot per-chunk QC and attach `chunkReports` to the engine row when verbose.
- [ ] Update the summarizer to print a defect-localization section when present.

---

## Task 7: Prosody calibration harness (P2.7)

**Files:**
- Create: `scripts/prosody_profile.py`
- Create: `scripts/prosody_calibration.py`
- Modify: `scripts/prosody_quality_gate.py`
- Modify: `scripts/delivery_adherence.py`
- Modify: `scripts/bench_delivery_prosody.py`
- Modify: `Sources/VocelloCLI/BenchCommand.swift`
- Create: `scripts/tests/test_prosody_quality_gate.py`
- Create: `scripts/tests/test_prosody_calibration.py`
- Create: `scripts/tests/fixtures/prosody/labels.jsonl`

- [ ] Define a versioned JSON profile schema with calibrated thresholds and delivery weights.
- [ ] Refactor `prosody_quality_gate.py` to load a profile; default to a built-in profile.
- [ ] Refactor `delivery_adherence.py` to read weights from the profile.
- [ ] Add `--prosody-profile` to `bench_delivery_prosody.py` and `BenchCommand.swift`.
- [ ] Add `prosody_calibration.py` CLI that ingests a labeled corpus and emits a calibrated profile.
- [ ] Add unit tests and synthetic fixture audio.

---

## Verification gates for the whole phase

```bash
./scripts/check_project_inputs.sh
./scripts/build_foundation_targets.sh
python -m pytest scripts/tests/ -q
```

After all tasks pass, commit with a single Phase 4 feature commit and push the branch.
