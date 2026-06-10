# Optimization progress

Durable record of backend/MLX + output-quality optimization work — what was investigated, decided,
shipped, and deferred. The blow-by-blow lives in git history + `HISTORY.md`; this file is the **standing
status** so a future session (or maintainer) can resume without re-deriving it. Anchored to the reference
baseline. Point-in-time as of **2026-06-09** (§H is the active program record).

## Reference baseline

[`baseline-2026-05-31-641a541.md`](baseline-2026-05-31-641a541.md) — pre-optimization reference, CLI-driven
(`vocello bench`), native floor **8 GB** tier. Headline: **RTF 0.20–0.89 (slower than realtime)**; the
**decode loop dominates wall time** and scales ~linearly with length; **clone is the heaviest** per length
and on memory (~7.4–8.7 GB physFoot in-process); `trims = 0` everywhere. Perf-over-time ledger:
[`HISTORY.md`](HISTORY.md).

## Status at a glance

| # | Workstream | Status | Where |
|---|---|---|---|
| A | Per-stage decode breakdown (measure) | ✅ done | `ac86b8a` (`summarize_generation_telemetry.py`) |
| B | The ~586 ms "dropout" investigation | ✅ done — root-caused | this doc + `641a541` baseline note |
| C | Punctuation-aware audioQC recalibration | ✅ done + verified | `ac86b8a` (`NativeStreamingSynthesisSession.swift`) |
| D | CodePredictor RoPE fusion | ✅ **done — closed by §H P3** (`f3cd2aa`): +26%, realtime crossed | §H |
| E | MLXSwift / mlx-swift-lm version bump (0.31.x) | ⏸ deferred — stay pinned, gated | this doc + CLAUDE.md "SPM dependencies" |
| F | iPhone 1.7B-4bit program — feasibility + WS0b profiling + compile/KV spikes | 🔬 see §F: compile rejected; **iOS RAM premise corrected — streaming peaks ~3 GB flat, KV windowing unneeded** | this doc + session plan |

## Grounding (the headline conclusion)

An external optimization report (a from-scratch iOS / iPhone-15-Pro playbook for Qwen3-TTS 1.7B) was
ground against Vocello's **shipped macOS engine**. Finding: the vendored `mlx-audio-swift` port **already
implements the large majority of its recommendations** — `small_to_mtp_projection` 2048→1024 bridge,
2048-dim speaker embedding, interleaved MRoPE `[24,20,20]`, Q/K RMSNorm, `MLXFast.scaledDotProductAttention`,
a single per-frame `eval()` (no per-step `.item()`), `asyncEval` streaming, the input-side decoder-drift fix
(`4fab110`), per-tier `GPU.cacheLimit`, fp16 KV cache, and a `compile(shapeless:)` SwiGLU. The report's two
"architecture corruption bugs" **do not exist here**. Adversarial verification dropped 7 of 12 candidate
levers as already-handled / overstated / infeasible. **The genuine remaining work is narrow**, and the
highest-value item was a quality finding, not a speed lever.

## A — Decode-loop measurement (done)

Added a per-stage **Decode breakdown** to the summarizer (`talker · sampCB0 · codePred · code2wav ·
stepEval · other`, from the `timingsMS` sub-keys already captured in the engine row).

**Key finding (changed the plan):** these are Swift-side wall-clock timers around **lazy** MLX ops, **not**
per-stage GPU compute. On custom/quality/long, `stepEval ≈ 77%` of decode is the **fused** compute of
Talker + 15× Code Predictor + sampling (the single per-frame `eval()`); `talker`/`codePred` measure graph
*build* time; `code2wav ≈ 0` because the decoder is `asyncEval`'d (Phase 2c) and overlaps the token loop —
pipelined, not free. **Consequence:** the wall-clock breakdown **cannot attribute decode *compute* per
stage**. Doing so needs an Instruments `xctrace` capture of the existing os_signpost intervals
("Talker Forward" / "Code Predictor Loop" / "Step Eval Flush" / "Audio Decoder"). This **gates D**.

## B — The ~586 ms "dropout" (done; root-caused — not an engine defect)

Effective sampling (all modes use `officialQualityDefault`): **temp 0.9, topK 50, topP 1.0 (nucleus off),
repetitionPenalty 1.05, minP 0.0**.

The baseline flagged a real ~586 ms mid-utterance silence. Investigation: it reproduced systematically on
long content (every long custom/design cell failed audioQC; clone passed), but objective analysis of fresh
takes showed **every interior silence ≥150 ms maps to a punctuation mark** — they are the model's **natural
prosodic pauses** at sentence/comma boundaries on long, slow narration, which the old fixed ≥400 ms detector
over-flagged. The one agy-confirmed genuine mid-phrase gap is positionally **adjacent to a comma pause** and
is indistinguishable from it by duration/amplitude alone (ear-only).

