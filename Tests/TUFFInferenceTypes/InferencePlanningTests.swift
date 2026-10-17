import Foundation
import Testing
@testable import TUFFInferenceTypes

@Suite struct InferencePlanningTests {
    private let weights = InferenceWeightLayout(fixedResidentBytes: 100,
        denseGroupBytes: [200, 400], expertLayers: [
            .init(bytesPerExpert: 10, expertCount: 8, minimumSlots: 2),
            .init(bytesPerExpert: 20, expertCount: 4, minimumSlots: 1),
        ])
    private let state = InferenceStateLayout(fullAttentionBytesPerToken: 2,
        slidingAttentionBytesPerToken: 3, slidingWindowTokens: 4, fixedStateBytes: 7)

    private func allocation(groups: Set<Int>, slots: [Int]) -> InferenceAllocation {
        InferenceAllocation(residentDenseGroups: groups, expertSlotsByLayer: slots,
            contextTokens: 10, scratchBytes: 13, stagingBytes: 400,
            retainedStateBytes: 19, hostAndHelperBytes: 23, transitionReserveBytes: 29)
    }

    @Test func partialAccountingIncludesAllExpertLayersAndTransitionAllocations() throws {
        let plan = try InferenceMemoryEstimate.calculate(weights: weights, state: state,
            allocation: allocation(groups: [0], slots: [3, 2]))
        #expect(plan.residentWeightBytes == 100 + 200 + 30 + 40)
        #expect(plan.stateBytes == 7 + 20 + 12)
        #expect(plan.runtimeBytes == 13 + 400 + 19 + 23 + 29)
        #expect(plan.peakAllocatedBytes == 893)
        #expect(plan.mode == .partial)
        #expect(plan.streamedDenseBytesPerToken == 400)
        #expect(plan.optimisticDiskDecodeCeiling(effectiveReadBytesPerSecond: 800) == 2)
    }

    @Test func fullResidencyRequiresEveryDenseGroupAndEveryExpert() throws {
        let resident = try InferenceMemoryEstimate.calculate(weights: weights, state: state,
            allocation: allocation(groups: [0, 1], slots: [8, 4]))
        #expect(resident.mode == .resident)
        #expect(resident.streamedDenseBytesPerToken == 0)
        #expect(resident.optimisticDiskDecodeCeiling(effectiveReadBytesPerSecond: 800) == nil)
        let expertStreaming = try InferenceMemoryEstimate.calculate(weights: weights, state: state,
            allocation: allocation(groups: [0, 1], slots: [2, 1]))
        #expect(expertStreaming.mode != .resident)
        // Dense groups give no estimate of routed expert traffic.
        #expect(expertStreaming.streamedDenseBytesPerToken == 0)
    }

    @Test func impossibleCacheOrGroupAllocationsAreRejected() {
        for invalid in [allocation(groups: [2], slots: [2, 1]),
                        allocation(groups: [], slots: [1, 1]),
                        allocation(groups: [], slots: [9, 1]),
                        allocation(groups: [], slots: [2])] {
            #expect(throws: InferencePlanningError.invalidAllocation) {
                try InferenceMemoryEstimate.calculate(weights: weights, state: state,
                    allocation: invalid)
            }
        }
        let noStreamingBuffer = InferenceAllocation(residentDenseGroups: [],
            expertSlotsByLayer: [2, 1], contextTokens: 10, scratchBytes: 0,
            stagingBytes: 399, hostAndHelperBytes: 0)
        #expect(throws: InferencePlanningError.invalidAllocation) {
            try InferenceMemoryEstimate.calculate(weights: weights, state: state,
                allocation: noStreamingBuffer)
        }
    }

    @Test func overflowIsNeverReportedAsASmallAllocation() {
        let huge = InferenceWeightLayout(fixedResidentBytes: UInt64.max,
            denseGroupBytes: [1], expertLayers: [])
        let selected = InferenceAllocation(residentDenseGroups: [0], expertSlotsByLayer: [],
            contextTokens: 1, scratchBytes: 0, stagingBytes: 0, hostAndHelperBytes: 0)
        #expect(throws: InferencePlanningError.arithmeticOverflow) {
            try InferenceMemoryEstimate.calculate(weights: huge,
                state: .init(fullAttentionBytesPerToken: 0), allocation: selected)
        }
        #expect(throws: InferencePlanningError.arithmeticOverflow) {
            try InferenceStateLayout(fullAttentionBytesPerToken: UInt64.max).bytes(contextTokens: 2)
        }
    }

    @Test func rowAccessTablesDoNotForceTheirWholePayloadIntoMemory() throws {
        let weights = InferenceWeightLayout(fixedResidentBytes: 100, denseGroupBytes: [],
            expertLayers: [], rowAccessTables: [
                .init(bytesPerRow: 64, rowCount: 1_000_000, maximumRowsPerToken: 4),
            ])
        let allocation = InferenceAllocation(residentDenseGroups: [], expertSlotsByLayer: [],
            contextTokens: 10, scratchBytes: 0, stagingBytes: 256, hostAndHelperBytes: 0,
            residentRowsByTable: [8])
        let estimate = try InferenceMemoryEstimate.calculate(weights: weights,
            state: .init(fullAttentionBytesPerToken: 0), allocation: allocation)
        #expect(estimate.residentWeightBytes == 100 + 8 * 64)
        #expect(estimate.mode == .partial)
        #expect(estimate.streamedDenseBytesPerToken == 0)
        #expect(estimate.streamedRowBytesPerTokenUpperBound == 4 * 64)
    }
}

