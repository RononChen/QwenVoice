import Foundation
import QwenVoiceCore

/// Progress snapshot consumed by `IOSModelInstallerViewModel`. (Moved here from the deleted
/// `IOSModelDeliveryActor`; the coordinator emits the same contract so the view model's `apply`
/// is unchanged. Only `downloading/verifying/installing/installed/deleting/deleted/failed` are
/// produced by the new engine — the pause/interrupt cases are dead.)
struct IOSModelDeliverySnapshot: Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case downloading
        case interrupted
        case resuming
        case restarting
        case paused
        case verifying
        case installing
        case installed
        case deleting
        case deleted
        case failed
    }

    let modelID: String
    let phase: Phase
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let estimatedBytes: Int64?
    let message: String?
    /// Monotonic token so the view model can ignore stale progress after cancel/fail.
    let operationGeneration: UInt64
}

/// Lightweight record of an in-flight download, persisted so the coordinator can reattach the
/// background URLSession (by identifier) and restore UI state after an app kill/relaunch.
/// URLSession auto-resumes pending tasks by identifier; the on-disk partials let each task
/// Range-resume, so the app only needs this list to know what was in flight.
struct IOSInFlightDownloadRecord: Codable, Sendable {
    let modelID: String
    let artifactVersion: String
    let backgroundSessionIdentifier: String
    let repo: String
    let revision: String
    let targetFolderPath: String
    let totalBytes: Int64
}

struct IOSInFlightDownloadsDocument: Codable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let downloads: [IOSInFlightDownloadRecord]
}

/// Drives the shared `HuggingFaceDownloader` engine for iOS model downloads over a **foreground**
/// URLSession (full speed; Apple throttles background sessions). Apple-aligned stable profile
/// (per WWDC23 "Build robust and resumable file transfers"): **one native `downloadTask` per file**
/// (byte-range chunking OFF — manual chunking caused uneven throughput) + the model's files
/// downloading concurrently (`maxConcurrentFiles = 6`) for speed, and **one model at a time**
/// (`maxConcurrentModels = 1`; a second request queues). Cancelling discards the partial (no
/// resume). The download only progresses while the app is foreground (a foreground URLSession
/// suspends on backgrounding); the engine resumes from on-disk partials when the app returns or
/// on next launch (see the in-flight records). Preserves the `IOSModelDeliverySnapshot` contract
/// the view model consumes. macOS/CLI keep byte-range ON (fast there); iOS trades that for
/// stability.
///
/// The `backgroundSessionIdentifier` / `IOSModelDeliveryBackgroundEventRelay` /
/// `backgroundSessionCompletionHandler` plumbing is **dormant** under this foreground profile
/// (kept for a potential future background-mode opt-in / cleanup) — a foreground session never
/// triggers `urlSessionDidFinishEvents` / `handleEventsForBackgroundURLSession`.
@MainActor
final class IOSModelDownloadCoordinator {
    struct InFlightDownload {
        let modelID: String
        let downloader: HuggingFaceDownloader   // retained for the download's lifetime
        let task: Task<Void, Never>
        let targetDir: URL
        /// Dormant under the foreground profile (no background session to identify).
        let backgroundSessionIdentifier: String
        let totalBytes: Int64
        let operationGeneration: UInt64
    }

    typealias SnapshotSink = @MainActor (IOSModelDeliverySnapshot) -> Void

    /// Maximum number of models downloading concurrently. **1 on iOS** (concurrent model downloads
    /// don't behave well on device — kept single). The bounded queue stays, so a second Download
    /// request queues and starts when the first terminates; bump this to re-enable concurrency.
    private static let maxConcurrentModels = 1

    private let modelAssetStore: LocalModelAssetStore
    private let configuration: IOSModelDeliveryConfiguration
    private let fileManager: FileManager
    private let snapshotSink: SnapshotSink
    private let catalogSession: URLSession
    private var inflight: [String: InFlightDownload] = [:]
    private var pending: [ModelDescriptor] = []
    private var cachedCatalog: IOSModelCatalogDocument?
    private var operationGeneration: UInt64 = 0

    init(
        modelAssetStore: LocalModelAssetStore,
        configuration: IOSModelDeliveryConfiguration = .default(),
        fileManager: FileManager = .default,
        snapshotSink: @escaping SnapshotSink
    ) {
        self.modelAssetStore = modelAssetStore
        self.configuration = configuration
        self.fileManager = fileManager
        self.snapshotSink = snapshotSink
        self.catalogSession = URLSession(configuration: .ephemeral)
    }