**Decision:** a sampling-side fix (e.g. minP floor / silence-run penalty) would suppress the model's
*natural* pauses to chase a rare, ear-only event — wrong tool, real prosody-degradation risk. Remediation
shifted to **C** (fix the tripwire); the listening pass stays the gate for the residual mid-phrase gap.

## C — Punctuation-aware audioQC recalibration (done, verified — `ac86b8a`)

`PCM16StreamLimiter` now records interior silence-run lengths; `makeAudioQCReport` counts **long pauses
(≥350 ms)** against the text's **pause budget** (interior punctuation boundaries, from `request.text`) and
flags only an **excess** beyond it (≥2 → fail, 1 → warn) or a single **egregious** ≥1200 ms gap (≥900 ms →
warn). Else `pass`. (`Sources/QwenVoiceCore/NativeStreamingSynthesisSession.swift`.)

**Verified** (re-bench custom,design × speed,quality × all lengths + deterministic replication on real WAVs
+ synthetic cases): **15/16 cells now `pass`** (every false-positive `fail`/`warn` cleared); the lone
remaining `warn` is a **real-but-natural ~1116 ms sentence-boundary pause** (correctly routed to the ear).
Sensitivity retained — synthetic 1300 ms → fail, 11 long pauses → fail. Perf unchanged (engine untouched;
see the `3da580d` `HISTORY.md` row vs the `641a541` baseline). The residual rare mid-phrase gap is ear-only;
the **mandatory listening pass remains the perceptual gate**.

## D — CodePredictor RoPE fusion (CLOSED — implemented in §H P3, `f3cd2aa`; kept for history)

CP RoPE is hand-rolled (`Qwen3TTSCodePredictor.swift`); `MLXFast.RoPE` exists in MLX-Swift 0.30.6 and the CP
uses standard 2D RoPE, so it *could* swap in. Realistic ceiling **~2–3 % RTF (CP only)**. **Gate (revised by
A):** the wall-clock breakdown can't decide if CP compute is a worthwhile slice of the fused `stepEval`, so
D should only be attempted **after an Instruments os_signpost capture** of one long/quality generation shows
the "Code Predictor Loop" interval is a meaningful fraction of "Step Eval Flush" GPU time. Vendored edit →
follow [`../docs/reference/mlx-audio-swift-patching.md`](../docs/reference/mlx-audio-swift-patching.md);
must preserve exact numerics (KV precision).

## E — MLXSwift / mlx-swift-lm version pin (deferred; **stay pinned**)

Pinned `exact: 0.30.6` (mlx-swift) + `2.30.6` (mlx-swift-lm) in **both** `project.yml` and the vendored
`third_party_patches/mlx-audio-swift/Package.swift`. Latest upstream is **0.31.3** (+ `mlx-swift-lm` 2.31.x;
a separate 3.x line also exists). **Decision: keep pinned at 0.30.6 / 2.30.6.** Rationale: the backend is
vendored + hand-ported and there's no automated test suite, so the exact pin keeps the compute substrate
deterministic; 0.30.6 is the benchmarked, working version and 0.31 adds nothing Vocello needs. 0.31 is **not
a free bump** — it changes the MLX quantization API (`Quantizable.toQuantized` gains a `QuantizationMode`;
quantize moved to a top-level fn), which touches the 4-bit (Speed) / 8-bit (Quality) model-load path, and
it's a core-MLX backend bump that can shift RTF/memory (what these benchmarks track). **When upgrading**
(quarterly review, or when a fix/model requires it): branch → bump all pin sites (project.yml mlx-swift +
vendored Package.swift mlx-swift & mlx-swift-lm, in lockstep) → `regenerate_project.sh` → both
`build_foundation_targets.sh` → `vocello bench` vs `baseline-2026-05-31-641a541.md` + listening pass → keep
only if RTF/quality/QC are unchanged; otherwise document the blocker and revert. Avoid the `mlx-swift-lm` 3.x
major line unless a feature specifically requires it.

## F — iPhone 1.7B 4-bit optimization program (2026-06-01)

