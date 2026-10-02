import Foundation

/// What the scheduler is doing, for status endpoints and the app.
public struct ServerSchedulerActivity: Equatable, Sendable {
    public var activeRequests: Int
    public var queuedRequests: Int
    /// The model in memory, if any.
    public var residentModel: String?
    /// Set while a model is being loaded or unloaded.
    public var transition: String?
    /// When an idle model will be unloaded, if a timer is running.
    public var idleUnloadDeadline: Date?

    public init(activeRequests: Int = 0, queuedRequests: Int = 0,
                residentModel: String? = nil, transition: String? = nil,
                idleUnloadDeadline: Date? = nil) {
        self.activeRequests = activeRequests
        self.queuedRequests = queuedRequests
        self.residentModel = residentModel
        self.transition = transition
        self.idleUnloadDeadline = idleUnloadDeadline
    }
}

/// Runs one generation at a time across any number of models, loading a model
/// only when a request for it reaches the front, and unloading it after it has
/// been idle for the configured delay.
///
/// Rules this type guarantees:
/// - A model is never unloaded while a request is running or waiting. The
///   idle timer only starts when the queue is empty and nothing is running,
///   and every new request cancels it.
/// - At most one model is resident. Switching unloads the current model
///   before the next one loads, so two large models are never in memory
///   together.
/// - Requests for the resident model go first, so a mixed queue does not
///   reload models back and forth, but a request for another model is passed
///   over at most `maximumBypass` times before it is served.
public actor ServerModelScheduler {
    public typealias Loader = @Sendable (String) async throws -> any ServerInferenceBackend
    public typealias Unloader = @Sendable (String, any ServerInferenceBackend) async -> Void

    private struct Waiter {
        let id: UUID
        let model: String
        let continuation: CheckedContinuation<Void, Error>
        var bypassed = 0
    }

    public static let defaultMaximumBypass = 3

    private let queueLimit: Int
    private let maximumBypass: Int
    private let loader: Loader
    private let unloader: Unloader
    private let unloadDelaySeconds: @Sendable () -> Int
    private let onActivity: @Sendable (ServerSchedulerActivity) -> Void
    private let sleep: @Sendable (Int) async throws -> Void

    private var admittedCount = 0
    private var active = false
    private var waiters: [Waiter] = []
    private var resident: (id: String, backend: any ServerInferenceBackend)?
    private var transition: String?
    private var idleTask: Task<Void, Never>?
    private var idleDeadline: Date?
    private var shuttingDown = false
    /// The slot is held by an unload rather than a request.
    private var holdingForUnload = false
    /// Increments whenever the idle timer is replaced, so a timer that wakes
    /// after being superseded does nothing.
    private var idleGeneration: UInt64 = 0

    public init(queueLimit: Int,
                maximumBypass: Int = ServerModelScheduler.defaultMaximumBypass,
                unloadDelaySeconds: @escaping @Sendable () -> Int,
                loader: @escaping Loader,
                unloader: @escaping Unloader = { _, _ in },
                onActivity: @escaping @Sendable (ServerSchedulerActivity) -> Void = { _ in },
                sleep: @escaping @Sendable (Int) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                }) {
        self.queueLimit = queueLimit
        self.maximumBypass = maximumBypass
        self.unloadDelaySeconds = unloadDelaySeconds
        self.loader = loader
        self.unloader = unloader
        self.onActivity = onActivity
        self.sleep = sleep
    }

    /// Waits for a turn, makes `model` resident, then runs `body` with it.
    public func run<T: Sendable>(
        model: String,
        onQueued: @escaping @Sendable () -> Void = {},
        _ body: @escaping @Sendable (any ServerInferenceBackend) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        // Same admission rule as the single-model coordinator: one running
        // plus `queueLimit` waiting.
        guard admittedCount <= queueLimit else { throw ServerRequestError.queueFull }
        admittedCount += 1
        defer { admittedCount -= 1 }

        try await acquire(model: model, onQueued: onQueued)
        defer { release() }
        let backend = try await makeResident(model)
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        return try await body(backend)
    }

    /// Unloads the resident model if nothing is running or queued. Returns
    /// whether the server is now free of model memory.
    @discardableResult
    public func unloadIfIdle() async -> Bool {
        guard !active, waiters.isEmpty, !shuttingDown else {
            return resident == nil && !active
        }
        guard resident != nil else { return true }
        cancelIdleTimer()
        active = true
        holdingForUnload = true
        await unloadResident()
        holdingForUnload = false
        release()
        return true
    }

    public func shutdown() async {
        shuttingDown = true
        cancelIdleTimer()
        let queued = waiters
        waiters.removeAll()
        for waiter in queued { waiter.continuation.resume(throwing: CancellationError()) }
        if !active, resident != nil {
            active = true
            holdingForUnload = true
            await unloadResident()
            holdingForUnload = false
            active = false
        }
        publish()
    }

    public var activity: ServerSchedulerActivity { snapshot() }
    public var queuedCount: Int { waiters.count }
    public var isActive: Bool { active }
    public var residentModel: String? { resident?.id }

    // MARK: - Turns

    private func acquire(model: String, onQueued: @escaping @Sendable () -> Void) async throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        cancelIdleTimer()
        if !active {
            active = true
            publish()
            return
        }
        guard waiters.count < queueLimit else { throw ServerRequestError.queueFull }
        onQueued()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, model: model, continuation: continuation))
                publish()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        if !active && waiters.isEmpty { scheduleIdleUnload() }
        publish()
    }

    /// Hands the slot to the next waiter, or starts the idle timer.
    private func release() {
        if let index = nextWaiterIndex() {
            waiters.remove(at: index).continuation.resume()
        } else {
            active = false
            if shuttingDown {
                active = true
                holdingForUnload = true
                Task {
                    await unloadResident()
                    holdingForUnload = false
                    active = false
                    publish()
                }
            } else {
                scheduleIdleUnload()
            }
        }
        publish()
    }

    /// The oldest request, unless the resident model has a waiting request
    /// and every request ahead of it may still be passed over.
    func nextWaiterIndex() -> Int? {
        guard !waiters.isEmpty else { return nil }
        guard let residentID = resident?.id, waiters[0].model != residentID,
              let preferred = waiters.firstIndex(where: { $0.model == residentID })
        else { return 0 }
        let passedOver = waiters[..<preferred].indices
        guard passedOver.allSatisfy({ waiters[$0].bypassed < maximumBypass }) else { return 0 }
        for index in passedOver { waiters[index].bypassed += 1 }
        return preferred
    }

    // MARK: - Residency

    private func makeResident(_ model: String) async throws -> any ServerInferenceBackend {
        if let resident, resident.id == model { return resident.backend }
        if resident != nil { await unloadResident() }
        transition = "loading \(model)"
        publish()
        defer {
            transition = nil
            publish()
        }
        let backend = try await loader(model)
        resident = (model, backend)
        return backend
    }

    private func unloadResident() async {
        guard let current = resident else { return }
        transition = "unloading \(current.id)"
        resident = nil
        publish()
        await unloader(current.id, current.backend)
        transition = nil
        publish()
    }

    private func scheduleIdleUnload() {
        cancelIdleTimer()
        guard resident != nil, !shuttingDown else { return }
        let delay = max(0, unloadDelaySeconds())
        idleGeneration &+= 1
        let generation = idleGeneration
        idleDeadline = Date().addingTimeInterval(TimeInterval(delay))
        let sleep = self.sleep
        idleTask = Task { [weak self] in
            if delay > 0 {
                do { try await sleep(delay) } catch { return }
            }
            await self?.idleTimerFired(generation: generation)
        }
    }

    private func cancelIdleTimer() {
        idleGeneration &+= 1
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
    }

    private func idleTimerFired(generation: UInt64) async {
        guard generation == idleGeneration, !active, waiters.isEmpty,
              !shuttingDown, resident != nil else { return }
        idleTask = nil
        idleDeadline = nil
        // Hold the slot while unloading: a request that arrives now waits
        // and then loads the model again rather than racing the unload.
        active = true
        holdingForUnload = true
        await unloadResident()
        holdingForUnload = false
        release()
    }

    private func snapshot() -> ServerSchedulerActivity {
        ServerSchedulerActivity(
            activeRequests: active && !holdingForUnload ? 1 : 0,
            queuedRequests: waiters.count,
            residentModel: resident?.id,
            transition: transition,
            idleUnloadDeadline: idleDeadline)
    }

    private func publish() { onActivity(snapshot()) }
}
