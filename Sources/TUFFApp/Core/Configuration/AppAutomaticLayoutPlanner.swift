import Foundation
import TUFFInferenceTypes
import TUFFModelCatalog
import TUFFModelMetadata
import TUFFRuntimeDescriptions

/// All resident mappings, all expert layers, state, scratch, staging and
/// overlapping growth are charged before a candidate is admitted. Byte counts
/// describe planned allocations, never a measured process footprint or speed.
enum AppAutomaticLayoutPlanner {
    /// Linear state must be copied in full even for a short conversation.
    /// Reserve enough for that state plus a useful short attention prefix.
    static func minimumUsefulRetention(config: ArchConfig, context: Int) -> UInt64 {
        let linear = config.fullAttentionLayerMask.filter { $0 == 2 }.count
        guard linear > 0 else { return 0 }
        let la = config.linearAttention
        let recurrent = linear * (la.numVHeads * la.valueHeadDim * la.keyHeadDim * 4
            + max(0, la.convKernelSize - 1) * la.qkvDim * 2)
        let full = config.fullAttentionLayerMask.filter { $0 == 1 }.count
        let prefix = full * config.numFullKVHeads * config.fullHeadDim * 4 * min(context, 512)
        return UInt64(recurrent + prefix)
    }
    static func estimate(catalog: TUFFModelDescriptor, summary: ModelWeightLayoutSummary,
                         context: Int, slots: Int, chunk: Int,
                         densePolicy: DenseResidencyPolicy, retainedBytes: UInt64 = ConversationRetentionBudget.defaultCapBytes) -> InferenceMemoryEstimate? {
        guard let variant = ModelVariant(rawValue: summary.architectureID),
              let config = ArchConfig.registeredArchitectures[variant], context > 0 else { return nil }
        let weights = summary.layout
        let layers: Set<Int>
        switch densePolicy {
        case .resident: layers = Set(weights.denseGroupBytes.indices)
        case .bounded(let selected): layers = selected
        case .automatic: return nil // Explicit groups are resolved before admission.
        }
        let kv = KVCacheMemoryPlan(config: config, maxContext: context, fp16RingEnabled: true,
            maxPrefillChunkTokens: max(chunk, config.family.acceptsImageInput
                ? min(context, VisionConfig(family: config.family).maximumPooledTokens) : chunk))
        let la = config.linearAttention
        let recurrent = UInt64(config.fullAttentionLayerMask.filter { $0 == 2 }.count
            * (la.numVHeads * la.valueHeadDim * la.keyHeadDim * 4
                + max(0, la.convKernelSize - 1) * la.qkvDim * 2))
        let scratch = InferenceMemoryPlan(descriptor: catalog, config: config,
            contextTokens: context, expertCacheSlots: slots, prefillChunkTokens: chunk).prefillScratchBytes
        let streamed = weights.denseGroupBytes.enumerated().filter { !layers.contains($0.offset) }.map(\.element)
        return try? InferenceMemoryEstimate.calculate(weights: weights,
            state: InferenceStateLayout(fullAttentionBytesPerToken: 0, fixedStateBytes: kv.totalBytes + recurrent),
            allocation: InferenceAllocation(residentDenseGroups: layers,
                expertSlotsByLayer: weights.expertLayers.map { min(slots, $0.expertCount) },
                contextTokens: context, scratchBytes: scratch,
                stagingBytes: streamed.isEmpty ? 0 : max(summary.minimumDenseStagingBytes, streamed.max()!),
                retainedStateBytes: retainedBytes,
                hostAndHelperBytes: 1 << 30, transitionReserveBytes: kv.growthOverlapBytes,
                residentRowsByTable: weights.rowAccessTables.map { _ in 0 }))
    }
    struct Candidate {
        let selection: InferencePlanCandidate
        let estimate: InferenceMemoryEstimate
        let denseLayers: Set<Int>
        let slots: Int
        let chunk: Int
        let retainedBytes: UInt64
    }