> **Superseded for the *current* iOS state — see [`../docs/reference/ios-engine-optimization.md`](../docs/reference/ios-engine-optimization.md).**
> §F below is the original backend-feasibility study (its decode-loop + RAM-lever findings are still valid and
> shared by both platforms). But its **process model is out of date**: the engine no longer runs in an
> ExtensionKit extension — it runs **in-process in the app** (`7822a8a`; the extension was removed in
> `aed617c` because a non-UI extension's Jetsam cap can't be raised by the entitlement). On-device generation
> now works (iPhone 17 Pro, RTF ~1.6–1.9, ~3 GB streaming peak, 0 trims). The iOS-engine doc is the live iOS
> progress + roadmap record.

Goal: get Speed (4-bit) Qwen3-TTS running on iPhone 15 Pro (8 GB). Full plan + the 57-agent verified lever
inventory live in the session plan; this records the standing findings. (Historical note: this study assumed
the engine ran in the iOS ExtensionKit extension with a separate Jetsam budget — that approach was abandoned
in favor of the in-process engine; see the doc linked above.)

**Feasibility (isolated engine, Speed 4-bit):** Custom/Design ~2.8–3.3 GB (fits under the default streaming
limit per §F.1 — the entitlement is headroom insurance, not required); Clone/long ~4.7 GB (marginal — wants
the raised limit ≥~5.2 GB or a ~400 MB cut); Quality 8-bit ~5.7 GB+ (out of scope — iPhone is 4-bit-only).
Hard floor (4-bit weights + activations) ~2.2 GB. **The increased-memory entitlement is a self-serve
capability** (enable it on the App ID — not an Apple grant; already declared in both iOS entitlements files).
The actual #1 prerequisite is re-establishing on-device build/deploy/proof tooling + on-device validation.

**WS0b decode-loop GPU attribution** — `xctrace --instrument os_signpost`, custom/speed/long, **327 frames /
31.1 s** wall, native 8 GB Mac (paired Begin/End from the raw `os-signpost` table; the `os-signpost-interval`
table collapses because the engine reuses `OS_SIGNPOST_ID_EXCLUSIVE`):

| stage (Σ over 327 frames) | total ms | % gen | mean/frame | nature |
|---|---|---|---|---|
| **Step Eval Flush** (single per-frame `eval()`) | 19072 | 61% | 58.3 ms | **GPU compute** — talker + 15×CP + sampling, fused |
| **Code Predictor Loop** | 5233 | 17% | 16.0 ms | **Swift CPU** — builds the 15-pass graph each frame |
| **Talker Forward** | 1744 | 6% | 5.3 ms | **Swift CPU** — graph build |
| inter-frame gap (Code2Wav asyncEval + chunk plumbing) | ~4000 | ~13% | — | overlapped decode |
| Sample First/Predicted + Codec Embed + EOS | ~620 | 2% | — | mostly build |

**Findings (supersedes the old workstream D ordering):**
- **`compile()` the per-frame graph — TESTED & REJECTED (2026-06-01).** The ~21 ms/frame build overhead is
  dominated by constructing the **quantized** `Linear` projections (4-bit → `QuantizedLinear` after
  `quantize(model:)`; bits 4 / group 64 / affine). A throwaway validation spike compiled the full talker
  MLP *including* the quantized projections via `compile(inputs: [gate, up, down], shapeless: true)`. Result:
  it **builds and runs correctly** (audioQC **pass** — so compiling a quantized forward IS feasible on MLX
  0.30.6), but it **regressed warm RTF ~5%** in a clean same-session A/B (custom/speed/long: **eager 0.80 vs
  compiled 0.76**; decode 24.8 s → 27.2 s). Cause: declaring the quantized module params as `inputs:` makes
  `compile` marshal their state (packed weight + scales + biases) on every call, costing more than the Swift
  build overhead it removes — and that cost **scales with the compiled region**, so a bigger region (whole
  layer / the 15-pass CP loop) would regress *more*, not less. **Conclusion: the ~22% build overhead is not
  productively attackable via MLX 0.30.6 `compile` on this quantized stack; do not pursue the fixed-shape-KV
  + compile rewrite.** (Only untested variant — baking weights as trace constants with no `inputs:` — is
  discouraged by MLX docs for module state and risks correctness; not recommended.)
- **Step Eval Flush (GPU, 61%)** is the model's real compute — largely fixed for 1.7B 4-bit at this
  precision; no transparent lever (quantization-mode work is pinned out at MLX 0.30.6, see §E).
- RoPE fusion → `MLXFast.RoPE` (CP + Talker): only a small slice of the build, and the compile spike showed
  build-time is hard to reclaim cheaply here → expected marginal/uncertain; low priority.

