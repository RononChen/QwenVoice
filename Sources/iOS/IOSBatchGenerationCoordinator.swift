import Foundation
import QwenVoiceCore

@MainActor
final class IOSBatchGenerationCoordinator: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let text: String
        var state: State
        var audioPath: String?
        var errorMessage: String?
        var duration: TimeInterval?

        enum State: Equatable {
            case pending
            case running
            case succeeded
            case failed
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var isCancelling = false
    @Published private(set) var currentIndex: Int? = nil
    @Published var topLevelError: String?

    private var runTask: Task<Void, Never>?

    var didCompleteAll: Bool {
        !items.isEmpty
            && items.allSatisfy { $0.state == .succeeded || $0.state == .failed }
            && !isProcessing
    }

    var successCount: Int {
        items.filter { $0.state == .succeeded }.count
    }

    var failureCount: Int {
        items.filter { $0.state == .failed }.count
    }

    func start(
        lines: [String],
        requestBuilder: @escaping @MainActor (String) -> (request: GenerationRequest, model: TTSModel)?,
        engine: TTSEngineStore
    ) {
        guard !isProcessing else { return }
        let trimmed = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else {
            topLevelError = "Add at least one line to batch."
            return
        }

        items = trimmed.map { Item(id: UUID(), text: $0, state: .pending) }
        isProcessing = true
        isCancelling = false
        topLevelError = nil

        runTask = Task { [weak self] in
            await self?.runBatch(requestBuilder: requestBuilder, engine: engine)
        }
    }

    func cancel() {
        guard isProcessing, !isCancelling else { return }
        isCancelling = true
        runTask?.cancel()
    }

    func reset() {
        runTask?.cancel()
        runTask = nil
        items = []
        isProcessing = false
        isCancelling = false
        currentIndex = nil
        topLevelError = nil
    }

    @MainActor
    private func runBatch(
        requestBuilder: @escaping @MainActor (String) -> (request: GenerationRequest, model: TTSModel)?,
        engine: TTSEngineStore
    ) async {
        defer {
            isProcessing = false
            isCancelling = false
            currentIndex = nil
            runTask = nil
        }

        for index in items.indices {
            if Task.isCancelled || isCancelling {
                markRemainingCancelled(startingAt: index)
                return
            }

            currentIndex = index
            updateState(at: index, to: .running)

            guard let resolved = requestBuilder(items[index].text) else {
                updateState(at: index, to: .failed, error: "Model configuration not found.")
                continue
            }

            do {
                let result = try await engine.generate(resolved.request)
                items[index].audioPath = result.audioPath
                items[index].duration = result.durationSeconds
                updateState(at: index, to: .succeeded)
                persistInBackground(text: items[index].text, model: resolved.model, result: result)
            } catch is CancellationError {
                updateState(at: index, to: .failed, error: "Cancelled")
                markRemainingCancelled(startingAt: index + 1)
                return
            } catch {
                updateState(at: index, to: .failed, error: error.localizedDescription)
            }
        }
    }

    private func updateState(at index: Int, to state: Item.State, error: String? = nil) {
        guard items.indices.contains(index) else { return }
        items[index].state = state
        if let error {
            items[index].errorMessage = error
        }
    }

    private func markRemainingCancelled(startingAt start: Int) {
        guard items.indices.contains(start) else { return }
        for index in start..<items.count where items[index].state == .pending || items[index].state == .running {
            updateState(at: index, to: .failed, error: "Cancelled")
        }
    }

    // Background persistence that mirrors the single-generation flow but
    // intentionally skips the autoplay handoff — batch users want to
    // queue everything and then review takes one at a time from the sheet
    // or History, not have every line start playing on completion.
    private func persistInBackground(
        text: String,
        model: TTSModel,
        result: GenerationResult
    ) {
        let generation = Generation(
            text: text,
            mode: model.mode.rawValue,
            modelTier: model.tier,
            voice: nil,
            emotion: nil,
            speed: nil,
            audioPath: result.audioPath,
            duration: result.durationSeconds,
            createdAt: Date()
        )

        Task.detached {
            do {
                let saved = try await DatabaseService.shared.saveGenerationAsync(generation)
                await MainActor.run {
                    NotificationCenter.default.post(name: .generationSaved, object: nil)
                    _ = saved
                }
            } catch {
                #if DEBUG
                print("[IOSBatchGenerationCoordinator] db_save_failed: \(error.localizedDescription)")
                #endif
            }
        }
    }
}
