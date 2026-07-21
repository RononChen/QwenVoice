import Foundation
import QwenVoiceCore
import QwenVoiceNative

enum BatchSegmentationMode: String, Codable, Equatable {
    case lineSeparated
    case longForm
}

struct LongFormBatchSegmenter {
    static let defaultMaxCharacters = 900
    static let runtimeTokenLimit = 450

    static func plan(from text: String, baseSeed: UInt64) throws -> LongFormPlan {
        try LongFormPlanner.plan(
            spokenTextPlan: SpokenTextPlanner.plan(originalText: text),
            configuration: LongFormPlanningConfiguration(
                runtimeTokenLimit: runtimeTokenLimit,
                baseSeed: baseSeed
            )
        )
    }
}

struct BatchProgressSnapshot: Equatable {
    enum Unit: Equatable {
        case clips
        case segments
    }

    let completedCount: Int
    let totalCount: Int
    let activeItemIndex: Int?
    let backendFraction: Double?
    let statusMessage: String
    let unit: Unit

    init(
        completedCount: Int = 0,
        totalCount: Int = 0,
        activeItemIndex: Int? = nil,
        backendFraction: Double? = nil,
        statusMessage: String = "",
        unit: Unit = .clips
    ) {
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.activeItemIndex = activeItemIndex
        self.backendFraction = backendFraction
        self.statusMessage = statusMessage
        self.unit = unit
    }

    var itemFraction: Double {
        guard totalCount > 0 else { return 0.0 }
        return min(max(Double(completedCount) / Double(totalCount), 0.0), 1.0)
    }

    var displayFraction: Double {
        min(max(backendFraction ?? itemFraction, 0.0), 1.0)
    }

    var itemStatusText: String {
        guard totalCount > 0 else { return "" }
        // The "Item N active" suffix used to be appended here, but during
        // batch generation `activeItemIndex` lags the engine's real
        // progress: the runner only increments `completedCount` after
        // `generateBatch` returns and saves run sequentially, while the
        // engine emits messages like "Generating item 2/2..." mid-batch.
        // That produced contradictory text such as "Generating item 2/2…
        // 0 of 2 clips completed · Item 1 active". `statusMessage` already
        // tells the user which item is in flight, so the count line just
        // reports completion.
        switch unit {
        case .clips:
            return AppLocalization.format(
                "%lld of %lld clips completed",
                Int64(completedCount),
                Int64(totalCount)
            )
        case .segments:
            return AppLocalization.format(
                "%lld of %lld segments completed",
                Int64(completedCount),
                Int64(totalCount)
            )
        }
    }
}

