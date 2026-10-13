import Foundation
import TUFFInferenceTypes

/// The conversation as chat-template messages. A tool round becomes an
/// assistant message carrying its calls, reasoning and any text it wrote,
/// followed by one tool message per result, so every template renders them in
/// its own native format. Nothing is folded into a user message.
package enum AppConversationMessages {
    /// Messages for `turns` plus the current message and its rounds.
    /// `finalThinking` says whether a completed turn's reasoning is rendered
    /// back (Harmony, or Qwen with preserved thinking); a tool round's
    /// reasoning is always passed and the template decides, because the
    /// templates keep it for the turn still in progress.
    package static func messages(for request: AppGenerationRequest,
                         turns: ArraySlice<AppChatTurn>,
                         finalThinking: Bool) -> [InferenceChatMessage] {
        var messages: [InferenceChatMessage] = []
        messages.reserveCapacity(turns.count * 2 + 2)
        if !request.systemPrompt.isEmpty {
            messages.append(.init(role: .system, content: request.systemPrompt))
        }
        for turn in turns {
            messages.append(.init(role: .user, content: turn.prompt))
            messages.append(contentsOf: roundMessages(turn.toolRounds))
            messages.append(.init(role: .assistant, content: turn.response,
                                  thinking: finalThinking ? turn.thinking : nil))
        }
        messages.append(.init(role: .user, content: request.prompt))
        messages.append(contentsOf: roundMessages(request.currentRounds))
        return messages
    }

    package static func roundMessages(_ rounds: [AppToolRound]) -> [InferenceChatMessage] {
        var messages: [InferenceChatMessage] = []
        for round in rounds where round.isComplete {
            messages.append(.init(role: .assistant,
                                  content: round.content.isEmpty ? nil : round.content,
                                  thinking: round.thinking,
                                  toolCalls: round.calls.map(\.historical)))
            for result in round.results {
                messages.append(.init(role: .tool, content: result.modelText,
                                      toolCallID: result.callID, name: result.name))
            }
        }
        return messages
    }

    /// Content SHA-256 of each message's images, aligned with `messages`.
    package static func imageIdentities(for request: AppGenerationRequest,
                                turns: ArraySlice<AppChatTurn>) -> [[String]] {
        var identities: [[String]] = []
        if !request.systemPrompt.isEmpty { identities.append([]) }
        for turn in turns {
            identities.append(turn.images.map(\.sha256))
            for round in turn.toolRounds where round.isComplete {
                identities.append([])
                identities.append(contentsOf: round.results.map { _ in [] })
            }
            identities.append([])
        }
        identities.append(request.imageAttachments.map(\.sha256))
        for round in request.currentRounds where round.isComplete {
            identities.append([])
            identities.append(contentsOf: round.results.map { _ in [] })
        }
        return identities
    }

}
