# Optimization progress

Durable record of backend/MLX + output-quality optimization work — what was investigated, decided,
shipped, and deferred. The blow-by-blow lives in git history + `HISTORY.md`; this file is the **standing
status** so a future session (or maintainer) can resume without re-deriving it. Anchored to the reference
baseline. Point-in-time as of **2026-05-31**.

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
| D | CodePredictor RoPE fusion | ⏸ deferred — gated, not recommended | n/a |
| E | MLXSwift / mlx-swift-lm version bump (0.31.x) | ⏸ deferred — stay pinned, gated | this doc + CLAUDE.md "SPM dependencies" |
| F | iPhone 1.7B-4bit program — feasibility + WS0b profiling + compile spike | 🔬 profiled; compile lever tested & rejected (2026-06-01) — see §F | this doc + session plan |

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

## D — CodePredictor RoPE fusion (deferred; **not recommended to start**)

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

Goal: get Speed (4-bit) Qwen3-TTS running on iPhone 15 Pro (8 GB). Full plan + the 57-agent verified lever
inventory live in the session plan; this records the standing findings. Engine runs in the iOS ExtensionKit
extension (separate Jetsam budget).

**Feasibility (isolated engine, Speed 4-bit):** Custom/Design ~2.8–3.3 GB (feasible behind the entitlement);
Clone/long ~4.7 GB (marginal — needs entitlement ≥~5.2 GB or ~400 MB cut); Quality 8-bit ~5.7 GB+ (out of
scope — iPhone is 4-bit-only). Hard floor (4-bit weights + activations) ~2.2 GB. **The Apple
increased-memory entitlement (pending) is the #1 blocking prerequisite** — already declared in the iOS
entitlements files.

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
- **Eager `talkerSourceWeights` release:** for the 4-bit model the source dict is the *quantized* safetensors
  (~1 GB, not 6.8 GB fp32) and MLX arrays are ref-shared with the model params, so the real cold-load saving
  is uncertain → needs a load-transient peak snapshot to measure before it's worth landing.
- **Net (revised after the compile spike):** backend speed gains for 1.7B 4-bit on this stack are **limited**
  — GPU compute (61%) is fixed at this precision, and the build overhead (22%) is not compile-attackable
  (regresses). The primary iPhone RAM unlock is the **entitlement**; transparent backend RAM cuts are modest.
  The realistic path to acceptable **iPhone RTF** is therefore the entitlement + evaluating the smaller/faster
  **0.6B variant** for on-device use (CLAUDE.md notes it's verified but unlisted), **not** backend
  micro-optimization of the 1.7B decode loop. Worth confirming with one more os_signpost capture whether the
  ~13% inter-frame gap (Code2Wav/plumbing) hides any cheap win before closing speed work.

## Invariants / do-NOT (carried from the grounding)

- No hard `Memory.memoryLimit` (reverted in `b77c08e` — spurious OOM downgrades).
- No **output-side** silence gating/smoothing of dropouts (masks the root cause; risks clipping real pauses).
- Don't revert the decoder-drift fix to output-side overlap-add (`4fab110`).
- Don't pipeline the autoregressive 15-pass Code Predictor loop; don't quantize TTS KV; keep macOS
  `MLXTTSEngine.events` `.unbounded`.
- Don't "fix" the phantom 1.7B arch bugs (projection / speaker-dim / MRoPE are correct).

## iOS-deferred (real, but iPhone is compile-safe only)

Thermal-state monitoring + automatic 0.6B fallback, iPhone jetsam / `memoryLimit` tuning +
`os_proc_available_memory()` gating, on-device RTF/peak-RAM proof — all pending Apple's increased-memory
entitlement (see [`../docs/reference/ios-increased-memory-entitlement-request.md`](../docs/reference/ios-increased-memory-entitlement-request.md)).
Map to `NativeMemoryPolicyResolver` (iPhonePro case).

## Next step (if resumed)

The only open lever is **D**, and only after the Instruments os_signpost capture above justifies it. The
quality tripwire (C) is in place; everything else the report proposed is already implemented or iOS-deferred.