    // MARK: - Public (mirrors what IOSModelInstallerViewModel calls)

    /// Request a model download. Returns immediately; the bounded queue runs up to
    /// `maxConcurrentModels` at once. A model already queued or downloading is a no-op.
    /// Cancel = discard (no resume).
    func install(model: ModelDescriptor) async throws {
        guard model.iosDownloadEligible else {
            throw IOSModelDeliveryError.notEligibleForIOS(modelID: model.id)
        }
        if inflight[model.id] != nil { return }
        if pending.contains(where: { $0.id == model.id }) { return }

        try fileManager.createDirectory(at: AppPaths.modelsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: AppPaths.modelDownloadStagingDir, withIntermediateDirectories: true)
        try? IOSModelDeliverySupport.excludeFromBackup(AppPaths.modelsDir)
        try? IOSModelDeliverySupport.excludeFromBackup(AppPaths.modelDownloadStagingDir)

        pending.append(model)
        await startPendingDownloads()
    }

    /// Cancel a download (in-flight or queued) and discard its staged partial (true cancel).
    func cancel(modelID: String) async {
        // Queued but not yet started: just drop it from the queue.
        if let pendingIndex = pending.firstIndex(where: { $0.id == modelID }) {
            pending.remove(at: pendingIndex)
            let descriptor = modelAssetStore.descriptor(id: modelID)?.model
            publish(.init(
                modelID: modelID, phase: .deleted, downloadedBytes: 0, totalBytes: nil,
                estimatedBytes: descriptor?.estimatedDownloadBytes, message: nil,
                operationGeneration: endOperation()
            ))
            return
        }
        guard let active = inflight[modelID] else { return }
        let terminalGeneration = endOperation()
        active.downloader.cancel()
        active.task.cancel()
        HuggingFaceDownloader.discardStaging(forTargetDirectory: active.targetDir)
        inflight.removeValue(forKey: modelID)
        removeInFlightRecord(modelID: modelID)
        let descriptor = modelAssetStore.descriptor(id: modelID)?.model
        publish(.init(
            modelID: modelID, phase: .deleted, downloadedBytes: 0, totalBytes: nil,
            estimatedBytes: descriptor?.estimatedDownloadBytes, message: nil,
            operationGeneration: terminalGeneration
        ))
        await startPendingDownloads()   // drain the freed slot
    }

    /// Delete an installed model (and cancel first if it's mid-download).
    func delete(model: ModelDescriptor) async throws {
        if inflight[model.id] != nil || pending.contains(where: { $0.id == model.id }) {
            await cancel(modelID: model.id)
        }

        let generation = beginOperation()
        publish(.init(
            modelID: model.id, phase: .deleting, downloadedBytes: 0, totalBytes: nil,
            estimatedBytes: model.estimatedDownloadBytes, message: nil,
            operationGeneration: generation
        ))

        let targetDir = model.installDirectory(in: AppPaths.modelsDir)
        if fileManager.fileExists(atPath: targetDir.path) {
            try fileManager.removeItem(at: targetDir)
        }
        HuggingFaceDownloader.discardStaging(forTargetDirectory: targetDir)

        let terminalGeneration = endOperation()
        publish(.init(
            modelID: model.id, phase: .deleted, downloadedBytes: 0, totalBytes: nil,
            estimatedBytes: model.estimatedDownloadBytes, message: nil,
            operationGeneration: terminalGeneration
        ))
    }

