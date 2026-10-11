import Foundation
import Testing
@testable import TUFFEngine
@testable import TUFFServerCore

/// What coding agents depend on, checked the way they talk to the server:
/// recorded client requests over real HTTP, against a scripted backend that
/// stands in for the model. Tool call IDs survive the round trip, assistant
/// and tool messages keep their order, arguments come back byte for byte,
/// usage matches what the engine counted, and a history that breaks the tool
/// protocol is refused rather than guessed at. No model is loaded.
@Suite(.serialized) struct ClientToolCallSuiteTests {
    /// Records every request it is given and answers from a script.
    actor RecordingBackend: ServerInferenceBackend {
        private var script: [ServerCompletion]
        private(set) var requests: [ValidatedChatRequest] = []

        init(_ script: [ServerCompletion]) { self.script = script }

        func generate(_ request: ValidatedChatRequest,
                      onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void)
            async throws -> ServerCompletion {
            requests.append(request)
            let next = script.isEmpty
                ? ServerCompletion(content: "Done.", toolCalls: [], finishReason: "stop",
                                   usage: OpenAIUsage(promptTokens: 1, completionTokens: 1,
                                                      totalTokens: 2))
                : script.removeFirst()
            if !next.reasoning.isEmpty { onEvent(.reasoning(next.reasoning)) }
            if !next.content.isEmpty { onEvent(.content(next.content)) }
            for call in next.toolCalls { onEvent(.toolCall(call)) }
            return next
        }
    }