struct BatchGenerationItemState: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case running
        case saved(audioPath: String)
        case failed(message: String)
        case cancelled
    }

    let id = UUID()
    let index: Int
    let line: String
    let segmentationMode: BatchSegmentationMode
    var status: Status

    init(
        index: Int,
        line: String,
        segmentationMode: BatchSegmentationMode = .lineSeparated,
        status: Status
    ) {
        self.index = index
        self.line = line
        self.segmentationMode = segmentationMode
        self.status = status
    }

    var audioPath: String? {
        if case .saved(let audioPath) = status {
            return audioPath
        }
        return nil
    }

    var isSaved: Bool {
        if case .saved = status {
            return true
        }
        return false
    }

    var isRetryable: Bool {
        switch status {
        case .pending, .running, .failed, .cancelled:
            return true
        case .saved:
            return false
        }
    }

    var statusLabel: String {
        switch status {
        case .pending:
            return "Pending"
        case .running:
            return "Running"
        case .saved:
            return "Saved"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var statusMessage: String? {
        switch status {
        case .failed(let message):
            return message
        default:
            return nil
        }
    }
}

@MainActor
protocol GenerationPersisting {
    func saveGeneration(_ generation: Generation) async throws -> Generation
}

extension DatabaseService: GenerationPersisting {
    func saveGeneration(_ generation: Generation) async throws -> Generation {
        try await saveGenerationAsync(generation)
    }
}

struct BatchGenerationRequest {
    let mode: GenerationMode
    let model: TTSModel
    let lines: [String]
    let segmentationMode: BatchSegmentationMode
    let voice: String?
    let emotion: String?
    let languageHint: String?
    let voiceDescription: String?
    let refAudio: String?
    let refText: String?
    let originalLongFormText: String?
    let longFormPlan: LongFormPlan?
    /// One sampling seed shared by every item in the batch (GitHub #30):
    /// segments of one batch keep a steadier character/pacing than fully
    /// independent draws (community-verified for long-form chunking), and
    /// Voice Design batches stop re-rolling a different voice per segment
    /// quite as wildly. Minted per batch run, so separate batches still
    /// differ from each other.
    let batchSeed: UInt64

    init(
        mode: GenerationMode,
        model: TTSModel,
        lines: [String],
        segmentationMode: BatchSegmentationMode = .lineSeparated,
        voice: String?,
        emotion: String?,
        languageHint: String? = nil,
        voiceDescription: String?,
        refAudio: String?,
        refText: String?,
        originalLongFormText: String? = nil,
        longFormPlan: LongFormPlan? = nil,
        batchSeed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)
    ) {
        self.mode = mode
        self.model = model
        self.lines = lines
        self.segmentationMode = segmentationMode
        self.voice = voice
        self.emotion = emotion
        self.languageHint = languageHint
        self.voiceDescription = voiceDescription
        self.refAudio = refAudio
        self.refText = refText
        self.originalLongFormText = originalLongFormText
        self.longFormPlan = longFormPlan
        self.batchSeed = batchSeed
    }

    func preparedForLongForm(originalText: String, plan: LongFormPlan) -> Self {
        Self(
            mode: mode,
            model: model,
            lines: plan.segments.map(\.modelFacingText),
            segmentationMode: .longForm,
            voice: voice,
            emotion: emotion,
            languageHint: languageHint,
            voiceDescription: voiceDescription,
            refAudio: refAudio,
            refText: refText,
            originalLongFormText: originalText,
            longFormPlan: plan,
            batchSeed: batchSeed
        )
    }

    func validationError(isModelAvailable: Bool, recoveryDetail: String) -> String? {
        guard isModelAvailable else {
            return recoveryDetail
        }

        if mode == .design && (voiceDescription ?? "").isEmpty {
            return "Enter a voice description before starting batch generation."
        }

        if mode == .clone && refAudio == nil {
            return "Select a reference audio file before starting batch generation."
        }

        return nil
    }

    func makeHistoryRecord(for line: String, result: QwenVoiceNative.GenerationResult) -> Generation {
        let voiceName: String?
        switch mode {
        case .custom:
            voiceName = voice
        case .design:
            voiceName = voiceDescription
        case .clone:
            if let voice {
                voiceName = voice
            } else if let refAudio {
                voiceName = URL(fileURLWithPath: refAudio).deletingPathExtension().lastPathComponent
            } else {
                voiceName = nil
            }
        }

        return Generation(
            text: line,
            mode: model.mode.rawValue,
            modelTier: model.tier,
            voice: voiceName,
            emotion: emotion,
            speed: nil,
            audioPath: result.audioPath,
            duration: result.durationSeconds,
            createdAt: Date()
        )
    }

    func makeGenerationRequest(
        for line: String,
        outputPath: String,
        batchIndex: Int?,
        batchTotal: Int?
    ) -> QwenVoiceNative.GenerationRequest {
        // Long form is orchestrated by the product as a sequence of ordinary
        // native requests. Passing batch metadata here makes MLXTTSEngine's
        // single-request support gate reject the call before synthesis starts.
        let transportBatchIndex = segmentationMode == .lineSeparated ? batchIndex : nil
        let transportBatchTotal = segmentationMode == .lineSeparated ? batchTotal : nil

        switch mode {
        case .custom:
            return QwenVoiceNative.GenerationRequest(
                modelID: model.id,
                text: line,
                outputPath: outputPath,
                shouldStream: false,
                batchIndex: transportBatchIndex,
                batchTotal: transportBatchTotal,
                languageHint: languageHint,
                payload: .custom(
                    speakerID: voice ?? TTSModel.defaultSpeaker,
                    deliveryStyle: model.supportsInstructionControl
                        ? (emotion ?? DeliveryProfile.neutralInstruction)
                        : nil
                ),
                seed: batchSeed,
                variation: GenerationVariationPreference.requestValue()
            )
        case .design:
            return QwenVoiceNative.GenerationRequest(
                modelID: model.id,
                text: line,
                outputPath: outputPath,
                shouldStream: false,
                batchIndex: transportBatchIndex,
                batchTotal: transportBatchTotal,
                languageHint: languageHint,
                payload: .design(
                    voiceDescription: voiceDescription ?? "",
                    deliveryStyle: emotion ?? DeliveryProfile.neutralInstruction
                ),
                seed: batchSeed,
                variation: GenerationVariationPreference.requestValue()
            )
        case .clone:
            return QwenVoiceNative.GenerationRequest(
                modelID: model.id,
                text: line,
                outputPath: outputPath,
                shouldStream: false,
                batchIndex: transportBatchIndex,
                batchTotal: transportBatchTotal,
                languageHint: languageHint,
                payload: .clone(
                    reference: CloneReference(
                        audioPath: refAudio ?? "",
                        transcript: refText
                    )
                ),
                seed: batchSeed,
                variation: GenerationVariationPreference.requestValue()
            )
        }
    }

    func makeBatchGenerationRequests(
        makeOutputPath: (String, String) -> String
    ) -> [QwenVoiceNative.GenerationRequest] {
        lines.enumerated().map { index, line in
            let outputText = outputText(for: line, index: index)
            return makeGenerationRequest(
                for: line,
                outputPath: makeOutputPath(model.outputSubfolder, outputText),
                batchIndex: index + 1,
                batchTotal: lines.count
            )
        }
    }

    func outputText(for line: String, index: Int) -> String {
        switch segmentationMode {
        case .lineSeparated:
            return line
        case .longForm:
            return String(format: "segment_%04d_%@", index + 1, String(line.prefix(40)))
        }
    }

}

