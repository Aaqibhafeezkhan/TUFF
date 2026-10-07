import Foundation

/// Swift String equality accepts canonically equivalent Unicode spellings.
/// A KV prefix identifies tokenized bytes, so history comparisons must be
/// stricter when falling back from an exact token-prefix match.
enum ConversationCacheIdentity {
    static func text(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): lhs.utf8.elementsEqual(rhs.utf8)
        default: false
        }
    }

    static func json(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        guard lhs == rhs else { return false }
        switch (lhs, rhs) {
        case (.string(let lhs), .string(let rhs)):
            return text(lhs, rhs)
        case (.array(let lhs), .array(let rhs)):
            return zip(lhs, rhs).allSatisfy { json($0, $1) }
        case (.object(let lhs), .object(let rhs)):
            return zip(lhs.keys.sorted(), rhs.keys.sorted()).allSatisfy { a, b in
                text(a, b) && json(lhs[a]!, rhs[b]!)
            }
        default:
            return true
        }
    }

    static func calls(_ lhs: [GFTokenizer.HistoricalToolCall],
                      _ rhs: [GFTokenizer.HistoricalToolCall]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            text(a.id, b.id) && text(a.name, b.name) && json(a.arguments, b.arguments)
        }
    }

    static func messages(_ lhs: some Collection<GFTokenizer.Message>,
                         _ rhs: some Collection<GFTokenizer.Message>) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.role == b.role && text(a.content, b.content) && text(a.thinking, b.thinking)
                && text(a.toolCallID, b.toolCallID) && text(a.name, b.name)
                && calls(a.toolCalls, b.toolCalls)
        }
    }

    static func tools(_ lhs: [GFTokenizer.FunctionDefinition],
                      _ rhs: [GFTokenizer.FunctionDefinition]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            text(a.name, b.name) && text(a.description, b.description) && json(a.parameters, b.parameters)
        }
    }
}
