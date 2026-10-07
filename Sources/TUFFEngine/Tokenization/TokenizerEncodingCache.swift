import Foundation

/// Exact-input CPU memoization. It never joins independently encoded pieces:
/// normalizers and BPE can change tokens at an ordinary text boundary.
/// Each tokenizer instance owns its cache, so model/template identities cannot
/// cross. Keys and token storage are charged against a small fixed budget.
final class TokenizerEncodingCache: @unchecked Sendable {
    struct Statistics: Equatable {
        var hits = 0
        var misses = 0
        var bytes = 0
        var entries = 0
    }

    private struct Entry {
        var tokens: [Int32]
        var bytes: Int
        var used: UInt64
    }

    private let lock = NSLock()
    private let budget: Int
    private let maximumEntries: Int
    private var entries: [Data: Entry] = [:]
    private var counters = Statistics()
    private var clock: UInt64 = 0

    init(budgetBytes: Int = 4 << 20, maximumEntries: Int = 32,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        budget = environment["TUFF_TOKENIZATION_CACHE"] == "off" ? 0 : max(0, budgetBytes)
        self.maximumEntries = max(0, maximumEntries)
    }

    var statistics: Statistics { lock.withLock { counters } }

    func value(for key: Data?, compute: () throws -> [Int32]) rethrows -> [Int32] {
        guard let key, budget > 0, maximumEntries > 0, key.count <= budget / 2 else {
            return try compute()
        }
        if let hit = lock.withLock({ () -> [Int32]? in
            clock &+= 1
            guard var entry = entries[key] else {
                counters.misses += 1
                return nil
            }
            entry.used = clock
            entries[key] = entry
            counters.hits += 1
            return entry.tokens
        }) { return hit }

        // Encoding can be expensive. Other callers may use a cached entry
        // while this one computes; duplicate misses are harmless.
        let tokens = try compute()
        let bytes = key.count + tokens.count * MemoryLayout<Int32>.stride + 128
        guard bytes <= budget else { return tokens }
        lock.withLock {
            if entries[key] != nil { return }
            while !entries.isEmpty,
                  entries.count >= maximumEntries || counters.bytes + bytes > budget {
                let oldest = entries.min { $0.value.used < $1.value.used }!
                counters.bytes -= oldest.value.bytes
                entries.removeValue(forKey: oldest.key)
            }
            clock &+= 1
            entries[key] = Entry(tokens: tokens, bytes: bytes, used: clock)
            counters.bytes += bytes
            counters.entries = entries.count
        }
        return tokens
    }

    static func textKey(_ text: String) -> Data? {
        // Short encodes cost little; avoid their allocation/locking overhead.
        guard text.utf8.count >= 256 else { return nil }
        var key = Data([0])
        key.append(contentsOf: text.utf8)
        return key
    }

    static func permitsTemplateMemoization(_ template: String?) -> Bool {
        // Custom tokenizers may consult a clock or randomness. With no
        // inspectable literal template, or any such built-in present, let
        // the upstream renderer run every time instead of caching its result.
        guard let template else { return false }
        return !["strftime_now", "random", "lipsum"].contains { template.contains($0) }
    }
}

/// JSON bytes preserve the exact Unicode spelling, unlike Swift String's
/// canonical-equivalence equality. Type tags additionally distinguish an
/// integer from a floating-point JSON number: Jinja can render 1 and 1.0
/// differently even though JSONEncoder emits the same number for both.
struct ToolChatEncodingIdentity: Encodable {
    let messages: [GFTokenizer.Message]
    let tools: [GFTokenizer.FunctionDefinition]
    let reasoning: ChatReasoning
    let preserveThinking: Bool
    let addGenerationPrompt: Bool
    let extendsSchema: Bool
    let jsonTypes: [UInt8]

    init(messages: [GFTokenizer.Message], tools: [GFTokenizer.FunctionDefinition],
         reasoning: ChatReasoning, preserveThinking: Bool,
         addGenerationPrompt: Bool, extendsSchema: Bool) {
        self.messages = messages
        self.tools = tools
        self.reasoning = reasoning
        self.preserveThinking = preserveThinking
        self.addGenerationPrompt = addGenerationPrompt
        self.extendsSchema = extendsSchema
        jsonTypes = messages.flatMap { $0.toolCalls.flatMap { Self.types($0.arguments) } }
            + tools.flatMap { Self.types($0.parameters) }
    }

    var key: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(self) else { return nil }
        var key = Data([1])
        key.append(bytes)
        return key
    }

    private static func types(_ value: JSONValue) -> [UInt8] {
        switch value {
        case .object(let values): [0] + values.keys.sorted().flatMap { types(values[$0]!) }
        case .array(let values): [1] + values.flatMap(types)
        case .string: [2]
        case .integer: [3]
        case .unsignedInteger: [4]
        case .decimal: [5]
        case .number: [6]
        case .bool: [7]
        case .null: [8]
        }
    }
}
