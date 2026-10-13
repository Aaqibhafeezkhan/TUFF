import Foundation
import Synchronization
import TUFFServerCore
import TUFFDecodeProtocol
import TUFFEngine

/// Runs only in an installed engine helper. Requests stay in the host's HTTP
/// scheduler; this connection owns one model and at most one prepared request.
public final class ServerEngineRPCService: @unchecked Sendable {
    public typealias Loader = @Sendable (ServerEngineLoadRequest) async throws -> any ServerInferenceBackend
    private let input: FileHandle
    private let output: FileHandle
    private let loader: Loader
    private let queue = Queue()
    private let outputLock = NSLock()
    private struct CancellationState {
        var active: (id: UUID, cancel: @Sendable () -> Void)?
        var pending: Set<UUID> = []
    }
    private let cancellation = Mutex(CancellationState())
    private let resolveArchitecture: @Sendable (URL) throws -> ArchConfig
    private let lostTransport = Mutex(false)

    public init(input: FileHandle, output: FileHandle, loader: @escaping Loader,
                resolveArchitecture: @escaping @Sendable (URL) throws -> ArchConfig = {
                    try ManifestReader.resolveArchitecture(directoryURL: $0)
                }) {
        self.input = input
        self.output = output
        self.loader = loader
        self.resolveArchitecture = resolveArchitecture
    }

    public static func production(input: FileHandle, output: FileHandle) -> Self {
        Self(input: input, output: output) { request in
            try await ServerModelSession.load(modelDirectory: URL(fileURLWithPath: request.modelPath),
                maxContext: request.maxContextTokens, promptCacheMode: .singlePrefix,
                retainedConversationBytes: request.retainedConversationBytes,
                runtimeConfiguration: request.runtimeConfiguration,
                integrityPolicy: .sizeCheckTrustedReceipt,
                denseResidencyPolicy: request.denseResidencyPolicy ?? .resident)
        }
    }

    public func run() async {
        DecodeUnixSocket.ignoreSIGPIPEProcessWide()
        startReader()
        let capabilities = DecodeEngineCapabilities(
            architectureIDs: ArchConfig.registeredArchitectures.keys.map(\.rawValue).sorted())
        var negotiated: String?
        var backend: (any ServerInferenceBackend)?
        var prepared: (id: UUID, value: ServerPreparedRequest)?
        while let command = await next(), !lostTransport.withLock({ $0 }) {
            switch command {
            case .hello(let hello):
                guard capabilities.accepts(hello) else {
                    negotiated = nil
                    sendFailure(hello.requestID, ServerRequestError.modelUnavailable("incompatible engine protocol or architecture"))
                    continue
                }
                negotiated = hello.architectureID
                var event = ServerEngineEvent(requestID: hello.requestID, kind: .hello)
                event.capabilities = capabilities
                send(event)
            case .load(let request):
                do {
                    try request.validate()
                    guard let negotiated else {
                        throw ServerRequestError.modelUnavailable("engine handshake required before model load")
                    }
                    let arch = try resolveArchitecture(URL(fileURLWithPath: request.modelPath))
                    guard arch.variant.rawValue == negotiated else {
                        throw ServerRequestError.modelUnavailable("model architecture differs from engine handshake")
                    }
                    prepared = nil
                    backend = nil
                    let loaded = try await perform(request.requestID) { [loader] in try await loader(request) }
                    backend = loaded
                    var event = ServerEngineEvent(requestID: request.requestID, kind: .ready)
                    event.modelVariant = arch.variant.rawValue
                    event.chatDialect = arch.family == .gptOss ? "harmony"
                        : (arch.family == .minimaxM2 ? "minimax" : (arch.family == .gemma4 ? "gemma" : "chatml"))
                    if let concrete = loaded as? ServerModelSession { event.defaultModelID = concrete.defaultModelID }
                    event.visionCapability = loaded.visionCapability
                    send(event)
                } catch { sendFailure(request.requestID, error) }
            case .prepare(let id, let request):
                do {
                    guard let backend else { throw ServerRequestError.modelUnavailable("model is not loaded") }
                    try request.generationConfig.validate()
                    prepared = nil
                    let value = try await perform(id) { try await backend.prepare(request) }
                    prepared = (id, value)
                    var event = ServerEngineEvent(requestID: id, kind: .prepared)
                    event.promptTokenCount = value.promptTokenCount
                    send(event)
                } catch { sendFailure(id, error) }
            case .generate(let id, let preparationID):
                do {
                    guard let backend, let value = prepared, value.id == preparationID else {
                        throw ServerRequestError.modelUnavailable("prepared engine request is missing")
                    }
                    prepared = nil
                    let completion = try await perform(id) { [self] in
                        try await backend.generate(value.value) { progress in
                            var event = ServerEngineEvent(requestID: id, kind: .progress)
                            event.inferenceEvent = progress
                            self.send(event)
                        }
                    }
                    var event = ServerEngineEvent(requestID: id, kind: .completed)
                    event.completion = completion
                    send(event)
                } catch { sendFailure(id, error) }
            case .cancel(let id):
                if prepared?.id == id { prepared = nil }
            case .shutdown:
                return
            }
        }
        prepared = nil
        backend = nil
    }

