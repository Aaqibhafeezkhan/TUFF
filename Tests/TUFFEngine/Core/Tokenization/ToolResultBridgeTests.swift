import Testing
import Foundation
@testable import TUFFEngine

/// The tool-result bridge for ChatML (Qwen), MiniMax and Harmony (GPT-OSS). The cached KV holds
/// the conversation through the assistant's tool call, without the closing
/// end-of-turn token; the bridge must carry on from exactly there so that
/// cached tokens plus bridge equal a full render of the incoming history.
@Suite struct ToolResultBridgeTests {
    private static func fixture(_ name: String) async throws -> GFTokenizer {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try await GFTokenizer.load(from: folder)
    }

    private static let searchTool = GFTokenizer.FunctionDefinition(
        name: "web_search",
        description: "Search the web",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])]),
            "required": .array([.string("query")]),
        ]))

    private static let call = GFTokenizer.HistoricalToolCall(
        id: "call_1", name: "web_search", arguments: .object(["query": .string("swift actors")]))

    private static let cached: [GFTokenizer.Message] = [
        .init(role: .system, content: "Be brief."),
        .init(role: .user, content: "What are Swift actors?"),
    ]

    private static func assistant(thinking: String? = "I should look this up.",
                                  content: String? = nil) -> GFTokenizer.Message {
        GFTokenizer.Message(role: .assistant, content: content, thinking: thinking,
                            toolCalls: [call])
    }

    private static let result = GFTokenizer.Message(
        role: .tool, content: "[1] Actors isolate mutable state.", toolCallID: "call_1",
        name: "web_search")

    /// The KV a generation would hold: the prefix render up to, not including,
    /// the assistant turn's closing token.
    private static func cachedKV(_ tokenizer: GFTokenizer, reasoning: ChatReasoning) throws -> [Int32] {
        let rendered = try tokenizer.encodeToolChat(
            messages: cached + [assistant()], tools: [searchTool], reasoning: reasoning,
            preserveThinking: false, addGenerationPrompt: false)
        let boundary = tokenizer.dialect == .minimax ? tokenizer.eosID : tokenizer.endOfTurnID
        let end = try #require(rendered.lastIndex(of: boundary))
        return Array(rendered[..<end])
    }

    @Test(arguments: ["ChatMLTokenizer", "MiniMaxTokenizer"], [ChatReasoning.off, .on])
    func cachedTokensPlusBridgeEqualTheFullRender(fixture: String,
                                                  reasoning: ChatReasoning) async throws {
        let tokenizer = try await Self.fixture(fixture)
        let incoming = Self.cached + [Self.assistant(), Self.result]
        let bridge = try tokenizer.encodeToolResultContinuation(
            cachedMessages: Self.cached, assistant: Self.assistant(),
            incomingMessages: incoming, tools: [Self.searchTool], reasoning: reasoning)
        let full = try tokenizer.encodeToolChat(
            messages: incoming, tools: [Self.searchTool], reasoning: reasoning,
            preserveThinking: false)
        let kv = try Self.cachedKV(tokenizer, reasoning: reasoning)
        #expect(kv + bridge == full)
        let boundary = tokenizer.dialect == .minimax ? tokenizer.eosID : tokenizer.endOfTurnID
        #expect(bridge.first == boundary)
        // The tool result itself is in the bridge.
        #expect(tokenizer.decode(bridge, skipSpecialTokens: false)
            .contains("Actors isolate mutable state."))
    }

    @Test func aSecondRoundBridgesFromTheLatestCall() async throws {
        let tokenizer = try await Self.fixture("ChatMLTokenizer")
        let secondCall = GFTokenizer.HistoricalToolCall(
            id: "call_2", name: "web_search", arguments: .object(["query": .string("actor reentrancy")]))
        let roundOne = Self.cached + [Self.assistant(), Self.result]
        let second = GFTokenizer.Message(role: .assistant, content: nil,
                                         thinking: "One more search.", toolCalls: [secondCall])
        let secondResult = GFTokenizer.Message(role: .tool, content: "[2] Reentrancy.",
                                               toolCallID: "call_2", name: "web_search")
        let bridge = try tokenizer.encodeToolResultContinuation(
            cachedMessages: roundOne, assistant: second,
            incomingMessages: roundOne + [second, secondResult],
            tools: [Self.searchTool], reasoning: .on)
        #expect(bridge.first == tokenizer.endOfTurnID)
        #expect(tokenizer.decode(bridge, skipSpecialTokens: false).contains("Reentrancy."))
    }

    @Test func assistantTextBeforeTheCallIsPartOfTheBoundary() async throws {
        let tokenizer = try await Self.fixture("ChatMLTokenizer")
        let speaking = Self.assistant(content: "Let me check.")
        let incoming = Self.cached + [speaking, Self.result]
        let bridge = try tokenizer.encodeToolResultContinuation(
            cachedMessages: Self.cached, assistant: speaking,
            incomingMessages: incoming, tools: [Self.searchTool])
        #expect(bridge.first == tokenizer.endOfTurnID)
        // A client that dropped the text sent a different turn.
        #expect(throws: GFTokenizerError.self) {
            try tokenizer.encodeToolResultContinuation(
                cachedMessages: Self.cached, assistant: speaking,
                incomingMessages: Self.cached + [Self.assistant(), Self.result],
                tools: [Self.searchTool])
        }
    }

    @Test func aRewrittenHistoryOrMissingResultIsRefused() async throws {
        let tokenizer = try await Self.fixture("ChatMLTokenizer")
        var rewritten = Self.cached
        rewritten[1] = .init(role: .user, content: "Something else")
        #expect(throws: GFTokenizerError.self) {
            try tokenizer.encodeToolResultContinuation(
                cachedMessages: Self.cached, assistant: Self.assistant(),
                incomingMessages: rewritten + [Self.assistant(), Self.result],
                tools: [Self.searchTool])
        }
        #expect(throws: GFTokenizerError.self) {
            try tokenizer.encodeToolResultContinuation(
                cachedMessages: Self.cached, assistant: Self.assistant(),
                incomingMessages: Self.cached + [Self.assistant(),
                                                 .init(role: .user, content: "no result")],
                tools: [Self.searchTool])
        }
    }

    private static let harmonyDate = "2026-10-09"

    private static func harmonyRender(_ tokenizer: GFTokenizer,
                                      _ messages: [GFTokenizer.Message],
                                      generationPrompt: Bool = true) throws -> [Int32] {
        tokenizer.encode(
            try HarmonyPromptRenderer().render(
                messages: messages, tools: [searchTool], reasoningEffort: .low,
                currentDate: harmonyDate, addGenerationPrompt: generationPrompt),
            addBOS: false)
    }

    /// The KV a GPT-OSS tool call leaves: everything through the call's
    /// arguments, with `<|call|>` withheld as the stop token.
    private static func harmonyKV(_ tokenizer: GFTokenizer,
                                  _ messages: [GFTokenizer.Message]) throws -> [Int32] {
        let rendered = try harmonyRender(tokenizer, messages, generationPrompt: false)
        let call = try #require(tokenizer.harmonyTokenIDs?.call)
        #expect(rendered.last == call)
        return Array(rendered.dropLast())
    }

    private static func harmonyBridge(_ tokenizer: GFTokenizer,
                                      cached: [GFTokenizer.Message],
                                      assistant: GFTokenizer.Message,
                                      incoming: [GFTokenizer.Message]) throws -> [Int32] {
        try tokenizer.encodeToolResultContinuation(
            cachedMessages: cached, assistant: assistant, incomingMessages: incoming,
            tools: [searchTool], reasoningEffort: .low, harmonyCurrentDate: harmonyDate)
    }

    @Test(arguments: [nil, "Let me check."])
    func harmonyCachedTokensPlusBridgeEqualTheFullRender(content: String?) async throws {
        let tokenizer = try await Self.fixture("HarmonyTokenizer")
        let assistant = Self.assistant(content: content)
        let incoming = Self.cached + [assistant, Self.result]
        let bridge = try Self.harmonyBridge(tokenizer, cached: Self.cached,
                                            assistant: assistant, incoming: incoming)
        let kv = try Self.harmonyKV(tokenizer, Self.cached + [assistant])
        #expect(kv + bridge == (try Self.harmonyRender(tokenizer, incoming)))
        #expect(bridge.first == tokenizer.harmonyTokenIDs?.call)
        #expect(tokenizer.decode(bridge, skipSpecialTokens: false)
            .contains("Actors isolate mutable state."))
    }

    /// Each round of an agent loop continues from the latest call. Earlier
    /// calls keep their analysis because no final answer follows them yet.
    @Test func harmonyASecondRoundBridgesFromTheLatestCall() async throws {
        let tokenizer = try await Self.fixture("HarmonyTokenizer")
        let secondCall = GFTokenizer.HistoricalToolCall(
            id: "call_2", name: "web_search", arguments: .object(["query": .string("actor reentrancy")]))
        let roundOne = Self.cached + [Self.assistant(), Self.result]
        let second = GFTokenizer.Message(role: .assistant, content: nil,
                                         thinking: "One more search.", toolCalls: [secondCall])
        let secondResult = GFTokenizer.Message(role: .tool, content: "[2] Reentrancy.",
                                               toolCallID: "call_2", name: "web_search")
        let incoming = roundOne + [second, secondResult]
        let bridge = try Self.harmonyBridge(tokenizer, cached: roundOne,
                                            assistant: second, incoming: incoming)
        let kv = try Self.harmonyKV(tokenizer, roundOne + [second])
        #expect(kv + bridge == (try Self.harmonyRender(tokenizer, incoming)))
        #expect(tokenizer.decode(kv, skipSpecialTokens: false).contains("I should look this up."))
    }

    @Test func harmonyRefusesWhatItCannotBridge() async throws {
        let tokenizer = try await Self.fixture("HarmonyTokenizer")
        let incoming = Self.cached + [Self.assistant(), Self.result]
        // Without the system message's effort and date the render is unknown.
        #expect(throws: GFTokenizerError.self) {
            try tokenizer.encodeToolResultContinuation(
                cachedMessages: Self.cached, assistant: Self.assistant(),
                incomingMessages: incoming, tools: [Self.searchTool])
        }
        // Anything after the result is not a tool-result continuation.
        #expect(throws: GFTokenizerError.self) {
            try Self.harmonyBridge(tokenizer, cached: Self.cached, assistant: Self.assistant(),
                                   incoming: incoming + [.init(role: .user, content: "and?")])
        }
        // A client that changed the call sent a different turn.
        let otherCall = GFTokenizer.Message(
            role: .assistant, content: nil, thinking: nil,
            toolCalls: [.init(id: "call_1", name: "web_search",
                              arguments: .object(["query": .string("swift tasks")]))])
        #expect(throws: GFTokenizerError.self) {
            try Self.harmonyBridge(tokenizer, cached: Self.cached, assistant: Self.assistant(),
                                   incoming: Self.cached + [otherCall, Self.result])
        }
    }

    /// The cache resumes a GPT-OSS tool round from the KV the call left,
    /// and the effective prompt is exactly the cold render.
    @Test func harmonyToolResultsResumeFromTheCache() async throws {
        let tokenizer = try await Self.fixture("HarmonyTokenizer")
        let domain = ConversationCacheDomain(
            modelID: "gpt-oss", sourceSnapshotHash: nil, runtimeProfileHash: "r",
            maximumContext: 4_096, kvStorage: "fp16", fp16RingEnabled: true,
            templateSHA256: "t")
        func transcript(_ messages: [GFTokenizer.Message]) -> ConversationTranscript {
            ConversationTranscript(messages: messages,
                                   imageIdentities: messages.map { _ in [] },
                                   tools: [Self.searchTool], reasoningEffort: .low,
                                   harmonyCurrentDate: Self.harmonyDate)
        }
        let call = ParsedToolCall(id: "call_1", name: "web_search",
                                  arguments: Self.call.arguments,
                                  argumentsJSON: try Self.call.arguments.encoded())
        let kv = try Self.harmonyKV(tokenizer, Self.cached + [Self.assistant()])
        let result = RawDecodeResult(
            prefillTokens: kv.count - 20, cachedPromptTokens: 0,
            computedPrefillTokens: kv.count - 20, prefillSeconds: 0, newTokens: 21,
            decodeSeconds: 0, reason: .toolCalls, kvPosition: kv.count,
            kvBackedTokenIDs: kv,
            uncommittedBoundaryTokenIDs: [try #require(tokenizer.harmonyTokenIDs?.call)])
        let entry = ConversationCache.entry(
            domain: domain, transcript: transcript(Self.cached), content: "",
            thinking: "I should look this up.", calls: [call], result: result)
        // A client that drops the reasoning it was shown still continues.
        let incoming = Self.cached + [Self.assistant(thinking: nil), Self.result]
        let match = ConversationCache.match(
            entry: entry, domain: domain, transcript: transcript(incoming),
            renderedPromptIDs: try Self.harmonyRender(tokenizer, incoming),
            tokenizer: tokenizer)
        guard case .hit(let effective, let cached) = match else {
            Issue.record("expected a hit, got \(match)")
            return
        }
        #expect(cached == kv.count)
        #expect(effective == (try Self.harmonyRender(
            tokenizer, Self.cached + [Self.assistant(), Self.result])))
    }
}
