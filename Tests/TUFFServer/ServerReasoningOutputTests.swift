import Foundation
import Testing
@testable import TUFFEngine
@testable import TUFFServerCore

/// Emits reasoning, then an answer, as a reasoning model does.
private actor ReasoningServerBackend: ServerInferenceBackend {
    let reasoning: String
    let calls: [ParsedToolCall]

    init(reasoning: String, calls: [ParsedToolCall] = []) {
        self.reasoning = reasoning
        self.calls = calls
    }

    func generate(
        _ request: ValidatedChatRequest,
        onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void
    ) async throws -> ServerCompletion {
        if !reasoning.isEmpty {
            onEvent(.reasoning("Thinking about "))
            onEvent(.reasoning("it."))
        }
        for call in calls { onEvent(.toolCall(call)) }
        if calls.isEmpty { onEvent(.content("Answer.")) }
        return ServerCompletion(
            content: calls.isEmpty ? "Answer." : "",
            reasoning: reasoning,
            toolCalls: calls,
            finishReason: calls.isEmpty ? "stop" : "tool_calls",
            usage: OpenAIUsage(promptTokens: 5, completionTokens: 9, totalTokens: 14,
                               reasoningTokens: reasoning.isEmpty ? nil : 6))
    }
}

@Suite("Reasoning in API responses", .serialized)
struct ServerReasoningOutputTests {
    private func post(_ backend: any ServerInferenceBackend, stream: Bool) async throws -> Data {
        let server = TUFFHTTPServer(modelID: "test-model", queueLimit: 1, backend: backend)
        let channel = try await server.start(port: 0)
        defer { Task { try? await server.shutdown() } }
        let port = try #require(channel.localAddress?.port)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data("""
        {"model":"test-model","messages":[{"role":"user","content":"hi"}],
         "stream":\(stream),"stream_options":{"include_usage":true}}
        """.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return data
    }

    @Test func aNonStreamingResponseCarriesReasoningApart() async throws {
        let data = try await post(ReasoningServerBackend(reasoning: "Thinking about it."), stream: false)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try #require((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        #expect(message["content"] as? String == "Answer.")
        #expect(message["reasoning_content"] as? String == "Thinking about it.")
        let usage = try #require(object["usage"] as? [String: Any])
        let details = try #require(usage["completion_tokens_details"] as? [String: Any])
        #expect(details["reasoning_tokens"] as? Int == 6)
    }

    @Test func aStreamSendsReasoningDeltasBeforeTheAnswer() async throws {
        let text = String(decoding: try await post(
            ReasoningServerBackend(reasoning: "Thinking about it."), stream: true), as: UTF8.self)
        let reasoning = try #require(text.range(of: #""reasoning_content":"Thinking about ""#))
        let answer = try #require(text.range(of: #""content":"Answer.""#))
        #expect(reasoning.lowerBound < answer.lowerBound)
        #expect(text.contains(#""reasoning_tokens":6"#))
        #expect(!text.contains(#""content":"Thinking"#))
    }

    @Test func aToolCallAfterReasoningKeepsItsArgumentsSeparate() async throws {
        let call = ParsedToolCall(id: "call_1", name: "read",
                                  arguments: .object(["path": .string("a.txt")]),
                                  argumentsJSON: #"{"path":"a.txt"}"#)
        let text = String(decoding: try await post(
            ReasoningServerBackend(reasoning: "Thinking about it.", calls: [call]), stream: true),
            as: UTF8.self)
        #expect(text.contains(#""reasoning_content":"it.""#))
        #expect(text.contains(#""finish_reason":"tool_calls""#))
        for line in text.split(separator: "\n") where line.contains("reasoning_content") {
            #expect(!line.contains("a.txt"))
        }
    }

    @Test func withoutReasoningTheResponseIsUnchanged() async throws {
        let data = try await post(ReasoningServerBackend(reasoning: ""), stream: false)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try #require((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        #expect(message["reasoning_content"] == nil)
        let usage = try #require(object["usage"] as? [String: Any])
        #expect(usage["completion_tokens_details"] == nil)
    }

    @Test func promptCacheKeyIsReadAsAPreferenceOnly() throws {
        func decode(_ extra: String) throws -> OpenAIChatRequest {
            try JSONDecoder().decode(OpenAIChatRequest.self, from: Data("""
            {"model":"m","messages":[{"role":"user","content":"x"}],\(extra)}
            """.utf8))
        }
        #expect(try decode(#""prompt_cache_key":"chat-7""#).promptCacheKey == "chat-7")
        #expect(try decode(#""prompt_cache_key":"""#).promptCacheKey == nil)
        // Before 8.0 any value was tolerated; a non-string is still ignored.
        #expect(try decode(#""prompt_cache_key":42"#).promptCacheKey == nil)
        let long = String(repeating: "k", count: 600)
        #expect(try decode("\"prompt_cache_key\":\"\(long)\"").promptCacheKey?.utf8.count == 256)
        let validated = try OpenAIRequestValidator.validate(
            try decode(#""prompt_cache_key":"chat-7""#), modelID: "m")
        #expect(validated.promptCacheKey == "chat-7")
        #expect(validated.conversationTranscript.messages.count == 1)
    }
}
