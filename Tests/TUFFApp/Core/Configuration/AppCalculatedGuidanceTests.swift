import Testing
import TUFFModelCatalog
import TUFFInferenceTypes
@testable import TUFFAppCore

@Suite struct AppCalculatedGuidanceTests {
    @Test func sharedArchitectureCheckpointsKeepTheirOwnLayoutAndSettings() throws {
        let base = AppModelInstallDescriptor(catalog: TUFFModelCatalog.gemma4_26B_A4B)
        let derivative = AppModelInstallDescriptor(catalog: TUFFModelCatalog.gemma4_26B_Heretic)
        let baseLayout = try #require(AppAutomaticMemoryPlanner.predictedLayout(for: base))
        let derivativeLayout = try #require(AppAutomaticMemoryPlanner.predictedLayout(for: derivative))
        #expect(baseLayout.architectureID == derivativeLayout.architectureID)
        #expect(baseLayout.modelID != derivativeLayout.modelID)
        #expect(derivativeLayout.packedResidentPayloadBytes > baseLayout.packedResidentPayloadBytes)
        #expect(base.settingsProfileKey != derivative.settingsProfileKey)
        #expect(base.installDirectoryName != derivative.installDirectoryName)
        #expect(base.imageCompanion != nil)
        #expect(derivative.imageCompanion?.repoID == derivative.repoID)
        #expect(derivative.imageCompanion?.repoID != base.imageCompanion?.repoID)
    }
    private var device: TUFFDeviceCapabilities {
        .init(unifiedMemoryBytes: 16 << 30, macOSMajorVersion: 26, appleSiliconGeneration: 2)
    }
    @Test func everyCatalogModelHasPinnedPreinstallLayoutCounts() throws {
        for catalog in TUFFModelCatalog.all {
            let descriptor = AppModelInstallDescriptor(catalog: catalog)
            let layout = try #require(AppAutomaticMemoryPlanner.predictedLayout(for: descriptor))
            #expect(layout.architectureID == catalog.architecture.id.rawValue)
            #expect(layout.packedResidentPayloadBytes > 0)
            try layout.layout.validate()
            if descriptor.usesExpertCache {
                #expect(!layout.layout.expertLayers.isEmpty)
                #expect(layout.layout.expertLayers.allSatisfy { $0.bytesPerExpert > 0 })
            } else {
                #expect(!layout.layout.denseGroupBytes.isEmpty)
                #expect(layout.minimumDenseStagingBytes > 0)
            }
        }
    }
    @Test func largeDenseFallbackDoesNotAssumeAFullerCacheIsFaster() throws {
        let descriptor = AppModelInstallDescriptor(catalog: TUFFModelCatalog.qwen38_27B)
        let plan = try #require(AppAutomaticMemoryPlanner.plan(for: descriptor, on: device,
            profile: .speed, useBundledLayout: true, contextTokens: 2_048))
        #expect(plan.residentLayerCount == 0)
        #expect(plan.residencyMode == .streamed)
        #expect(plan.streamedBytesPerToken > 10 << 30)
        #expect(plan.estimatedWorkingSetBytes <= plan.safeBudgetBytes)
    }
    @Test func aFittingDenseCheckpointKeepsTheResidentFastPath() throws {
        let descriptor = AppModelInstallDescriptor(catalog: TUFFModelCatalog.ornith15_9B)
        let plan = try #require(AppAutomaticMemoryPlanner.plan(for: descriptor, on: device,
            profile: .speed, useBundledLayout: true, contextTokens: 2_048))
        #expect(plan.residentLayerCount == 32)
        #expect(plan.residencyMode == .resident)
        #expect(plan.streamedBytesPerToken == 0)
    }
    @Test func automaticCandidatesIncludeTheQualifiedLargePrefillChunk() throws {
        let descriptor = AppModelInstallDescriptor.default
        let plan = try #require(AppAutomaticMemoryPlanner.plan(for: descriptor, on: device,
            profile: .balanced, useBundledLayout: true))
        #expect(plan.expertCacheSlots == 16)
        #expect(plan.prefillChunkTokens == TUFFModelCatalog.gemma4_26B_A4B.recommendedPrefillChunkTokens(on: device))
        #expect(plan.estimatedWorkingSetBytes <= plan.safeBudgetBytes)
    }
    @Test func denseResidencyCanTakePriorityOverExpendableSnapshots() throws {
        let descriptor = AppModelInstallDescriptor(catalog: TUFFModelCatalog.gemma4_12B_QAT)
        let plan = try #require(AppAutomaticMemoryPlanner.plan(for: descriptor, on: device,
            profile: .speed, useBundledLayout: true, contextTokens: 2_048))
        #expect(plan.residencyMode == .resident)
        #expect(plan.streamedBytesPerToken == 0)
        #expect(try #require(plan.retainedConversationBytes) < 1 << 30)
        #expect(plan.estimatedWorkingSetBytes <= plan.safeBudgetBytes)
    }
    @Test func oneTimingNeverOverridesRepeatedComparableEvidence() throws {
        let descriptor = AppModelInstallDescriptor(catalog: TUFFModelCatalog.qwen38_27B)
        let summary = try #require(AppAutomaticMemoryPlanner.predictedLayout(for: descriptor))
        let observations = (0..<3).map { _ in
            InferencePlanObservation(candidateID: "c2048-e16-d0-p128", workloadKey: "fixture",
                decodeTokens: 16, decodeSeconds: 16, timeToFirstTokenSeconds: 5)
        } + [.init(candidateID: "c2048-e16-d1-p128", workloadKey: "fixture",
                  decodeTokens: 16, decodeSeconds: 0.1, timeToFirstTokenSeconds: 0.1)]
        let selected = try #require(AppAutomaticMemoryPlanner.plan(for: descriptor, on: device,
            layoutSummary: summary, observations: observations, workloadKey: "fixture", contextTokens: 2_048))
        #expect(selected.residentLayerCount == 0)
        #expect(selected.evidence == .observed)
    }
}
