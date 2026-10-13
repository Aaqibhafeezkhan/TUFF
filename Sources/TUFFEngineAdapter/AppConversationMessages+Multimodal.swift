import Foundation
import TUFFEngine
import TUFFAppCore

extension AppConversationMessages {
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
