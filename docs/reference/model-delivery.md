# Model delivery

Vocello uses one shared native downloader, `HuggingFaceDownloader`, for pinned Hugging Face model
artifacts. macOS and the CLI use foreground `URLSession` instances. iPhone uses one bundle-aware
background session for the app lifetime. There is no second downloader, cloud synthesis path, or
ordinary-CI model fetch.

## Integrity and installation

Every file is matched to the model contract or the bundled iOS catalog, downloaded into staging,
checked against its exact byte count and SHA-256, and installed by an atomic directory swap. A
newly assembled file is hashed once. A same-process verified-artifact receipt permits finalization
without reading the complete file again; after a relaunch the staged file is hashed once before a
new receipt is trusted. Installed models retain the existing integrity-manifest format. Catalog-v2
artifacts additionally carry a shared-component installation plan: the installer publishes verified
component blobs before atomically presenting complete ordinary model folders.

At macOS/CLI runtime load, a pre-catalog legacy installation that lacks the integrity manifest is
adopted locally only after every catalog file passes its exact size and SHA-256. Adoption writes the
manifest atomically without rewriting the model directory or inspecting the generated
`.qvoice_prepared_model` overlay, which older releases may have populated with local symlinks. A
missing or changed catalog file still fails closed and does not produce a manifest or trigger an
implicit download.

macOS and CLI staging remains next to the model store under `.qwenvoice-downloads/`. iPhone has one
layout under the app-support root:

```text
downloads/
  ios_model_delivery_state.json
  staging/
    delegate-files/
    <model-id>/{files,partials,resume-data}/
diagnostics/model-downloads/
models/
  .qwenvoice-components-v1/  # content-addressed shared-component blobs and publication state
```

## macOS 手动下载入口与放置位置

macOS 设置页的“模型下载”区域在每个 Qwen 模型下提供“手动下载”折叠项，显示固定到生产目录版本的
Hugging Face 页面、当前运行环境的绝对安装路径，以及“打开 Hugging Face”“复制整包下载命令”
“显示文件夹”“复制路径”“重新检测”按钮。“手动下载”整行（箭头与文字）均可点击展开，不要求用户
精确点中左侧小箭头。
Qwen 模型不是单个文件：手动下载时必须取得对应提交的完整仓库，并保持仓库内部目录结构不变。应用重新检查时会
核对所需文件、精确大小和 SHA-256；验证通过后才会将目录视为已安装，并自动写入本地安装元数据。

“复制整包下载命令”从当前模型合同实时组成官方 `hf download` 命令，包含仓库名、固定的 40 位提交 SHA 和
当前运行环境的绝对目标目录。例如“声音克隆 / 速度”正式版会复制：

```sh
hf download 'mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit' --revision '37e955a1deb861c088ae5f3a67043185f3d1a60c' --local-dir "$HOME/Library/Application Support/QwenVoice/models/Qwen3-TTS-12Hz-1.7B-Base-4bit"
```

该命令要求用户已经安装 Hugging Face 官方 `hf` 命令行工具。同一命令可在中断后再次执行；其本地目录元数据会
避免重复下载未变化的完整文件。设置页实际复制的目录会经过 shell 安全引用，并以应用当前显示路径为准。

正式版的模型根目录为：

```text
~/Library/Application Support/QwenVoice/models/
```

六个生产模型的固定来源与目标文件夹如下：

| 功能 / 版本 | Hugging Face 固定版本页面 | 本地目标文件夹 |
| --- | --- | --- |
| 声音克隆 / 质量 | `https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit/tree/e7dd0585652209fa0d7783659aad4e8a324de11c` | `Qwen3-TTS-12Hz-1.7B-Base-8bit/` |
| 声音克隆 / 速度 | `https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit/tree/37e955a1deb861c088ae5f3a67043185f3d1a60c` | `Qwen3-TTS-12Hz-1.7B-Base-4bit/` |
| 自定义声音 / 质量 | `https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/tree/41d3337e8b7f2843a75841595fc14e4b9a7a4b96` | `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/` |
| 自定义声音 / 速度 | `https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit/tree/f35faf19b0cc2160865af64ecf0f22f83d335135` | `Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit/` |
| 声音设计 / 质量 | `https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit/tree/f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee` | `Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit/` |
| 声音设计 / 速度 | `https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit/tree/5c390979e4b93af5f2932f90742ca99c7dd04687` | `Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit/` |

例如“声音克隆 / 速度”的完整目标路径是：

```text
~/Library/Application Support/QwenVoice/models/Qwen3-TTS-12Hz-1.7B-Base-4bit/
```

调试模式改用 `QwenVoice-Debug` 隔离目录，因此实际操作时应以设置页展示并可复制的绝对路径为准。Whisper
字幕模型是单文件，具有独立的导入和校验流程，详见
[`macos-srt-subtitle-generation.md`](macos-srt-subtitle-generation.md)。

### Cross-platform production catalog

