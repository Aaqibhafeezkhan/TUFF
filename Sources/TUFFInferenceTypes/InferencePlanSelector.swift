import Foundation

public struct InferencePlanCandidate: Codable, Sendable, Equatable {
    public let id: String
    public let contextTokens: Int
    public let peakAllocatedBytes: UInt64
    public let estimatedSecondsPerDecodeToken: Double?
    public let estimatedTimeToFirstTokenSeconds: Double?

    public init(id: String, contextTokens: Int, peakAllocatedBytes: UInt64,
                estimatedSecondsPerDecodeToken: Double? = nil,
                estimatedTimeToFirstTokenSeconds: Double? = nil) {
        self.id = id
        self.contextTokens = contextTokens
        self.peakAllocatedBytes = peakAllocatedBytes
        self.estimatedSecondsPerDecodeToken = estimatedSecondsPerDecodeToken
        self.estimatedTimeToFirstTokenSeconds = estimatedTimeToFirstTokenSeconds
    }
}

/// A caller compares one identity and workload class at a time. Cold requests,
/// warmed requests, prefix reuse and thermal constraints have different keys.
public struct InferencePlanObservation: Codable, Sendable, Equatable {
    public let candidateID: String
    public let workloadKey: String
    public let decodeTokens: Int
    public let decodeSeconds: Double
    public let timeToFirstTokenSeconds: Double
    public let pressure: InferenceMemoryPressure
    public let swapGrowthBytes: UInt64

    public init(candidateID: String, workloadKey: String, decodeTokens: Int,
                decodeSeconds: Double, timeToFirstTokenSeconds: Double,
                pressure: InferenceMemoryPressure = .normal, swapGrowthBytes: UInt64 = 0) {
        self.candidateID = candidateID
        self.workloadKey = workloadKey
        self.decodeTokens = decodeTokens
        self.decodeSeconds = decodeSeconds
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.pressure = pressure
        self.swapGrowthBytes = swapGrowthBytes
    }
}

public enum InferencePlanEvidence: String, Codable, Sendable {
    case calculated, observed, fallback
}

public struct InferencePlanSelection: Codable, Sendable, Equatable {
    public let candidate: InferencePlanCandidate
    public let evidence: InferencePlanEvidence
}

public enum InferencePlanSelector {
    public static let minimumComparableObservations = 3
    public static let equivalentPerformanceFraction = 0.05
    /// Paging below this is noise. The swap counters are system-wide, so a
    /// little paging by another app during an answer must not quarantine a
    /// choice; thrashing pages far more than this.
    public static let significantSwapGrowthBytes: UInt64 = 64 << 20

    public static func select(candidates: [InferencePlanCandidate],
                              observations: [InferencePlanObservation] = [],
                              workloadKey: String, objective: InferencePlanningObjective,
                              budgetBytes: UInt64, requiredContextTokens: Int,
                              expectedOutputTokens: Int, fallbackID: String? = nil) throws
        -> InferencePlanSelection {
        guard requiredContextTokens > 0, expectedOutputTokens > 0,
              Set(candidates.map(\.id)).count == candidates.count else {
            throw InferencePlanningError.invalidAllocation
        }
        let legal = candidates.filter {
            !$0.id.isEmpty && $0.contextTokens >= requiredContextTokens
                && $0.peakAllocatedBytes <= budgetBytes
        }
        guard !legal.isEmpty else { throw InferencePlanningError.insufficientBudget }
        var scored: [(InferencePlanCandidate, Double, InferencePlanEvidence)] = []
        var pressured: Set<String> = []
        for candidate in legal {
            // Allocation health also matters when prefill was cancelled before
            // any decode token. It is independent of cold/warm speed classes.
            if observations.contains(where: { $0.candidateID == candidate.id
                && ($0.pressure != .normal || $0.swapGrowthBytes >= significantSwapGrowthBytes) }) {
                pressured.insert(candidate.id)
                continue
            }
            let comparable = observations.filter {
                $0.candidateID == candidate.id && $0.workloadKey == workloadKey
                    && $0.decodeTokens > 0 && $0.decodeSeconds.isFinite && $0.decodeSeconds > 0
                    && $0.timeToFirstTokenSeconds.isFinite && $0.timeToFirstTokenSeconds >= 0
            }
            let perToken: Double?
            let ttft: Double?
            let evidence: InferencePlanEvidence
            if comparable.count >= minimumComparableObservations {
                perToken = median(comparable.map { $0.decodeSeconds / Double($0.decodeTokens) })
                ttft = median(comparable.map(\.timeToFirstTokenSeconds))
                evidence = .observed
            } else {
                perToken = candidate.estimatedSecondsPerDecodeToken
                ttft = candidate.estimatedTimeToFirstTokenSeconds
                evidence = .calculated
            }
            guard let perToken, perToken.isFinite, perToken > 0 else { continue }
            let score: Double
            switch objective {
            case .speed: score = perToken
            case .balanced, .context:
                guard let ttft, ttft.isFinite, ttft >= 0 else { continue }
                score = ttft + perToken * Double(expectedOutputTokens)
            }
            guard score.isFinite else { continue }
            scored.append((candidate, score, evidence))
        }
        let unpressured = legal.filter { !pressured.contains($0.id) }
        // When every choice was seen under pressure, the pressure came from
        // the Mac rather than from a choice. Plan as if nothing had been
        // observed instead of leaving the model with no plan at all.
        guard !unpressured.isEmpty else {
            return try select(candidates: candidates, workloadKey: workloadKey, objective: objective,
                budgetBytes: budgetBytes, requiredContextTokens: requiredContextTokens,
                expectedOutputTokens: expectedOutputTokens, fallbackID: fallbackID)
        }
        let maxContext = unpressured.map(\.contextTokens).max()!
        if objective == .context { scored.removeAll { $0.0.contextTokens < maxContext } }
        // Do not claim an unobserved prediction beat measured evidence when
        // comparable measured candidates already exist.
        if scored.contains(where: { $0.2 == .observed }) {
            scored.removeAll { $0.2 != .observed }
        }
        if let best = scored.map({ $0.1 }).min() {
            let equivalent = scored.filter { $0.1 <= best * (1 + equivalentPerformanceFraction) }
            let selected = equivalent.sorted {
                if $0.0.peakAllocatedBytes != $1.0.peakAllocatedBytes {
                    return $0.0.peakAllocatedBytes < $1.0.peakAllocatedBytes
                }
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0.id < $1.0.id
            }[0]
            return InferencePlanSelection(candidate: selected.0, evidence: selected.2)
        }
        let eligible = objective == .context
            ? unpressured.filter { $0.contextTokens == maxContext } : unpressured
        let fallback = eligible.first { $0.id == fallbackID }
            ?? eligible.sorted {
                if $0.peakAllocatedBytes != $1.peakAllocatedBytes {
                    return $0.peakAllocatedBytes < $1.peakAllocatedBytes
                }
                return $0.id < $1.id
            }[0]
        return InferencePlanSelection(candidate: fallback, evidence: .fallback)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? sorted[mid - 1] / 2 + sorted[mid] / 2 : sorted[mid]
    }
}
