import Testing
import Foundation
@testable import TUFFEngine

/// The tool-result bridge for ChatML (Qwen) and MiniMax. The cached KV holds
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

    @Test func harmonyHasNoToolResultBridge() async throws {
        let tokenizer = try await Self.fixture("HarmonyTokenizer")
        #expect(throws: GFTokenizerError.self) {
            try tokenizer.encodeToolResultContinuation(
                cachedMessages: Self.cached, assistant: Self.assistant(),
                incomingMessages: Self.cached + [Self.assistant(), Self.result],
                tools: [Self.searchTool])
        }
    }

    /// Harmony's missing bridge is an expected miss, not a template that
    /// disagrees with the cached turn, so it does not reach the server's
    /// bridge-failure log.
    @Test func harmonyToolResultsMissQuietly() async throws {
        let tokenizer = try await Self.fixture("HarmonyTokenizer")
        let domain = ConversationCacheDomain(
            modelID: "gpt-oss", sourceSnapshotHash: nil, runtimeProfileHash: "r",
            maximumContext: 4_096, kvStorage: "fp16", fp16RingEnabled: true,
            templateSHA256: "t")
        func transcript(_ messages: [GFTokenizer.Message]) -> ConversationTranscript {
            ConversationTranscript(messages: messages,
                                   imageIdentities: messages.map { _ in [] },
                                   tools: [Self.searchTool])
        }
        let call = ParsedToolCall(id: "call_1", name: "web_search",
                                  arguments: Self.call.arguments,
                                  argumentsJSON: try Self.call.arguments.encoded())
        let result = RawDecodeResult(
            prefillTokens: 3, cachedPromptTokens: 0, computedPrefillTokens: 3,
            prefillSeconds: 0, newTokens: 1, decodeSeconds: 0, reason: .toolCalls,
            kvPosition: 3, kvBackedTokenIDs: [1, 2, 3], uncommittedBoundaryTokenIDs: [4])
        let entry = ConversationCache.entry(
            domain: domain, transcript: transcript(Self.cached), content: "",
            calls: [call], result: result)
        let match = ConversationCache.match(
            entry: entry, domain: domain,
            transcript: transcript(Self.cached + [Self.assistant(thinking: nil), Self.result]),
            renderedPromptIDs: [9, 9, 9, 9, 9], tokenizer: tokenizer)
        #expect(match.missReason == .unsupportedContinuation, "\(match)")
    }
}