    static func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func post(_ port: Int, _ body: [String: Any]) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The `data:` events of a streamed response, up to `[DONE]`.
    static func events(_ data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard line.hasPrefix("data: "), !line.hasSuffix("[DONE]") else { return nil }
            return try? JSONSerialization.jsonObject(
                with: Data(line.dropFirst(6).utf8)) as? [String: Any]
        }
    }

    /// Tool calls as a client assembles them from streamed deltas.
    static func streamedCalls(_ events: [[String: Any]]) -> [(id: String, name: String, arguments: String)] {
        var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        for event in events {
            let choices = event["choices"] as? [[String: Any]] ?? []
            for delta in choices.compactMap({ $0["delta"] as? [String: Any] }) {
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = call["index"] as? Int ?? 0
                    var entry = calls[index] ?? ("", "", "")
                    if let id = call["id"] as? String { entry.id += id }
                    let function = call["function"] as? [String: Any] ?? [:]
                    if let name = function["name"] as? String { entry.name += name }
                    if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                    calls[index] = entry
                }
            }
        }
        return calls.keys.sorted().map { calls[$0]! }
    }

    static func finishReason(_ events: [[String: Any]]) -> String? {
        events.compactMap { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String }.last
    }

    static func call(_ id: String, _ name: String, _ json: String) throws -> ParsedToolCall {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return ParsedToolCall(id: id, name: name, arguments: value, argumentsJSON: json)
    }

    static func usage(_ prompt: Int, _ completion: Int, cached: Int = 0, reasoning: Int? = nil) -> OpenAIUsage {
        OpenAIUsage(promptTokens: prompt, completionTokens: completion,
                    totalTokens: prompt + completion, cachedTokens: cached,
                    reasoningTokens: reasoning)
    }

    func withServer(_ backend: RecordingBackend, dialect: ChatDialect = .chatml,
                    _ body: (Int) async throws -> Void) async throws {
        let server = TUFFHTTPServer(modelID: "test-model", queueLimit: 2, backend: backend,
                                    chatDialect: dialect)
        let channel = try await server.start(port: 0)
        do {
            try await body(try #require(channel.localAddress?.port))
            try await server.shutdown()
        } catch {
            try? await server.shutdown()
            throw error
        }
    }

    // MARK: Recorded clients

    /// OpenCode's two requests from a real session: the opening turn, then the
    /// turn carrying its tool result. The call the server streams must reach
    /// the client intact, and the result must reach the model under the same
    /// ID, after the call, with the arguments the model wrote.
    @Test(arguments: [ChatDialect.chatml, .gemma, .harmony])
    func aRecordedOpenCodeLoopKeepsIDsOrderAndArguments(dialect: ChatDialect) async throws {
        var initial = try Self.fixture("opencode-1.15.11-initial")
        var followUp = try Self.fixture("opencode-1.15.11-tool-result")
        initial["model"] = "test-model"
        followUp["model"] = "test-model"
        let recorded = try #require(((followUp["messages"] as? [[String: Any]])?[2]["tool_calls"]
            as? [[String: Any]])?.first)
        let id = try #require(recorded["id"] as? String)
        let arguments = try #require((recorded["function"] as? [String: Any])?["arguments"] as? String)
        let backend = RecordingBackend([
            ServerCompletion(content: "", toolCalls: [try Self.call(id, "read", arguments)],
                             finishReason: "tool_calls", usage: Self.usage(1_200, 24)),
        ])
        try await withServer(backend, dialect: dialect) { port in
            let (status, data) = try await Self.post(port, initial)
            #expect(status == 200)
            let events = Self.events(data)
            let calls = Self.streamedCalls(events)
            #expect(calls.count == 1)
            #expect(calls.first?.id == id)
            #expect(calls.first?.name == "read")
            #expect(calls.first?.arguments == arguments)
            #expect(Self.finishReason(events) == "tool_calls")
            // OpenCode asks for usage; it arrives on the final chunk.
            let usage = events.compactMap { $0["usage"] as? [String: Any] }.last
            #expect(usage?["prompt_tokens"] as? Int == 1_200)
            #expect(usage?["completion_tokens"] as? Int == 24)

            let (followStatus, _) = try await Self.post(port, followUp)
            #expect(followStatus == 200)
        }
        let requests = await backend.requests
        #expect(requests.count == 2)
        let messages = try #require(requests.last?.messages)
        #expect(messages.map(\.role) == [.system, .user, .assistant, .tool])
        #expect(messages[2].toolCalls.first?.id == id)
        #expect(messages[2].toolCalls.first?.arguments
            == (try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))))
        #expect(messages[3].toolCallID == id)
        let result = try #require((followUp["messages"] as? [[String: Any]])?[3]["content"] as? String)
        #expect(messages[3].content == result)
    }

    /// Every recorded client's opening request, with all its declared tools,
    /// gets a streamed call it can assemble exactly.
    @Test(arguments: ["opencode-1.15.11-initial", "omp-18.4.12-initial", "dsh-0.1.1-rc.1-initial"])
    func everyRecordedClientAssemblesTheStreamedCall(fixture: String) async throws {
        var body = try Self.fixture(fixture)
        body["model"] = "test-model"
        body["stream"] = true
        let tools = try #require(body["tools"] as? [[String: Any]])
        let name = try #require((tools.first?["function"] as? [String: Any])?["name"] as? String)
        let call = try Self.call("call_recorded_1", name, #"{"value":"ok"}"#)
        let backend = RecordingBackend([
            ServerCompletion(content: "", toolCalls: [call], finishReason: "tool_calls",
                             usage: Self.usage(500, 12)),
        ])
        try await withServer(backend) { port in
            let (status, data) = try await Self.post(port, body)
            #expect(status == 200, "\(String(decoding: data, as: UTF8.self).prefix(300))")
            let events = Self.events(data)
            let calls = Self.streamedCalls(events)
            #expect(calls.count == 1)
            #expect(calls.first?.id == "call_recorded_1")
            #expect(calls.first?.name == name)
            #expect(calls.first?.arguments == #"{"value":"ok"}"#)
            #expect(Self.finishReason(events) == "tool_calls")
        }
        #expect(await backend.requests.first?.tools.count == tools.count)
    }

    /// DeepSeek's harness sends two user messages and 25 tools; the result
    /// still lands after its call under the same ID.
    @Test func aRecordedDeepSeekHarnessResultLandsAfterItsCall() async throws {
        var followUp = try Self.fixture("dsh-0.1.1-rc.1-tool-result")
        followUp["model"] = "test-model"
        let backend = RecordingBackend([])
        try await withServer(backend) { port in
            let (status, _) = try await Self.post(port, followUp)
            #expect(status == 200)
        }
        let request = try #require(await backend.requests.first)
        #expect(request.tools.count == 25)
        let messages = request.messages
        #expect(messages.map(\.role) == [.system, .user, .user, .assistant, .tool])
        let callID = try #require(messages[3].toolCalls.first?.id)
        #expect(messages[4].toolCallID == callID)
    }

    // MARK: Arguments, finish reasons and usage

    static let awkwardArguments =
        #"{"path":"/tmp/é \"quoted\"\nline","n":12,"f":1.5,"nested":{"list":[1,"two",null,true]},"empty":{}}"#

    /// The arguments a client receives are the exact text the model wrote,
    /// streamed or not, and sending them back gives the model the same value.
    @Test(arguments: [false, true])
    func argumentsRoundTripByteForByte(stream: Bool) async throws {
        let call = try Self.call("call_awkward_1", "read", Self.awkwardArguments)
        let backend = RecordingBackend([
            ServerCompletion(content: "", toolCalls: [call], finishReason: "tool_calls",
                             usage: Self.usage(40, 30)),
        ])
        let tool: [String: Any] = ["type": "function", "function": [
            "name": "read", "description": "Read a file",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"]]]]]
        let user: [String: Any] = ["role": "user", "content": "Read it."]
        try await withServer(backend) { port in
            let (status, data) = try await Self.post(port, [
                "model": "test-model", "stream": stream, "tools": [tool], "messages": [user]])
            #expect(status == 200)
            let received: String
            if stream {
                received = try #require(Self.streamedCalls(Self.events(data)).first?.arguments)
            } else {
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let message = try #require((object["choices"] as? [[String: Any]])?.first?["message"]
                    as? [String: Any])
                let function = try #require((message["tool_calls"] as? [[String: Any]])?.first?["function"]
                    as? [String: Any])
                received = try #require(function["arguments"] as? String)
                #expect((object["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
                    == "tool_calls")
            }
            #expect(received == Self.awkwardArguments)

            let (followStatus, _) = try await Self.post(port, [
                "model": "test-model", "tools": [tool], "messages": [
                    user,
                    ["role": "assistant", "content": NSNull(), "tool_calls": [[
                        "id": "call_awkward_1", "type": "function",
                        "function": ["name": "read", "arguments": received]]]],
                    ["role": "tool", "tool_call_id": "call_awkward_1", "content": "ok"],
                ]])
            #expect(followStatus == 200)
        }
        let echoed = try #require(await backend.requests.last?.messages[1].toolCalls.first)
        #expect(echoed.arguments == call.arguments)
    }

    /// Usage is what the engine counted, including reused and reasoning
    /// tokens, in both response shapes.
    @Test(arguments: [false, true])
    func usageMatchesTheEngineCounts(stream: Bool) async throws {
        let backend = RecordingBackend([
            ServerCompletion(content: "Paris.", reasoning: "Capital of France.", toolCalls: [],
                             finishReason: "stop",
                             usage: Self.usage(1_234, 56, cached: 1_200, reasoning: 10)),
        ])
        try await withServer(backend) { port in
            var body: [String: Any] = ["model": "test-model", "stream": stream,
                                       "messages": [["role": "user", "content": "Capital?"]]]
            if stream { body["stream_options"] = ["include_usage": true] }
            let (status, data) = try await Self.post(port, body)
            #expect(status == 200)
            let usage: [String: Any]?
            if stream {
                usage = Self.events(data).compactMap { $0["usage"] as? [String: Any] }.last
            } else {
                usage = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["usage"]
                    as? [String: Any]
            }
            #expect(usage?["prompt_tokens"] as? Int == 1_234)
            #expect(usage?["completion_tokens"] as? Int == 56)
            #expect(usage?["total_tokens"] as? Int == 1_290)
            #expect((usage?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int == 1_200)
            #expect((usage?["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int == 10)
        }
    }

    // MARK: Broken histories

    /// A tool result has to answer the call before it. A client that sends
    /// one under another ID, or with no call at all, gets a 400 and the model
    /// never sees a history it would have to guess about.
    @Test func aToolResultThatAnswersNoCallIsRefused() async throws {
        let backend = RecordingBackend([])
        let tool: [String: Any] = ["type": "function", "function": [
            "name": "read", "parameters": ["type": "object", "properties": [:] as [String: Any]]]]
        let call: [String: Any] = ["role": "assistant", "content": NSNull(), "tool_calls": [[
            "id": "call_a", "type": "function", "function": ["name": "read", "arguments": "{}"]]]]
        let histories: [String: [[String: Any]]] = [
            "wrong id": [["role": "user", "content": "go"], call,
                         ["role": "tool", "tool_call_id": "call_b", "content": "x"]],
            "no call": [["role": "user", "content": "go"],
                        ["role": "tool", "tool_call_id": "call_a", "content": "x"]],
        ]
        try await withServer(backend) { port in
            for (name, messages) in histories {
                let (status, data) = try await Self.post(port, [
                    "model": "test-model", "tools": [tool], "messages": messages])
                #expect(status == 400, "\(name): \(String(decoding: data, as: UTF8.self))")
            }
        }
        #expect(await backend.requests.isEmpty)
    }
}