**RAM-lever corrections (under the strict no-degradation bar):**
- **Sliding-window KV is NOT a transparent RAM lever.** `RotatingKVCache` (mlx-swift-lm `KVCache.swift:441`)
  grows in 256-token steps and only trims once it exceeds `maxSize`; a window large enough to be lossless
  (≥ the ~500–600-token real generation length) saves ~0 RAM, while a window small enough to cap RAM **drops
  oldest context** → not transparent → fails the strict bar on long content. Its real use is fixing shapes
  for the compile lever above.
- **Eager `talkerSourceWeights` release — TESTED, no-op (2026-06-01).** Reordered to free the source dict
  *before* the talker eval (pre-extracting the speaker subset). Clean same-session A/B on custom/speed/long:
  **no measurable load-peak reduction** (cold/warm physFoot + peakGPU within noise; RTF unchanged). Confirmed
  the prediction — with no speaker encoder, `talkerSourceWeights` ≈ the talker buffers already held by the
  model (MLX arrays are ref-shared), so releasing the dict frees ~nothing. Could help only the clone/base
  **speaker-encoder** path (holds the speaker subset across the eval); re-test there with a saved voice if
  clone/long RAM becomes the focus. **Reverted (not committed).**
- **Net (revised after the compile spike):** backend speed gains for 1.7B 4-bit on this stack are **limited**
  — GPU compute (61%) is fixed at this precision, and the build overhead (22%) is not compile-attackable
  (regresses). The primary iPhone RAM unlock is the **entitlement**; transparent backend RAM cuts are modest.
  The realistic path to acceptable **iPhone RTF** is therefore the entitlement + evaluating the smaller/faster
  **0.6B variant** for on-device use (CLAUDE.md notes it's verified but unlisted), **not** backend
  micro-optimization of the 1.7B decode loop. Worth confirming with one more os_signpost capture whether the
  ~13% inter-frame gap (Code2Wav/plumbing) hides any cheap win before closing speed work.

### F.1 — STREAMING vs NON-STREAMING peak RAM (2026-06-01) — the RAM premise was wrong

Chasing the iOS RAM target via the talker KV cache: a `RotatingKVCache` sliding window for the talker was
implemented + validated (parked on `feature/rotating-kv`). It is **correct** (audioQC pass with rotation
forced; full audio; RTF unchanged) but delivers **~0 RAM benefit** — windowing ~380 KV tokens on a 69 s
generation moved peak <5 MB. The investigation's "talker KV ≈ 2.7 GB / 30–50% of peak" was an **estimate
that the measurement refutes**: the talker KV is tens of MB, not GB.

**The real driver — and the headline correction to the whole RAM analysis:** the `vocello` bench / CLI
default is **non-streaming** (accumulates *all* generated codec tokens + decodes the full audio at the end),
but **iOS is streaming-first** (emits + releases chunks). Measured on the *same* 69–76 s custom/speed input:

| path | gpuAllocPeak | physFoot |
|---|---|---|
| non-streaming (bench default) | ~8.0 GB | ~7.6 GB |
| **streaming (what iOS uses)** | **~3.0 GB** | **~3.0 GB** |

And streaming peak is **flat with length** — short 2901 MB · medium 2860 MB · long-76 s 2992 MB. So the
non-streaming numbers that drove this entire optimization program (clone ~7–8 GB, "+3.4 GB short→long", the
"marginal/infeasible" feasibility verdict) **overstate the iOS-relevant peak by ~2.5×**. In the actual iOS
streaming path, **custom/Speed peaks at ~3 GB regardless of length** — comfortably viable on iPhone 15 Pro
(at/under even the default ~3.5–4 GB process limit; the entitlement is headroom/clone insurance, not a hard
blocker for custom/design). The +3.4 GB growth is non-streaming accumulation that iOS never incurs.

**Consequences:**
- **Re-baseline the iOS feasibility verdict on the STREAMING path** (the bench non-streaming peak is the wrong
  yardstick for iOS). Custom/Design Speed ≈ 3 GB flat. Clone streaming untested (no saved voice installed) —
  expect ~3.5–4 GB (speaker conditioning + ~3 GB floor); measure when a clone voice is available.
- **Talker-KV windowing is unnecessary for iOS** (KV isn't the driver; streaming already keeps peak flat).
  Originally parked on `feature/rotating-kv`; the "multi-minute single-shot" escape hatch was later closed too
  (see **§F.2** — the token cap forecloses it). Final disposition: shipped **env-only, off by default**.
- For any future bench that wants an iOS-representative peak, use `vocello generate --stream` (or a streaming
  bench mode), **not** the non-streaming full-result path.

### F.2 — Windowing revisited (default-on + toggle) → INERT at the token cap; shipped env-only (2026-06-01)

Revisited per a directive to enable the window on **both platforms, default-on, with a user disable toggle**.
Built the full feature — per-tier `W = 2048` default, a cross-process `NativeTalkerKVCacheGate`, a Settings
toggle on macOS + iOS, and the `initialize`-handshake relay — then two findings collapsed the rationale and it
was scoped back down:

1. **Generation is nondeterministic.** Two identical-config CLI runs of the same text differ (21.4 s vs
   22.6 s, different SHA) — the sampler is unseeded. So the plan's "byte-identical output" transparency test
   **cannot hold** regardless of cache. Transparency survives only *by construction*: `RotatingKVCache`
   returns bit-identical keys/values to `KVCacheSimple` until `offset` exceeds `maxSize`.

2. **The window is INERT at the current token cap.** `maxCacheSize = keep + W = keep + 2048`; tracing
   `updateInPlace` (`KVCache.swift:518`), the first *rotation* (overwrite of oldest generated KV) fires on
   **generated token 2049** (`idx == maxCacheSize → idx = keep`). But **`maxNewTokens = 2048`**
   (`Qwen3GenerationConfiguration()` default, `QwenVoiceBackendCore.swift:20`) — and the engine **hard-errors**
   at the cap, *discarding* the output (verified: a 535-word / 2894-char script → `NativeRuntimeError …
   "reached maxNewTokens before EOS. The output was discarded"`, exit 1). Generation therefore stops exactly
   one token *before* the first rotation. With `W = 2048 = maxNewTokens` the rotating cache **never rotates,
   never trims, never reorders** → bit-identical KV to `KVCacheSimple` on every realized generation, same peak.
   The "multi-minute single-shot" use case §F.1 left open **cannot occur** — the token cap forecloses it.

**Net:** `W ≥ maxNewTokens` ⇒ provably transparent but provably useless (no rotation; ~0 RAM benefit atop the
already-tiny talker KV per §F.1). `W < maxNewTokens` ⇒ *would* rotate, but those generations already error out
at the cap, and the talker-KV saving is still ~0. No win either way at the current config.

**Disposition (maintainer call):** dropped the default-on per-tier policy, the user-facing Settings toggles
(both platforms), and the IPC handshake relay. **Merged env-only plumbing** — the `QVOICE_TALKER_KV_WINDOW`
knob in `NativeMemoryPolicyResolver` + the vendored `RotatingKVCache` talker path — **off by default**. It is
dormant dev/insurance capability that activates only if the token ceiling is ever raised above the window
(e.g. `checkpointDefaultMaxNewTokens = 8192`). `feature/rotating-kv` deleted.

## Invariants / do-NOT (carried from the grounding)

- No hard `Memory.memoryLimit` (reverted in `b77c08e` — spurious OOM downgrades).
- No **output-side** silence gating/smoothing of dropouts (masks the root cause; risks clipping real pauses).
- Don't revert the decoder-drift fix to output-side overlap-add (`4fab110`).
- Don't pipeline the autoregressive 15-pass Code Predictor loop; don't quantize TTS KV; keep macOS
  `MLXTTSEngine.events` `.unbounded`.
- Don't "fix" the phantom 1.7B arch bugs (projection / speaker-dim / MRoPE are correct).

## iOS (now on-device-capable — see the iOS-engine doc)

iPhone is no longer compile-safe-only: on-device build/validation tooling is established, the entitlement is
enabled, and generation works on device (in-process). The `os_proc_available_memory()` gating + per-tier
policy are implemented (`NativeMemoryPolicyResolver` iPhonePro case + `IOSMemoryBudgetPolicy`); no hard
`memoryLimit` (reverted `b77c08e`). The remaining iOS levers (thermal-state monitoring + automatic 0.6B
fallback, the 0.6B variant evaluation, an 8 GB-device proof, the signed-IPA/TestFlight lane) + the full
progress record live in
[`../docs/reference/ios-engine-optimization.md`](../docs/reference/ios-engine-optimization.md). Entitlement
detail: [`../docs/reference/ios-increased-memory-entitlement-request.md`](../docs/reference/ios-increased-memory-entitlement-request.md).

### Live streaming playback — verified zero-cost (2026-06-06, `b961cc8`)

iOS live-preview playback (audio during generation) was checked for engine impact via an on-device A/B on
the same binary: live OFF (`QWENVOICE_STREAMING_PREVIEW_DATA=off` → `.skip` = pre-feature: no PCM, chunks
dropped, no consumer) vs ON (`.emit` = feature; the autorun harness keeps `AudioPlayerViewModel` alive so
the `AVAudioEngine` consumer is exercised too). iPhone 17 Pro, custom/speed, short+long × 3, interleaved.
**Result: no measurable cost** — RTF +0.5% overall (short −1.9% / long +0.2%, within run-to-run noise),
physFootprint peak identical (~2.7 GB, off-max 2731 vs on-max 2722 MB; inside the 2.4–3.3 GB band, far
under the 4.5 GB guard), **0 memory trims** across all 12 runs, audioQC all pass. Ledger rows in
[`HISTORY.md`](HISTORY.md). The `scripts/ios_device.sh` launch now forwards caller-set `QWENVOICE_*`/`QVOICE_*`
env, so this A/B is repeatable (`QWENVOICE_STREAMING_PREVIEW_DATA=off scripts/ios_device.sh bench …`).

## G — macOS UI smoothness under engine load (2026-06-09; XPC kept)

**The architecture question, settled.** The XPC engine service was introduced (`228d3cd`, 2026-04-18)
because the SwiftUI UI lagged under engine load on RAM-constrained Macs. Investigated whether the
in-process iOS model would be more elegant. Verdict: **keep XPC** —
- Per-chunk XPC wire cost is metadata-dominated (~<2 KB; PCM travels by file path), and the per-chunk
  UI path was already clean (off-MainActor producer, `.utility` drain, zero per-chunk `@Published`).
  IPC was never the lag.
- iOS proves smoothness comes from *memory discipline*, not process model — so the discipline was
  ported instead (below).
- XPC uniquely provides (1) proven crash isolation (the 2026-05-15 MLX C++ assertion killed the
  *service*; the app survived + reconnected) and (2) the retirement lever below, which in-process can
  never have. A dev-only in-process A/B mode was considered and declined.

**Shipped (all validated live on a native 8 GB Mac):**
1. **UI-responsiveness KPI** — `MainThreadStallWatchdog` (SharedSupport/Telemetry): 100 ms main-thread
   heartbeat during generations; `uiStallCount50/250`, `uiMaxStallMS`, `uiHeartbeats` in the app-layer
   row counters; `UIstall` summarizer column + trailing `uiMaxStall ms` ledger column. "The UI lags" is
   now a number. First sample (XPC, custom/speed, native floor tier): 3 stalls >50 ms, max 241–262 ms
   per ~5 s generation.
2. **Warm-admission discipline** (iOS port) — `MacWarmupAdmissionPolicy` defers *proactive* warms while
   the app-process kernel pressure level is soft/hardTrim on floor8GB/mid16GB (+30 s post-hardTrim
   hysteresis on floor). `QWENVOICE_MAC_WARM_GATE=off|records|enforce` (default `enforce` since 2026-06-09 — pressured
   validation done: simulated hardTrim produced both `memory pressure (hardTrim)` and
   `post-hardTrim cool-down` deferral events on the native floor tier). User generations never gated.
3. **Idle-unload churn fix** (found during validation; possibly the real historical lag source) — the
   warm coordinator cleared `completedContext` on every idle transition, so after each 120 s floor-tier
   idle-unload it immediately re-warmed the ~2.3 GB model: an endless unload→reload churn that defeated
   the memory policy. Idle-unloads now stick on floor8GBMac. First post-fix generation: **0 UI stalls**
   (vs 3/max-262 ms pre-fix; small sample, watch the ledger column).
4. **Service retirement-to-reclaim** — the XPC-only lever: model unload returns weights, but MLX heap
   fragmentation + Metal shader caches stay resident until process exit. `shutdownWhenIdle` IPC +
   `MacEngineServiceLifecycleCoordinator` (floor tier, idle + hardTrim-or-5-min-dwell + 30 s grace;
   `QWENVOICE_ENGINE_RETIRE_DWELL_SECONDS` dev override). Client marks the exit expected → no error UI,
   no auto-reconnect, lazy relaunch. Measured: service exited on schedule (RSS → 0), follow-up
   generation relaunched transparently, `warmState: cold`, TTFC 2814 ms vs ~1220 ms warm.

**Residual:** the post-retirement readiness note briefly shows "Preparing Custom Voice" (cosmetic; no connection is
actually made). Ledger rows: `pre-ui-kpi baseline` and `post smoothness ws sanity` (2026-06-09).

## H — Qwen3-specialization program (2026-06-09; branch `engine-risk`)

The exhaustive backend program: specialize the vendored tree for Qwen3-TTS, close the remaining
speed/RAM levers under the standing quality gates, and build an iPhone-15-Pro restriction simulation
for the maintainer's 17 Pro. Phases P0–P6; per-phase ledger rows labeled `P<n>-…`.

### P0 — Instruments compute attribution (the long-gated capture, finally run)

Capture: `xctrace record --template "Metal System Trace" --instrument os_signpost --launch -- vocello
bench --modes custom --variants speed --lengths long --warm 2` on the native 8 GB M2 (trace overhead
≈25%: RTF 0.64–0.70 under trace vs 0.85 clean — fractions are the deliverable, not absolutes).
Signpost interval table parsed clean (no WS0b collapse on Xcode 26 xctrace). Warm-gen attribution
(consistent across both warm gens, 270–279 frames each):

| Window (signpost) | % of generation wall | GPU busy inside the window |
|---|---|---|
| Step Eval Flush (the fused per-frame eval) | 66–67% | **41–50%** |
| Code Predictor Loop (graph build, 15 passes) | 13–15% | **3–5% (idle)** |
| └ Code Predictor Step (per-pass build, ~1.0 ms × 15 × frame) | 12–13% | — |
| Talker Forward (graph build) | 4–5% | **2–5% (idle)** |
| Sampling (first + predicted codebooks) | ~1.6% | — |
| **Whole generation** | 100% | **31–37%** |

**The headline finding: the workload is kernel-launch/CPU-bound, not GPU-bound.** Even inside the
fused eval the GPU idles half the time (batch-1 tiny-matmul launch gaps in the MLX Metal scheduler);
during the ~23%-of-wall graph-build phases it is essentially idle, so every ms of Swift build cost
removed converts ≈1:1 to wall time. Decision table outcomes:

- GPU busy 31–37% « 80% → **P2 (graph-build/allocator elimination) is first-order. GO.**
- CP RoPE fusion (§D) → **GO with revised rationale**: the win is ~6 graph-build ops → 1 fused op per
  CP pass (×15×~300 frames of CPU build), not GPU time. §D's "2–3% RTF (GPU)" framing is obsolete.
- Sampling-stall lever → not opened: Sample First Codebook ≈0.2% wall; the eval-window idle is
  launch-shaped, not a token-read stall.
- Audio Decoder row: N/A in this capture — `bench` runs the quality-first batch path (no streaming
  decoder signposts). The decode shows up as the ~23% GPU-busy remainder outside stepEval.
- **Structural ceiling (recorded, not actionable at 0.30.6):** the ~50% launch-gap idle inside
  stepEval is only addressable by graph capture/compile — measured −5% at 0.30.6 (§F WS0b). Re-test
  under the gated 0.31.x bump (§E) whenever that happens.
- Clone/long capture: skipped as not decision-relevant (identical per-frame loop; clone differs in
  prefill, and P4's KV decision is a physFoot A/B, not a trace question).

### P1 — Vendored tree specialized to Qwen3-TTS (`a2b5f15`)

Deleted ~36K of ~49K LOC: STT/STS/VAD/LID/G2P/UI/Tools targets+products+executables, eight non-Mimi
codec families, `Mimi/Mimi.swift`+`AudioCodecModel.swift`, dead Core files (AudioPlayer,
AudioSessionManager, PCMStreamConverter, UnigramTokenizer), unused swift-transformers/MLXLLM deps.
Compiler-arbitrated keeps: `Seanet.swift` (SeanetEncoder is the speaker-encoder front end),
`AudioUtils.swift`+`DSP.swift` (clone path uses `loadAudioArray`/`computeMelSpectrogram`). Both
foundation builds green; clone path validated post-prune (0.55 warm vs 0.56 baseline, QC pass).
Honesty note: the row labeled `P1 vendored Qwen3 specialization` benched a stale pre-P1 binary
(`build.sh build` does not rebuild the CLI) — it serves as the fresh same-day baseline instead;
P1's real gate was the link step plus the later clone validation.

### P2 — Sampler scratch + CP step constants (`0c3a313`; ~+1% wall, allocator relief)

CP sampler scratch (the 14 CP samples/frame re-allocated arange/zeros/-inf — ~17K allocs per
generation), dtype-keyed -inf row caches for topK/topP, zeros/eos caches, CP pass-0 mask memo.
Same-conditions A/B (P1-only control vs P2): warm RTF 0.80 → 0.81, stepEval/frame 67.9 → 65.8 ms,
codePred/frame 16.3 → 16.0 ms. Within noise on wall but consistently positive; main value is
allocator pressure (iPhone-relevant) + build-phase reduction. **Thermal lesson:** warm cells can
read *slower than cold* on a heat-soaked 8 GB M2 — accept/reject benching needs cool-downs and
same-day controls (the 2026-05-31 "0.85" is a fresh-machine number).

### P3 — Fused CP RoPE (`f3cd2aa`; **+26% — the 8 GB Mac crosses realtime**)

`MLXFast.RoPE` (offset-based) replaces the manual rotate-half chain in the code predictor:
~600 fewer kernel launches per frame on the launch-bound decode. **custom/speed/long warm RTF
0.81 → 1.02**; stepEval/frame 65.8 → ~50 ms; codePred build 16.0 → 11.3 ms; clone 0.55 → 0.58.
Numerics: fused kernel rotates in fp32 vs the old bf16-quantized tables — probe measured exactly
1–2 bf16 ULPs on q/k (a precision improvement, not identical token streams), so the full
perceptual gate ran: audioQC pass + agy listening on fresh custom/design/clone takes, all clean.
The talker keeps its manual path — 3D interleaved MRoPE `[24,20,20]` is not expressible by
`MLXFast.RoPE` (a possible future lever only if decode-time positions prove degenerate-equal).
§D is hereby **closed: implemented, far above its estimated ceiling** (the 2–3% estimate assumed a
GPU-bound workload; the launch-bound reality made it 10×).

### P4 — RAM levers (`6f9f04b`; KV-quant NOT shipped)

- **8-bit talker KV** (via `attentionWithCacheUpdate`, behavior-identical for plain caches):
  clone/long saves 271 MB physFoot but costs **−8.6% RTF** (dequant kernels on a launch-bound
  decode). No tier has a RAM emergency that justifies it (iPhone clone ~3.3 GB vs 5–6 GB entitled,
  0 trims) → **env-only dev knob** `QVOICE_TALKER_KV_QUANT=8|4`, default off, never combined with
  the rotating-window cache.
- **Load-peak transient**: closed without chunked binding — on-device evidence (0 trims, flat
  ~2.4–3.3 GB streaming peaks, §F) shows the load transient is not a binding constraint on any
  shipping tier.
- **GPU cacheLimit re-sweep**: not re-run this program; current per-tier values stand (set during
  the iOS program; no P0–P4 row shows cache-pressure misfit). Open as a low-priority follow-up.

### P5 — iPhone 15 Pro simulation: validated (memory dimension PASS)

On-device under `--sim-device iphone15pro` (5,000 MB clamp; rows stamped `simulatedDevice`):
custom/long **RTF 1.89** / physFoot 2,723 MB (margin 2,277 MB ≥ the 500 MB bar); clone **RTF 1.62**
/ 3,332 MB (margin 1,668 MB ≥ 300 MB); **0 trims, QC pass, clone gate ON** (proven by execution).
On-device RTF sits at the top of the pre-program 1.6–1.9 band (P3's launch-bound win is smaller on
the A19 than the M2 — its launch overhead is lower, consistent with the P0 theory). Ops note: the
first launch of a freshly installed build can exceed the default 300 s autorun sentinel timeout
(cold Metal-shader compile) — use `QVOICE_IOS_BENCH_TIMEOUT=600` after installing a new binary.
The analytic 15 Pro compute projection (0.60× ⇒ RTF ≈ 1.0–1.1 post-§H) and the real-device gate
remain as documented in ios-engine-optimization.md §9.

### P6 — Final full-matrix validation (macOS, native floor tier)

`P6 final full-matrix (P0-P4)` ledger row + the 12-cell speed matrix: **QC pass on every cell**
(including design/long, historically warn/fail-prone). Warm medians — custom 0.99/1.11/**1.07**
(short/medium/long), design 0.99/1.11/0.99, clone 0.24/0.47/**0.63** (clone short is prefill-
dominated by design). Headline vs the same-day pre-program baseline: **custom/warm/medium
0.83 → 1.11 (+34%)**; custom/warm/long 0.80 → 1.07 (+34%); clone/long 0.55 → 0.63 (+15%);
physFoot unchanged (4493 vs 4486). Listening: agy 3-mode adjudication clean (P3 gate); nothing
flagged in the final matrix.

## Next step (if resumed)

§H is the active program (branch `engine-risk`): P2 hot-path build/allocator work is first-order per
the P0 capture; then gated P3 (RoPE fusion, token-identity gate), P4 RAM levers (KV-quant A/B with
the clone listening gate), P5 iPhone-15-Pro sim harness, P6 wrap-up. §D is superseded by the §H P0
decision table. For UI smoothness (G), watch the `uiMaxStall ms` ledger column across releases.
