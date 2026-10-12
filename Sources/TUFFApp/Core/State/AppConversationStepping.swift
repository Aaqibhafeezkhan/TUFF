import Foundation

/// Next and previous chat, in the order the sidebar lists them.
public enum AppConversationStepping {
    /// The chat `offset` places from `current`, wrapping at either end. With
    /// no current chat, a step forward opens the first and a step back the
    /// last. Nil when there are no chats.
    public static func target(
        in conversations: [AppConversationRecord],
        from current: UUID?,
        offset: Int
    ) -> AppConversationRecord? {
        guard !conversations.isEmpty else { return nil }
        guard let current, let index = conversations.firstIndex(where: { $0.id == current }) else {
            return offset >= 0 ? conversations.first : conversations.last
        }
        let count = conversations.count
        return conversations[((index + offset) % count + count) % count]
    }
}
