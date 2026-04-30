import Combine
import Foundation
import QwenVoiceCore
import QwenVoiceNative

@MainActor
final class MacGenerationWarmupCoordinator: ObservableObject {
    struct WarmupRequest: Equatable {
        let mode: GenerationMode
        let modelID: String
    }

    private enum WarmupAction: Equatable {
        case warm
        case transitionFromLoadedModel
    }

    private struct WarmupPlan: Equatable {
        let request: WarmupRequest
        let action: WarmupAction
    }

    private let debounce: Duration
    private let customVoiceDebounce: Duration
    private let modeTransitionDebounce: Duration
    private var pendingTask: Task<Void, Never>?
    private var pendingPlan: WarmupPlan?
    private var dispatchedRequest: WarmupRequest?
    private var completedRequest: WarmupRequest?
    private var revision: UInt64 = 0

    init(
        debounce: Duration = .milliseconds(300),
        customVoiceDebounce: Duration = .milliseconds(100),
        modeTransitionDebounce: Duration = .milliseconds(900)
    ) {
        self.debounce = debounce
        self.customVoiceDebounce = customVoiceDebounce
        self.modeTransitionDebounce = modeTransitionDebounce
    }

    func scheduleWarmupIfNeeded(
        mode: GenerationMode?,
        modelID: String?,
        isModelAvailable: Bool,
        snapshot: TTSEngineSnapshot,
        ttsEngineStore: TTSEngineStore
    ) {
        guard let mode,
              let modelID,
              isModelAvailable,
              snapshot.isReady else {
            cancelPendingWarmup()
            return
        }

        let request = WarmupRequest(mode: mode, modelID: modelID)
        guard let action = warmupAction(snapshot: snapshot, request: request) else {
            cancelPendingWarmup()
            return
        }
        guard completedRequest != request else {
            cancelPendingWarmup()
            return
        }
        guard dispatchedRequest == nil else {
            cancelPendingWarmup()
            return
        }
        let plan = WarmupPlan(request: request, action: action)
        guard pendingPlan != plan else { return }

        revision += 1
        let scheduledRevision = revision
        let debounce = debounce(for: plan)
        pendingPlan = plan
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self, weak ttsEngineStore] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self,
                  let ttsEngineStore,
                  !Task.isCancelled,
                  self.revision == scheduledRevision,
                  self.pendingPlan == plan,
                  self.dispatchedRequest == nil,
                  ttsEngineStore.snapshot.isReady,
                  self.warmupAction(
                    snapshot: ttsEngineStore.snapshot,
                    request: plan.request
                  ) == plan.action else {
                return
            }

            self.pendingPlan = nil
            self.dispatchedRequest = plan.request
            defer {
                if self.dispatchedRequest == plan.request {
                    self.dispatchedRequest = nil
                }
            }

            switch plan.action {
            case .warm:
                await self.performWarmup(
                    for: plan.request,
                    ttsEngineStore: ttsEngineStore
                )
            case .transitionFromLoadedModel:
                do {
                    try await ttsEngineStore.unloadModel()
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.revision == scheduledRevision,
                      self.pendingPlan == nil,
                      ttsEngineStore.snapshot.isReady,
                      self.warmupAction(
                        snapshot: ttsEngineStore.snapshot,
                        request: plan.request
                      ) == .warm else {
                    return
                }
                await self.performWarmup(
                    for: plan.request,
                    ttsEngineStore: ttsEngineStore
                )
            }

            if case .loaded(let loadedModelID) = ttsEngineStore.snapshot.loadState,
               loadedModelID == plan.request.modelID {
                self.completedRequest = plan.request
            }
        }
    }

    func cancelPendingWarmup() {
        revision += 1
        pendingTask?.cancel()
        pendingTask = nil
        pendingPlan = nil
    }

    func observe(snapshot: TTSEngineSnapshot) {
        if !shouldAllowAnyNavigationWarmup(snapshot: snapshot) {
            cancelPendingWarmup()
        }

        switch snapshot.loadState {
        case .idle:
            dispatchedRequest = nil
            completedRequest = nil
        case .loaded(let modelID):
            dispatchedRequest = nil
            if completedRequest?.modelID != modelID {
                completedRequest = nil
            }
        case .failed:
            dispatchedRequest = nil
            completedRequest = nil
        case .starting, .running:
            completedRequest = nil
            break
        }
    }

    private func warmupAction(
        snapshot: TTSEngineSnapshot,
        request: WarmupRequest
    ) -> WarmupAction? {
        switch snapshot.loadState {
        case .idle:
            return .warm
        case .loaded(let modelID):
            if modelID == request.modelID {
                return request.mode == .custom ? .warm : nil
            }
            return .transitionFromLoadedModel
        case .failed, .running, .starting:
            return nil
        }
    }

    private func shouldAllowAnyNavigationWarmup(snapshot: TTSEngineSnapshot) -> Bool {
        switch snapshot.loadState {
        case .idle, .loaded:
            return true
        case .failed, .running, .starting:
            return false
        }
    }

    private func debounce(for plan: WarmupPlan) -> Duration {
        switch plan.action {
        case .transitionFromLoadedModel:
            return modeTransitionDebounce
        case .warm:
            return plan.request.mode == .custom ? customVoiceDebounce : debounce
        }
    }

    private func performWarmup(
        for request: WarmupRequest,
        ttsEngineStore: TTSEngineStore
    ) async {
        if let prewarmRequest = interactivePrewarmRequest(for: request) {
            _ = await ttsEngineStore.prefetchInteractiveReadinessIfNeeded(for: prewarmRequest)
        } else {
            await ttsEngineStore.ensureModelLoadedIfNeeded(id: request.modelID)
        }
    }

    private func interactivePrewarmRequest(for request: WarmupRequest) -> GenerationRequest? {
        guard request.mode == .custom else { return nil }
        return GenerationRequest(
            modelID: request.modelID,
            text: QwenVoiceCore.GenerationSemantics.canonicalCustomWarmText,
            outputPath: "",
            shouldStream: true,
            streamingInterval: QwenVoiceCore.GenerationSemantics.appStreamingInterval,
            payload: .custom(
                speakerID: QwenVoiceCore.GenerationSemantics.canonicalCustomWarmSpeaker,
                deliveryStyle: QwenVoiceCore.GenerationSemantics.canonicalCustomWarmInstruction()
            )
        )
    }
}
