import Foundation
import Testing
import TUFFEngine
@testable import TUFFAppCore
@testable import TUFFDecodeService
import TUFFDecodeProtocol

/// Transport loss in the decode service, driven over real pipes with a fake
/// inference client. Ordering is established with semaphores and the
/// service's own lifecycle, not with sleeps.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DecodeServiceTransportTests {
    // MARK: Fakes

    /// Opens once; a waiter that arrives after it opened returns at once.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let waiter = waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    /// Mirrors `RealInferenceClient`: one generation task per stream, ended by
    /// `cancel()` or by the consumer going away.
    private final class FakeInference: DecodeServiceInference, @unchecked Sendable {
        enum Behavior { case finish, waitForCancel, waitForCancelAndCleanup }

        private let lock = NSLock()
        private var behaviors: [Behavior]
        private let generationTasks = GenerationTaskRegistry()
        private var counts = (loads: 0, unloads: 0, generates: 0, cancels: 0,
                              cancelled: 0, completed: 0, producing: 0,
                              unloadsWhileProducing: 0)
        let started = DispatchSemaphore(value: 0)
        let cancellationObserved = DispatchSemaphore(value: 0)
        let idleWaitStarted = DispatchSemaphore(value: 0)
        let cleanupMayFinish = Gate()

        init(_ behaviors: [Behavior] = []) {
            self.behaviors = behaviors
        }

        var currentVisionTowerBytes: UInt64? { nil }
        var loads: Int { lock.withLock { counts.loads } }
        var unloads: Int { lock.withLock { counts.unloads } }
        var generates: Int { lock.withLock { counts.generates } }
        var cancelled: Int { lock.withLock { counts.cancelled } }
        var completed: Int { lock.withLock { counts.completed } }
        var producing: Int { lock.withLock { counts.producing } }
        var unloadsWhileProducing: Int { lock.withLock { counts.unloadsWhileProducing } }

        func ensureLoaded(modelDirectory: URL, maxContextTokens: Int,
                          options: AppRuntimeOptions, forceLogitsHead: Bool,
                          onState: @escaping @Sendable (AppModelLoadState) -> Void) async throws {
            lock.withLock { counts.loads += 1 }
        }

        func unload() async {
            lock.withLock {
                counts.unloads += 1
                if counts.producing > 0 { counts.unloadsWhileProducing += 1 }
            }
        }

        func waitUntilIdle() async {
            idleWaitStarted.signal()
            await generationTasks.waitUntilIdle()
        }

        func generate(_ request: AppGenerationRequest)
            -> AsyncThrowingStream<AppInferenceEvent, Error> {
            AsyncThrowingStream { continuation in
                let id = UUID()
                guard generationTasks.reserve(id) else {
                    continuation.finish(throwing: AppInferenceError.generationInFlight)
                    return
                }
                let behavior = lock.withLock { () -> Behavior in
                    counts.generates += 1
                    counts.producing += 1
                    return behaviors.isEmpty ? .finish : behaviors.removeFirst()
                }
                let task = Task { [self] in
                    defer {
                        lock.withLock { counts.producing -= 1 }
                        generationTasks.clear(id)
                    }
                    started.signal()
                    switch behavior {
                    case .finish:
                        continuation.yield(.token(AppTokenEvent(
                            index: 0, textDelta: "done", elapsedDecodeSeconds: 0.1)))
                        continuation.yield(.finished(Self.diagnostics(.eos)))
                        lock.withLock { counts.completed += 1 }
                    case .waitForCancel, .waitForCancelAndCleanup:
                        let gate = Gate()
                        await withTaskCancellationHandler {
                            await gate.wait()
                        } onCancel: {
                            gate.open()
                        }
                        lock.withLock { counts.cancelled += 1 }
                        cancellationObserved.signal()
                        if case .waitForCancelAndCleanup = behavior {
                            await cleanupMayFinish.wait()
                        }
                        continuation.yield(.cancelled(Self.diagnostics(.cancelled)))
                    }
                    continuation.finish()
                }
                generationTasks.attach(task, to: id)
                continuation.onTermination = { [generationTasks] _ in
                    generationTasks.take(id)?.cancel()
                }
            }
        }

        func cancel() {
            lock.withLock { counts.cancels += 1 }
            generationTasks.takeCurrent()?.cancel()
        }

        static func diagnostics(_ reason: AppStopReason) -> AppDiagnostics {
            AppDiagnostics(
                generatedTokens: 1,
                stopReason: reason,
                timeToFirstTokenSeconds: nil,
                decodeSeconds: 0,
                tokensPerSecond: 0,
                peakMemoryBytes: nil,
                runtimeOptions: AppRuntimeOptions())
        }
    }

    /// Reads every frame the service writes until the pipe closes.
    private final class EventCollector: @unchecked Sendable {
        private let condition = NSCondition()
        private var events: [DecodeServiceEvent] = []

        init(reading handle: FileHandle) {
            let thread = Thread { [self] in
                while let event = try? DecodeFrameCodec.read(
                    DecodeServiceEvent.self, from: handle) {
                    condition.lock()
                    events.append(event)
                    condition.broadcast()
                    condition.unlock()
                }
            }
            thread.start()
        }

        /// Waits off the cooperative pool until `count` events of `kind` arrived.
        func wait(for kind: DecodeServiceEventKind, count: Int = 1) async -> Bool {
            await DecodeServiceTransportTests.offPool { [self] in
                let deadline = Date().addingTimeInterval(20)
                condition.lock()
                defer { condition.unlock() }
                while events.filter({ $0.kind == kind }).count < count {
                    guard condition.wait(until: deadline) else { return false }
                }
                return true
            }
        }

        var terminalKinds: [DecodeServiceEventKind] {
            condition.lock()
            defer { condition.unlock() }
            return events.map(\.kind).filter {
                [.finished, .cancelled, .failed].contains($0)
            }
        }
    }

    private struct Transport {
        let input = Pipe()
        let output = Pipe()

        init() {
            DecodeUnixSocket.disableSIGPIPE(on: output.fileHandleForWriting.fileDescriptor)
        }

        func send(_ command: DecodeServiceCommand) throws {
            try input.fileHandleForWriting.write(contentsOf: DecodeFrameCodec.encode(command))
        }

        func closeInput() {
            try? input.fileHandleForWriting.close()
        }

        func closeOutputWriter() {
            try? output.fileHandleForWriting.close()
        }
    }

    private static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    private static func waitForStart(_ fake: FakeInference) async -> Bool {
        await offPool { fake.started.wait(timeout: .now() + 20) == .success }
    }

    private static let load = DecodeServiceCommand.load(DecodeLoadRequest(
        modelPath: "/tmp/tuff-fake-model", maxContextTokens: 1_024))

    private static func generate() -> DecodeServiceCommand {
        .generate(DecodeGenerationRequest(
            prompt: "hello", maxNewTokens: 4, maxContextTokens: 1_024,
            temperature: 0))
    }

    private static func start(_ service: DecodeService) -> Task<DecodeTransportLoss?, Never> {
        Task { await service.run() }
    }

    // MARK: Transport loss

    @Test func inputEOFCancelsTheActiveGeneration() async throws {
        let transport = Transport()
        let fake = FakeInference([.waitForCancel])
        let service = DecodeService(
            client: fake,
            input: transport.input.fileHandleForReading,
            output: transport.output.fileHandleForWriting)
        let events = EventCollector(reading: transport.output.fileHandleForReading)
        let run = Self.start(service)

        try transport.send(Self.load)
        #expect(await events.wait(for: .ready))
        try transport.send(Self.generate())
        #expect(await Self.waitForStart(fake))
        transport.closeInput()

        #expect(await run.value == .inputClosed)
        #expect(fake.cancelled == 1)
        #expect(fake.completed == 0)
        #expect(fake.unloads == 1)
        transport.closeOutputWriter()
    }

    @Test func aDisconnectJustBeforeRegistrationNeverStartsInference() async throws {
        let transport = Transport()
        let fake = FakeInference([.waitForCancel])
        let service = DecodeService(
            client: fake,
            input: transport.input.fileHandleForReading,
            output: transport.output.fileHandleForWriting,
            beforeGenerationStarts: { lifecycle in
                // The input thread sees EOF and records the loss after the
                // command was accepted but before inference starts.
                transport.closeInput()
                _ = lifecycle.waitForLoss(until: Date().addingTimeInterval(20))
            })
        let events = EventCollector(reading: transport.output.fileHandleForReading)
        let run = Self.start(service)

        try transport.send(Self.load)
        #expect(await events.wait(for: .ready))
        try transport.send(Self.generate())

        #expect(await run.value == .inputClosed)
        #expect(fake.generates == 0)
        #expect(fake.unloads == 1)
        transport.closeOutputWriter()
    }

    @Test func disconnectDrainsTheProducerBeforeUnloading() async throws {
        let transport = Transport()
        let fake = FakeInference([.waitForCancelAndCleanup])
        let service = DecodeService(
            client: fake,
            input: transport.input.fileHandleForReading,
            output: transport.output.fileHandleForWriting)
        let events = EventCollector(reading: transport.output.fileHandleForReading)
        let run = Self.start(service)

        try transport.send(Self.load)
        #expect(await events.wait(for: .ready))
        try transport.send(Self.generate())
        #expect(await Self.waitForStart(fake))
        transport.closeInput()

        #expect(await Self.offPool {
            fake.cancellationObserved.wait(timeout: .now() + 20) == .success
        })
        #expect(await Self.offPool {
            fake.idleWaitStarted.wait(timeout: .now() + 20) == .success
        })
        // The cancelled consumer has ended, but its producer is deliberately
        // still draining. Neither unload nor service completion may pass it.
        #expect(fake.producing == 1)
        #expect(fake.unloads == 0)
        fake.cleanupMayFinish.open()

        #expect(await run.value == .inputClosed)
        #expect(fake.producing == 0)
        #expect(fake.unloads == 1)
        #expect(fake.unloadsWhileProducing == 0)
        transport.closeOutputWriter()
    }

    @Test func aFailedOutputCancelsTheActiveGeneration() async throws {
        let transport = Transport()
        let fake = FakeInference([.waitForCancel])
        let service = DecodeService(
            client: fake,
            input: transport.input.fileHandleForReading,
            output: transport.output.fileHandleForWriting)
        let run = Self.start(service)

        try transport.send(Self.load)
        let ready = await Self.offPool {
            try? DecodeFrameCodec.read(
                DecodeServiceEvent.self, from: transport.output.fileHandleForReading)
        }
        #expect(ready?.kind == .ready)
        try transport.send(Self.generate())
        #expect(await Self.waitForStart(fake))
        // The writer's next frame now fails with EPIPE.
        try transport.output.fileHandleForReading.close()

        #expect(await run.value == .outputFailed)
        #expect(fake.cancelled == 1)
        #expect(fake.completed == 0)
        #expect(fake.unloads == 1)
        transport.closeInput()
    }

    @Test func aFailedOutputOutsideAGenerationDiscardsQueuedWork() async throws {
        let transport = Transport()
        let fake = FakeInference()
        try transport.output.fileHandleForReading.close()
        let service = DecodeService(
            client: fake,
            input: transport.input.fileHandleForReading,
            output: transport.output.fileHandleForWriting)
        // Queued before the service runs, so both are waiting when the ready
        // frame fails to write.
        try transport.send(Self.load)
        try transport.send(Self.generate())

        #expect(await Self.start(service).value == .outputFailed)
        #expect(fake.loads == 1)
        #expect(fake.generates == 0)
        #expect(fake.unloads == 1)
        transport.closeInput()
    }

    @Test func generationsQueuedBeforeADisconnectNeverRun() async throws {
        let transport = Transport()
        let fake = FakeInference([.waitForCancel, .finish])
        let service = DecodeService(
            client: fake,
            input: transport.input.fileHandleForReading,
            output: transport.output.fileHandleForWriting)
        let events = EventCollector(reading: transport.output.fileHandleForReading)
        let run = Self.start(service)

        try transport.send(Self.load)
        #expect(await events.wait(for: .ready))
        try transport.send(Self.generate())
        #expect(await Self.waitForStart(fake))
        // The single input thread queues this before it reads the EOF.
        try transport.send(Self.generate())
        transport.closeInput()

        #expect(await run.value == .inputClosed)
        #expect(fake.generates == 1)
        #expect(fake.cancelled == 1)
        #expect(fake.completed == 0)
        transport.closeOutputWriter()
    }

    // MARK: Orderly paths

    @Test func explicitCancelCompletionAndShutdownAreUnchanged() async throws {
        let transport = Transport()
        let fake = FakeInference([.waitForCancel, .finish])
        let service = DecodeService(
            client: fake,
            input: transport.input.fileHandleForReading,
            output: transport.output.fileHandleForWriting)
        let events = EventCollector(reading: transport.output.fileHandleForReading)
        let run = Self.start(service)

        try transport.send(Self.load)
        #expect(await events.wait(for: .ready))
        try transport.send(Self.generate())
        #expect(await Self.waitForStart(fake))
        try transport.send(.cancel)
        #expect(await events.wait(for: .cancelled))

        try transport.send(Self.generate())
        #expect(await events.wait(for: .finished))
        try transport.send(.shutdown)

        #expect(await run.value == nil)
        #expect(service.lifecycle.lostTransport == nil)
        #expect(fake.generates == 2)
        #expect(fake.cancelled == 1)
        #expect(fake.completed == 1)
        #expect(fake.unloads == 1)
        #expect(events.terminalKinds == [.cancelled, .finished])
        transport.closeInput()
        transport.closeOutputWriter()
    }

    // MARK: Lifecycle

    @Test func abortCancelsTheAttachedGenerationOnce() {
        let commands = DecodeCommandQueue()
        let inferenceCancels = Counter()
        let generationCancels = Counter()
        let lifecycle = DecodeTransportLifecycle(
            commands: commands, cancelInference: { inferenceCancels.increment() })
        commands.append(.cancel)
        #expect(lifecycle.attachGeneration { generationCancels.increment() })

        #expect(lifecycle.abort(.inputClosed))
        #expect(!lifecycle.abort(.outputFailed))
        #expect(lifecycle.lostTransport == .inputClosed)
        #expect(generationCancels.value == 1)
        #expect(inferenceCancels.value == 1)
        #expect(commands.next() == nil)
    }

    @Test func nothingStartsOrQueuesAfterAbort() {
        let commands = DecodeCommandQueue()
        let inferenceCancels = Counter()
        let generationCancels = Counter()
        let lifecycle = DecodeTransportLifecycle(
            commands: commands, cancelInference: { inferenceCancels.increment() })
        lifecycle.abort(.outputFailed)

        #expect(!lifecycle.attachGeneration { generationCancels.increment() })
        #expect(generationCancels.value == 1)
        #expect(inferenceCancels.value == 2)
        commands.append(.shutdown)
        #expect(commands.next() == nil)
        #expect(lifecycle.waitForLoss(until: Date()) == .outputFailed)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
