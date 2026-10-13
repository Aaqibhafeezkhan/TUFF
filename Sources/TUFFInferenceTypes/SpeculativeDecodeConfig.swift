public enum SpeculativeDecodeMode: String, Codable, Sendable, Equatable {
    case off
    case greedy
    case auto
}

/// Speculative-decoding controls. It is disabled by default and currently
/// enables only greedy verification. Other sampling configurations intentionally
/// continue through the ordinary target path.
///
/// `greedy` is a fixed-size mode for reproducible experiments. `auto` treats
/// `draftTokens` as an upper bound, starts at a conservative two-token block,
/// and adapts from measured acceptance and target time. The adaptive mode is
/// deliberately opt-in so a caller can make a clean baseline comparison.
public struct SpeculativeDecodeConfig: Codable, Sendable, Equatable {
    public var mode: SpeculativeDecodeMode
    public var draftTokens: Int

    public init(mode: SpeculativeDecodeMode = .off,
                draftTokens: Int = 4) {
        self.mode = mode
        self.draftTokens = draftTokens
    }

    public static let off = SpeculativeDecodeConfig()
    public var isEnabled: Bool { mode != .off }
}
