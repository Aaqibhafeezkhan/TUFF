import Foundation
import Testing
import TUFFDecodeProtocol
import TUFFEngine
@testable import TUFFServerCore
@testable import TUFFServerEngine

@Suite(.serialized, .timeLimit(.minutes(1))) struct ServerEngineRPCServiceTests {
    private actor FakeBackend: ServerInferenceBackend {
        nonisolated let visionCapability = "missing"
        func prepare(_ request: ValidatedChatRequest) async throws -> ServerPreparedRequest {
            ServerPreparedRequest(request: request, promptIDs: [1, 2, 3])
        }
        func generate(_ request: ValidatedChatRequest,
                      onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void) async throws -> ServerCompletion {
            onEvent(.reasoning("checking"))
            onEvent(.content("answer"))
            return ServerCompletion(content: "answer", reasoning: "checking", toolCalls: [],
                finishReason: "stop", usage: OpenAIUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5))
        }
    }

    private struct Harness {
        let incoming = Pipe()
        let outgoing = Pipe()
        let service: ServerEngineRPCService
        let task: Task<Void, Never>
        init() {
            let input = incoming.fileHandleForReading, output = outgoing.fileHandleForWriting
            let backend = FakeBackend()
            service = ServerEngineRPCService(input: input, output: output,
                loader: { _ in backend }, resolveArchitecture: { _ in .gemma4_26B_A4B })
            let owned = service
            task = Task { await owned.run() }
        }
        func send(_ command: ServerEngineCommand) throws {
            try incoming.fileHandleForWriting.write(contentsOf: DecodeFrameCodec.encode(command))
        }
        func receive() async throws -> ServerEngineEvent {
            let handle = outgoing.fileHandleForReading
            return try await Task.detached { try DecodeFrameCodec.read(ServerEngineEvent.self, from: handle) }.value
        }
        func stop() async throws {
            try send(.shutdown)
            await task.value
            try incoming.fileHandleForWriting.close()
            try outgoing.fileHandleForReading.close()
        }
    }

    @Test func refusesLoadBeforeHandshake() async throws {
        let harness = Harness()
        let request = ServerEngineLoadRequest(modelPath: "/unused", maxContextTokens: 8192,
            retainedConversationBytes: 0, runtimeConfiguration: .production)
        try harness.send(.load(request))
        let event = try await harness.receive()
        #expect(event.kind == .failed)
        #expect(event.requestID == request.requestID)
        #expect(event.error?.contains("handshake") == true)
        try await harness.stop()
    }

    @Test func preparationAndStreamingCompletionCrossTheProcessProtocol() async throws {
        let harness = Harness()
        let hello = DecodeEngineHello(architectureID: "gemma4-26b-a4b")
        try harness.send(.hello(hello))
        let greeting = try await harness.receive()
        #expect(greeting.capabilities?.accepts(hello) == true)
        let load = ServerEngineLoadRequest(modelPath: "/unused", maxContextTokens: 8192,
            retainedConversationBytes: 0, runtimeConfiguration: .production)
        try harness.send(.load(load))
        #expect(try await harness.receive().kind == .ready)
        let request = ValidatedChatRequest(messages: [.init(role: .user, content: "hello")],
            tools: [], stream: true, includeUsage: true, generationConfig: .init(maxNewTokens: 16),
            maximumCompletionTokens: 16)
        let preparationID = UUID(), generationID = UUID()
        try harness.send(.prepare(preparationID, request))
        let prepared = try await harness.receive()
        #expect(prepared.promptTokenCount == 3)
        try harness.send(.generate(generationID, preparationID: preparationID))
        var events: [ServerInferenceEvent] = []
        var completed: ServerCompletion?
        while completed == nil {
            let event = try await harness.receive()
            #expect(event.requestID == generationID)
            if let progress = event.inferenceEvent { events.append(progress) }
            if event.kind == .failed { Issue.record("engine failed: \(event.error ?? "unknown")"); break }
            completed = event.completion
        }
        #expect(events == [.reasoning("checking"), .content("answer")])
        #expect(completed?.usage.completionTokens == 2)
        try await harness.stop()
    }
}
