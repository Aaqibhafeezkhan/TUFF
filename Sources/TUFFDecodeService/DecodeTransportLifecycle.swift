import Foundation

/// Which direction of the app transport stopped working.
enum DecodeTransportLoss: Equatable, Sendable {
    case inputClosed
    case outputFailed
}

/// Losing either direction of the app transport ends the service: nobody can
/// send it a cancel or read what it produces. The first loss cancels the
/// active generation, discards queued commands and refuses any generation that
/// has not started yet. Every transition happens under one lock, so a loss
/// that lands just before a generation registers still cancels it.
final class DecodeTransportLifecycle: @unchecked Sendable {
    private let condition = NSCondition()
    private let commands: DecodeCommandQueue
    private let cancelInference: @Sendable () -> Void
    private var loss: DecodeTransportLoss?
    private var cancelGeneration: (@Sendable () -> Void)?

    init(commands: DecodeCommandQueue,
         cancelInference: @escaping @Sendable () -> Void) {
        self.commands = commands
        self.cancelInference = cancelInference
    }

    var lostTransport: DecodeTransportLoss? {
        condition.lock()
        defer { condition.unlock() }
        return loss
    }

    /// Records the first loss and stops all work. Later calls change nothing
    /// and return false.
    @discardableResult
    func abort(_ reason: DecodeTransportLoss) -> Bool {
        condition.lock()
        guard loss == nil else {
            condition.unlock()
            return false
        }
        loss = reason
        let cancel = cancelGeneration
        cancelGeneration = nil
        condition.broadcast()
        condition.unlock()

        commands.discardAndClose()
        cancel?()
        cancelInference()
        return true
    }

    /// Registers how to cancel a generation that is about to run. After a loss
    /// nothing is registered, `cancel` runs at once, and the result is false.
    @discardableResult
    func attachGeneration(cancel: @escaping @Sendable () -> Void) -> Bool {
        condition.lock()
        guard loss == nil else {
            condition.unlock()
            cancel()
            cancelInference()
            return false
        }
        cancelGeneration = cancel
        condition.unlock()
        return true
    }

    func detachGeneration() {
        condition.lock()
        cancelGeneration = nil
        condition.unlock()
    }

    /// Blocks until a loss is recorded or the deadline passes.
    func waitForLoss(until deadline: Date) -> DecodeTransportLoss? {
        condition.lock()
        defer { condition.unlock() }
        while loss == nil, condition.wait(until: deadline) {}
        return loss
    }
}
