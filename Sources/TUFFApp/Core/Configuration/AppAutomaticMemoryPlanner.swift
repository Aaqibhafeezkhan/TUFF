import TUFFEngine
import TUFFModelCatalog

/// The concrete memory settings Auto resolves for one model on one Mac.
public struct AppAutomaticMemoryPlan: Equatable, Sendable {
    public let profile: AppAutomaticMemoryProfile
    public let contextTokens: Int
    public let expertCacheSlots: Int
    public let estimatedWorkingSetBytes: UInt64
    public let safeBudgetBytes: UInt64

    public init(profile: AppAutomaticMemoryProfile = .balanced,
                contextTokens: Int,
                expertCacheSlots: Int,
                estimatedWorkingSetBytes: UInt64,
                safeBudgetBytes: UInt64) {
        self.profile = profile
        self.contextTokens = contextTokens
        self.expertCacheSlots = expertCacheSlots
        self.estimatedWorkingSetBytes = estimatedWorkingSetBytes
        self.safeBudgetBytes = safeBudgetBytes
    }
}

/// Resolves context and cache capacity using the shared runtime allocation plan.
/// Cache counts retain qualified defaults; larger context must fit alongside
/// the selected chunk's scratch and ring storage.
public enum AppAutomaticMemoryPlanner {
    public static func plan(
        for descriptor: AppModelInstallDescriptor,
        on device: TUFFDeviceCapabilities,
        profile: AppAutomaticMemoryProfile = .balanced
    ) -> AppAutomaticMemoryPlan? {
        guard let id = descriptor.catalogID,
              let catalog = TUFFModelCatalog.model(id: id) else { return nil }

        let budget = device.safeAppMemoryBudgetBytes
        let chunk = catalog.recommendedPrefillChunkTokens(on: device)
        let qualifiedContext = catalog.runtimeDefaults.contextTokens
        func fits(context: Int, slots: Int) -> Bool {
            guard catalog.estimatedInferenceWorkingSetBytes(contextTokens: context,
                                            expertCacheSlots: slots,
                                            prefillChunkTokens: chunk) <= budget
            else { return false }
            return descriptor.usesExpertCache
                || denseResidentBytes(catalog, context: context) <= budget
        }

        // The qualified slot count, clamped to what this model can use, then
        // raised just far enough to reach chunked prefill. GPT-OSS 20B is
        // qualified at four slots, and the chunked prefill path needs sixteen;
        // leaving it at four would trade a much slower prompt for memory Auto
        // is not otherwise spending. Nothing grows past that — see the note
        // above for why filling the budget with slots is a loss.
        let slots: Int
        if descriptor.usesExpertCache {
            let options = descriptor.usefulExpertCacheSlotCounts.sorted()
            let qualified = catalog.runtimeDefaults.expertCacheSlots
            let clamped = options.contains(qualified)
                ? qualified
                : (options.last(where: { $0 <= qualified })
                    ?? options.first
                    ?? qualified)
            let prefillFloor = options.first {
                $0 >= RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill
            }
            if let prefillFloor, prefillFloor > clamped,
               fits(context: qualifiedContext, slots: prefillFloor) {
                slots = prefillFloor
            } else {
                slots = clamped
            }
        } else {
            slots = catalog.runtimeDefaults.expertCacheSlots
        }

        let contextOptions = AppContextLengthOption.options(for: descriptor)
            .map(\.tokens).sorted()

        // Find what this checkpoint can afford on this Mac, then space the
        // profiles across that capacity. A 2K qualification must not trap
        // Speed/Balanced at 2K/4K on machines with gigabytes left for KV.
        let affordable = contextOptions.last {
            fits(context: $0, slots: slots)
        } ?? qualifiedContext
        let target = max(qualifiedContext, affordable / profile.contextCapacityDivisor)
        let context = contextOptions.last { $0 <= target } ?? qualifiedContext

        return AppAutomaticMemoryPlan(
            profile: profile,
            contextTokens: context,
            expertCacheSlots: slots,
            estimatedWorkingSetBytes: catalog.estimatedInferenceWorkingSetBytes(
                contextTokens: context,
                expertCacheSlots: slots,
                prefillChunkTokens: chunk),
            safeBudgetBytes: budget)
    }

    /// What a dense model really keeps resident: every weight, because every
    /// token reads all of them, plus its KV cache and a runtime allowance.
    /// The qualified working set leaves file-backed weights out, which is
    /// right for streamed experts but not here. Measured on a 16 GB M2,
    /// Gemma 4 12B decoded at 6.3 tok/s with 8K of context and 3.0 with the
    /// 131K Auto used to choose, and as low as 0.34 once a long run added
    /// more state. Only extra context is refused this way; a model's
    /// qualified context is always kept.
    static func denseResidentBytes(_ catalog: TUFFModelDescriptor, context: Int) -> UInt64 {
        let kv = catalog.memory.kvCache.estimatedBytes(contextTokens: context)
        guard kv != .max else { return .max }
        let total = catalog.source.installedBytes.addingReportingOverflow(kv)
        guard !total.overflow else { return .max }
        let withRuntime = total.partialValue.addingReportingOverflow(denseRuntimeAllowanceBytes)
        return withRuntime.overflow ? .max : withRuntime.partialValue
    }

    /// Scratch, tokenizer, sampling and the app itself, beside the weights
    /// and KV cache.
    static let denseRuntimeAllowanceBytes: UInt64 = TUFFModelCatalog.oneGiB

    public static func applying(
        _ profile: AppModelSettingsProfile,
        for descriptor: AppModelInstallDescriptor,
        on device: TUFFDeviceCapabilities
    ) -> AppModelSettingsProfile {
        guard profile.automaticMemory,
              let plan = plan(for: descriptor,
                              on: device,
                              profile: profile.automaticMemoryProfile) else { return profile }
        var resolved = profile
        resolved.contextTokens = plan.contextTokens
        resolved.expertCacheSlots = plan.expertCacheSlots
        // Auto owns the memory-dependent prefill decision too. This lets a
        // GPT-OSS profile whose manual four-slot cache disables prefill gain
        // the faster chunked path when Auto can afford at least 16 slots.
        resolved.prefillEnabled = resolved.expertCacheSlots
            >= RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill
        return resolved
    }
}