`Sources/Resources/qwenvoice_production_model_catalog.json` is the reproducible, bundled catalog
contract used by macOS, CLI, and iPhone delivery. Its versioned shape is declared
by `config/model-catalog-schema-v2.json`; it is generated only from the shared model contract and
checked-in exact file evidence:

```sh
python3 scripts/model_catalog_contract.py rebuild --check
python3 scripts/model_catalog_contract.py validate
```

Every covered artifact has a 40-character immutable Hugging Face revision, an allowlisted HTTPS
resolve URL, safe relative paths, positive exact byte counts, and a lowercase SHA-256 for every
required file. Source digests make independent edits to the shared contract, iPhone catalog, or
generated catalog fail validation.

Initial artifact requests remain restricted to the catalog's exact host. URLSession redirects are
also policy-checked: only HTTPS destinations without credentials or IP/local hosts are accepted,
and the destination must remain on the configured host or the explicit Hugging Face distribution
suffixes `huggingface.co` and `hf.co`. A rejected redirect is never adopted as background work.

The catalog is `complete`: the bundled iPhone evidence supplies the three Speed variants and
`config/model-artifact-receipts.json` supplies the three Quality variants. All six packages pin a
revision plus the exact size and SHA-256 of every required file; no hash or size is inferred.
Schema v2 also proves that the four files beneath `speech_tokenizer/` have the same content across
all six artifacts. It gives that component separate content identity (ordered path, size, and
SHA-256) and compatibility identity (content plus component schema, loader ABI, runtime profile,
and encoder capability), along with ordered source artifacts. Schema-v1 catalog documents remain
read-compatible but cannot claim shared-component reuse.

macOS, CLI, and iOS now resolve `ProductionModelCatalog.deliveryPlan(...)` rather than enumerating a
live repository. `validate --require-complete` proves this static contract. It does not replace the
isolated Mac/iPhone lifecycle proofs, which must be refreshed after redirect, restoration,
delivery-routing, or shared-component changes.

## Shared component store

`SharedModelComponentStore` is the one content-addressed storage implementation. It lives beneath
the existing model root, not in another cache, and provides these fail-closed rules:

- A component is reusable only after every blob passes the catalog's exact size and SHA-256.
- When the store is verified, a later artifact's delivery plan omits only those exact component
  files and records the reused byte count; all other files still download normally.
- New component bytes are published immutably. The installed model exposes regular hard links to
  the verified blobs, never symlinks, so existing regular-file and deep-integrity checks still hold.
- Hashing and full replica validation happen outside the cross-process publication lock. Only the
  stale-safe atomic exchange, tombstone, and liveness publication hold the lock.
- Deleting a model never removes blobs needed by another installed manifest. Pruning derives
  liveness from strict installed manifests rather than mutable reference counts.
- Corrupt/missing blobs, symlink traversal, a concurrently changed model, or failed post-install
  validation aborts or rolls back without replacing the last valid model.

The production install path is integrated for all hosts. Resolving a schema-v2 delivery plan also
reconciles an existing installed artifact one at a time: every catalog file is authenticated before
the model can publish component bytes, and a healthy model is left alone while a damaged linked
presentation is repaired only from verified store blobs. A failed local authentication leaves the
existing directory untouched, grants no reuse, and lets the ordinary downloader repair it from the
network. Live validation of all six macOS artifacts and the three iOS Speed artifacts is still
pending. Do not report the projected disk or network savings as observed production evidence until
those runs complete.

The iOS ledger is atomically written, versioned, and contains only privacy-safe identifiers and
relative paths. It records the logical request, model and artifact version, expected and verified
files, retries, monotonic received bytes, and terminal state. A one-time migration cancels the old
per-model sessions, waits for their cancellation callbacks, moves recoverable staging into the v2
layout, and removes the old document only when those sessions are empty. Installed models are not
touched.

## iPhone restoration and ownership

At launch, the coordinator asks the single background session for all tasks. Valid tasks whose
encoded model/artifact/file identity exactly matches the ledger and current catalog are adopted.
Unknown, stale, or duplicate tasks are cancelled, and only missing files receive new tasks.
Delegate temporary files are synchronously moved into durable app-group staging before the callback
returns. UIKit's background-session completion handler is released only after all delegate events
and durable install/failure postprocessing finish. Completion routing is exact-identifier scoped:
the canonical and debug-isolated coordinators retain and acknowledge only their own session's
handler. A foreign handler is neither stored nor completed, while an owned session with no durable
work is completed after reconciliation.

iPhone runs one model request at a time. macOS keeps its existing foreground concurrency. Both
platforms keep per-file range chunking disabled by default.

## States, cancellation, and retry

Visible states are: queued, waiting for connectivity, downloading, retrying, verifying, installing,
cancelling, installed, failed, deleting, and deleted. Speed and ETA are shown only during active
transfer. A separate no-progress message appears after 20 seconds of an actively running task;
waiting-for-connectivity comes from the URLSession delegate.

