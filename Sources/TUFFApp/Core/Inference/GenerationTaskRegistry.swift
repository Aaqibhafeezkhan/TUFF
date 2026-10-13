import Foundation
import Synchronization

package final class GenerationTaskRegistry: Sendable {
    private struct Entry: Sendable {
        let id: UUID
        var task: Task<Void, Never>?
        var cancellationRequested = false
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex<Entry?>(nil)

    package init() {}

    package func reserve(_ id: UUID) -> Bool {
        state.withLock { entry in
            guard entry == nil else { return false }
            entry = Entry(id: id, task: nil)
            return true
        }
    }

    package func attach(_ task: Task<Void, Never>, to id: UUID) {
        let shouldCancel = state.withLock { entry -> Bool in
            guard entry?.id == id else { return true }
            entry?.task = task
            return entry?.cancellationRequested == true
        }
        if shouldCancel { task.cancel() }
    }

    package func take(_ id: UUID) -> Task<Void, Never>? {
        state.withLock { entry in
            guard entry?.id == id else { return nil }
            // Cancellation does not mean the producer has finished. Retain
            // its reservation until clear() acknowledges all cleanup.
            entry?.cancellationRequested = true
            return entry?.task
        }
    }

    package func takeCurrent() -> Task<Void, Never>? {
        state.withLock { entry in
            entry?.cancellationRequested = true
            return entry?.task
        }
    }

    package func clear(_ id: UUID) {
        let waiters = state.withLock { entry -> [CheckedContinuation<Void, Never>] in
            guard entry?.id == id else { return [] }
            let waiters = entry?.idleWaiters ?? []
            entry = nil
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    package func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let alreadyIdle = state.withLock { entry -> Bool in
                guard entry != nil else { return true }
                entry?.idleWaiters.append(continuation)
                return false
            }
            if alreadyIdle { continuation.resume() }
        }
    }

}
