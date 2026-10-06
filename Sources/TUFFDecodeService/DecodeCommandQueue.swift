import Foundation
import TUFFDecodeProtocol

final class DecodeCommandQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var commands: [DecodeServiceCommand] = []
    private var closed = false

    func append(_ command: DecodeServiceCommand) {
        condition.lock()
        defer { condition.unlock() }
        // After the transport is gone nothing may queue more work.
        guard !closed else { return }
        commands.append(command)
        condition.signal()
    }

    /// Drops every queued command and wakes the reader with nil. Commands that
    /// arrived before the transport was lost must not run once nobody can
    /// receive their output.
    func discardAndClose() {
        condition.lock()
        closed = true
        commands.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    func next() -> DecodeServiceCommand? {
        condition.lock()
        defer { condition.unlock() }
        while commands.isEmpty && !closed { condition.wait() }
        guard !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }
}
