import Foundation

public enum ExpertReadPurpose: Sendable, Equatable { case demand, prefetch }

/// Logical pread traffic, including OS-cache hits; physical SSD traffic is not measured.
public struct ExpertReadMetrics: Codable, Sendable, Equatable {
    /// Expert requests accepted by cache planning, including hits.
    public var demandRequests: UInt64 = 0
    /// Speculative expert requests, including predictions already cached.
    public var predictionRequests: UInt64 = 0
    public var demandReads: UInt64 = 0
    public var demandBytes: UInt64 = 0
    public var demandFailures: UInt64 = 0
    public var prefetchReads: UInt64 = 0
    public var prefetchBytes: UInt64 = 0
    public var prefetchFailures: UInt64 = 0
    /// Completed speculative records subsequently hit by demand, once per insertion.
    public var usefulPrefetchReads: UInt64 = 0
    /// Completed speculative records evicted before their first demand hit.
    public var unusedPrefetchEvictions: UInt64 = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case demandRequests, predictionRequests
        case demandReads, demandBytes, demandFailures, prefetchReads, prefetchBytes, prefetchFailures
        case usefulPrefetchReads, unusedPrefetchEvictions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        demandRequests = try values.decodeIfPresent(UInt64.self, forKey: .demandRequests) ?? 0
        predictionRequests = try values.decodeIfPresent(UInt64.self, forKey: .predictionRequests) ?? 0
        demandReads = try values.decodeIfPresent(UInt64.self, forKey: .demandReads) ?? 0
        demandBytes = try values.decodeIfPresent(UInt64.self, forKey: .demandBytes) ?? 0
        demandFailures = try values.decodeIfPresent(UInt64.self, forKey: .demandFailures) ?? 0
        prefetchReads = try values.decodeIfPresent(UInt64.self, forKey: .prefetchReads) ?? 0
        prefetchBytes = try values.decodeIfPresent(UInt64.self, forKey: .prefetchBytes) ?? 0
        prefetchFailures = try values.decodeIfPresent(UInt64.self, forKey: .prefetchFailures) ?? 0
        usefulPrefetchReads = try values.decodeIfPresent(UInt64.self, forKey: .usefulPrefetchReads) ?? 0
        unusedPrefetchEvictions = try values.decodeIfPresent(UInt64.self, forKey: .unusedPrefetchEvictions) ?? 0
    }

    mutating func record(purpose: ExpertReadPurpose, bytes: UInt64, succeeded: Bool) {
        switch purpose {
        case .demand:
            demandBytes += bytes
            if succeeded { demandReads += 1 } else { demandFailures += 1 }
        case .prefetch:
            prefetchBytes += bytes
            if succeeded { prefetchReads += 1 } else { prefetchFailures += 1 }
        }
    }

    public func subtracting(_ baseline: Self) -> Self {
        var delta = Self()
        delta.demandRequests = demandRequests &- baseline.demandRequests
        delta.predictionRequests = predictionRequests &- baseline.predictionRequests
        delta.demandReads = demandReads &- baseline.demandReads
        delta.demandBytes = demandBytes &- baseline.demandBytes
        delta.demandFailures = demandFailures &- baseline.demandFailures
        delta.prefetchReads = prefetchReads &- baseline.prefetchReads
        delta.prefetchBytes = prefetchBytes &- baseline.prefetchBytes
        delta.prefetchFailures = prefetchFailures &- baseline.prefetchFailures
        delta.usefulPrefetchReads = usefulPrefetchReads &- baseline.usefulPrefetchReads
        delta.unusedPrefetchEvictions = unusedPrefetchEvictions &- baseline.unusedPrefetchEvictions
        return delta
    }

    mutating func add(_ other: Self) {
        demandRequests += other.demandRequests
        predictionRequests += other.predictionRequests
        demandReads += other.demandReads
        demandBytes += other.demandBytes
        demandFailures += other.demandFailures
        prefetchReads += other.prefetchReads
        prefetchBytes += other.prefetchBytes
        prefetchFailures += other.prefetchFailures
        usefulPrefetchReads += other.usefulPrefetchReads
        unusedPrefetchEvictions += other.unusedPrefetchEvictions
    }
}
