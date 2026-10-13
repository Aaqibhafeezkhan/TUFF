public enum InferenceChatRole: String, Codable, Sendable {
        case system, developer, user, assistant, tool
    }

public struct InferenceChatMessage: Codable, Sendable, Equatable {
        public let role: InferenceChatRole
        public let content: String?
        public let thinking: String?
        public let toolCalls: [InferenceToolCall]
        public let toolCallID: String?
        public let name: String?

        public init(role: InferenceChatRole, content: String) {
            self.role = role
            self.content = content
            self.thinking = nil
            self.toolCalls = []
            self.toolCallID = nil
            self.name = nil
        }

        public init(role: InferenceChatRole,
                    content: String?,
                    toolCalls: [InferenceToolCall] = [],
                    toolCallID: String? = nil,
                    name: String? = nil) {
            self.role = role
            self.content = content
            self.thinking = nil
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
            self.name = name
        }

        public init(role: InferenceChatRole,
                    content: String?,
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
