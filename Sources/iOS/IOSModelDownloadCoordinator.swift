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

/// Drives the shared `HuggingFaceDownloader` engine for iOS model downloads over a background
/// URLSession. **One model at a time** (jetsam safety), parallel files within it, byte-range
/// chunking off. Replaces the old `IOSModelDeliveryActor`; preserves the
/// `IOSModelDeliverySnapshot` contract the view model consumes. The in-flight downloader is
/// retained for the app lifetime so the background session's delegate survives across
/// backgrounding/relaunch.
@MainActor
final class IOSModelDownloadCoordinator {
    struct InFlightDownload {
        let modelID: String
        let downloader: HuggingFaceDownloader   // retained => background session delegate alive
        let task: Task<Void, Never>
        let targetDir: URL
        let backgroundSessionIdentifier: String
        let totalBytes: Int64
        let operationGeneration: UInt64
    }

    typealias SnapshotSink = @MainActor (IOSModelDeliverySnapshot) -> Void

    private let modelAssetStore: LocalModelAssetStore
    private let configuration: IOSModelDeliveryConfiguration
    private let fileManager: FileManager
    private let snapshotSink: SnapshotSink
    private let catalogSession: URLSession
    private var inflight: InFlightDownload?
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

    /// Begin downloading `model` over a fresh background URLSession. One model at a time; a
    /// concurrent request for a different model throws. Cancel = discard (no resume).
    func install(model: ModelDescriptor) async throws {
        guard model.iosDownloadEligible else {
            throw IOSModelDeliveryError.notEligibleForIOS(modelID: model.id)
        }
        if let inflight {
            if inflight.modelID == model.id { return }   // already running; ignore
            throw IOSModelDeliveryError.invalidConfiguration("Another model download is already running.")
        }

        try fileManager.createDirectory(at: AppPaths.modelsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: AppPaths.modelDownloadStagingDir, withIntermediateDirectories: true)
        try? IOSModelDeliverySupport.excludeFromBackup(AppPaths.modelsDir)
        try? IOSModelDeliverySupport.excludeFromBackup(AppPaths.modelDownloadStagingDir)

        let catalog = try await fetchCatalog()
        let entry = try IOSModelDeliverySupport.matchingCatalogEntry(
            for: model, in: catalog, configuration: configuration
        )
        let totalBytes = entry.totalBytes > 0
            ? entry.totalBytes
            : entry.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        try IOSModelDeliverySupport.ensureSufficientDiskSpace(
            requiredBytes: totalBytes, at: AppPaths.appSupportDir, fileManager: fileManager
        )

        let files = resolveFiles(entry: entry)
        let repo = model.huggingFaceRepo
        let revision = model.huggingFaceRevision ?? "main"
        let targetDir = model.installDirectory(in: AppPaths.modelsDir)
        let sessionID = "\(configuration.backgroundSessionIdentifier).\(model.id)"
        let generation = beginOperation()

        let downloader = makeDownloader(
            modelID: model.id, totalBytes: totalBytes,
            estimatedBytes: model.estimatedDownloadBytes, generation: generation, sessionID: sessionID
        )

        // Persist the in-flight record BEFORE starting so a crash mid-setup is recoverable.
        saveInFlightRecords([.init(
            modelID: model.id, artifactVersion: model.artifactVersion,
            backgroundSessionIdentifier: sessionID, repo: repo, revision: revision,
            targetFolderPath: targetDir.path, totalBytes: totalBytes
        )])

        inflight = startRun(
            modelID: model.id, files: files, repo: repo, revision: revision, targetDir: targetDir,
            downloader: downloader, generation: generation,
            totalBytes: totalBytes, estimatedBytes: model.estimatedDownloadBytes,
            sessionID: sessionID
        )
    }

    /// Cancel the in-flight download and discard its staged partial (true cancel; no resume).
    func cancel(modelID: String) async {
        guard let active = inflight, active.modelID == modelID else { return }
        let terminalGeneration = endOperation()
        active.downloader.cancel()
        active.task.cancel()
        HuggingFaceDownloader.discardStaging(forTargetDirectory: active.targetDir)
        inflight = nil
        saveInFlightRecords([])
        let descriptor = modelAssetStore.descriptor(id: modelID)?.model
        publish(.init(
            modelID: modelID, phase: .deleted, downloadedBytes: 0, totalBytes: nil,
            estimatedBytes: descriptor?.estimatedDownloadBytes, message: nil,
            operationGeneration: terminalGeneration
        ))
    }

    /// Delete an installed model (and cancel first if it's mid-download).
    func delete(model: ModelDescriptor) async throws {
        if let active = inflight {
            if active.modelID == model.id {
                await cancel(modelID: model.id)
            } else {
                throw IOSModelDeliveryError.invalidConfiguration("Another model download is already running.")
            }
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

    /// On app launch: reattach any in-flight background URLSession (same identifier → system
    /// re-enqueues pending tasks; on-disk partials let each Range-resume) and restore UI state.
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

            // Re-resolve the file list from the catalog (single source of truth).
            guard let files = try? await resolveFiles(for: descriptor) else {
                removeInFlightRecord(modelID: record.modelID)
                continue
            }

            activeSessionIDs.insert(record.backgroundSessionIdentifier)
            let generation = beginOperation()
            let downloader = makeDownloader(
                modelID: record.modelID, totalBytes: record.totalBytes,
                estimatedBytes: descriptor.estimatedDownloadBytes,
                generation: generation, sessionID: record.backgroundSessionIdentifier
            )
            // Immediate UI feedback; the byte count catches up on the first delegate callback.
            publish(.init(
                modelID: record.modelID, phase: .downloading, downloadedBytes: 0,
                totalBytes: record.totalBytes, estimatedBytes: descriptor.estimatedDownloadBytes,
                message: nil, operationGeneration: generation
            ))
            inflight = startRun(
                modelID: record.modelID, files: files, repo: record.repo, revision: record.revision,
                targetDir: targetDir, downloader: downloader, generation: generation,
                totalBytes: record.totalBytes, estimatedBytes: descriptor.estimatedDownloadBytes,
                sessionID: record.backgroundSessionIdentifier
            )
            break   // single model at a time
        }
        // Flush orphan completion handlers for sessions we did NOT reattach (e.g. the download
        // finished before the app reattached on relaunch).
        IOSModelDeliveryBackgroundEventRelay.completeOrphans(keeping: activeSessionIDs)
    }