Explicit **Cancel** is a discard operation. The coordinator first persists `cancelRequested`, stops
new task registration, awaits all resume-data cancellation callbacks and terminal tasks, persists
the final deleted tombstone, and only then removes staging or reports deletion. If either critical
ledger write fails, cancellation fails closed: tasks or staging are preserved as applicable, the UI
shows a privacy-safe storage error, and relaunch cannot silently reinterpret the request as queued.
**Retry** preserves already verified files and reconstructs progress from the ledger, staged
partials, and adopted task byte counts.

Transient connection failures and HTTP 408, 429, and 5xx responses retry up to three times. A
`Retry-After` value is honored up to five minutes. One integrity mismatch receives one clean retry.
Cancellation, disk exhaustion, local filesystem errors, TLS trust failures, configuration errors,
and permanent 4xx responses do not retry.

## Diagnostics and acceptance

Local diagnostic summaries retain at most 20 records and 5 MB. Their allowlisted fields cover
timing, protocol, redirect/reuse and constrained/expensive-network flags, transferred bytes, and a
sanitized failure class. A successful attempt also records expected and wire bytes, duplicate bytes,
retry count, protocol set, thermal state, phase timings, and final-integrity status. Task completion
waits for URLSession's terminal callback so the success summary cannot overtake final task metrics.
Foreground delegate callbacks are serialized, durable staging is sequenced before terminal
completion, and high-frequency byte callbacks are reduced to bounded cumulative progress updates
plus the exact terminal byte count. This prevents a completed transfer from being stranded behind
its own progress backlog without sacrificing final byte accuracy.
Diagnostic summaries never contain a raw URL, absolute path, device identity, or user data.

Deterministic tests are model-free and Simulator-free. Live delivery is an explicit diagnostic:

```sh
# isolated macOS/CLI data root
./scripts/build.sh cli models install pro_custom_speed \
  --data-dir "$PWD/build/scratch/transient/model-download-acceptance" --verbose

# paired physical iPhone; safe leaf under managed Application Support,
# never the canonical App Group model tree
scripts/ui_test.sh ios model-download
```

The iPhone proof backgrounds and terminates the app during transfer, relaunches it, requires
non-regressing adopted progress, waits for exact verified installation, and deletes the isolated
model through the visible UI. It is not part of smoke, benchmark, CI, release, or packaging.
Crash-delta snapshots retain hashes rather than duplicating the device's historical diagnostics;
the lane pulls only its bounded model-download summaries into the local untracked result artifact.

The 2026-07-14 isolated Custom Speed acceptance passed on the Mac mini M2 8 GB and physical iPhone
17 Pro. Both transfers moved the exact 2,312,057,897 expected bytes without retry or duplicate
payload. Any control-plane traffic in earlier delivery routes was recorded separately and was never
classified as duplicate model payload. The iPhone XCUITest completed its
background/relaunch/install/visible-delete lifecycle in
81.6 seconds and reported HTTP/2 plus HTTP/1.1 with fair thermal state. This is lifecycle evidence,
not a performance baseline, and did not change concurrency or range-chunking defaults.

The lane also enters canonical Settings before and after the isolated lifecycle and requires all
three production models to remain installed with no visible canonical transfer in flight. The
debug isolation override accepts only an absolute
diagnostic path or one safe relative leaf; traversal and nested relative paths fail closed. Only
the managed relative leaf selects a separate app-lifetime background session, and its identifier
contains a one-way digest rather than the leaf itself. Production and absolute diagnostic roots
retain the historical bundle-scoped session identifier, so private paths cannot create arbitrary
URLSession namespaces.

Post-policy physical-iPhone run `ios-xcui-model-download-20260716-163359-61377762` repeated the
complete lifecycle. Expected and wire bytes both equaled 2,312,057,897, with zero retries or
duplicate bytes, one accepted redirect per artifact inside the declared provider boundary, HTTP/3
plus HTTP/1.1, nominal thermal state, final integrity, visible isolated cleanup, and canonical model
state preserved. Post-catalog macOS/CLI proof `model-download-acceptance-9a8da87` then transferred
the same exact 2,312,057,897 expected and wire bytes with zero control or duplicate bytes, zero
retries, HTTP/3 plus HTTP/1.1, and nominal thermal state. It measured 35.638 seconds of network
time, 0.003 seconds of verification, and 0.001 seconds of installation, reported final integrity,
and removed the isolated payload after preserving only bounded local diagnostics. These single
transfers are lifecycle evidence rather than concurrency tuning experiments.

## Tuning policy

One live transfer is a lifecycle proof, not a concurrency experiment. Connection counts or chunking
defaults may change only after a controlled comparison improves total transfer time by at least 15%
without more retries, duplicate bytes, thermal regression, or restoration failure.

Background Assets was evaluated and not adopted in this change. See
[`../decisions/model-delivery-background-assets.md`](../decisions/model-delivery-background-assets.md).

Changed-path evidence expectations are classified by
[`evidence-impact.md`](evidence-impact.md). Live model downloads remain explicit quality evidence,
not ordinary commit, merge, or release-packaging blockers.
