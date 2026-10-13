import Foundation

/// Automatic context targets scale with both this model's KV cost and the
/// Mac's memory. Runtime observations refine cache and chunk choices.
public enum AppAutomaticMemoryProfile: String, Codable, CaseIterable,
                                       Identifiable, Sendable {
    case speed
    case balanced
    case context

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .speed: "Speed"
        case .balanced: "Balanced"
        case .context: "Context"
        }
    }

    public var explanation: String {
        switch self {
        case .speed:
            "Prioritizes decode speed and a lighter context. Repeated local observations refine cache choices."
        case .balanced:
            "Balances response latency, memory and context. Larger caches are used when observations support them."
        case .context:
            "Uses the longest supported context within the allocation budget, trading weight residency when needed."
        }
    }

    // Compatibility planner for callers without a verified weight layout.
    var contextCapacityDivisor: Int {
        switch self { case .speed: 4; case .balanced: 2; case .context: 1 }
    }

}
