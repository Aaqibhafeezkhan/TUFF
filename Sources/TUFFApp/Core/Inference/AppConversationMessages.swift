import Foundation
import TUFFEngine

/// The conversation as chat-template messages. A tool round becomes an
/// assistant message carrying its calls, reasoning and any text it wrote,
/// followed by one tool message per result, so every template renders them in
/// its own native format. Nothing is folded into a user message.
enum AppConversationMessages {
    /// Messages for `turns` plus the current message and its rounds.
    /// `finalThinking` says whether a completed turn's reasoning is rendered
    /// back (Harmony, or Qwen with preserved thinking); a tool round's
    /// reasoning is always passed and the template decides, because the
    /// templates keep it for the turn still in progress.
    static func messages(for request: AppGenerationRequest,
                         turns: ArraySlice<AppChatTurn>,
                         finalThinking: Bool) -> [GFTokenizer.Message] {
        var messages: [GFTokenizer.Message] = []
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

    static func roundMessages(_ rounds: [AppToolRound]) -> [GFTokenizer.Message] {
        var messages: [GFTokenizer.Message] = []
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
    static func imageIdentities(for request: AppGenerationRequest,
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

    /// Multimodal messages with the same structure. Images present in
    /// `features` are placed ahead of a user message's text.
    static func multimodalMessages(for request: AppGenerationRequest,
                                   turns: ArraySlice<AppChatTurn>,
                                   features: [UUID: VisionFeatures],
                                   finalThinking: Bool)
        -> (messages: [MultimodalMessage], used: [UUID: VisionFeatures]) {
        var messages: [MultimodalMessage] = []
        var used: [UUID: VisionFeatures] = [:]
        if !request.systemPrompt.isEmpty {
            messages.append(MultimodalMessage(role: .system, content: [.text(request.systemPrompt)]))
        }
        func userMessage(text: String, images: [AppImageAttachment]) -> MultimodalMessage {
            var content: [MultimodalContentPart] = []
            for image in images {
                guard let encoded = features[image.id] else { continue }
                used[image.id] = encoded
                content.append(.image(id: image.id))
            }
            if !text.isEmpty || content.isEmpty { content.append(.text(text)) }
            return MultimodalMessage(role: .user, content: content)
        }
        func rounds(_ rounds: [AppToolRound]) {
            for message in roundMessages(rounds) {
                messages.append(MultimodalMessage(
                    role: message.role,
                    content: (message.content ?? "").isEmpty ? [] : [.text(message.content ?? "")],
                    thinking: message.thinking,
                    toolCalls: message.toolCalls,
                    toolCallID: message.toolCallID,
                    name: message.name))
            }
        }
        for turn in turns {
            messages.append(userMessage(text: turn.prompt, images: turn.images))
            rounds(turn.toolRounds)
            messages.append(MultimodalMessage(role: .assistant, content: [.text(turn.response)],
                                              thinking: finalThinking ? turn.thinking : nil))
        }
        messages.append(userMessage(text: request.prompt, images: request.imageAttachments))
        rounds(request.currentRounds)
        return (messages, used)
    }
}
