import TUFFModelCatalog
import Darwin

/// Admission estimate, not resident pages or a measured process footprint.
/// Adds runtime allocations conservatively to the qualified catalog baseline:
/// its historical scratch allowance is not subtracted without new evidence.
public struct InferenceMemoryPlan: Sendable, Equatable {
    public let prefillScratchBytes: UInt64
    public let kvCacheBytes: UInt64
    public let additionalRingBytes: UInt64
    public let cacheTrackingMetadataReserveBytes: UInt64
    public let estimatedWorkingSetBytes: UInt64

    public init(descriptor: TUFFModelDescriptor, config: ArchConfig,
                contextTokens: Int, expertCacheSlots: Int,
                prefillChunkTokens: Int) {
        let context = max(1, contextTokens)
        cacheTrackingMetadataReserveBytes = Self.trackingMetadataReserve(
            config: config, slots: expertCacheSlots)
        let chunk = max(PrefillRuntimeConfig.baselineChunkTokens,
                        min(PrefillRuntimeConfig.maxChunkTokens, prefillChunkTokens))
        // The affine runner reserves image capacity even for a text request.
        let visionRows = config.family.acceptsImageInput
            ? min(context, VisionConfig(family: config.family).maximumPooledTokens) : 0
        let kv = KVCacheMemoryPlan(config: config, maxContext: context,
                                  fp16RingEnabled: true,
                                  maxPrefillChunkTokens: max(chunk, visionRows))
        kvCacheBytes = kv.totalBytes
        let baselineKV = descriptor.memory.kvCache.estimatedBytes(contextTokens: context)
        additionalRingBytes = kv.totalBytes > baselineKV ? kv.totalBytes - baselineKV : 0
        if config.family == .gptOss {
            let expert = GPTOSSExpertScratchLayout(hiddenSize: config.hiddenSize,
                intermediateSize: config.moeIntermediateSize, topK: config.topKExperts,
                queryCapacity: chunk)
            let rowBytes = config.hiddenSize * 8
                + config.numHeads * config.headDim * 4
                + config.numKVHeads * config.headDim * 4
                + config.numExperts * 4 + config.topKExperts * 4
            let batched = GPTOSSBatchedExperts.maxRows
                * (2 * config.hiddenSize + 3 * config.moeIntermediateSize) * 2
            prefillScratchBytes = UInt64(chunk * rowBytes + expert.totalBytes + batched)
        } else {
            let scratch = PrefillChunkScratchLayout(config: config, chunkTokens: chunk)
            // Old and new chunk scratch coexist while a larger chunk is allocated.
            let batched = config.numExperts > 0
                ? PrefillBatchedRoutedExperts.maxRows
                    * (2 * config.hiddenSize + 3 * config.moeIntermediateSize) * 2 : 0
            prefillScratchBytes = UInt64(2 * scratch.totalPersistentBytes + batched)
        }
        var estimate = descriptor.memory.estimatedWorkingSetBytes(
            contextTokens: context,
            expertCacheSlots: min(max(0, expertCacheSlots), max(1, config.numExperts)))
        // Flash Next's full KV grows geometrically; the old buffers can coexist
        // with their replacements. Reserve a full additional KV allocation.
        let growth = config.family == .qwen4Exp ? kv.totalBytes : 0
        for bytes in [prefillScratchBytes, additionalRingBytes, growth, cacheTrackingMetadataReserveBytes] {
            let sum = estimate.addingReportingOverflow(bytes)
            estimate = sum.overflow ? .max : sum.partialValue
        }
        estimatedWorkingSetBytes = estimate
    }

    private static func trackingMetadataReserve(config: ArchConfig, slots: Int) -> UInt64 {
        guard config.numExperts > 0, config.numLayers > 0 else { return 0 }
        let page = UInt64(max(1, sysconf(_SC_PAGESIZE)))
        // Two new host arrays per opened expert layer: prediction counts and
        // unused-prefetch flags. Allow 64 bytes per allocation and whole pages.
        func allocation(_ bytes: UInt64) -> UInt64 {
            let header = bytes.addingReportingOverflow(64)
            let rounded = header.partialValue.addingReportingOverflow(page - 1)
            guard !header.overflow && !rounded.overflow else { return .max }
            return rounded.partialValue / page * page
        }
        let counters = UInt64(config.numExperts).multipliedReportingOverflow(
            by: UInt64(MemoryLayout<Int>.stride))
        guard !counters.overflow else { return .max }
        let flags = UInt64(min(max(1, slots), config.numExperts))
        let layer = allocation(counters.partialValue).addingReportingOverflow(allocation(flags))
        guard !layer.overflow else { return .max }
        let total = layer.partialValue.multipliedReportingOverflow(by: UInt64(config.numLayers))
        return total.overflow ? .max : total.partialValue
    }
}

public extension TUFFModelDescriptor {
    func estimatedInferenceWorkingSetBytes(contextTokens: Int, expertCacheSlots: Int,
                                           prefillChunkTokens: Int) -> UInt64 {
        guard let variant = ModelVariant(rawValue: architecture.id.rawValue),
              let config = ArchConfig.registeredArchitectures[variant] else { return .max }
        return InferenceMemoryPlan(descriptor: self, config: config,
            contextTokens: contextTokens, expertCacheSlots: expertCacheSlots,
            prefillChunkTokens: prefillChunkTokens).estimatedWorkingSetBytes
    }
}