@Suite struct InferencePlanSelectorTests {
    private func candidate(_ id: String, bytes: UInt64, context: Int = 4096,
                           perToken: Double? = nil, ttft: Double? = nil) -> InferencePlanCandidate {
        .init(id: id, contextTokens: context, peakAllocatedBytes: bytes,
            estimatedSecondsPerDecodeToken: perToken, estimatedTimeToFirstTokenSeconds: ttft)
    }

    private func observations(_ id: String, perToken: Double, ttft: Double = 1,
                              key: String = "warm-short") -> [InferencePlanObservation] {
        (0..<3).map { _ in
            .init(candidateID: id, workloadKey: key, decodeTokens: 100,
                decodeSeconds: perToken * 100, timeToFirstTokenSeconds: ttft)
        }
    }

    private func select(_ candidates: [InferencePlanCandidate],
                        _ samples: [InferencePlanObservation] = [],
                        objective: InferencePlanningObjective = .speed,
                        budget: UInt64 = 1000, requiredContext: Int = 2048,
                        fallback: String? = nil) throws -> InferencePlanSelection {
        try InferencePlanSelector.select(candidates: candidates, observations: samples,
            workloadKey: "warm-short", objective: objective, budgetBytes: budget,
            requiredContextTokens: requiredContext, expectedOutputTokens: 100,
            fallbackID: fallback)
    }

    @Test func aLargerCacheLosesWhenItSlowsDecode() throws {
        let candidates = [candidate("small", bytes: 300), candidate("large", bytes: 900)]
        let result = try select(candidates,
            observations("small", perToken: 0.1) + observations("large", perToken: 0.2))
        #expect(result.candidate.id == "small")
        #expect(result.evidence == .observed)
    }

    @Test func aLargerCacheWinsWhenItsBenefitIsSubstantial() throws {
        let result = try select([candidate("small", bytes: 300), candidate("large", bytes: 900)],
            observations("small", perToken: 0.2) + observations("large", perToken: 0.1))
        #expect(result.candidate.id == "large")
    }

    @Test func equivalentPerformanceSelectsTheSmallerAllocationRegardlessOfOrder() throws {
        let candidates = [candidate("small", bytes: 300), candidate("large", bytes: 900)]
        let samples = observations("small", perToken: 0.104) + observations("large", perToken: 0.1)
        #expect(try select(candidates, samples).candidate.id == "small")
        #expect(try select(Array(candidates.reversed()), samples).candidate.id == "small")
    }