enum BatchGenerationOutcome: Equatable {
    case completed(items: [BatchGenerationItemState])
    case cancelled(items: [BatchGenerationItemState], restartFailedMessage: String?)
    case failed(items: [BatchGenerationItemState], message: String)

    var items: [BatchGenerationItemState] {
        switch self {
        case .completed(let items):
            return items
        case .cancelled(let items, _):
            return items
        case .failed(let items, _):
            return items
        }
    }

    var completedCount: Int {
        items.filter(\.isSaved).count
    }

    var totalCount: Int {
        items.count
    }

    var retryRemainingLines: [String] {
        items.compactMap { item in
            switch item.status {
            case .pending, .running, .cancelled:
                return item.line
            case .failed, .saved:
                return nil
            }
        }
    }

    var retryFailedLines: [String] {
        items.compactMap { item in
            if case .failed = item.status {
                return item.line
            }
            return nil
        }
    }

    var savedAudioPaths: [String] {
        items.compactMap(\.audioPath)
    }

    func withRestartFailure(_ message: String?) -> BatchGenerationOutcome {
        guard case .cancelled(let items, _) = self else { return self }
        return .cancelled(items: items, restartFailedMessage: message)
    }
}

private enum LongFormProductGenerationError: LocalizedError {
    case missingPlan
    case planMismatch
    case unexpectedSegmentOutput(index: Int)
    case incompleteSegment(index: Int, reason: GenerationFinishReason)
    case segmentQuality(index: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingPlan:
            return "The long-form plan is unavailable. Submit the script again."
        case .planMismatch:
            return "The long-form plan no longer matches the script. Submit it again."
        case .unexpectedSegmentOutput(let index):
            return AppLocalization.format(
                "Segment %lld was written outside its temporary workspace. The task stopped safely.",
                Int64(index)
            )
        case .incompleteSegment(let index, let reason):
            return AppLocalization.format(
                "Segment %lld did not finish (%@). The task stopped and its temporary files were cleaned up.",
                Int64(index),
                reason.rawValue
            )
        case .segmentQuality(let index, let detail):
            return AppLocalization.format(
                "Segment %lld failed the audio check: %@",
                Int64(index),
                detail
            )
        }
    }
}

