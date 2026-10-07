import Foundation
import TUFFEngine
import TUFFAppCore
import TUFFDecodeProtocol

/// The inference operations the decode service drives. `RealInferenceClient`
/// is the production client; tests substitute a fake.
protocol DecodeServiceInference: AppModelLifecycleClient {
    var currentVisionTowerBytes: UInt64? { get }
    func waitUntilIdle() async
}

extension RealInferenceClient: DecodeServiceInference {}

/// The decode service's command loop over one app transport. Commands are
/// read on their own thread so a cancel reaches the client while a generation
/// runs. If either direction of the transport fails, the service cancels its
/// work, releases the session and returns.
final class DecodeService: @unchecked Sendable {
    private let client: any DecodeServiceInference
    private let input: FileHandle
    private let output: FileHandle
    private let commands = DecodeCommandQueue()
    let lifecycle: DecodeTransportLifecycle
    /// Test hook that runs after a generation command is accepted and before
    /// its inference starts.
    private let beforeGenerationStarts: (@Sendable (DecodeTransportLifecycle) -> Void)?

    init(client: any DecodeServiceInference,
         input: FileHandle,
         output: FileHandle,
         beforeGenerationStarts: (@Sendable (DecodeTransportLifecycle) -> Void)? = nil) {
        self.client = client
        self.input = input
        self.output = output
        self.beforeGenerationStarts = beforeGenerationStarts
        lifecycle = DecodeTransportLifecycle(
            commands: commands,
            cancelInference: { [client] in client.cancel() })
    }

    /// Runs until an orderly shutdown (nil) or a transport loss (the loss).
    /// Either way the loaded session is released before this returns.
    func run() async -> DecodeTransportLoss? {
        startInputThread()
        var modelDirectory: URL?
        var loadedOptions: DecodeRuntimeOptions?
        commandLoop: while let command = await nextCommand() {
            guard lifecycle.lostTransport == nil else { break }
            switch command {
            case .load(let request):
                let directory = URL(fileURLWithPath: request.modelPath)
                do {
                    let options = try Self.appRuntimeOptions(request.runtimeOptions)
                    try await client.ensureLoaded(
                        modelDirectory: directory,
                        maxContextTokens: request.maxContextTokens,
                        options: options,
                        forceLogitsHead: request.forceLogitsHead) { _ in }
                    modelDirectory = directory
                    loadedOptions = request.runtimeOptions
                    let memory = AppMemorySampler().sample()
                    send(DecodeServiceEvent(
                        kind: .ready, generationID: request.requestID,
                        currentMemoryBytes: memory, peakMemoryBytes: memory))
                } catch {
                    send(DecodeServiceEvent(
                        kind: .failed, generationID: request.requestID,
                        error: "\(error)"))
                }
            case .generate(let request):
                guard let modelDirectory else {
                    send(DecodeServiceEvent(
                        kind: .failed, generationID: request.generationID,
                        error: "model is not loaded"))
                    continue
                }
                // Prefill is chosen per request, not at load, so it must not be
                // part of this comparison: toggling it and pressing Generate was
                // refused as a mismatched session.
                var comparable = request.runtimeOptions
                comparable.prefillEnabled = loadedOptions?.prefillEnabled
                    ?? comparable.prefillEnabled
                comparable.prefillChunkTokens = loadedOptions?.prefillChunkTokens
                    ?? comparable.prefillChunkTokens
                guard comparable == loadedOptions else {
                    send(DecodeServiceEvent(
                        kind: .failed, generationID: request.generationID,
                        error: "generation runtime options do not match the loaded session"))
                    continue
                }
                await generate(request, modelDirectory: modelDirectory)
            case .cancel:
                break
            case .unload(let requestID):
                await client.unload()
                modelDirectory = nil
                loadedOptions = nil
                send(DecodeServiceEvent(kind: .unloaded, generationID: requestID))
            case .shutdown:
                break commandLoop
            }
        }
        await client.waitUntilIdle()
        await client.unload()
        return lifecycle.lostTransport
    }