    @Test func pressureAndSwapCanRejectAnOtherwiseFasterCandidate() throws {
        let candidates = [candidate("safe", bytes: 300), candidate("fast", bytes: 900)]
        for pressure in [InferenceMemoryPressure.warning, .critical] {
            let unsafe = InferencePlanObservation(candidateID: "fast", workloadKey: "warm-short",
                decodeTokens: 100, decodeSeconds: 1, timeToFirstTokenSeconds: 0.1,
                pressure: pressure)
            #expect(try select(candidates, observations("safe", perToken: 0.1)
                + observations("fast", perToken: 0.01) + [unsafe]).candidate.id == "safe")
        }
        let swapping = InferencePlanObservation(candidateID: "fast", workloadKey: "warm-short",
            decodeTokens: 100, decodeSeconds: 1, timeToFirstTokenSeconds: 0.1,
            swapGrowthBytes: InferencePlanSelector.significantSwapGrowthBytes)
        #expect(try select(candidates, observations("safe", perToken: 0.1)
            + [swapping]).candidate.id == "safe")
    }

    /// The swap counters are system-wide. A few pages written by another app
    /// during an answer used to quarantine the loaded plan (#54).
    @Test func incidentalPagingDoesNotQuarantineACandidate() throws {
        let candidates = [candidate("safe", bytes: 300), candidate("fast", bytes: 900)]
        let noise = InferencePlanObservation(candidateID: "fast", workloadKey: "warm-short",
            decodeTokens: 100, decodeSeconds: 1, timeToFirstTokenSeconds: 0.1,
            swapGrowthBytes: InferencePlanSelector.significantSwapGrowthBytes - 1)
        #expect(try select(candidates, observations("safe", perToken: 0.1)
            + observations("fast", perToken: 0.01) + [noise]).candidate.id == "fast")
    }

    /// Pressure on every choice says more about the Mac than about any one
    /// choice. Throwing here left the model with no plan and a failed load.
    @Test func pressureOnEveryCandidatePlansAsIfNothingWasObserved() throws {
        let candidates = [candidate("small", bytes: 300, perToken: 0.2, ttft: 1),
                          candidate("large", bytes: 900, perToken: 0.1, ttft: 1)]
        let pressured = candidates.map {
            InferencePlanObservation(candidateID: $0.id, workloadKey: "warm-short",
                decodeTokens: 100, decodeSeconds: 1, timeToFirstTokenSeconds: 0.1, pressure: .warning)
        }
        let result = try select(candidates, pressured)
        #expect(result.candidate.id == "large")
        #expect(result.evidence == .calculated)
    }

    @Test func cancelledColdPrefillQuarantinesAllocationForAWarmRequest() throws {
        let candidates = [candidate("safe", bytes: 300), candidate("fast", bytes: 900)]
        for paging in [UInt64(0), InferencePlanSelector.significantSwapGrowthBytes] {
            let cancelled = InferencePlanObservation(candidateID: "fast", workloadKey: "cold-short",
                decodeTokens: 0, decodeSeconds: 0, timeToFirstTokenSeconds: 0,
                pressure: paging == 0 ? .warning : .normal, swapGrowthBytes: paging)
            #expect(try select(candidates, observations("safe", perToken: 0.1)
                + observations("fast", perToken: 0.01) + [cancelled]).candidate.id == "safe")
        }
    }

    @Test func profilesUseTheRequestedWorkloadRatherThanMaximizingOneMetric() throws {
        let candidates = [candidate("slow-prompt", bytes: 300), candidate("quick-prompt", bytes: 400),
                          candidate("long", bytes: 700, context: 8192)]
        let samples = observations("slow-prompt", perToken: 0.1, ttft: 30)
            + observations("quick-prompt", perToken: 0.2, ttft: 1)
            + observations("long", perToken: 0.3, ttft: 2)
        #expect(try select(candidates, samples, objective: .speed).candidate.id == "slow-prompt")
        #expect(try select(candidates, samples, objective: .balanced).candidate.id == "quick-prompt")
        #expect(try select(candidates, samples, objective: .context).candidate.id == "long")
    }

    @Test func aColdRecordCannotDecideAWarmWorkload() throws {
        let result = try select([candidate("known-good", bytes: 300), candidate("unknown", bytes: 200)],
            observations("unknown", perToken: 0.001, key: "cold-short"), fallback: "known-good")
        #expect(result.candidate.id == "known-good")
        #expect(result.evidence == .fallback)
    }

    @Test func insufficientContextAndBudgetNeverFallBackToAnUnsafePlan() {
        #expect(throws: InferencePlanningError.insufficientBudget) {
            try select([candidate("too-large", bytes: 1001)], fallback: "too-large")
        }
        #expect(throws: InferencePlanningError.insufficientBudget) {
            try select([candidate("too-short", bytes: 100, context: 1024)], fallback: "too-short")
        }
    }

    @Test func invalidTimingCannotWinTheSearch() throws {
        let bad = candidate("bad", bytes: 100, perToken: .nan, ttft: -1)
        let good = candidate("good", bytes: 200, perToken: 0.2, ttft: 1)
        #expect(try select([bad, good]).candidate.id == "good")
    }
}