@MainActor
final class BatchGenerationCoordinator: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progressSnapshot = BatchProgressSnapshot()
    @Published private(set) var itemStates: [BatchGenerationItemState] = []
    @Published var errorMessage: String?
    @Published private(set) var outcome: BatchGenerationOutcome?

    private var runner: BatchGenerationRunner?
    private var runTask: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?
    private var cancelRestartFailedMessage: String?

    func startBatch(
        batchText: String,
        segmentationMode: BatchSegmentationMode = .lineSeparated,
        requestBuilder: ([String]) -> BatchGenerationRequest?,
        isModelAvailable: (TTSModel) -> Bool,
        recoveryDetail: (TTSModel) -> String,
        engineStore: TTSEngineStore,
        store: any GenerationPersisting = DatabaseService.shared
    ) {
        let lines: [String]
        let initialLongFormPlan: LongFormPlan?
        switch segmentationMode {
        case .lineSeparated:
            lines = batchText.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            initialLongFormPlan = nil
        case .longForm:
            do {
                let plan = try LongFormBatchSegmenter.plan(from: batchText, baseSeed: 0)
                initialLongFormPlan = plan
                lines = plan.segments.map(\.modelFacingText)
            } catch {
                errorMessage = AppLocalization.format(
                    "Unable to plan the long script: %@",
                    error.localizedDescription
                )
                return
            }
        }

        guard !lines.isEmpty else { return }
        let maxBatchSegments = 100
        if lines.count > maxBatchSegments {
            errorMessage = "Batch is too large: \(lines.count) segments exceeds the maximum of \(maxBatchSegments). Please split the text and try again."
            return
        }
        guard var request = requestBuilder(lines) else {
            errorMessage = "Model configuration not found"
            return
        }

        if segmentationMode == .longForm, initialLongFormPlan != nil {
            do {
                let seededPlan = try LongFormBatchSegmenter.plan(
                    from: batchText,
                    baseSeed: request.batchSeed
                )
                request = request.preparedForLongForm(
                    originalText: batchText,
                    plan: seededPlan
                )
            } catch {
                errorMessage = AppLocalization.format(
                    "Unable to plan the long script: %@",
                    error.localizedDescription
                )
                return
            }
        }

        if let validationError = request.validationError(
            isModelAvailable: isModelAvailable(request.model),
            recoveryDetail: recoveryDetail(request.model)
        ) {
            errorMessage = validationError
            return
        }

        let runner = BatchGenerationRunner(
            engineStore: engineStore,
            store: store
        )

        self.runner = runner
        runTask?.cancel()
        cancelTask = nil
        cancelRestartFailedMessage = nil
        isProcessing = true
        isCancelling = false
        errorMessage = nil
        outcome = nil
        itemStates = if segmentationMode == .longForm {
            [
                BatchGenerationItemState(
                    index: 0,
                    line: batchText,
                    segmentationMode: .longForm,
                    status: .pending
                )
            ]
        } else {
            lines.enumerated().map { index, line in
                BatchGenerationItemState(index: index, line: line, status: .pending)
            }
        }
        progressSnapshot = BatchProgressSnapshot(
            completedCount: 0,
            totalCount: lines.count,
            activeItemIndex: lines.isEmpty ? nil : 0,
            statusMessage: "Preparing batch..."
        )

        runTask = Task { [weak self] in
            guard let self else { return }

            var outcome = await runner.run(
                request: request,
                makeOutputPath: { makeOutputPath(subfolder: $0, text: $1) },
                onProgress: { [weak self] snapshot in
                    self?.progressSnapshot = snapshot
                },
                onItemsUpdated: { [weak self] items in
                    self?.itemStates = items
                }
            )

            if case .cancelled = outcome, let cancelTask = self.cancelTask {
                await cancelTask.value
                if let cancelRestartFailedMessage {
                    outcome = outcome.withRestartFailure(cancelRestartFailedMessage)
                }
            }

            self.isProcessing = false
            self.isCancelling = false
            self.runner = nil
            self.runTask = nil
            self.outcome = outcome

            if case .failed(_, let message) = outcome {
                self.errorMessage = message
            } else if case .cancelled(_, let restartFailedMessage) = outcome {
                self.errorMessage = restartFailedMessage
            }
        }
    }

    /// Sheet-dismissal safety net: if the sheet disappears while a batch is
    /// still processing (programmatic dismissal, window close — anything but
    /// the Cancel button), cancel the run so it can't keep generating and
    /// holding the engine's generation slot with no visible UI.
    func cancelIfDismissedWhileProcessing() {
        guard isProcessing else { return }
        cancelBatch(dismiss: {})
    }

    func cancelBatch(
        dismiss: @escaping () -> Void
    ) {
        guard isProcessing else {
            dismiss()
            return
        }

        guard !isCancelling else { return }
        guard let runner else {
            isProcessing = false
            dismiss()
            return
        }

        isCancelling = true
        errorMessage = nil
        cancelRestartFailedMessage = nil
        progressSnapshot = BatchProgressSnapshot(
            completedCount: progressSnapshot.completedCount,
            totalCount: progressSnapshot.totalCount,
            activeItemIndex: progressSnapshot.activeItemIndex,
            backendFraction: progressSnapshot.backendFraction,
            statusMessage: "Cancelling..."
        )
        runTask?.cancel()
        cancelTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await runner.requestCancellation()
            } catch {
                self.cancelRestartFailedMessage = "Batch generation was interrupted, but the backend could not be restarted: \(error.localizedDescription)"
            }
        }
    }
}

