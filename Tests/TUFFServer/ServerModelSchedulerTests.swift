import Foundation
import Testing
@testable import TUFFServerCore

private actor RouterTestBackend: ServerInferenceBackend {
    func generate(_ request: ValidatedChatRequest,
                  onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void) async throws -> ServerCompletion {
        onEvent(.content("Paris"))
        return ServerCompletion(content: "Paris", toolCalls: [], finishReason: "stop",
            usage: .init(promptTokens: 2, completionTokens: 1, totalTokens: 3))
    }
}

private actor SchedulerLog {
    var entries: [String] = []
    func add(_ value: String) { entries.append(value) }
}

private actor SchedulerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    var waiting: Bool { continuation != nil }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@Suite(.serialized) struct ServerModelSchedulerTests {
    private func settle(_ condition: () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "SchedulerTestTimeout", code: 1)
    }
    private func make(_ log: SchedulerLog, delay: Int = 600, limit: Int = 4,
                      timer: SchedulerGate? = nil) -> ServerModelScheduler {
        ServerModelScheduler(queueLimit: limit, unloadDelaySeconds: { delay },
            loader: { name in await log.add("load \(name)"); return RouterTestBackend() },
            unloader: { name, _ in await log.add("unload \(name)") },
            sleep: { seconds in
                if let timer { await timer.wait() } else { try await Task.sleep(for: .seconds(seconds)) }
            })
    }

    @Test func repeatsReuseAndSwitchReleasesBeforeLoading() async throws {
        let log = SchedulerLog(), scheduler = make(log)
        for _ in 0..<2 { _ = try await scheduler.run(model: "a") { _ in 1 } }
        #expect(await log.entries == ["load a"])
        _ = try await scheduler.run(model: "b") { _ in 1 }
        #expect(await log.entries == ["load a", "unload a", "load b"])
        #expect(await scheduler.unloadIfIdle())
        #expect(await scheduler.residentModel == nil)
        await scheduler.shutdown()
    }

    @Test func immediateUnloadAndReload() async throws {
        let log = SchedulerLog(), scheduler = make(log, delay: 0)
        _ = try await scheduler.run(model: "a") { _ in 1 }
        try await settle { await log.entries.count == 2 }
        _ = try await scheduler.run(model: "a") { _ in 1 }
        try await settle { await log.entries.count == 4 }
        #expect(await log.entries == ["load a", "unload a", "load a", "unload a"])
        await scheduler.shutdown()
    }

    @Test func idleTimerNeverUnloadsAnActiveOrQueuedRequest() async throws {
        let log = SchedulerLog(), timer = SchedulerGate(), first = SchedulerGate(), second = SchedulerGate()
        let scheduler = make(log, delay: 1, timer: timer)
        _ = try await scheduler.run(model: "a") { _ in 1 }
        try await settle { await timer.waiting }
        let active = Task { try await scheduler.run(model: "a") { _ in await first.wait() } }
        try await settle { await first.waiting }
        let queued = Task { try await scheduler.run(model: "a") { _ in await second.wait() } }
        try await settle { await scheduler.queuedCount == 1 }
        await timer.open()
        #expect(await scheduler.unloadIfIdle() == false)
        #expect(await log.entries == ["load a"])
        await first.open()
        try await active.value
        try await settle { await second.waiting }
        #expect(await log.entries == ["load a"])
        await second.open()
        try await queued.value
        try await settle { await scheduler.residentModel == nil }
        await scheduler.shutdown()
    }

    @Test func affinityBypassIsCapped() async throws {
        let log = SchedulerLog(), gate = SchedulerGate(), scheduler = make(log, limit: 16)
        let first = Task { try await scheduler.run(model: "a") { _ in await gate.wait() } }
        try await settle { await gate.waiting }
        var tasks: [Task<Void, Error>] = []
        for (index, model) in ["b", "a", "a", "a", "a"].enumerated() {
            let task = Task { try await scheduler.run(model: model) { _ in await log.add("run \(index)") } }
            tasks.append(task)
            try await settle { await scheduler.queuedCount == index + 1 }
        }
        await gate.open(); try await first.value
        for task in tasks { try await task.value }
        #expect(await log.entries.filter { $0.hasPrefix("run") } == ["run 1", "run 2", "run 3", "run 0", "run 4"])
        await scheduler.shutdown()
    }

    @Test func queueLimitCancellationAndShutdown() async throws {
        let log = SchedulerLog(), gate = SchedulerGate(), scheduler = make(log, limit: 1)
        let active = Task { try await scheduler.run(model: "a") { _ in await gate.wait() } }
        try await settle { await gate.waiting }
        let queued = Task { try await scheduler.run(model: "b") { _ in 1 } }
        try await settle { await scheduler.queuedCount == 1 }
        await #expect(throws: ServerRequestError.queueFull) { try await scheduler.run(model: "c") { _ in 1 } }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await scheduler.queuedCount == 0)
        let shutdownWaiter = Task { try await scheduler.run(model: "b") { _ in 1 } }
        try await settle { await scheduler.queuedCount == 1 }
        await scheduler.shutdown()
        await #expect(throws: CancellationError.self) { try await shutdownWaiter.value }
        #expect(await log.entries == ["load a"])
        await gate.open(); try await active.value
        try await settle { let a = await scheduler.activity; return a.activeRequests == 0 && a.residentModel == nil }
        #expect(await log.entries == ["load a", "unload a"])
        await #expect(throws: CancellationError.self) { try await scheduler.run(model: "a") { _ in 1 } }
    }

    @Test func loadFailureReleasesTheTurn() async throws {
        let scheduler = ServerModelScheduler(queueLimit: 1, unloadDelaySeconds: { 600 }, loader: { name in
            if name == "bad" { throw ServerRequestError.unknownModel }
            return RouterTestBackend()
        })
        await #expect(throws: ServerRequestError.unknownModel) { try await scheduler.run(model: "bad") { _ in 1 } }
        #expect(await scheduler.isActive == false)
        #expect(try await scheduler.run(model: "good") { _ in 42 } == 42)
        await scheduler.shutdown()
        #expect(await scheduler.residentModel == nil)
    }
}
