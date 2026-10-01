import Testing
import TUFFModelCatalog
@testable import TUFFEngine

@Suite struct InferenceMemoryPlanTests {
    @Test func everyCatalogModelIncludesChunkScratchAndRuntimeKV() throws {
        for descriptor in TUFFModelCatalog.all {
            let variant = try #require(ModelVariant(rawValue: descriptor.architecture.id.rawValue))
            let config = try #require(ArchConfig.registeredArchitectures[variant])
            let small = InferenceMemoryPlan(descriptor: descriptor, config: config,
                contextTokens: 4096, expertCacheSlots: descriptor.runtimeDefaults.expertCacheSlots,
                prefillChunkTokens: 256)
            let large = InferenceMemoryPlan(descriptor: descriptor, config: config,
                contextTokens: 4096, expertCacheSlots: descriptor.runtimeDefaults.expertCacheSlots,
                prefillChunkTokens: 2048)
            #expect(large.prefillScratchBytes > small.prefillScratchBytes)
            #expect(large.estimatedWorkingSetBytes > small.estimatedWorkingSetBytes)
            let vision = config.family.acceptsImageInput
                ? min(4096, VisionConfig(family: config.family).maximumPooledTokens) : 0
            let expectedKV = KVCacheMemoryPlan(config: config, maxContext: 4096,
                fp16RingEnabled: true, maxPrefillChunkTokens: max(2048, vision))
            #expect(large.kvCacheBytes == expectedKV.totalBytes)
            #expect(large.estimatedWorkingSetBytes == descriptor.estimatedInferenceWorkingSetBytes(
                contextTokens: 4096, expertCacheSlots: descriptor.runtimeDefaults.expertCacheSlots,
                prefillChunkTokens: 2048))
        }
    }

    @Test func allLayerSlotCostsMatchPackedRecords() {
        let records: [(TUFFModelDescriptor, UInt64, UInt64)] = [
            (TUFFModelCatalog.gemma4_26B_A4B, 30, 3_358_720), (TUFFModelCatalog.qwen36_35B_A3B, 40, 1_769_472),
            (TUFFModelCatalog.gptOss_20B, 24, 13_238_272), (TUFFModelCatalog.gptOss_120B, 36, 13_238_272),
            (TUFFModelCatalog.minimaxM27, 62, 7_962_624), (TUFFModelCatalog.qwen38FlashNext, 48, 3_080_192)
        ]
        for (descriptor, layers, stride) in records {
            #expect(descriptor.memory.expertCacheBytesPerSlot == layers * stride)
            let four = descriptor.memory.estimatedWorkingSetBytes(contextTokens: 4096, expertCacheSlots: 4)
            let sixteen = descriptor.memory.estimatedWorkingSetBytes(contextTokens: 4096, expertCacheSlots: 16)
            #expect(sixteen - four == 12 * layers * stride)
        }
    }

    @Test func unsupportedHugeContextSaturatesInsteadOfWrapping() {
        #expect(TUFFModelCatalog.gptOss_120B.estimatedInferenceWorkingSetBytes(
            contextTokens: Int.max, expertCacheSlots: 16, prefillChunkTokens: 2048) == .max)
    }
}
