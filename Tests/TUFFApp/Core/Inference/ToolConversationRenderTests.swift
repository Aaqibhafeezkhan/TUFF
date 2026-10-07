import Foundation
import Testing
import TUFFEngine

@testable import TUFFAppCore

/// Tool rounds reach the model through its own template: the call as the
/// assistant's tool call, the result as a tool response, and nothing folded
/// into a user message.
@Suite struct ToolConversationRenderTests {
    private static func chatML() async throws -> GFTokenizer {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TUFFEngine/Core/Tokenization/Fixtures/ChatMLTokenizer")
        return try await GFTokenizer.load(from: folder)
    }

    private static let round = AppToolRound(
        thinking: "I should search.", content: "",
        calls: [AppToolCall(id: "call_7", name: "web_search",
                            arguments: .object(["query": .string("swift actors")]))],
        results: [AppToolResult(callID: "call_7", name: "web_search", status: .succeeded,
                                modelText: "[1] Actors\nhttps://docs.example.org/actors\nIsolation.",
                                summary: "1 result", sourceIDs: [1])])

    private static func request(rounds: [AppToolRound] = [round],
                                capabilities: AppChatCapabilities = .init(web: true))
        -> AppGenerationRequest {
        AppGenerationRequest(modelDirectory: URL(fileURLWithPath: "/tmp/model.gturbo"),
                             prompt: "What are Swift actors?", maxContextTokens: 8_192,
                             tools: AppToolCatalog.definitions(for: capabilities),
                             currentRounds: rounds)
    }

    private static func ordered(_ markers: [String], in text: String) -> Bool {
        var start = text.startIndex
        for marker in markers {
            guard let found = text.range(of: marker, range: start..<text.endIndex) else {
                return false
            }
            start = found.upperBound
        }
        return true
    }

    @Test func qwenRendersNativeCallsAndResponses() async throws {
        let tokenizer = try await Self.chatML()
        let rendered = try RealInferenceSession.renderConversation(
            request: Self.request(), tokenizer: tokenizer, maxContext: 8_192,
            modelVariant: .qwen38FlashNext)
        let text = tokenizer.decode(rendered.tokens, skipSpecialTokens: false)
        #expect(text.contains("<tools>"))
        #expect(text.contains("\"name\": \"web_search\"") || text.contains("\"name\":\"web_search\""))
        #expect(Self.ordered([
            "<|im_start|>user\nWhat are Swift actors?<|im_end|>",
            "<|im_start|>assistant\n<think>\nI should search.\n</think>",
            "<tool_call>\n<function=web_search>\n<parameter=query>\nswift actors\n</parameter>",
            "<|im_start|>user\n<tool_response>\n[1] Actors",
            "</tool_response><|im_end|>",
            "<|im_start|>assistant\n",
        ], in: text))
        // The user's own message carries only what they typed.
        #expect(text.components(separatedBy: "What are Swift actors?").count == 2)
    }

    @Test func gemmaRendersNativeCallsAndResponses() async throws {
        let tokenizer = try await GFTokenizer.load()
        let rendered = try RealInferenceSession.renderConversation(
            request: Self.request(), tokenizer: tokenizer, maxContext: 8_192,
            modelVariant: .gemma4_26B_A4B)
        let text = tokenizer.decode(rendered.tokens, skipSpecialTokens: false)
        #expect(Self.ordered([
            "<|turn>user\nWhat are Swift actors?",
            "<|tool_call>call:web_search{",
            "<tool_call|>",
            "<|tool_response>response:web_search",
            "[1] Actors",
        ], in: text))
        #expect(!text.contains("<|turn>user\n[1] Actors"))
    }

    @Test func aChatWithoutToolsRendersExactlyAsBefore() async throws {
        let tokenizer = try await GFTokenizer.load()
        var plain = Self.request(rounds: [], capabilities: .none)
        plain.systemPrompt = "Be brief."
        plain.history = [AppChatTurn(prompt: "Hi", response: "Hello.")]
        #expect(!plain.usesToolTemplate)
        let rendered = try RealInferenceSession.renderConversation(
            request: plain, tokenizer: tokenizer, maxContext: 8_192,
            modelVariant: .gemma4_26B_A4B)
        let direct = tokenizer.encode(try tokenizer.applyChatTemplate([
            .init(role: .system, content: "Be brief."),
            .init(role: .user, content: "Hi"),
            .init(role: .assistant, content: "Hello."),
            .init(role: .user, content: "What are Swift actors?"),
        ], modelVariant: .gemma4_26B_A4B), addBOS: false)
        #expect(rendered.tokens == direct)
    }

    @Test func historyWithToolRoundsKeepsTheToolTemplateWhenToolsAreOff() async throws {
        let tokenizer = try await Self.chatML()
        var later = Self.request(rounds: [], capabilities: .none)
        later.history = [AppChatTurn(prompt: "What are Swift actors?",
                                     response: "They isolate state [1].",
                                     toolRounds: [Self.round])]
        later.prompt = "Thanks."
        #expect(later.usesToolTemplate)
        let rendered = try RealInferenceSession.renderConversation(
            request: later, tokenizer: tokenizer, maxContext: 8_192,
            modelVariant: .qwen38FlashNext)
        let text = tokenizer.decode(rendered.tokens, skipSpecialTokens: false)
        #expect(!text.contains("<tools>"))
        #expect(Self.ordered(["<tool_call>", "<tool_response>", "They isolate state [1].",
                              "Thanks."], in: text))
    }

    @Test func theCacheTranscriptMatchesTheRenderedMessages() {
        var request = Self.request()
        request.history = [AppChatTurn(prompt: "Earlier", response: "Answer",
                                       toolRounds: [Self.round])]
        let transcript = RealInferenceSession.transcript(for: request,
                                                         modelVariant: .qwen38FlashNext,
                                                         harmonyDate: nil)
        #expect(transcript.imageIdentities?.count == transcript.messages.count)
        #expect(transcript.tools.map(\.name) == ["web_search", "read_webpage"])
        #expect(transcript.messages.filter { $0.role == .tool }.count == 2)
    }

    @Test func textBridgesStayLimitedToOrdinaryTurns() {
        var request = Self.request(rounds: [], capabilities: .none)
        #expect(RealInferenceSession.allowsTextBridge(request))
        request.reasoning = .on
        #expect(!RealInferenceSession.allowsTextBridge(request))
        request.reasoning = .off
        request.assistantPrefix = "Partial"
        #expect(!RealInferenceSession.allowsTextBridge(request))
    }
}