    private func perform<T: Sendable>(_ id: UUID,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await operation() }
        let preCancelled = cancellation.withLock { state in
            state.active = (id, { task.cancel() })
            return state.pending.remove(id) != nil
        }
        defer { cancellation.withLock { if $0.active?.id == id { $0.active = nil } } }
        if preCancelled || lostTransport.withLock({ $0 }) { task.cancel() }
        let result = try await task.value
        if task.isCancelled { throw CancellationError() }
        return result
    }

    private func startReader() {
        Thread { [self] in
            do {
                while true {
                    let command = try DecodeFrameCodec.read(ServerEngineCommand.self, from: input)
                    if case .cancel(let id) = command {
                        cancellation.withLock {
                            if $0.active?.id == id { $0.active?.cancel() }
                            else if $0.pending.count < 32 { $0.pending.insert(id) }
                        }
                    }
                    if case .shutdown = command {
                        cancellation.withLock { $0.active?.cancel() }
                    }
                    guard queue.append(command) else { break }
                    if case .shutdown = command { return }
                }
            } catch {}
            abortTransport()
        }.start()
    }

    private func next() async -> ServerEngineCommand? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [queue] in
                continuation.resume(returning: queue.next())
            }
        }
    }

    private func sendFailure(_ id: UUID, _ error: Error) {
        var event = ServerEngineEvent(requestID: id, kind: .failed)
        event.cancelled = error is CancellationError
        event.requestError = error as? ServerRequestError
        event.error = error is CancellationError ? "request cancelled" : String(describing: error)
        send(event)
    }

    private func send(_ event: ServerEngineEvent) {
        do {
            let data = try DecodeFrameCodec.encode(event)
            outputLock.lock()
            defer { outputLock.unlock() }
            try output.write(contentsOf: data)
        } catch { abortTransport() }
    }

    private func abortTransport() {
        lostTransport.withLock { $0 = true }
        cancellation.withLock { $0.active?.cancel() }
        queue.close()
    }

    private final class Queue: @unchecked Sendable {
        private let condition = NSCondition()
        private var commands: [ServerEngineCommand] = []
        private var closed = false
        func append(_ command: ServerEngineCommand) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard !closed, commands.count < 32 else { return false }
            commands.append(command)
            condition.signal()
            return true
        }
        func close() {
            condition.lock()
            closed = true
            commands.removeAll()
            condition.broadcast()
            condition.unlock()
        }
        func next() -> ServerEngineCommand? {
            condition.lock()
            defer { condition.unlock() }
            while commands.isEmpty && !closed { condition.wait() }
            return commands.isEmpty ? nil : commands.removeFirst()
        }
    }
}
