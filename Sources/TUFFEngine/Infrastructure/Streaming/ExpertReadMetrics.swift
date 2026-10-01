import Foundation

public enum ExpertReadPurpose: Sendable { case demand, prefetch }

/// Logical pread traffic, including OS-cache hits; physical SSD traffic is not measured.
public struct ExpertReadMetrics: Codable, Sendable, Equatable {
    public var demandReads: UInt64 = 0
    public var demandBytes: UInt64 = 0
    public var demandFailures: UInt64 = 0
    public var prefetchReads: UInt64 = 0
    public var prefetchBytes: UInt64 = 0
    public var prefetchFailures: UInt64 = 0

    public init() {}

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
        delta.demandReads = demandReads &- baseline.demandReads
        delta.demandBytes = demandBytes &- baseline.demandBytes
        delta.demandFailures = demandFailures &- baseline.demandFailures
        delta.prefetchReads = prefetchReads &- baseline.prefetchReads
        delta.prefetchBytes = prefetchBytes &- baseline.prefetchBytes
        delta.prefetchFailures = prefetchFailures &- baseline.prefetchFailures
        return delta
    }

    mutating func add(_ other: Self) {
        demandReads += other.demandReads
        demandBytes += other.demandBytes
        demandFailures += other.demandFailures
        prefetchReads += other.prefetchReads
        prefetchBytes += other.prefetchBytes
        prefetchFailures += other.prefetchFailures
    }
}
