# Computer Use failure analysis and suite block

> **Current status — 2026-07-10:** macOS Computer Use `quick`, `full`, `benchmark`, and
> destructive acceptance, plus iOS `quick`, `full`, and `benchmark`, are blocked. The installed
> helper generation described below is diagnostic-only for Vocello until the resumption criteria
> pass.

Upstream tracking:

- [openai/codex#32293](https://github.com/openai/codex/issues/32293) — controlled exact-path
  reproduction, routing identity, and duplicate-app isolation.
- [Bounds-trap differential comment](https://github.com/openai/codex/issues/32293#issuecomment-4940886542)
  — normalized stacks, register state, disassembly, and accessibility-log correlation.
- [Warm History differential](https://github.com/openai/codex/issues/32293#issuecomment-4941236462)
  — one stable exact-path History observation with unchanged helper identity and no crash delta.

This document is the repository source of truth for the active Computer Use block. The issue is in
OpenAI's signed helper, not Vocello's generation backend. Deterministic build, unit, integration,
telemetry, and project-input work may continue while frontend attestations remain blocked. The
block never prevents committing, pushing, opening a pull request, or ordinarily merging that work;
it prevents explicit frontend acceptance and the matching platform's release.

## Confirmed failure

Four controlled captures produced the same native failure:

| Field | Value |
| --- | --- |
| ChatGPT Desktop | `26.707.41301 (5103)` |
| Computer Use plugin | `1.0.1000366` |
| Helper | `26.708.1000366 (1000366)` |
| Bundle / team | `com.openai.sky.CUAService` / `2DC432GLL2` |
| Executable UUID | `61C0B615-7F27-3A07-8D97-77ABC7139236` |
| Executable SHA-256 | `b47f564a5dee10fc8f21f6c8b2aee934b30ad04feee33746053253b3661df4e0` |
| Exception | `EXC_BREAKPOINT / SIGTRAP` |
| Fault queue | `com.apple.root.user-initiated-qos.cooperative` |

Two failures used the former plugin-cache route and two used ChatGPT Desktop's managed runtime at
`~/.codex/computer-use`. All four have the same helper UUID, instruction, normalized 20-frame
offset sequence, register mismatch, and accessibility error pattern. The first exact-path target
observation also failed after the other physical Vocello bundles were temporarily isolated.
Therefore helper routing and duplicate physical app installations are not required causes, though
fallback routing and duplicate or wrong-path running app processes remain invalid evidence.

The faulting helper code performs a bounds check before a collection-removal-style operation:

```asm
ldr  x8, [x19, #0x10]   ; current collection count
cmp  x21, x8             ; requested index
b.hs trap
...
trap:
brk  #0x1
```

Every report records `x21 = 5` and `x8 = 4`. The immediate failure is therefore certain: the
helper reaches its trap while attempting an operation at index 5 on a four-element collection.
The private collection and source line cannot be named without OpenAI's matching symbols.

In every reproduction, the crash report's faulting thread ID is the same unified-log thread that
emits the final
`TransformedUIElement … AccessibilitySupport.UIElementError Code=0` event. The latest controlled
run completed its accessibility settle wait, returned a new tree, began screenshot enumeration on
another thread, logged the transformation error on the faulting accessibility worker, and trapped.
Finder accessibility and screenshot capture had succeeded immediately beforehand. This places the
failure in accessibility-tree transformation rather than ordinary permission enrollment,
screenshot acquisition, memory pressure, or model execution.

## Likely Vocello trigger

Both production and debug preferences restored Settings during the controlled cold captures.
At reproduction time, Settings contained a grouped SwiftUI `Form`, multiple sections, toggles, a
segmented picker, complex `LabeledContent` rows, dynamically refreshed model rows, nested
accessibility containment groups, and a model refresh followed by a delayed first-responder reset.
The first candidate patch removes only that timed focus mutation. A fresh-task, warm History
observation passed on 2026-07-10, but it did not traverse Settings; the Settings A/B therefore
remains pending in a separate fresh helper session.

That topology overlaps [openai/codex#28933](https://github.com/openai/codex/issues/28933), whose
small SwiftUI `Form` reproduction also causes a Computer Use `SIGTRAP`. The strongest current
hypothesis is a stale child/work-list index after an accessibility-tree mutation or unsupported
tree transformation. This is correlation, not a proven source-level cause. No Vocello
accessibility workaround has yet passed an A/B capture.

## Capability and routing state are separate

A live `SkyComputerUseService` process does not prove that a Codex task can use Computer Use.
Readiness has four independent layers:

1. The bundled plugin is installed.
2. The plugin is enabled and its server and skill are available to the current, newly started task.
   For plugin `1.0.1000366`, `bundledContentVariant=node-repl`: the enabled Node REPL entry is the
   active server, while the disabled manifest-shaped Computer Use entry is an expected inert mirror.
   An enabled mirror is a conflicting second route.
3. Exactly one supported Desktop-managed helper is running, with the expected signed identity and
   no fallback, duplicate, unknown-path, stale-client, or zombie condition.
4. The helper can return both accessibility text and a screenshot for the selected target without
   producing a new crash report.

After the last controlled crash and marketplace refresh, the CLI reported Computer Use
`1.0.1000366` as available but not installed or enabled, while one Desktop-managed service process
continued to run. That snapshot proves why doctors and operators must test all four layers rather
than treating process presence as plugin readiness. User-scoped state may change, so every new
session must inspect it live.

The plugin was reinstalled and enabled on 2026-07-10 after saving a timestamped user-config backup.
The already-running task did not gain the plugin wiring retroactively and correctly refused to
launch Vocello. After Desktop and Codex restarted, a fresh task exposed the skill, wrapper, and
Node REPL route. The live audit then found one canonical helper with matching signed source/runtime
identity and no fallback, duplicate, unknown path, stale client, or zombie. This confirms the
installation boundary and routing repair; it is not evidence that helper `1000366` is repaired.

The Desktop-managed `~/.codex/computer-use` copy is expected for the audited Desktop build. Do not
delete it, substitute another helper, install a second Computer Use transport, reset all privacy
permissions, edit approval databases, alter code signatures, or repeatedly relaunch after a crash.

## Diagnostic-only observation protocol

Helper build `1000366` and UUID `61C0…9236` must not run normal Vocello suites. One bounded
observation is permitted only when explicitly requested to isolate this defect:

1. Confirm the plugin is installed and enabled, start a fresh Codex task, and confirm its Computer
   Use server and skill are callable.
2. Record the helper version, UUID, executable hash, process count/path, and current crash-report
   baseline. Require one supported Desktop-managed service.
3. Capture Finder once and require accessibility text plus a screenshot.
4. Prepare the non-attestable History-pinned launch:

   ```sh
   scripts/macos_agent_ui.sh warm-diagnostic --phase prepare \
     --initial-screen history --acknowledge-known-bad-helper
   ```

   The command refuses a pre-existing Vocello process, launches only the exact
   `build/Vocello.app`, and requires its PID to remain stable for three seconds. Confirm one visible
   window through Computer Use before continuing.
5. Observe the exact app path **once**.
6. Before Computer Use removes its temporary screenshot, record non-sensitive observation metadata:

   ```sh
   scripts/macos_agent_ui.sh warm-diagnostic --phase record-observation \
     --app-path "$PWD/build/Vocello.app" \
     --accessibility-length <returned-text-length> \
     --window-count 1 \
     --screenshot-url '<returned-file-url>'
   ```

   The harness verifies the exact app path and live screenshot file, then stores only AX length,
   window count, screenshot byte count/hash, and timestamp. It never stores the AX text or temporary
   screenshot path.
7. Verify the unchanged app/helper identities and crash delta exactly once:

   ```sh
   scripts/macos_agent_ui.sh warm-diagnostic --phase verify
   ```

8. Stop immediately after either the response or a native-pipe closure. Do not retry, select the
   app by display name or bundle identifier, relaunch Vocello, interact with controls, or continue
   into a suite. Target Finder before cleanup, then run:

   ```sh
   scripts/macos_agent_ui.sh warm-diagnostic --phase abort
   ```

The diagnostic state is stored separately under ignored `build/macos/agent-ui/` state. It cannot
be validated, attested, or consumed by release readiness. Cleanup preserves separate verification
and cleanup verdicts and performs a final helper-identity/crash-delta check; it cannot overwrite a
failed diagnostic with a generic aborted status.

### 2026-07-10 bounded diagnostic result

The permitted History-pinned diagnostic passed once in a fresh task:

- `sky.list_apps()` and Finder accessibility/screenshot capture succeeded.
- The helper remained the sole canonical process at PID `63045`; its UUID and SHA-256 did not
  change, and no plugin-cache fallback appeared.
- `warm-diagnostic --phase prepare` launched only the exact `build/Vocello.app` at PID `81259`.
- The single exact-path observation returned the History accessibility tree (1,815 characters) and
  a screenshot.
- `warm-diagnostic --phase verify` consumed the one-observation budget with no new `.ips` report.
- Capture returned to Finder before abort; cleanup left zero Vocello processes and the same helper
  PID running.

This proves only that a prelaunched, settled History surface can be transformed by this helper. It
does not distinguish cold-launch churn from the Settings hierarchy, validate the focus-reset
candidate, or clear the known-bad-helper block. The next UI diagnostic, if explicitly authorized,
must use a fresh Desktop/helper session and target exactly one Settings variant once.

The first History run predated the metadata-recording phase: its AX length and screenshot URL are
in the task output, but Computer Use deleted the temporary screenshot when the app closed, so no
durable screenshot hash exists for that run. Future diagnostics must record metadata before verify
and cleanup; the History result remains differential evidence, not an attestation.

For iOS, the equivalent diagnostic is at most one passive iPhone Mirroring observation after the
same routing and crash baseline. Do not click, navigate, generate, benchmark, or attest. The shared
helper has not earned normal-suite trust merely because Finder or the mirroring window opens.

Diagnostic observations never perform generation. Once normal suites are unblocked, Settings must
visibly show Custom, Design, and Clone Speed as installed/ready, Generate as enabled, and the
benchmark clone voice in Saved Voices before the first generation. If readiness is incomplete,
stop the run and use the explicit model repair/bootstrap command outside the suite; then start a
fresh run and verify the visible states again. A filesystem inventory or prior successful take is
not a substitute. The seeded `telemetry-overhead` lane also performs real generation: it now
requires a current full Computer Use attestation proving `model-readiness`, uses a read-only model
integrity check, and never invokes `models ensure` automatically.

## Remediation and resumption

The preferred fix is a newer signed OpenAI helper that revalidates or re-resolves collection
indices after tree invalidation, or restarts transformation from a fresh snapshot instead of
trapping. The upstream issue requests a matching dSYM, a symbolicated stack, or a diagnostic build
that identifies the failing accessibility path/tree revision.

A Vocello-side diagnostic bisect now has a non-persisting debug launch-screen selector for testing
History, Custom, and Settings independently. History passed the bounded warm observation. The first
Settings candidate removes the delayed focus reset, but has not yet received its one-observation A/B.
If Settings still fails, continue with `LabeledContent` rows, `Form`, AppKit popup anchor, nested
containment groups, and segmented picker in that order. Any retained workaround must preserve
VoiceOver semantics, keyboard order, stable accessibility identifiers, visible model state, and
all Settings behavior. Hiding controls or whole subtrees from accessibility is not an acceptable
workaround.

Normal suites may resume only after this document is updated and either a different signed helper
or a validated app-side workaround passes all of the following in one fresh session:

1. Plugin installed/enabled and server/skill available to the task.
2. Exactly one supported helper, no stale clients or zombies, and no initial crash delta.
3. Finder capture.
4. Cold exact-path Vocello capture.
5. Prelaunched-and-settled exact-path Vocello capture.
6. History, Custom, and Settings captures plus one harmless action on each relevant surface.
7. Two repeated Finder/Vocello observations and one after an idle interval.
8. No helper PID change, pipe closure, new `.ips`, duplicate app process, or wrong-path launch.
9. Separate passive iPhone Mirroring validation before any iOS suite.
10. Visible model and saved-voice readiness before generation.

Only then run fresh `full`, review, attestation, and independent 29-take benchmark suites for the
platform being released. Existing or partial frontend evidence does not clear that platform's
release gate, and one platform's evidence never gates the other platform's artifact.