    static func candidates(catalog: TUFFModelDescriptor, descriptor: AppModelInstallDescriptor,
                           summary: ModelWeightLayoutSummary,
                           budget: UInt64, contextOverride: Int? = nil,
                           recommendedChunk: Int = 128,
                           retainConversation: Bool = true) -> [Candidate] {
        do { try summary.layout.validate() } catch { return [] }
        guard summary.architectureID == catalog.architecture.id.rawValue,
              let variant = ModelVariant(rawValue: summary.architectureID),
              let config = ArchConfig.registeredArchitectures[variant] else { return [] }
        let weights = summary.layout
        var minimumExpertBytes: UInt64 = 0
        for layer in weights.expertLayers {
            let bytes = layer.bytesPerExpert.multipliedReportingOverflow(by: UInt64(layer.minimumSlots))
            let total = minimumExpertBytes.addingReportingOverflow(bytes.partialValue)
            guard !bytes.overflow, !total.overflow else { return [] }
            minimumExpertBytes = total.partialValue
        }
        let cacheDominates = minimumExpertBytes > budget / 2
        let linearCount = config.fullAttentionLayerMask.filter { $0 == 2 }.count
        let la = config.linearAttention
        let recurrent = UInt64(linearCount * (la.numVHeads * la.valueHeadDim * la.keyHeadDim * 4
            + max(0, la.convKernelSize - 1) * la.qkvDim * 2))
        let contexts = contextOverride.map { [$0] } ?? AppContextLengthOption.options(for: descriptor).map(\.tokens)
        guard contexts.allSatisfy({ $0 > 0 && $0 <= catalog.maximumContextTokens }) else { return [] }
        let slots = weights.expertLayers.isEmpty ? [catalog.runtimeDefaults.expertCacheSlots]
            : descriptor.usefulExpertCacheSlotCounts
        let denseOrder = weights.denseGroupBytes.indices.sorted {
            weights.denseGroupBytes[$0] > weights.denseGroupBytes[$1]
        }
        let groupCounts = Array(0...denseOrder.count)
        var result: [Candidate] = []
        let chunks = Set([32, 64, 128, 256, recommendedChunk]).sorted()
        for context in contexts {
            for chunk in chunks.filter({ AppRuntimeOptions.allowedPrefillChunkTokens.contains($0) }) {
                let kv = KVCacheMemoryPlan(config: config, maxContext: context,
                    fp16RingEnabled: true, maxPrefillChunkTokens: max(chunk, config.family.acceptsImageInput
                        ? min(context, VisionConfig(family: config.family).maximumPooledTokens) : chunk))
                let state = InferenceStateLayout(fullAttentionBytesPerToken: 0,
                    fixedStateBytes: kv.totalBytes + recurrent)
                let scratch = InferenceMemoryPlan(descriptor: catalog, config: config,
                    contextTokens: context, expertCacheSlots: 16,
                    prefillChunkTokens: chunk).prefillScratchBytes
                for cache in slots {
                    for count in groupCounts {
                        let layers = Set(denseOrder.prefix(count))
                        // Whole-page accounting can exceed the compact staged
                        // span. Reserving the larger value is conservative.
                        let staging = denseOrder.count == count ? 0
                            : max(summary.minimumDenseStagingBytes,
                                weights.denseGroupBytes.enumerated().filter { !layers.contains($0.offset) }.map(\.element).max() ?? 0)
                        func allocation(retained: UInt64) -> InferenceAllocation { InferenceAllocation(residentDenseGroups: layers,
                            expertSlotsByLayer: weights.expertLayers.map { min(cache, $0.expertCount) },
                            contextTokens: context, scratchBytes: scratch, stagingBytes: staging,
                            retainedStateBytes: retained,
                            hostAndHelperBytes: 1 << 30,
                            transitionReserveBytes: kv.growthOverlapBytes,
                            residentRowsByTable: weights.rowAccessTables.map { _ in 0 }) }
                        guard let base = try? InferenceMemoryEstimate.calculate(weights: weights,
                            state: state, allocation: allocation(retained: 0)), base.peakAllocatedBytes <= budget else { continue }
                        // Snapshots are expendable. Never force a dense pack to
                        // stream simply to reserve an unused 1 GiB cache.
                        let availableRetention = UInt64(ConversationRetentionBudget.budget(safeBudgetBytes: budget,
                            workingSetBytes: base.peakAllocatedBytes))
                        let minimumRetention = minimumUsefulRetention(config: config, context: context)
                        // A large mandatory expert cache needs breathing room
                        // for streamed pages. One useful snapshot is enough;
                        // reserving every spare byte defeats that reserve.
                        let retained = retainConversation && availableRetention >= minimumRetention
                            ? (cacheDominates ? minimumRetention : availableRetention) : 0
                        guard let estimate = try? InferenceMemoryEstimate.calculate(weights: weights,
                            state: state, allocation: allocation(retained: retained)) else { continue }
                        let id = "c\(context)-e\(cache)-d\(count)-p\(chunk)"
                        result.append(Candidate(selection: .init(id: id, contextTokens: context,
                            peakAllocatedBytes: estimate.peakAllocatedBytes), estimate: estimate,
                            denseLayers: layers, slots: cache, chunk: chunk, retainedBytes: retained))
                    }
                }
            }
        }
        return result
    }

