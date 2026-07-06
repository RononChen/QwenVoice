# Language bench (Phases 2–3)

Headless matrix for the Qwen3 language path:

1. **Phase 2 — hint contract:** UI hint → resolved `notes.languageHint` in engine telemetry.
2. **Phase 3 — output verification:** in-app Speech transcription + language score + WER vs script.

## Config

| File | Role |
| --- | --- |
| `config/language-bench-corpus.json` | Native script snippets per language |
| `config/language-bench-matrix.json` | Cells: mode, `uiHint`, `scriptLang`, `expectedHint` |

Cells tagged `"quick": true` form the **quick** subset (English + French + negative control, 7 cells).
**full** runs all 19 cells (6 languages × custom pinned/auto + design auto + negative).

## iOS (on-device)

Requires Custom Voice **Speed** installed on the paired iPhone.

**Speech Recognition:** Phase 3 transcribes each output WAV in the app process. Grant
**Settings → Privacy → Speech Recognition → Vocello** once before the first output-gated run.

```sh
scripts/ios_device.sh lang-bench --subset quick --label "lang-smoke"
scripts/ios_device.sh lang-bench --subset full --label "lang-full"
```

Skip output verification (hint gate only):

```sh
QVOICE_LANG_BENCH_SKIP_OUTPUT=1 scripts/ios_device.sh lang-bench --subset quick
```

Per cell the driver sets:

- `QVOICE_MAC_BENCH_RUN_ID` — shared run id (`ios-lang-bench-…`)
- `QVOICE_MAC_BENCH_CELL` — matrix cell id
- `QVOICE_IOS_AUTORUN_LANG` — UI hint (`english`, `french`, …; omitted for Auto)
- `QVOICE_IOS_AUTORUN` — `mode:speed:<script>`
- `QVOICE_IOS_VERIFY_OUTPUT=1` — Speech round-trip (default unless skipped)

Gates:

- `scripts/check_language_hints.py` — `engine/generations.jsonl`
- `scripts/check_language_output.py` — `autorun-done.json` → `outputVerification`

### Validated (2026-07-06)

Quick subset **7/7 PASS** on device (`ios-lang-bench-20260706-110143`) — hint gate only
(run predates Phase 3 output verification in autorun).

## macOS (in-process CLI)

Requires test models (`scripts/macos_test.sh models ensure`).

```sh
scripts/macos_test.sh lang-bench --subset quick
```

Uses `QWENVOICE_DEBUG=1`, `vocello generate --language …`, and the hint gate against
`~/Library/Application Support/QwenVoice-Debug/diagnostics/`. CLI Speech is **not** used
(TCC); output verification is iOS autorun only.

## Offline gate tests

```sh
python3 scripts/test_check_language_hints.py
```

## Related

- Phase 1 unit tests: `scripts/macos_test.sh core-test`
- Language semantics: `docs/reference/qwen3-tts-guide.md` §7
- iOS device lanes: `docs/reference/ios-device-testing.md`