@MainActor
final class BatchGenerationRunner {
    private let engineStore: TTSEngineStore
    private let store: any GenerationPersisting
    private let generationEvents: GenerationLibraryEvents
    private let audioQualityEvaluator: (URL, String) async -> AudioQualityGate.Report
    private let cancellationState = BatchGenerationCancellationState()

    init(
        engineStore: TTSEngineStore,
        store: any GenerationPersisting,
        generationEvents: GenerationLibraryEvents = .shared,
        audioQualityEvaluator: @escaping (URL, String) async -> AudioQualityGate.Report = { url, spokenText in
            await Task.detached(priority: .utility) {
                AudioQualityGate.evaluate(url: url, spokenText: spokenText)
            }.value
        }
    ) {
        self.engineStore = engineStore
        self.store = store
        self.generationEvents = generationEvents
        self.audioQualityEvaluator = audioQualityEvaluator
    }

    func run(
        request: BatchGenerationRequest,
        makeOutputPath: (String, String) -> String,
        onProgress: @escaping @MainActor (BatchProgressSnapshot) -> Void,
        onItemsUpdated: @escaping @MainActor ([BatchGenerationItemState]) -> Void
    ) async -> BatchGenerationOutcome {
        if request.segmentationMode == .longForm {
            return await runLongForm(
                request: request,
                makeOutputPath: makeOutputPath,
                onProgress: onProgress,
                onItemsUpdated: onItemsUpdated
            )
        }

        var items = request.lines.enumerated().map { index, line in
            BatchGenerationItemState(index: index, line: line, status: .pending)
        }
        var completedCount = 0
        let total = request.lines.count

        func publishItems() {
            onItemsUpdated(items)
        }

        func markItemsCancelled(startingAt index: Int) {
            guard index < items.count else { return }
            for itemIndex in index..<items.count where !items[itemIndex].isSaved {
                items[itemIndex].status = .cancelled
            }
        }

        func publishProgress(activeItemIndex: Int?, message: String, backendFraction: Double? = nil) {
            onProgress(
                BatchProgressSnapshot(
                    completedCount: completedCount,
                    totalCount: total,
                    activeItemIndex: activeItemIndex,
                    backendFraction: backendFraction,
                    statusMessage: message
                )
            )
        }

        publishItems()

        if total > 1 {
            if await cancellationState.wasRequested() {
                markItemsCancelled(startingAt: 0)
                publishItems()
                engineStore.clearGenerationActivity()
                return .cancelled(items: items, restartFailedMessage: nil)
            }

            items[0].status = .running
            publishItems()
            publishProgress(activeItemIndex: 0, message: "Preparing batch...")

            let batchRequests = request.makeBatchGenerationRequests(makeOutputPath: makeOutputPath)

            do {
                let results = try await engineStore.generateBatch(
                    batchRequests,
                    progressHandler: { fraction, message in
                        publishProgress(
                            activeItemIndex: completedCount < total ? completedCount : nil,
                            message: message,
                            backendFraction: fraction
                        )
                    }
                )

                guard results.count == request.lines.count else {
                    if let firstRunningIndex = items.firstIndex(where: { $0.status == .running || $0.status == .pending }) {
                        items[firstRunningIndex].status = .failed(
                            message: "Batch generation returned \(results.count) results for \(request.lines.count) requests."
                        )
                    }
                    publishItems()
                    return .failed(
                        items: items,
                        message: "Batch generation returned \(results.count) results for \(request.lines.count) requests."
                    )
                }

                for (index, pair) in zip(request.lines, results).enumerated() {
                    if await cancellationState.wasRequested() {
                        markItemsCancelled(startingAt: index)
                        publishItems()
                        engineStore.clearGenerationActivity()
                        return .cancelled(items: items, restartFailedMessage: nil)
                    }

                    items[index].status = .running
                    publishItems()
                    publishProgress(activeItemIndex: index, message: "Saving item \(index + 1)/\(total)...")

                    let (line, result) = pair
                    let generation = request.makeHistoryRecord(for: line, result: result)

                    do {
                        let savedGeneration = try await store.saveGeneration(generation)
                        // Use the payload-carrying announce so HistoryView
                        // (which only subscribes to `generationAppended`)
                        // refreshes live during batch runs. The helper
                        // still fires the legacy `generationSaved` event
                        // for any subscriber that hasn't migrated.
                        generationEvents.announceGenerationAppended(savedGeneration)
                        completedCount += 1
                        items[index].status = .saved(audioPath: result.audioPath)
                        if index + 1 < items.count {
                            items[index + 1].status = .pending
                        }
                        publishItems()
                    } catch {
                        items[index].status = .failed(message: error.localizedDescription)
                        publishItems()
                        return .failed(items: items, message: error.localizedDescription)
                    }
                }

                publishProgress(activeItemIndex: nil, message: "Done")
                return .completed(items: items)
            } catch {
                let cancellationRequested = await cancellationState.wasRequested()
                if error is CancellationError || cancellationRequested {
                    if let firstUnfinished = items.firstIndex(where: { !$0.isSaved }) {
                        markItemsCancelled(startingAt: firstUnfinished)
                    }
                    publishItems()
                    engineStore.clearGenerationActivity()
                    return .cancelled(items: items, restartFailedMessage: nil)
                }

                if let activeIndex = items.firstIndex(where: { $0.status == .running || $0.status == .pending }) {
                    items[activeIndex].status = .failed(message: error.localizedDescription)
                }
                publishItems()
                return .failed(items: items, message: error.localizedDescription)
            }
        }

        for (index, line) in request.lines.enumerated() {
            if await cancellationState.wasRequested() {
                markItemsCancelled(startingAt: index)
                publishItems()
                engineStore.clearGenerationActivity()
                return .cancelled(items: items, restartFailedMessage: nil)
            }

            items[index].status = .running
            publishItems()
            publishProgress(activeItemIndex: index, message: "Generating item \(index + 1)/\(total)...")

            let outputPath = makeOutputPath(request.model.outputSubfolder, line)
            do {
                let result = try await generateResult(
                    for: request,
                    line: line,
                    outputPath: outputPath,
                    batchIndex: index + 1,
                    batchTotal: total
                )

                publishProgress(activeItemIndex: index, message: "Saving item \(index + 1)/\(total)...")

                let generation = request.makeHistoryRecord(for: line, result: result)
                let savedGeneration = try await store.saveGeneration(generation)
                // See above: payload-carrying announce so HistoryView
                // appends the new row live.
                generationEvents.announceGenerationAppended(savedGeneration)
                completedCount += 1
                items[index].status = .saved(audioPath: result.audioPath)
                publishItems()
            } catch {
                let cancellationRequested = await cancellationState.wasRequested()
                if error is CancellationError || cancellationRequested {
                    markItemsCancelled(startingAt: index)
                    publishItems()
                    engineStore.clearGenerationActivity()
                    return .cancelled(items: items, restartFailedMessage: nil)
                }

                items[index].status = .failed(message: error.localizedDescription)
                publishItems()
                return .failed(items: items, message: error.localizedDescription)
            }
        }

        if await cancellationState.wasRequested() {
            if let firstUnfinished = items.firstIndex(where: { !$0.isSaved }) {
                markItemsCancelled(startingAt: firstUnfinished)
            }
            publishItems()
            engineStore.clearGenerationActivity()
            return .cancelled(items: items, restartFailedMessage: nil)
        }

        publishProgress(activeItemIndex: nil, message: "Done")
        return .completed(items: items)
    }