    /// Flush any pending background completion handler for a session we're not running. Called
    /// from the app delegate's background-event delivery when no in-flight download owns it.
    func resumeBackgroundEventsIfNeeded() async {
        let active = inflight.map { Set([$0.backgroundSessionIdentifier]) } ?? []
        IOSModelDeliveryBackgroundEventRelay.completeOrphans(keeping: active)
    }

    // MARK: - Private

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
            guard inflight?.operationGeneration == generation else { return }
            inflight = nil
            saveInFlightRecords([])
            publish(.init(
                modelID: modelID, phase: .installed, downloadedBytes: totalBytes,
                totalBytes: totalBytes, estimatedBytes: estimatedBytes, message: nil,
                operationGeneration: generation
            ))
        } catch is CancellationError {
            // Cancel is handled by `cancel(modelID:)` (inflight already cleared); no-op here.
        } catch let dlError as HuggingFaceDownloader.DownloadError {
            if case .cancelled = dlError { return }
            guard inflight?.operationGeneration == generation else { return }
            inflight = nil
            saveInFlightRecords([])
            publish(.init(
                modelID: modelID, phase: .failed, downloadedBytes: 0, totalBytes: totalBytes,
                estimatedBytes: estimatedBytes, message: dlError.localizedDescription,
                operationGeneration: generation
            ))
        } catch {
            guard inflight?.operationGeneration == generation else { return }
            inflight = nil
            saveInFlightRecords([])
            publish(.init(
                modelID: modelID, phase: .failed, downloadedBytes: 0, totalBytes: totalBytes,
                estimatedBytes: estimatedBytes, message: error.localizedDescription,
                operationGeneration: generation
            ))
        }
    }

    /// Resolve a catalog entry's files into engine `RepoFile`s with host-allowlist-validated URLs.
    private func resolveFiles(entry: IOSModelCatalogEntry) -> [HuggingFaceDownloader.RepoFile] {
        entry.files.map { f in
            let url = (try? IOSModelDeliverySupport.downloadURL(for: f, entry: entry, configuration: configuration))
            return HuggingFaceDownloader.RepoFile(
                path: f.relativePath, size: f.sizeBytes, sha256: f.sha256, absoluteURL: url
            )
        }
    }

    /// Re-fetch the catalog and resolve files for `descriptor` (used by relaunch-restore).
    private func resolveFiles(for descriptor: ModelDescriptor) async throws -> [HuggingFaceDownloader.RepoFile] {
        let catalog = try await fetchCatalog()
        let entry = try IOSModelDeliverySupport.matchingCatalogEntry(
            for: descriptor, in: catalog, configuration: configuration
        )
        return resolveFiles(entry: entry)
    }

    private func makeDownloader(
        modelID: String,
        totalBytes: Int64,
        estimatedBytes: Int64?,
        generation: UInt64,
        sessionID: String
    ) -> HuggingFaceDownloader {
        let bgConfig = URLSessionConfiguration.background(withIdentifier: sessionID)
        bgConfig.waitsForConnectivity = true
        bgConfig.sessionSendsLaunchEvents = true
        bgConfig.isDiscretionary = false
        bgConfig.allowsExpensiveNetworkAccess = true
        bgConfig.allowsConstrainedNetworkAccess = true
        bgConfig.timeoutIntervalForRequest = 300

        var engineConfig = HuggingFaceDownloader.Configuration()
        engineConfig.maxConcurrentFiles = 3          // parallel files within the single model
        engineConfig.chunkLargeFiles = false         // background sessions throttle range requests

        return HuggingFaceDownloader(
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.handleProgress(
                        modelID: modelID, generation: generation, totalBytes: totalBytes,
                        estimatedBytes: estimatedBytes, progress: progress
                    )
                }
            },
            sessionConfiguration: bgConfig,
            engineConfiguration: engineConfig,
            backgroundSessionCompletionHandler: { identifier in
                Task { @MainActor in
                    IOSModelDeliveryBackgroundEventRelay.complete(forSessionIdentifier: identifier)
                }
            }
        )
    }

    private func handleProgress(
        modelID: String,
        generation: UInt64,
        totalBytes: Int64,
        estimatedBytes: Int64?,
        progress: HuggingFaceDownloader.RepositoryProgress
    ) {
        guard inflight?.operationGeneration == generation else { return }   // stale
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

    private func removeInFlightRecord(modelID: String) {
        saveInFlightRecords(loadInFlightRecords().filter { $0.modelID != modelID })
    }
}
