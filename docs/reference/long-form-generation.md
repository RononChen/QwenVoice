# Long-form generation

This reference distinguishes the current macOS product path from the staged schema-v4 planning and
bounded-assembly foundations. Source and `config/runtime-refactor-contract.json` remain higher
authority. iOS long-form UI and execution are out of scope.

## Shipping path

macOS currently routes long text through `LongTextGenerationRouter`, `LongFormBatchSegmenter`, and
`BatchGenerationRunner`. It produces independent non-streaming segment results and a manifest-v3
document. That path remains the only shipping long-form authority.

Do not claim sequential streaming, schema-v4 resume identity, bounded joined-WAV publication, or
one-item History semantics from the presence of the new foundation types. Existing schema-v3
documents remain readable historical/product evidence and must not be upgraded by fabricating
missing plan identity.

## Schema-v4 planning foundation

`SpokenTextPlanning.swift` and `LongFormPlanning.swift` provide model-free contracts for the future
cutover:

- Original text remains private; evidence contains only safe digests, versions, ranges, counts, and
  typed transformation risks.
- Original/spoken ranges use UTF-8 byte offsets bound to the original-text digest.
- Boundary precedence is paragraph, sentence (including CJK punctuation), semicolon/colon, safe
  clause, whitespace, then grapheme fallback.
- Decimal, version, URL, abbreviation, and other protected ranges cannot be split silently.
- Every segment records a stable ID, revision lineage, boundary type, conservative token estimate,
  runtime token limit, intended pause, and deterministic sub-seed.
- `LongFormManifestV4` validates that plan evidence. `LongFormManifestDocument` reads schema v3 only
  as a limited legacy summary.

The planner is not called by the shipping batch coordinator yet.

## Bounded assembler foundation

`BoundedLongFormAssembler` accepts already persisted PCM16 segment WAVs and produces one atomic
24 kHz mono PCM16 WAV. It is bounded by `LongFormAssemblyConfiguration.blockFrames` rather than
audio duration:

1. Analyze each segment in a fixed-block pass for format, non-silent extent, RMS, and verified
   non-speech edges.
2. Read it again in fixed blocks, apply bounded gain, edge trim, and fades only over verified
   non-speech, then write incrementally.
3. Insert the boundary's declared pause without allocating the whole silence span.
4. Finish atomically, reopen the result, and verify its sample rate and exact frame count.

`LongFormAssemblyEvidence` contains the output digest/readability, output frame count, bounded
working-set high-water mark, maximum segment-boundary jump, and a segment-to-output frame map with
trim, gain, fade, pause, and revision lineage. It deliberately contains no local path, source text,
spoken text, transcript, or audio bytes.

The assembler is deterministic foundation code with synthetic tests for block bounds, mapping,
silence rejection, gain/trim/fade behavior, atomic readability, and cancellation. No shipping
coordinator invokes it yet.

## Remaining cutover work

Promotion requires all of the following in one product-owned path:

- One sequential streaming product session per planned segment.
- Model and product terminal/finalization barriers for every segment.
- Identity-matching resume and replacement lineage without automatic retry after cancellation.
- Incremental Fast QC per segment before assembly.
- Atomic joined output, joined signal/readability/continuity validation, and one accepted History
  item while failed/replaced attempts remain local project evidence.
- Three-pass ASR per applicable accepted segment rather than one audiobook-length Speech request.
- Clean 1-, 10-, and 100-segment macOS evidence proving steady-state memory does not scale with
  total audio duration.

Until those gates pass, the runtime contract must continue to report
`manifest-v3-nonstreaming` as the shipping long-form authority.
