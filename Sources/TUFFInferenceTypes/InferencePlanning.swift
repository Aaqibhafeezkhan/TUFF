import Foundation

public enum InferenceResidencyMode: String, Codable, Sendable, CaseIterable {
    case resident, partial, streamed
}

public enum InferencePlanningObjective: String, Codable, Sendable {
    case speed, balanced, context
}

public enum InferenceMemoryPressure: String, Codable, Sendable {
    case normal, warning, critical
}

public enum InferencePlanningError: Error, Equatable {
    case invalidLayout
    case invalidAllocation
    case arithmeticOverflow
    case insufficientBudget
}

/// Packed byte counts include quantization metadata and alignment. No values
/// here are derived from parameter count or measured process footprint.
public struct InferenceWeightLayout: Codable, Sendable, Equatable {
    public struct RowAccessTable: Codable, Sendable, Equatable {
        public let bytesPerRow: UInt64
        public let rowCount: Int
        public let maximumRowsPerToken: Int

        public init(bytesPerRow: UInt64, rowCount: Int, maximumRowsPerToken: Int) {
            self.bytesPerRow = bytesPerRow
            self.rowCount = rowCount
            self.maximumRowsPerToken = maximumRowsPerToken
        }
    }

    public struct ExpertLayer: Codable, Sendable, Equatable {
        public let bytesPerExpert: UInt64
        public let expertCount: Int
        public let minimumSlots: Int

        public init(bytesPerExpert: UInt64, expertCount: Int, minimumSlots: Int) {
            self.bytesPerExpert = bytesPerExpert
            self.expertCount = expertCount
            self.minimumSlots = minimumSlots
        }
    }

    public let fixedResidentBytes: UInt64
    public let denseGroupBytes: [UInt64]
    public let expertLayers: [ExpertLayer]
    public let rowAccessTables: [RowAccessTable]

    public init(fixedResidentBytes: UInt64, denseGroupBytes: [UInt64],
                expertLayers: [ExpertLayer], rowAccessTables: [RowAccessTable] = []) {
        self.fixedResidentBytes = fixedResidentBytes
        self.denseGroupBytes = denseGroupBytes
        self.expertLayers = expertLayers
        self.rowAccessTables = rowAccessTables
    }

    public func validate() throws {
        guard denseGroupBytes.allSatisfy({ $0 > 0 }),
              expertLayers.allSatisfy({ $0.bytesPerExpert > 0 && $0.expertCount > 0
                  && $0.minimumSlots > 0 && $0.minimumSlots <= $0.expertCount }),
              rowAccessTables.allSatisfy({ $0.bytesPerRow > 0 && $0.rowCount > 0
                  && $0.maximumRowsPerToken > 0 && $0.maximumRowsPerToken <= $0.rowCount }) else {
            throw InferencePlanningError.invalidLayout
        }
    }
}

public struct InferenceStateLayout: Codable, Sendable, Equatable {
    public let fullAttentionBytesPerToken: UInt64
    public let slidingAttentionBytesPerToken: UInt64
    public let slidingWindowTokens: Int
    public let fixedStateBytes: UInt64

    public init(fullAttentionBytesPerToken: UInt64,
                slidingAttentionBytesPerToken: UInt64 = 0,
                slidingWindowTokens: Int = 0, fixedStateBytes: UInt64 = 0) {
        self.fullAttentionBytesPerToken = fullAttentionBytesPerToken
        self.slidingAttentionBytesPerToken = slidingAttentionBytesPerToken
        self.slidingWindowTokens = slidingWindowTokens
        self.fixedStateBytes = fixedStateBytes
    }

    public func bytes(contextTokens: Int) throws -> UInt64 {
        guard contextTokens > 0, slidingWindowTokens >= 0 else {
            throw InferencePlanningError.invalidLayout
        }
        return try InferenceByteMath.sum([
            fixedStateBytes,
            InferenceByteMath.multiply(fullAttentionBytesPerToken, UInt64(contextTokens)),
            InferenceByteMath.multiply(slidingAttentionBytesPerToken,
                UInt64(min(contextTokens, slidingWindowTokens))),
        ])
    }
}

public struct InferenceAllocation: Codable, Sendable, Equatable {
    public let residentDenseGroups: Set<Int>
    public let expertSlotsByLayer: [Int]
    public let residentRowsByTable: [Int]
    public let contextTokens: Int
    public let scratchBytes: UInt64
    public let stagingBytes: UInt64
    public let retainedStateBytes: UInt64
    public let hostAndHelperBytes: UInt64
    /// Additional allocations that coexist during KV growth or cache replacement.
    public let transitionReserveBytes: UInt64

