import Foundation
import TUFFDecodeProtocol
import TUFFRuntimeManagement

public struct ServerEngineRemoteError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// HTTP scheduling and image leases remain in the host. Tokenization, cached
/// runner state, image encoding and generation live in an installed helper.
public actor ProcessBackedServerModelSession: ServerInferenceBackend {
    public nonisolated let visionCapability: String
    private let transport: Transport
    private let installation: InferenceEngineInstallation?
    private let modelDirectory: URL

    private init(transport: Transport, visionCapability: String, installation: InferenceEngineInstallation?, modelDirectory: URL) {
        self.transport = transport
        self.visionCapability = visionCapability
        self.installation = installation
        self.modelDirectory = modelDirectory
    }

    public static func load(executableURL: URL, engineLockFileURL: URL? = nil,
                            architectureID: String, expectedModelID: String? = nil,
                            request: ServerEngineLoadRequest,
                            installation: InferenceEngineInstallation? = nil) async throws -> Self {
        try request.validate()
        let transport = try Transport(executableURL: executableURL, engineLockFileURL: engineLockFileURL)
        do {
            let hello = DecodeEngineHello(architectureID: architectureID, requiredFeatures: ["bounded-retention"])
            try transport.send(.hello(hello))
            let negotiation = try await transport.next(requestID: hello.requestID)
            try requireSuccess(negotiation)
            guard negotiation.kind == .hello, negotiation.capabilities?.accepts(hello) == true else {
                throw ServerEngineRemoteError("inference engine handshake is incompatible")
            }
            try transport.send(.load(request))
            let ready = try await transport.next(requestID: request.requestID)
            try requireSuccess(ready)
            guard ready.kind == .ready, ready.modelVariant == architectureID,
                  expectedModelID == nil || ready.defaultModelID == expectedModelID else {
                throw ServerEngineRemoteError("inference engine loaded an unexpected model")
            }
            return Self(transport: transport, visionCapability: ready.visionCapability ?? "missing", installation: installation,
                modelDirectory: URL(fileURLWithPath: request.modelPath))
        } catch {
            transport.stop()
            throw error
        }
    }

    public func unload() async {
        await Task.detached { [transport] in transport.stop() }.value
        await installation?.release()
    }

    public func prepare(_ request: ValidatedChatRequest) async throws -> ServerPreparedRequest {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try transport.send(.prepare(id, request))
            let event = try await transport.next(requestID: id)
            try Self.requireSuccess(event)
            try Task.checkCancellation()
            guard event.kind == .prepared else { throw ServerEngineRemoteError("unexpected engine preparation response") }
            return ServerPreparedRequest(request: request, remotePreparationID: id,
                                         remotePromptTokenCount: event.promptTokenCount)
        } onCancel: { [transport] in try? transport.send(.cancel(id)) }
    }

    public func generate(_ request: ValidatedChatRequest,
                         onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void) async throws -> ServerCompletion {
        let prepared = try await prepare(request)
        return try await generate(prepared, onEvent: onEvent)
    }

    public func generate(_ prepared: ServerPreparedRequest,
                         onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void) async throws -> ServerCompletion {
        guard let preparationID = prepared.remotePreparationID else {
            throw ServerEngineRemoteError("request was not prepared by the inference helper")
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try transport.send(.generate(id, preparationID: preparationID))
            while true {
                let event = try await transport.next(requestID: id)
                try Self.requireSuccess(event)
                if event.kind == .progress, let progress = event.inferenceEvent {
                    if !Task.isCancelled { onEvent(progress) }
                } else if event.kind == .completed, let completion = event.completion {
                    try Task.checkCancellation()
                    if let installation { await InferenceEngineEnvironment.markKnownGood(installation, for: modelDirectory) }
                    return completion
                } else { throw ServerEngineRemoteError("unexpected inference engine response") }
            }
        } onCancel: { [transport] in try? transport.send(.cancel(id)) }
    }

    private static func requireSuccess(_ event: ServerEngineEvent) throws {
        guard event.kind == .failed else { return }
        if event.cancelled == true { throw CancellationError() }
        if let error = event.requestError { throw error }
        throw ServerEngineRemoteError(event.error ?? "inference engine request failed")
    }

    private final class Transport: @unchecked Sendable {
        private let process: Process
        private let input: FileHandle
        private let output: FileHandle
        private let writeLock = NSLock()
        private let stateLock = NSLock()
        private var stopped = false

        init(executableURL: URL, engineLockFileURL: URL?) throws {
            DecodeUnixSocket.ignoreSIGPIPEProcessWide()
            let incoming = Pipe(), outgoing = Pipe()
            let child = Process()
            child.executableURL = executableURL
            child.arguments = ["--server-rpc"]
            if let engineLockFileURL { child.arguments! += ["--engine-lock", engineLockFileURL.path] }
            child.standardInput = incoming
            child.standardOutput = outgoing
            child.standardError = FileHandle.standardError
            try child.run()
            process = child
            input = incoming.fileHandleForWriting
            output = outgoing.fileHandleForReading
        }

        deinit { stop() }

        func send(_ command: ServerEngineCommand) throws {
            let data = try DecodeFrameCodec.encode(command)
            writeLock.lock()
            defer { writeLock.unlock() }
            try input.write(contentsOf: data)
        }

        func next(requestID: UUID) async throws -> ServerEngineEvent {
            // Independent of the caller's cancellation: image leases remain
            // alive until the helper acknowledges cancellation or exits.
            let event = try await Task.detached(priority: .userInitiated) { [output] in
                try DecodeFrameCodec.read(ServerEngineEvent.self, from: output)
            }.value
            guard event.requestID == requestID else {
                throw ServerEngineRemoteError("inference engine response belongs to a different request")
            }
            return event
        }

        func stop() {
            stateLock.lock()
            guard !stopped else { stateLock.unlock(); return }
            stopped = true
            stateLock.unlock()
            try? send(.shutdown)
            try? input.close()
            if process.isRunning {
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                if process.isRunning, finished.wait(timeout: .now() + 2) == .timedOut {
                    process.terminate()
                }
                process.waitUntilExit()
            }
            try? output.close()
        }
    }
}
