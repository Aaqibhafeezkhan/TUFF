import Foundation
import Tokenizers
import Testing
@testable import TUFFEngine

struct TokenizerEncodingCacheTests {
    @Test func dynamicOrUnknownTemplatesAreNeverMemoized() {
        #expect(!TokenizerEncodingCache.permitsTemplateMemoization(nil))
        #expect(!TokenizerEncodingCache.permitsTemplateMemoization("{{ strftime_now('%Y') }}"))
        #expect(!TokenizerEncodingCache.permitsTemplateMemoization("{{ [1, 2] | random }}"))
        #expect(!TokenizerEncodingCache.permitsTemplateMemoization("{{ lipsum() }}"))
        #expect(TokenizerEncodingCache.permitsTemplateMemoization("{{ messages[0].content }}"))
    }
    @Test func exactKeysDoNotMergeUnicodeSpellings() {
        let prefix = String(repeating: "text ", count: 100)
        #expect(TokenizerEncodingCache.textKey(prefix + "é")
                != TokenizerEncodingCache.textKey(prefix + "e\u{301}"))
        let first = identity(messages: [.init(role: .user, content: "é")])
        let second = identity(messages: [.init(role: .user, content: "e\u{301}")])
        #expect(first.key != second.key)
    }

    @Test func hitsPreserveTokensAndTheByteBudgetEvictsOldEntries() throws {
        let cache = TokenizerEncodingCache(budgetBytes: 400, maximumEntries: 2, environment: [:])
        var computations = 0
        func encode(_ text: String) -> [Int32] {
            cache.value(for: Data(text.utf8)) { computations += 1; return [1, 2, 3] }
        }
        #expect(encode("a") == [1, 2, 3])
        #expect(encode("b") == [1, 2, 3])
        _ = encode("a") // A is now newer than B.
        _ = encode("c")
        _ = encode("a")
        #expect(computations == 3)
        _ = encode("b")
        #expect(computations == 4)
        #expect(cache.statistics.bytes <= 400)
        #expect(cache.statistics.entries <= 2)
    }

    @Test func disabledOversizedAndFailedComputationsAreNotRetained() {
        let disabled = TokenizerEncodingCache(environment: ["TUFF_TOKENIZATION_CACHE": "off"])
        _ = disabled.value(for: Data([0])) { [1] }
        #expect(disabled.statistics.entries == 0)
        let cache = TokenizerEncodingCache(budgetBytes: 256, environment: [:])
        _ = cache.value(for: Data(repeating: 1, count: 257)) { [1] }
        #expect(cache.statistics.entries == 0)
        enum Failure: Error { case expected }
        #expect(throws: Failure.self) {
            try cache.value(for: Data([0])) { throw Failure.expected }
        }
        #expect(cache.statistics.entries == 0)
    }

    @Test func structuredKeysIncludeEveryRenderOptionAndJSONNumberType() {
        let messages: [GFTokenizer.Message] = [.init(role: .user, content: "Search")]
        let ordinary = identity(messages: messages).key
        #expect(ordinary != identity(messages: messages, reasoning: .on).key)
        #expect(ordinary != identity(messages: messages, preserveThinking: true).key)
        #expect(ordinary != identity(messages: messages, addGenerationPrompt: false).key)
        #expect(ordinary != identity(messages: messages, extendsSchema: true).key)
        let a = GFTokenizer.FunctionDefinition(name: "a", description: "", parameters: .integer(1))
        let b = GFTokenizer.FunctionDefinition(name: "a", description: "", parameters: .number(1))
        #expect(identity(messages: messages, tools: [a]).key
                != identity(messages: messages, tools: [b]).key)
        #expect(ordinary != identity(messages: [.init(role: .user, content: "Changed")]).key)
    }

    @Test func cachedLongTextMatchesTheUnderlyingTokenizerIncludingBOS() async throws {
        let tok = try await fixtureTokenizer()
        let text = String(repeating: "hello world, repeated history. ", count: 60)
        let expected = tok.tokenizer.encode(text: text, addSpecialTokens: false).map(Int32.init)
        #expect(tok.encode(text, addBOS: false) == expected)
        #expect(tok.encode(text, addBOS: false) == expected)
        #expect(tok.encode(text, addBOS: true) == expected) // ChatML has no BOS.
        #expect(tok.encodingCacheStatistics.hits >= 2)
    }

    @Test func cachedToolRenderMatchesUncachedAndDoesNotAliasChangedHistory() async throws {
        let tok = try await fixtureTokenizer()
        let messages: [GFTokenizer.Message] = [
            .init(role: .system, content: "Be brief."),
            .init(role: .user, content: String(repeating: "history ", count: 200)),
        ]
        let first = try tok.encodeToolChat(messages: messages, tools: [])
        let upstreamMessages: [Tokenizers.Message] = messages.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        let expected = try tok.tokenizer.applyChatTemplate(
            messages: upstreamMessages,
            chatTemplate: nil, addGenerationPrompt: true,
            truncation: false, maxLength: nil, tools: [],
            additionalContext: ["enable_thinking": false, "preserve_thinking": false])
            .map(Int32.init)
        let repeated = try tok.encodeToolChat(messages: messages, tools: [])
        #expect(first == expected)
        #expect(first == repeated)
        #expect(tok.encodingCacheStatistics.hits >= 1)
        var changed = messages
        changed.append(.init(role: .assistant, content: "hello"))
        changed.append(.init(role: .user, content: "next"))
        let next = try tok.encodeToolChat(messages: changed, tools: [])
        #expect(next != first)
        #expect(try tok.encodeToolChat(messages: messages, tools: []) == first)
    }

    @Test func repeatedLongTranscriptEncodingKeepsExactIDs() async throws {
        // Uses the pinned real tokenizer, already needed by TokenizerTests.
        // Timing is evidence only, never a flaky pass/fail threshold or an
        // inference-speed claim. No model weights or GPU inference are used.
        let tok = try await GFTokenizer.load()
        let text = String(repeating: "The lighthouse keeper records a calm sea and a clear sky.\n", count: 600)
        let reference = tok.tokenizer.encode(text: text, addSpecialTokens: false).map(Int32.init)
        #expect(tok.encode(text, addBOS: false) == reference)
        var coldTimes: [Double] = []
        var cachedTimes: [Double] = []
        for repeatIndex in 0..<5 {
            func cold() {
                let start = ContinuousClock.now
                let result = tok.tokenizer.encode(text: text, addSpecialTokens: false).map(Int32.init)
                coldTimes.append(ConversationStateStore.seconds(since: start))
                #expect(result == reference)
            }
            func cached() {
                let start = ContinuousClock.now
                let result = tok.encode(text, addBOS: false)
                cachedTimes.append(ConversationStateStore.seconds(since: start))
                #expect(result == reference)
            }
            if repeatIndex % 2 == 0 { cold(); cached() } else { cached(); cold() }
        }
        print("[tokenization-cache] bytes=\(text.utf8.count) tokens=\(reference.count) "
              + "uncached_seconds=\(coldTimes) cached_seconds=\(cachedTimes)")
    }

    private func fixtureTokenizer() async throws -> GFTokenizer {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ChatMLTokenizer")
        return try await GFTokenizer.load(from: folder)
    }

    private func identity(messages: [GFTokenizer.Message],
                          tools: [GFTokenizer.FunctionDefinition] = [],
                          reasoning: ChatReasoning = .off, preserveThinking: Bool = false,
                          addGenerationPrompt: Bool = true, extendsSchema: Bool = false)
        -> ToolChatEncodingIdentity {
        ToolChatEncodingIdentity(messages: messages, tools: tools, reasoning: reasoning,
                                 preserveThinking: preserveThinking,
                                 addGenerationPrompt: addGenerationPrompt, extendsSchema: extendsSchema)
    }
}