    func requestCancellation() async throws {
        await cancellationState.request()
        try await engineStore.cancelActiveGeneration()
    }

    private func runLongForm(
        request: BatchGenerationRequest,
        makeOutputPath: (String, String) -> String,
        onProgress: @escaping @MainActor (BatchProgressSnapshot) -> Void,
        onItemsUpdated: @escaping @MainActor ([BatchGenerationItemState]) -> Void
    ) async -> BatchGenerationOutcome {
        let originalText = request.originalLongFormText ?? request.lines.joined(separator: "\n")
        var items = [
            BatchGenerationItemState(
                index: 0,
                line: originalText,
                segmentationMode: .longForm,
                status: .running
            )
        ]
        onItemsUpdated(items)

        guard let plan = request.longFormPlan else {
            let error = LongFormProductGenerationError.missingPlan
            items[0].status = .failed(message: error.localizedDescription)
            onItemsUpdated(items)
            return .failed(items: items, message: error.localizedDescription)
        }
        guard plan.segments.count == request.lines.count,
              plan.segments.map(\.modelFacingText) == request.lines else {
            let error = LongFormProductGenerationError.planMismatch
            items[0].status = .failed(message: error.localizedDescription)
            onItemsUpdated(items)
            return .failed(items: items, message: error.localizedDescription)
        }

        let total = plan.segments.count
        var completedCount = 0
        var finalOutputURL: URL?
        var historyAccepted = false
        let workspace: LongFormTaskWorkspace

        do {
            workspace = try LongFormTaskWorkspace(rootURL: AppPaths.longFormWorkDir)
        } catch {
            items[0].status = .failed(message: error.localizedDescription)
            onItemsUpdated(items)
            return .failed(items: items, message: error.localizedDescription)
        }

        defer {
            try? workspace.remove()
            if !historyAccepted, let finalOutputURL,
               FileManager.default.fileExists(atPath: finalOutputURL.path) {
                try? FileManager.default.removeItem(at: finalOutputURL)
            }
        }

        func publishProgress(activeIndex: Int?, message: String) {
            onProgress(
                BatchProgressSnapshot(
                    completedCount: completedCount,
                    totalCount: total,
                    activeItemIndex: activeIndex,
                    statusMessage: message,
                    unit: .segments
                )
            )
        }

        do {
            var sources: [LongFormAssemblySegmentSource] = []
            sources.reserveCapacity(total)

            for (index, segment) in plan.segments.enumerated() {
                try Task.checkCancellation()
                if await cancellationState.wasRequested() {
                    throw CancellationError()
                }

                publishProgress(
                    activeIndex: index,
                    message: AppLocalization.format(
                        "Generating segment %lld/%lld...",
                        Int64(index + 1),
                        Int64(total)
                    )
                )
                let segmentURL = workspace.segmentURL(at: index)
                let result = try await generateResult(
                    for: request,
                    line: segment.modelFacingText,
                    outputPath: segmentURL.path,
                    batchIndex: index + 1,
                    batchTotal: total
                )

                guard URL(fileURLWithPath: result.audioPath).standardizedFileURL == segmentURL.standardizedFileURL else {
                    throw LongFormProductGenerationError.unexpectedSegmentOutput(index: index + 1)
                }

                if let finishReason = result.finishReason, finishReason != .eos {
                    throw LongFormProductGenerationError.incompleteSegment(
                        index: index + 1,
                        reason: finishReason
                    )
                }
                let qualityReport = await audioQualityEvaluator(
                    segmentURL,
                    segment.modelFacingText
                )
                guard qualityReport.passed else {
                    throw LongFormProductGenerationError.segmentQuality(
                        index: index + 1,
                        detail: qualityReport.failureSummary
                    )
                }

                sources.append(
                    LongFormAssemblySegmentSource(
                        segmentID: segment.segmentID,
                        lineage: segment.evidence.lineage,
                        audioURL: segmentURL,
                        boundary: segment.evidence.boundary,
                        intendedPauseMilliseconds: segment.evidence.intendedPauseMilliseconds
                    )
                )
                completedCount += 1
                publishProgress(
                    activeIndex: index + 1 < total ? index + 1 : nil,
                    message: AppLocalization.format(
                        "Generated %lld/%lld segments",
                        Int64(completedCount),
                        Int64(total)
                    )
                )
            }

            try Task.checkCancellation()
            if await cancellationState.wasRequested() {
                throw CancellationError()
            }

            publishProgress(activeIndex: nil, message: "Assembling the complete audio...")
            let outputURL = URL(
                fileURLWithPath: makeOutputPath(request.model.outputSubfolder, originalText),
                isDirectory: false
            )
            finalOutputURL = outputURL
            let assembly = try await BoundedLongFormAssembler.assemble(
                segments: sources,
                outputURL: outputURL
            )

            try Task.checkCancellation()
            if await cancellationState.wasRequested() {
                throw CancellationError()
            }

            publishProgress(activeIndex: nil, message: "Saving the complete audio...")
            let duration = Double(assembly.outputFrameCount) / Double(assembly.sampleRate)
            let result = QwenVoiceNative.GenerationResult(
                audioPath: outputURL.path,
                durationSeconds: duration,
                streamSessionDirectory: nil,
                usedStreaming: false,
                finishReason: .eos
            )
            let generation = request.makeHistoryRecord(for: originalText, result: result)
            let savedGeneration = try await store.saveGeneration(generation)
            generationEvents.announceGenerationAppended(savedGeneration)
            historyAccepted = true

            items[0].status = .saved(audioPath: outputURL.path)
            onItemsUpdated(items)
            publishProgress(activeIndex: nil, message: "Done")
            return .completed(items: items)
        } catch {
            let cancellationRequested = await cancellationState.wasRequested()
            if error is CancellationError || cancellationRequested {
                items[0].status = .cancelled
                onItemsUpdated(items)
                engineStore.clearGenerationActivity()
                return .cancelled(items: items, restartFailedMessage: nil)
            }

            items[0].status = .failed(message: error.localizedDescription)
            onItemsUpdated(items)
            return .failed(items: items, message: error.localizedDescription)
        }
    }

    private func generateResult(
        for request: BatchGenerationRequest,
        line: String,
        outputPath: String,
        batchIndex: Int,
        batchTotal: Int
    ) async throws -> QwenVoiceNative.GenerationResult {
        try await engineStore.generate(
            request.makeGenerationRequest(
                for: line,
                outputPath: outputPath,
                batchIndex: batchIndex,
                batchTotal: batchTotal
            )
        )
    }

}

actor BatchGenerationCancellationState {
    private var isRequested = false

    func request() {
        isRequested = true
    }

    func wasRequested() -> Bool {
        isRequested
    }
}
