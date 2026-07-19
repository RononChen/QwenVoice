import Foundation
import QwenVoiceCore

/// Owns service-side admission for the one generation command that may be in
/// flight across the XPC boundary.
///
/// Admission is deliberately split into three steps:
///
/// 1. `reserve()` claims the service before callers create any generation
///    task, timing entry, or event forwarder.
/// 2. `bind()` installs cancellation and terminal-wait operations while the
///    task is still suspended at `waitUntilOpen(_:)`.
/// 3. `open(_:)` is the only operation that lets model work begin.
///
/// The command owner calls `finish(_:)` only after its task and any event
/// forwarder have terminated. `cancelCurrent()` requests cancellation and
/// waits for the bound task, but intentionally does not release admission;
/// this prevents retirement or a replacement request from racing the command
/// owner's remaining transport cleanup.
public actor ServiceActiveGenerationCoordinator {
    public struct Reservation: Hashable, Sendable {
        fileprivate let id: UUID

        fileprivate init(id: UUID) {
            self.id = id
        }
    }

    private struct Binding: Sendable {
        let cancel: @Sendable () -> Void
        let waitForTermination: @Sendable () async -> Void
    }

    private enum StartDisposition: Equatable {
        case suspended
        case open
        case denied
    }

    private struct ActiveGeneration {
        let reservation: Reservation
        var binding: Binding?
        var startDisposition: StartDisposition = .suspended
        var cancellationRequested = false
        var startWaiters: [CheckedContinuation<Bool, Never>] = []
        var bindingWaiters: [CheckedContinuation<Binding?, Never>] = []
    }

    private var activeGeneration: ActiveGeneration?

    public init() {}

    public var hasActive: Bool {
        activeGeneration != nil
    }

    public var isCancellationRequested: Bool {
        activeGeneration?.cancellationRequested == true
    }

    /// Claims service admission without starting or registering any work.
    public func reserve() throws -> Reservation {
        guard activeGeneration == nil else {
            throw TTSEngineError.generationFailed(
                "The engine is already generating audio. Wait for it to finish or cancel it before starting another generation."
            )
        }
        let reservation = Reservation(id: UUID())
        activeGeneration = ActiveGeneration(reservation: reservation)
        return reservation
    }

    /// Binds cancellation and terminal wait operations before the task gate is
    /// opened. Returns `false` when cancellation arrived during the narrow
    /// reserve-to-bind window; callers must not install transport side effects
    /// or open model work in that case.
    @discardableResult
    public func bind(
        _ reservation: Reservation,
        cancel: @escaping @Sendable () -> Void,
        waitForTermination: @escaping @Sendable () async -> Void
    ) throws -> Bool {
        guard var current = activeGeneration,
              current.reservation == reservation else {
            throw TTSEngineError.generationFailed(
                "The engine-service generation reservation is no longer active."
            )
        }
        guard current.binding == nil else {
            throw TTSEngineError.generationFailed(
                "The engine-service generation reservation was already bound."
            )
        }

        let binding = Binding(
            cancel: cancel,
            waitForTermination: waitForTermination
        )
        current.binding = binding
        let bindingWaiters = current.bindingWaiters
        current.bindingWaiters.removeAll(keepingCapacity: false)

        if current.cancellationRequested {
            current.startDisposition = .denied
            let startWaiters = current.startWaiters
            current.startWaiters.removeAll(keepingCapacity: false)
            activeGeneration = current
            bindingWaiters.forEach { $0.resume(returning: binding) }
            startWaiters.forEach { $0.resume(returning: false) }
            return false
        }

        activeGeneration = current
        bindingWaiters.forEach { $0.resume(returning: binding) }
        return true
    }

    /// Suspends a newly created task until cancellation and terminal waiting
    /// have been durably bound and the command owner explicitly opens it.
    public func waitUntilOpen(_ reservation: Reservation) async -> Bool {
        guard var current = activeGeneration,
              current.reservation == reservation else {
            return false
        }
        switch current.startDisposition {
        case .open:
            return true
        case .denied:
            return false
        case .suspended:
            return await withCheckedContinuation { continuation in
                current.startWaiters.append(continuation)
                activeGeneration = current
            }
        }
    }

    /// Opens the task gate only after a matching reservation has been bound.
    public func open(_ reservation: Reservation) throws {
        guard var current = activeGeneration,
              current.reservation == reservation else {
            throw TTSEngineError.generationFailed(
                "The engine-service generation reservation is no longer active."
            )
        }
        guard current.binding != nil else {
            throw TTSEngineError.generationFailed(
                "The engine-service generation reservation must be bound before it is opened."
            )
        }
        guard current.startDisposition == .suspended else {
            throw CancellationError()
        }

        current.startDisposition = .open
        let waiters = current.startWaiters
        current.startWaiters.removeAll(keepingCapacity: false)
        activeGeneration = current
        waiters.forEach { $0.resume(returning: true) }
    }

    /// Releases admission after the command owner has completed its task and
    /// transport cleanup. Stale finishes cannot release a newer reservation.
    public func finish(_ reservation: Reservation) {
        guard let current = activeGeneration,
              current.reservation == reservation else {
            return
        }
        activeGeneration = nil
        current.startWaiters.forEach { $0.resume(returning: false) }
        current.bindingWaiters.forEach { $0.resume(returning: nil) }
    }

    /// Aborts a reservation whose task could not be bound. This is separate
    /// from normal `finish` only to make the pre-open failure intent explicit.
    public func abort(_ reservation: Reservation) {
        finish(reservation)
    }

    /// Requests cancellation once and waits for the bound task to terminate.
    /// Admission remains owned until the command owner calls `finish(_:)`.
    public func cancelCurrent() async {
        guard var current = activeGeneration else { return }
        let reservation = current.reservation
        let shouldRequestCancellation = !current.cancellationRequested
        current.cancellationRequested = true

        // Before binding, deny the task without allowing any service-side
        // timing or transport setup. Once binding exists, keep the gate
        // suspended: the command owner will install its event subscriber and
        // open the already-cancelled task so the engine can publish its normal
        // terminal event rather than leaving an unstarted subscription behind.
        if current.startDisposition == .suspended, current.binding == nil {
            current.startDisposition = .denied
            let waiters = current.startWaiters
            current.startWaiters.removeAll(keepingCapacity: false)
            activeGeneration = current
            waiters.forEach { $0.resume(returning: false) }
        } else {
            activeGeneration = current
        }

        guard let binding = await bindingForCancellation(of: reservation) else {
            return
        }
        if shouldRequestCancellation {
            binding.cancel()
        }
        await binding.waitForTermination()
    }

    private func bindingForCancellation(
        of reservation: Reservation
    ) async -> Binding? {
        guard var current = activeGeneration,
              current.reservation == reservation else {
            return nil
        }
        if let binding = current.binding {
            return binding
        }
        return await withCheckedContinuation { continuation in
            current.bindingWaiters.append(continuation)
            activeGeneration = current
        }
    }
}
