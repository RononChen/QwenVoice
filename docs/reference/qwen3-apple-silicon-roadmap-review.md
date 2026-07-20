# Qwen3-TTS, Apple Silicon, and Vocello roadmap review

> Cross-check of Vocello’s convergence roadmap against official Qwen3-TTS docs and
> Apple Metal/MLX guidance. Protects the low-RAM + streaming-preview “secret sauce”
> that makes the product feel fast on 8 GB Mac and physical iPhone.
>
> Reviewed 2026-07-19. Code and machine-readable contracts win over this prose.

## Secret sauce (do not trade for roadmap convenience)

| Ingredient | Why it feels fast | Where it lives |
| --- | --- | --- |
| Constrained first/later codec frames (7 / 7\|14) | Early audible PCM without waiting for full decode | Generation semantics / classified session |
| Separate preview router vs lossless channel | UI hears progress without dropping final audio under backpressure | Frontend preview path + `GenerationOutputAdapter` |
| Request-local sampling + memory | No global RNG/cache thrash between takes | Sampling v2 / request-local memory config |
| Tiered `Memory.cacheLimit` + trim/unload | Stays inside 8 GB Mac / iPhone Pro budget | `NativeMemoryPolicyResolver` |
| macOS XPC engine isolation | UI process stays light while GPU work runs in service | `QwenVoiceEngineService` |
| 4-bit Speed on iOS / floor 8 GB Mac | Weight footprint fits unified memory | Production catalog + preferred variant |

Telemetry v9, long-form v4, and history v3 must not regress first-preview latency, peak
footprint, or trim/unload safety. Fail closed on `hardTrim` / `fullUnload` for the secret-sauce
characterization cells in `config/characterization-fixtures.json`.

## Official Qwen3-TTS vs Vocello

### Alignments

Three modes (Custom / Design / Clone), 12 Hz tokenizer + 24 kHz PCM, product streaming on all
released models, instruction control on 1.7B Custom/Design only, and `x_vector_only` clone with
consent match the shipping contract. Vocello’s early-frame chunks + preview delivery are the
product analogue of Qwen’s dual-track low first-packet design—not a port of the Python CUDA demos.

### Semantic traps

1. **“Streaming” means different things.** Official docs still process complete text when
   `non_streaming_mode=False`; true character-by-character input is a future Qwen update.
   Published ~97 ms first-packet figures are NVIDIA A100 + FlashAttention-2, not Apple Silicon.
   Vocello’s win is on-device first-preview + lossless finalization, not CUDA parity.
2. **0.6B for latency/memory** is ruled out (no VoiceDesign; fragments the mode matrix). Keep that
   decision visible so Phase 5–7 work does not rediscover 0.6B as an easy win.
3. **Fine-tune / vLLM / DashScope** are out of product scope.
4. When Qwen ships true incremental text input, treat it as a new Phase 7/11 spike—not a silent
   change to complete-text streaming.

## Apple Metal + MLX vs Vocello

Unified-memory MLX, quantization for on-device size, request-local KV/cache policy, and reclaim via
cache limits + soft/hard trim / `fullUnload` align with Apple and MLX guidance. Keep:

- **No hard production `Memory.memoryLimit`** (soft relief is the product model).
- **MLX-only** during convergence (no Core ML / MPS Graph / custom Metal second path).
- **Pin lockstep** for `mlx-swift` + `mlx-swift-lm` until overall promotion.
- Tighter cache-limit A/B only after Phase 5 seed proof, evidence-gated.
- Quantized KV and `compile()` remain diagnostic unless new evidence overturns prior −RTF findings.

For “lightning fast” claims, prefer `playbackScheduled` / first-chunk materialization until a true
first-render player callback exists. Nested v9 may still mark some preview domains unavailable.

## Glossary

| Term | Meaning |
| --- | --- |
| Qwen dual-track streaming | Official hybrid path aimed at low first-packet latency on CUDA-class demos |
| Vocello product streaming / preview | Early codec-frame chunks + frontend preview router for perceived speed |
| Lossless final channel | Actor-owned classified session → `GenerationOutputAdapter` → atomic WAV + Fast QC |

## Pre-research baselines (2026-07-19)

Both platforms ran exploratory full 29-take UI matrices on a dirty worktree
(`passedWithWarnings`, soft trim). They are baselines for research, not clean promotion controls.

| Platform | Record | Notes |
| --- | --- | --- |
| macOS (Mac mini M2 8 GB) | `benchmarks/runs/ui-generation/macos-xcui-benchmark-20260719-215547-11f8f4cf.json` | Smoke + gate also passed after dSYM refresh |
| iPhone 17 Pro | `benchmarks/runs/ui-generation/ios-xcui-benchmark-20260719-224743-1e69da39.json` | Smoke passed; `ios_device.sh gate` later PASS (`ios-gate-20260719-191932`); headless Phase 5 seed pairs PASS |

## Recommendations (ordered)

1. Keep Phase 5 live fixed-seed pairs before any v9 authority flip.
2. ~~Secret-sauce latency/memory cells~~ captured 2026-07-19 via focused UI short runs
   (`secret-sauce-20260719`, `secret-sauce-ios-20260719`); evaluate with
   `scripts/check_secret_sauce_cells.py` before treating later full matrices as promotion evidence.
3. Do not target A100 97 ms; use Vocello clean-control regression bounds.
4. Defer Metal 4 / Neural Accelerator work until pins and hardware matrix expand post-promotion.
5. Split unrelated dirty-tree work (Cursor migration, Codex storage, convergence scaffolding) into
   separate PRs when publishing.

Related: [`docs/decisions/runtime-streaming-quality-convergence.md`](../decisions/runtime-streaming-quality-convergence.md),
[`docs/development-progress.md`](../development-progress.md),
[`config/characterization-fixtures.json`](../../config/characterization-fixtures.json),
[`docs/reference/mlx-guide.md`](mlx-guide.md),
[`docs/reference/ios-engine-optimization.md`](ios-engine-optimization.md).