    /// On app launch: resume any downloads that were in flight when the app was killed. The
    /// foreground URLSession doesn't survive a kill, but the on-disk partials let each file
    /// Range-resume; records beyond the concurrency cap are re-queued.
    func restoreInFlightDownloadsIfNeeded() async {
        let records = loadInFlightRecords()
        var activeSessionIDs = Set<String>()
        for record in records {
            guard let descriptor = modelAssetStore.descriptor(id: record.modelID)?.model else {
                removeInFlightRecord(modelID: record.modelID)
                continue
            }
            let targetDir = URL(fileURLWithPath: record.targetFolderPath, isDirectory: true)
            let alreadyInstalled = (try? descriptor.isAvailable(in: AppPaths.modelsDir, fileManager: fileManager)) == true
            // Stale if the catalog's artifact version bumped or the model finished installing.
            if descriptor.artifactVersion != record.artifactVersion || alreadyInstalled {
                HuggingFaceDownloader.discardStaging(forTargetDirectory: targetDir)
                removeInFlightRecord(modelID: record.modelID)
                continue
            }

            // At cap: re-queue so it starts when a slot frees (its record stays for recovery).
            guard inflight.count < Self.maxConcurrentModels else {
                if !pending.contains(where: { $0.id == record.modelID }) {
                    pending.append(descriptor)
                }
                continue
            }

            guard let files = try? await resolveFiles(for: descriptor) else {
                removeInFlightRecord(modelID: record.modelID)
                continue
            }

            activeSessionIDs.insert(record.backgroundSessionIdentifier)
            let generation = beginOperation()
            let downloader = makeDownloader(
                modelID: record.modelID, totalBytes: record.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes, generation: generation
            )
            publish(.init(
                modelID: record.modelID, phase: .downloading, downloadedBytes: 0,
                totalBytes: record.totalBytes, estimatedBytes: descriptor.estimatedDownloadBytes,
                message: nil, operationGeneration: generation
            ))
            inflight[record.modelID] = startRun(
                modelID: record.modelID, files: files, repo: record.repo, revision: record.revision,
                targetDir: targetDir, downloader: downloader, generation: generation,
                totalBytes: record.totalBytes, estimatedBytes: descriptor.estimatedDownloadBytes,
                sessionID: record.backgroundSessionIdentifier
            )
        }
        // Flush orphan completion handlers for sessions we did NOT reattach. (Dormant under the
        // foreground profile, but harmless.)
        IOSModelDeliveryBackgroundEventRelay.completeOrphans(keeping: activeSessionIDs)
    }

    /// Flush any pending background completion handler for a session we're not running. (Dormant
    /// under the foreground profile.)
    func resumeBackgroundEventsIfNeeded() async {
        let active = Set(inflight.values.map(\.backgroundSessionIdentifier))
        IOSModelDeliveryBackgroundEventRelay.completeOrphans(keeping: active)
    }

    // MARK: - Private: queue

    /// Launch queued downloads until the concurrency cap is reached.
    private func startPendingDownloads() async {
        while inflight.count < Self.maxConcurrentModels, let model = pending.first {
            pending.removeFirst()
            await beginDownload(model)
        }
    }

    /// Resolve one queued model against the (cached) catalog and start its download.
    private func beginDownload(_ model: ModelDescriptor) async {
        let entry: IOSModelCatalogEntry
        do {
            let catalog = try await fetchCatalog()
            entry = try IOSModelDeliverySupport.matchingCatalogEntry(
                for: model, in: catalog, configuration: configuration
            )
        } catch {
            publishFailed(modelID: model.id, message: error.localizedDescription)
            return
        }
        let totalBytes = entry.totalBytes > 0
            ? entry.totalBytes
            : entry.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        do {
            try IOSModelDeliverySupport.ensureSufficientDiskSpace(
                requiredBytes: totalBytes, at: AppPaths.appSupportDir, fileManager: fileManager
            )
        } catch {
            publishFailed(modelID: model.id, message: error.localizedDescription)
            return
        }

        let files = resolveFiles(entry: entry)
        let repo = model.huggingFaceRepo
        let revision = model.huggingFaceRevision ?? "main"
        let targetDir = model.installDirectory(in: AppPaths.modelsDir)
        let sessionID = "\(configuration.backgroundSessionIdentifier).\(model.id)"   // dormant
        let generation = beginOperation()
        let downloader = makeDownloader(
            modelID: model.id, totalBytes: totalBytes,
            estimatedBytes: model.estimatedDownloadBytes, generation: generation
        )

        upsertInFlightRecord(.init(
            modelID: model.id, artifactVersion: model.artifactVersion,
            backgroundSessionIdentifier: sessionID, repo: repo, revision: revision,
            targetFolderPath: targetDir.path, totalBytes: totalBytes
        ))
        inflight[model.id] = startRun(
            modelID: model.id, files: files, repo: repo, revision: revision, targetDir: targetDir,
            downloader: downloader, generation: generation,
            totalBytes: totalBytes, estimatedBytes: model.estimatedDownloadBytes, sessionID: sessionID
        )
    }

