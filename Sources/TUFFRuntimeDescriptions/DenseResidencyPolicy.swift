/// Controlled layer residency. The bounded path keeps global tables resident
/// and stages one nonresident layer at a time, after the preceding GPU work.
public enum DenseResidencyPolicy: Sendable, Equatable, Codable {
    case automatic(weightBudgetBytes: UInt64)
    case resident
    case bounded(residentLayers: Set<Int>)
}
