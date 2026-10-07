import Foundation
import TUFFEngine

public enum ServerPromptCacheMode: String, Sendable, Equatable {
    case off
    case singlePrefix = "single-prefix"
}

// The matcher, entry and miss reasons live in the engine so the app's decode
// service and this server decide reuse the same way.
typealias ServerPromptCacheDomain = ConversationCacheDomain
typealias ServerPromptCacheEntry = ConversationCacheEntry
typealias ServerPromptCacheMissReason = ConversationCacheMissReason
typealias ServerPromptCacheMatch = ConversationCacheMatch

extension ValidatedChatRequest {
    /// A text bridge retains generated reasoning that a fresh template render
    /// can drop. Require an exact rendered prefix for completed thinking turns;
    /// tool results continue the same turn and have their own checked bridge.
    var allowsTextBridge: Bool {
        reasoning == .off && !preserveThinking && reasoningEffort == nil
    }

    /// The request as the conversation cache sees it. A multimodal request
    /// without one identity list per message has none, so it neither
    /// publishes nor matches.
    var conversationTranscript: ConversationTranscript {
        let count = messages.count
        if multimodalMessages == nil, imageIdentities.isEmpty {
            return ConversationTranscript(
                messages: messages, imageIdentities: Array(repeating: [], count: count),
                tools: tools, reasoning: reasoning, reasoningEffort: reasoningEffort,
                harmonyCurrentDate: harmonyCurrentDate, preserveThinking: preserveThinking)
        }
        guard imageIdentities.count == count else {
            return .withoutImageIdentity(
                messages: messages, tools: tools, reasoning: reasoning,
                reasoningEffort: reasoningEffort, harmonyCurrentDate: harmonyCurrentDate,
                preserveThinking: preserveThinking)
        }
        return ConversationTranscript(
            messages: messages, imageIdentities: imageIdentities,
            tools: tools, reasoning: reasoning, reasoningEffort: reasoningEffort,
            harmonyCurrentDate: harmonyCurrentDate, preserveThinking: preserveThinking)
    }
}

/// One retained prefix, matched and published through the engine's
/// conversation cache. The serving session keeps its conversations in a
/// `ConversationStateStore`; this single-entry form remains for callers and
/// tests that exercise the matching rules on their own.
struct ServerPromptCache: Sendable {
    private(set) var entry: ServerPromptCacheEntry?

    var kvBackedTokenIDs: [Int32]? { entry?.kvBackedTokenIDs }
    var inputMessageCount: Int? { entry?.inputMessages.count }

    mutating func invalidate() {
        entry = nil
    }

    static func identities(for request: ValidatedChatRequest) -> [[String]]? {
        request.conversationTranscript.imageIdentities
    }

    mutating func publish(
        domain: ServerPromptCacheDomain,
        request: ValidatedChatRequest,
        content: String,
        thinking: String? = nil,
        calls: [ParsedToolCall],
        result: RawDecodeResult,
        stopStringFiltered: Bool = false
    ) {
        entry = ConversationCache.entry(
            domain: domain, transcript: request.conversationTranscript,
            content: content, thinking: thinking, calls: calls, result: result,
            stopStringFiltered: stopStringFiltered)
    }

    func match(
        domain: ServerPromptCacheDomain,
        request: ValidatedChatRequest,
        renderedPromptIDs: [Int32]?,
        tokenizer: GFTokenizer,
        modelVariant: ModelVariant? = nil
    ) -> ServerPromptCacheMatch {
        let match = ConversationCache.match(
            entry: entry, domain: domain, transcript: request.conversationTranscript,
            renderedPromptIDs: renderedPromptIDs, tokenizer: tokenizer,
            modelVariant: modelVariant, allowsTextBridge: request.allowsTextBridge)
        if match.missReason == .bridgeRenderFailed {
            ServerLog.promptCacheBridgeFailed(error: GFTokenizerError.invalidChatTemplate(
                "tool-result bridge failed to encode"))
        }
        // The single-entry form reported an absent entry as unusable.
        return match.missReason == .noEntry ? .miss(.unusableEntry) : match
    }

    func entryMissReason(domain: ServerPromptCacheDomain,
                         request: ValidatedChatRequest) -> String {
        ConversationCache.entryMissReason(
            entry: entry, domain: domain, transcript: request.conversationTranscript)
    }

    func historyMissReason(entry: ServerPromptCacheEntry,
                           request: ValidatedChatRequest) -> String {
        ConversationCache.historyMissReason(
            entry: entry, transcript: request.conversationTranscript)
    }
}