    static func plan(catalog: TUFFModelDescriptor, descriptor: AppModelInstallDescriptor,
                     device: TUFFDeviceCapabilities, profile: AppAutomaticMemoryProfile,
                     summary: ModelWeightLayoutSummary, observations: [InferencePlanObservation],
                     workloadKey: String, contextOverride: Int? = nil,
                     imageInput: Bool = false) -> AppAutomaticMemoryPlan? {
        do { try summary.layout.validate() } catch { return nil }
        let minimumSlots = summary.layout.expertLayers.map(\.minimumSlots).max() ?? 0
        var minimumExpertBytes: UInt64 = 0
        for layer in summary.layout.expertLayers {
            let bytes = layer.bytesPerExpert.multipliedReportingOverflow(by: UInt64(layer.minimumSlots))
            let total = minimumExpertBytes.addingReportingOverflow(bytes.partialValue)
            guard !bytes.overflow, !total.overflow else { return nil }
            minimumExpertBytes = total.partialValue
        }
        // When even one routed working set occupies a quarter of this Mac,
        // leave more room for macOS, other apps and the streaming file cache.
        // On a roomier Mac the same layout naturally keeps the normal budget.
        // This is an allocation heuristic, not a promised SSD-write limit.
        let cacheDominates = minimumExpertBytes > device.unifiedMemoryBytes / 4
        let normalBudget = cacheDominates ? min(device.safeAppMemoryBudgetBytes,
            device.unifiedMemoryBytes / 2) : device.safeAppMemoryBudgetBytes
        let pressure = AppAutoMemoryPressureMonitor.shared.snapshot.pressure
        let budget = pressure == .normal ? normalBudget
            : normalBudget / 100 * (pressure == .critical ? 65 : 80)
        let all = candidates(catalog: catalog, descriptor: descriptor, summary: summary, budget: budget,
            contextOverride: contextOverride, recommendedChunk: catalog.recommendedPrefillChunkTokens(on: device),
            retainConversation: profile != .speed && !cacheDominates)
        // Image spans only run under chunked prefill, which needs 16 expert
        // slots. Below that an image prompt fails partway through, so an
        // image workload only gets a smaller cache when nothing larger fits.
        let imageSlots = RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill
        let legal = imageInput && !summary.layout.expertLayers.isEmpty
            && all.contains(where: { $0.slots >= imageSlots })
            ? all.filter { $0.slots >= imageSlots } : all
        guard !legal.isEmpty else { return nil }
        let qualifiedSlots = cacheDominates ? minimumSlots
            : max(minimumSlots, catalog.runtimeDefaults.expertCacheSlots)
        let defaultChunk = cacheDominates ? 32 : catalog.recommendedPrefillChunkTokens(on: device)
        let baseline = legal.filter { $0.slots == qualifiedSlots && $0.chunk == defaultChunk }
        let initialPool = baseline.isEmpty ? legal : baseline
        let reusable = initialPool.filter {
            guard let variant = ModelVariant(rawValue: summary.architectureID),
                  let config = ArchConfig.registeredArchitectures[variant] else { return false }
            let minimum = minimumUsefulRetention(config: config, context: $0.selection.contextTokens)
            return minimum > 0 && $0.retainedBytes >= minimum
        }
        // Balanced favors a usable conversation snapshot over a few extra
        // projection mappings. A tiny unusable reserve buys no prefix reuse.
        let pool = profile == .balanced && !reusable.isEmpty ? reusable : initialPool
        let minimumContext = contextOverride ?? min(2_048, pool.map { $0.selection.contextTokens }.max()!)
        // Speed and Balanced first preserve as much dense residency as fits at
        // a useful context. Context may trade residency for a larger window.
        let affordablePool: [Candidate]
        let fullDenseFits = pool.contains { $0.selection.contextTokens >= minimumContext
            && $0.denseLayers.count == summary.layout.denseGroupBytes.count }
        if cacheDominates || (summary.layout.expertLayers.isEmpty && !fullDenseFits) {
            // Large dense packs and mandatory expert caches can thrash when
            // partial residency nearly fills memory. Start with streaming;
            // comparable healthy observations may still select residency.
            affordablePool = pool.filter { $0.denseLayers.isEmpty }
        } else if profile != .context, let retained = pool.filter({ $0.selection.contextTokens >= minimumContext }).map({ $0.denseLayers.count }).max() {
            affordablePool = pool.filter { $0.denseLayers.count == retained }
        } else { affordablePool = pool }
        let affordable = affordablePool.map { $0.selection.contextTokens }.max() ?? minimumContext
        // Initial windows are useful defaults, not arbitrary fractions of the
        // affordable maximum. Actual requests may require a larger window.
        let target = profile == .context ? affordable
            : min(affordable, max(minimumContext,
                profile == .balanced && !cacheDominates ? 16_384 : catalog.runtimeDefaults.contextTokens))
        let required = contextOverride ?? AppContextLengthOption.options(for: descriptor).map(\.tokens).last { $0 <= target } ?? 2_048
        let fallback = affordablePool.filter { $0.selection.contextTokens == required }.sorted {
            if $0.denseLayers.count != $1.denseLayers.count { return $0.denseLayers.count > $1.denseLayers.count }
            return $0.selection.peakAllocatedBytes < $1.selection.peakAllocatedBytes
        }.first ?? pool.min { $0.selection.peakAllocatedBytes < $1.selection.peakAllocatedBytes }!
        let objective = InferencePlanningObjective(rawValue: profile.rawValue) ?? .balanced
        guard let selected = try? InferencePlanSelector.select(candidates: legal.map(\.selection),
            observations: observations, workloadKey: workloadKey, objective: objective,
            budgetBytes: budget, requiredContextTokens: required, expectedOutputTokens: 128,
            fallbackID: fallback.selection.id),
              let candidate = legal.first(where: { $0.selection.id == selected.candidate.id }) else { return nil }
        let dense = !summary.layout.denseGroupBytes.isEmpty
        return AppAutomaticMemoryPlan(profile: profile, contextTokens: candidate.selection.contextTokens,
            expertCacheSlots: candidate.slots, estimatedWorkingSetBytes: candidate.estimate.peakAllocatedBytes,
            safeBudgetBytes: budget,
            denseResidencyPolicy: dense && candidate.denseLayers.count < summary.layout.denseGroupBytes.count
                ? .bounded(residentLayers: candidate.denseLayers) : .resident,
            residencyMode: candidate.estimate.mode,
            residentLayerCount: dense ? candidate.denseLayers.count : nil,
            streamedBytesPerToken: candidate.estimate.streamedDenseBytesPerToken,
            prefillChunkTokens: candidate.chunk, evidence: selected.evidence,
            candidateID: candidate.selection.id, retainedConversationBytes: Int(candidate.retainedBytes))
    }
}