    private func startInputThread() {
        let thread = Thread { [input, client, commands, lifecycle] in
            do {
                while true {
                    let command = try DecodeFrameCodec.read(
                        DecodeServiceCommand.self, from: input)
                    if case .cancel = command { client.cancel() }
                    commands.append(command)
                    if case .shutdown = command { break }
                }
            } catch {
                // End of file or a broken frame: the app is gone or no longer
                // speaking the protocol, so nothing it queued may still run.
                lifecycle.abort(.inputClosed)
            }
        }
        thread.name = "TUFF.DecodeService.Input"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func generate(_ request: DecodeGenerationRequest,
                          modelDirectory: URL) async {
        let outbox = DecodeServiceOutbox(
            generationID: request.generationID,
            towerBytes: { [client] in client.currentVisionTowerBytes })
        let writerFinished = DispatchSemaphore(value: 0)
        let writer = Thread { [output, lifecycle] in
            defer { writerFinished.signal() }
            do { try outbox.runWriter(to: output) }
            catch {
                FileHandle.standardError.write(Data("IPC writer failed: \(error)\n".utf8))
                lifecycle.abort(.outputFailed)
            }
        }
        writer.name = "TUFF.DecodeService.Writer"
        writer.qualityOfService = .userInitiated
        writer.start()

        beforeGenerationStarts?(lifecycle)
        let inference = Task { [client, lifecycle] in
            // A loss recorded after this command was dequeued must not start
            // inference. One recorded after this check cancels this task
            // through the registration below, which ends the stream and the
            // client's generation with it.
            guard lifecycle.lostTransport == nil else { throw CancellationError() }
            try Task.checkCancellation()
            let generation = try Self.appGenerationRequest(
                request, modelDirectory: modelDirectory)
            for try await event in client.generate(generation) {
                outbox.publish(event)
            }
        }
        lifecycle.attachGeneration { inference.cancel() }
        do {
            try await inference.value
            outbox.finish()
        } catch {
            outbox.finish(error: error)
        }
        // Ending the stream consumer does not acknowledge the independently
        // running producer. Drain it before another command can reuse or
        // unload the session and release its residency lease.
        await client.waitUntilIdle()
        lifecycle.detachGeneration()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                writerFinished.wait()
                continuation.resume()
            }
        }
    }

    private static func appGenerationRequest(
        _ request: DecodeGenerationRequest,
        modelDirectory: URL
    ) throws -> AppGenerationRequest {
        // The trust boundary: these paths arrive over a socket, and
        // this process opens and hashes whatever they name. Without
        // this, a peer could use the service to report on any file
        // the user can read.
        // History carries its own images now, so the same rule has
        // to cover them: a path that reaches this process is opened
        // and hashed whether it arrived as the current message or as
        // an earlier one.
        let everyAttachment = (request.imageAttachments ?? [])
            + request.history.flatMap { $0.images ?? [] }
        if let outside = everyAttachment.first(where: {
            !AppImageAttachmentStore.contains(URL(fileURLWithPath: $0.path))
        }) {
            throw DecodeServiceError.attachmentOutsideStore(
                path: outside.path)
        }
        let options = try appRuntimeOptions(request.runtimeOptions)
        return AppGenerationRequest(
            modelDirectory: modelDirectory, prompt: request.prompt,
            systemPrompt: request.systemPrompt ?? "",
            assistantPrefix: request.assistantPrefix ?? "",
            history: request.history.map { turn in
                AppChatTurn(
                    prompt: turn.prompt,
                    response: turn.response,
                    thinking: turn.thinking,
                    images: (turn.images ?? []).map {
                        AppImageAttachment(
                            id: $0.id,
                            fileURL: URL(fileURLWithPath: $0.path),
                            displayName: $0.displayName,
                            encodedBytes: $0.encodedBytes,
                            sha256: $0.sha256)
                    },
                    toolRounds: (turn.toolRounds ?? []).map(appToolRound))
            },
            imageAttachments: (request.imageAttachments ?? []).map {
                AppImageAttachment(
                    id: $0.id,
                    fileURL: URL(fileURLWithPath: $0.path),
                    displayName: $0.displayName,
                    encodedBytes: $0.encodedBytes,
                    sha256: $0.sha256)
            },
            maxNewTokens: request.maxNewTokens,
            maxContextTokens: request.maxContextTokens,
            reasoning: ChatReasoning(
                rawValue: request.reasoning.rawValue) ?? .off,
            reasoningEffort: request.reasoningEffort.flatMap {
                GPTOSSReasoningEffort(rawValue: $0.rawValue)
            },
            preserveThinking: request.preserveThinking,
            temperature: request.temperature,
            topK: request.topK,
            topP: request.topP,
            repetitionPenalty: request.repetitionPenalty,
            seed: request.seed,
            runtimeOptions: options,
            tools: request.tools ?? [],
            currentRounds: (request.currentRounds ?? []).map(appToolRound),
            conversationKey: request.conversationKey)
    }

    /// A round as the model reads it. Status and summaries stay in the app;
    /// the service only renders the calls and the result text.
    static func appToolRound(_ round: DecodeToolRound) -> AppToolRound {
        AppToolRound(
            thinking: round.thinking, content: round.content,
            calls: round.calls.map { AppToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) },
            results: round.results.map {
                AppToolResult(callID: $0.callID, name: $0.name, status: .succeeded,
                              modelText: $0.content, summary: "")
            })
    }

    private func nextCommand() async -> DecodeServiceCommand? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [commands] in
                continuation.resume(returning: commands.next())
            }
        }
    }

    /// Writes one event outside a generation. A failed write means the app
    /// can no longer hear the service, which ends it like a closed input.
    private func send(_ event: DecodeServiceEvent) {
        do {
            try output.write(contentsOf: DecodeFrameCodec.encode(event))
        } catch {
            FileHandle.standardError.write(Data("IPC write failed: \(error)\n".utf8))
            lifecycle.abort(.outputFailed)
        }
    }

    static func appRuntimeOptions(_ options: DecodeRuntimeOptions) throws
        -> AppRuntimeOptions {
        guard let cachePolicy = AppExpertCachePolicy(
            rawValue: options.expertCachePolicy) else {
            throw AppInferenceError.invalidRequest(
                "unknown expert cache policy \(options.expertCachePolicy)")
        }
        guard let rdadvisePolicy = AppRDAdvicePolicy(
            rawValue: options.rdadvisePolicy) else {
            throw AppInferenceError.invalidRequest(
                "unknown RDADVISE policy \(options.rdadvisePolicy)")
        }
        guard let modelVerification = AppModelVerification(
            rawValue: options.modelVerification) else {
            throw AppInferenceError.invalidRequest(
                "unknown model verification \(options.modelVerification)")
        }
        // An unknown policy is a request for behaviour that does not exist;
        // absent means the shipped default.
        guard let visionResidencyPolicy = VisionResidencyPolicy(
            rawValue: options.visionResidencyPolicy ?? VisionResidencyPolicy.onDemand.rawValue)
        else {
            throw AppInferenceError.invalidRequest(
                "unknown vision residency policy \(options.visionResidencyPolicy ?? "")")
        }
        let resolved = AppRuntimeOptions(
            expertCacheSlots: options.expertCacheSlots,
            expertCachePolicy: cachePolicy,
            prefillEnabled: options.prefillEnabled,
            prefillChunkTokens: options.prefillChunkTokens,
            rdadvisePolicy: rdadvisePolicy,
            modelVerification: modelVerification,
            visionResidencyPolicy: visionResidencyPolicy)
        try resolved.validate()
        return resolved
    }

}
