import Foundation

public enum MultimodalContentPart: Codable, Sendable, Equatable {
    case text(String)
    case image(id: UUID)
}

/// A continuation turn's content, before image token counts are known.
public enum MultimodalContinuationPart: Sendable, Equatable {
    case text(String)
    case image
}

/// Tokens for a continuation turn. Ranges are relative to this turn, which is
/// also the suffix handed to the runner, so they need no rebasing.
public struct MultimodalContinuationTokens: Sendable, Equatable {
    public let effectiveTokenIDs: [Int32]
    public let embeddingTokenIDs: [Int32]
    public let imageTokenRanges: [Range<Int>]
    package init(effectiveTokenIDs: [Int32], embeddingTokenIDs: [Int32], imageTokenRanges: [Range<Int>]) {
        self.effectiveTokenIDs = effectiveTokenIDs
        self.embeddingTokenIDs = embeddingTokenIDs
        self.imageTokenRanges = imageTokenRanges
    }
}

public struct MultimodalMessage: Codable, Sendable, Equatable {
    public let role: InferenceChatRole
    public let content: [MultimodalContentPart]
    public let thinking: String?
    public let toolCalls: [InferenceToolCall]
    public let toolCallID: String?
    public let name: String?

    public init(role: InferenceChatRole,
                content: [MultimodalContentPart],
                toolCalls: [InferenceToolCall] = [],
                toolCallID: String? = nil,
                name: String? = nil) {
        self.init(
            role: role,
            content: content,
            thinking: nil,
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            name: name)
    }

    public init(role: InferenceChatRole,
                content: [MultimodalContentPart],
                thinking: String?,
                toolCalls: [InferenceToolCall] = [],
                toolCallID: String? = nil,
                name: String? = nil) {
        self.role = role
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }
}