/// A call the length limit cut off is a length stop, not a malformed call.
@Suite struct TruncatedToolCallTests {
    private static func decoder() async throws -> (GFTokenizer, StructuredAssistantDecoder) {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TUFFEngine/Core/Tokenization/Fixtures/ChatMLTokenizer")
        let tokenizer = try await GFTokenizer.load(from: folder)
        return (tokenizer, StructuredAssistantDecoder(tokenizer: tokenizer, allowedTools: ["web_search"]))
    }

    @Test func anOpenCallAtTheLimitIsATruncation() async throws {
        let (tokenizer, decoder) = try await Self.decoder()
        for token in tokenizer.encode("Answer [1].\n\n<tool_call>\n<function=web_search>\n<parameter=query>\nar", addBOS: false) {
            _ = try decoder.consume(tokenID: token, delta: tokenizer.decode([token]))
        }
        #expect(try RealInferenceSession.finish(decoder, reason: .maxTokens))
    }

    @Test func anOpenCallBeforeTheLimitIsMalformed() async throws {
        let (tokenizer, decoder) = try await Self.decoder()
        for token in tokenizer.encode("<tool_call>\n<function=web_search>", addBOS: false) {
            _ = try decoder.consume(tokenID: token, delta: tokenizer.decode([token]))
        }
        #expect(throws: AppInferenceError.malformedToolCall("malformed call")) {
            _ = try RealInferenceSession.finish(decoder, reason: .endOfTurn)
        }
    }

    @Test func aCompleteAnswerFinishesNormally() async throws {
        let (tokenizer, decoder) = try await Self.decoder()
        for token in tokenizer.encode("Plain.", addBOS: false) {
            _ = try decoder.consume(tokenID: token, delta: tokenizer.decode([token]))
        }
        #expect(try !RealInferenceSession.finish(decoder, reason: .maxTokens))
    }
}