    /// Spawn the download Task and return the `InFlightDownload` handle. The Task reconciles the
    /// terminal state, gated on `generation` so a cancel/fail that supersedes it is a no-op.
    private func startRun(
        modelID: String,
        files: [HuggingFaceDownloader.RepoFile],
        repo: String,
        revision: String,
        targetDir: URL,
        downloader: HuggingFaceDownloader,
        generation: UInt64,
        totalBytes: Int64,
        estimatedBytes: Int64?,
        sessionID: String
    ) -> InFlightDownload {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDownload(
                modelID: modelID, files: files, repo: repo, revision: revision, targetDir: targetDir,
                downloader: downloader, generation: generation,
                totalBytes: totalBytes, estimatedBytes: estimatedBytes
            )
        }
        return InFlightDownload(
            modelID: modelID, downloader: downloader, task: task, targetDir: targetDir,
            backgroundSessionIdentifier: sessionID, totalBytes: totalBytes, operationGeneration: generation
        )
    }

    private func runDownload(
        modelID: String,
        files: [HuggingFaceDownloader.RepoFile],
        repo: String,
        revision: String,
        targetDir: URL,
        downloader: HuggingFaceDownloader,
        generation: UInt64,
        totalBytes: Int64,
        estimatedBytes: Int64?
    ) async {
        do {
            try await downloader.downloadFiles(files, repo: repo, revision: revision, to: targetDir)
            guard inflight[modelID]?.operationGeneration == generation else { return }
            inflight.removeValue(forKey: modelID)
            removeInFlightRecord(modelID: modelID)
            publish(.init(
                modelID: modelID, phase: .installed, downloadedBytes: totalBytes,
                totalBytes: totalBytes, estimatedBytes: estimatedBytes, message: nil,
                operationGeneration: generation
            ))
        } catch is CancellationError {
            // Cancel is handled by `cancel(modelID:)` (inflight already cleared); no-op here.
            return
        } catch let dlError as HuggingFaceDownloader.DownloadError {
            if case .cancelled = dlError { return }
            guard inflight[modelID]?.operationGeneration == generation else { return }
            inflight.removeValue(forKey: modelID)
            removeInFlightRecord(modelID: modelID)
            publish(.init(
                modelID: modelID, phase: .failed, downloadedBytes: 0, totalBytes: totalBytes,
                estimatedBytes: estimatedBytes, message: dlError.localizedDescription,
                operationGeneration: generation
            ))
        } catch {
            guard inflight[modelID]?.operationGeneration == generation else { return }
            inflight.removeValue(forKey: modelID)
            removeInFlightRecord(modelID: modelID)
            publish(.init(
                modelID: modelID, phase: .failed, downloadedBytes: 0, totalBytes: totalBytes,
                estimatedBytes: estimatedBytes, message: error.localizedDescription,
                operationGeneration: generation
            ))
        }
        // A slot just freed (success or failure) — drain the next queued download. (The cancel
        // paths `return` above, so this only runs for terminal success/failure; cancel drains
        // itself in `cancel(modelID:)`.)
        await startPendingDownloads()
    }

    private func publishFailed(modelID: String, message: String) {
        let descriptor = modelAssetStore.descriptor(id: modelID)?.model
        publish(.init(
            modelID: modelID, phase: .failed, downloadedBytes: 0, totalBytes: nil,
            estimatedBytes: descriptor?.estimatedDownloadBytes, message: message,
            operationGeneration: endOperation()
        ))
    }

    // MARK: - Private: catalog + downloader

    /// Resolve a catalog entry's files into engine `RepoFile`s with host-allowlist-validated URLs.
    private func resolveFiles(entry: IOSModelCatalogEntry) -> [HuggingFaceDownloader.RepoFile] {
        entry.files.map { f in
            let url = (try? IOSModelDeliverySupport.downloadURL(for: f, entry: entry, configuration: configuration))
            return HuggingFaceDownloader.RepoFile(
                path: f.relativePath, size: f.sizeBytes, sha256: f.sha256, absoluteURL: url
            )
        }
    }

    /// Resolve files for `descriptor` via the (cached) catalog (used by relaunch-restore).
    private func resolveFiles(for descriptor: ModelDescriptor) async throws -> [HuggingFaceDownloader.RepoFile] {
        let catalog = try await fetchCatalog()
        let entry = try IOSModelDeliverySupport.matchingCatalogEntry(
            for: descriptor, in: catalog, configuration: configuration
        )
        return resolveFiles(entry: entry)
    }

    /// Build the engine with the macOS/CLI profile: foreground URLSession (default), byte-range
    /// chunking on, 6 concurrent files. The engine's init sets `httpMaximumConnectionsPerHost`
    /// for foreground sessions. No background-session config (full speed, no throttle).
    private func makeDownloader(
        modelID: String,
        totalBytes: Int64,
        estimatedBytes: Int64?,
        generation: UInt64
    ) -> HuggingFaceDownloader {
        var engineConfig = HuggingFaceDownloader.Configuration()
        engineConfig.maxConcurrentFiles = 6          // the model's files download concurrently (6)
        engineConfig.chunkLargeFiles = false         // one native downloadTask per file — stable, even throughput (no chunk tapering)

        return HuggingFaceDownloader(
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.handleProgress(
                        modelID: modelID, generation: generation, totalBytes: totalBytes,
                        estimatedBytes: estimatedBytes, progress: progress
                    )
                }
            },
            engineConfiguration: engineConfig
            // sessionConfiguration defaults to .default (foreground) → full speed.
            // backgroundSessionCompletionHandler omitted: dormant under the foreground profile.
        )
    }

    private func handleProgress(
        modelID: String,
        generation: UInt64,
        totalBytes: Int64,
        estimatedBytes: Int64?,
        progress: HuggingFaceDownloader.RepositoryProgress
    ) {
        guard inflight[modelID]?.operationGeneration == generation else { return }   // stale
        let phase: IOSModelDeliverySnapshot.Phase
        switch progress.phase {
        case .downloading: phase = .downloading
        case .verifying: phase = .verifying
        case .installing: phase = .installing
        }
        publish(.init(
            modelID: modelID, phase: phase, downloadedBytes: progress.downloadedBytes,
            totalBytes: progress.totalBytes > 0 ? progress.totalBytes : totalBytes,
            estimatedBytes: estimatedBytes, message: nil, operationGeneration: generation
        ))
    }

    private func publish(_ snapshot: IOSModelDeliverySnapshot) {
        snapshotSink(snapshot)
    }

    private func fetchCatalog() async throws -> IOSModelCatalogDocument {
        if let cachedCatalog { return cachedCatalog }
        let document = try await fetchCatalogUncached()
        cachedCatalog = document
        return document
    }

    private func fetchCatalogUncached() async throws -> IOSModelCatalogDocument {
        if configuration.catalogURL.isBundledModelCatalog {
            guard let catalogURL = Bundle.main.url(
                forResource: IOSModelDeliveryConfiguration.bundledCatalogResourceName,
                withExtension: IOSModelDeliveryConfiguration.bundledCatalogResourceExtension
            ) else {
                throw IOSModelDeliveryError.invalidCatalog("Bundled iPhone model catalog is missing.")
            }
            let data = try Data(contentsOf: catalogURL)
            return try JSONDecoder().decode(IOSModelCatalogDocument.self, from: data)
        }

        let (data, response) = try await catalogSession.data(from: configuration.catalogURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw IOSModelDeliveryError.invalidCatalog("Catalog endpoint returned an unexpected response.")
        }
        return try JSONDecoder().decode(IOSModelCatalogDocument.self, from: data)
    }

    private func beginOperation() -> UInt64 {
        operationGeneration += 1
        return operationGeneration
    }

    @discardableResult
    private func endOperation() -> UInt64 {
        operationGeneration += 1
        return operationGeneration
    }

    // MARK: - In-flight persistence

    private func loadInFlightRecords() -> [IOSInFlightDownloadRecord] {
        guard let data = try? Data(contentsOf: AppPaths.iosInFlightDownloadsFile),
              let document = try? JSONDecoder().decode(IOSInFlightDownloadsDocument.self, from: data) else {
            return []
        }
        return document.downloads
    }

    private func saveInFlightRecords(_ records: [IOSInFlightDownloadRecord]) {
        let document = IOSInFlightDownloadsDocument(
            schemaVersion: IOSInFlightDownloadsDocument.currentSchemaVersion,
            downloads: records
        )
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: AppPaths.iosInFlightDownloadsFile, options: .atomic)
    }

    private func upsertInFlightRecord(_ record: IOSInFlightDownloadRecord) {
        var records = loadInFlightRecords().filter { $0.modelID != record.modelID }
        records.append(record)
        saveInFlightRecords(records)
    }

    private func removeInFlightRecord(modelID: String) {
        saveInFlightRecords(loadInFlightRecords().filter { $0.modelID != modelID })
    }
}