    public init(residentDenseGroups: Set<Int>, expertSlotsByLayer: [Int],
                contextTokens: Int, scratchBytes: UInt64, stagingBytes: UInt64,
                retainedStateBytes: UInt64 = 0, hostAndHelperBytes: UInt64,
                transitionReserveBytes: UInt64 = 0, residentRowsByTable: [Int] = []) {
        self.residentDenseGroups = residentDenseGroups
        self.expertSlotsByLayer = expertSlotsByLayer
        self.residentRowsByTable = residentRowsByTable
        self.contextTokens = contextTokens
        self.scratchBytes = scratchBytes
        self.stagingBytes = stagingBytes
        self.retainedStateBytes = retainedStateBytes
        self.hostAndHelperBytes = hostAndHelperBytes
        self.transitionReserveBytes = transitionReserveBytes
    }
}

public struct InferenceMemoryEstimate: Codable, Sendable, Equatable {
    public let mode: InferenceResidencyMode
    public let residentWeightBytes: UInt64
    public let stateBytes: UInt64
    public let runtimeBytes: UInt64
    public let peakAllocatedBytes: UInt64
    /// Dense groups only. Routed expert read volume requires routing observations.
    public let streamedDenseBytesPerToken: UInt64
    /// Worst-case row demand if none of the requested rows hit their cache.
    public let streamedRowBytesPerTokenUpperBound: UInt64

    public static func calculate(weights: InferenceWeightLayout,
                                 state: InferenceStateLayout,
                                 allocation: InferenceAllocation) throws -> Self {
        try weights.validate()
        guard allocation.contextTokens > 0,
              allocation.expertSlotsByLayer.count == weights.expertLayers.count,
              allocation.residentRowsByTable.count == weights.rowAccessTables.count,
              allocation.residentDenseGroups.allSatisfy({ weights.denseGroupBytes.indices.contains($0) }) else {
            throw InferencePlanningError.invalidAllocation
        }
        var resident = [weights.fixedResidentBytes]
        var streamed: [UInt64] = []
        for (index, bytes) in weights.denseGroupBytes.enumerated() {
            if allocation.residentDenseGroups.contains(index) { resident.append(bytes) }
            else { streamed.append(bytes) }
        }
        if let largestStreamedGroup = streamed.max(), allocation.stagingBytes < largestStreamedGroup {
            throw InferencePlanningError.invalidAllocation
        }
        var fullExperts = true
        for (layer, slots) in zip(weights.expertLayers, allocation.expertSlotsByLayer) {
            guard slots >= layer.minimumSlots, slots <= layer.expertCount else {
                throw InferencePlanningError.invalidAllocation
            }
            resident.append(try InferenceByteMath.multiply(layer.bytesPerExpert, UInt64(slots)))
            fullExperts = fullExperts && slots == layer.expertCount
        }
        var allRowsResident = true
        var rowDemand: [UInt64] = []
        for (table, rows) in zip(weights.rowAccessTables, allocation.residentRowsByTable) {
            guard rows >= 0, rows <= table.rowCount else { throw InferencePlanningError.invalidAllocation }
            resident.append(try InferenceByteMath.multiply(table.bytesPerRow, UInt64(rows)))
            if rows < table.rowCount {
                allRowsResident = false
                rowDemand.append(try InferenceByteMath.multiply(table.bytesPerRow,
                    UInt64(table.maximumRowsPerToken)))
            }
        }
        let weightBytes = try InferenceByteMath.sum(resident)
        let stateBytes = try state.bytes(contextTokens: allocation.contextTokens)
        let runtimeBytes = try InferenceByteMath.sum([allocation.scratchBytes,
            allocation.stagingBytes, allocation.retainedStateBytes,
            allocation.hostAndHelperBytes, allocation.transitionReserveBytes])
        let allResident = streamed.isEmpty && fullExperts && allRowsResident
        let someCached = !allocation.residentDenseGroups.isEmpty
            || allocation.residentRowsByTable.contains(where: { $0 > 0 })
            || zip(weights.expertLayers, allocation.expertSlotsByLayer).contains { layer, slots in
                slots > layer.minimumSlots
            }
        return Self(mode: allResident ? .resident : (someCached ? .partial : .streamed),
            residentWeightBytes: weightBytes, stateBytes: stateBytes, runtimeBytes: runtimeBytes,
            peakAllocatedBytes: try InferenceByteMath.sum([weightBytes, stateBytes, runtimeBytes]),
            streamedDenseBytesPerToken: try InferenceByteMath.sum(streamed),
            streamedRowBytesPerTokenUpperBound: try InferenceByteMath.sum(rowDemand))
    }

    public func optimisticDiskDecodeCeiling(effectiveReadBytesPerSecond: Double) -> Double? {
        guard streamedDenseBytesPerToken > 0, effectiveReadBytesPerSecond.isFinite,
              effectiveReadBytesPerSecond > 0 else { return nil }
        return effectiveReadBytesPerSecond / Double(streamedDenseBytesPerToken)
    }
}

enum InferenceByteMath {
    static func sum(_ values: [UInt64]) throws -> UInt64 {
        try values.reduce(0) { total, bytes in
            let result = total.addingReportingOverflow(bytes)
            guard !result.overflow else { throw InferencePlanningError.arithmeticOverflow }
            return result.partialValue
        }
    }

    static func multiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw InferencePlanningError.arithmeticOverflow }
        return result.partialValue
    }
}
