import Foundation
import TUFFInferenceTypes
import TUFFModelCatalog
import TUFFModelMetadata

/// Bounded local probes use an ordinary text request with no tools, attachments,
/// history or saved chat. Heavy streaming exits early instead of spending many
/// minutes to tune a model whose minimum disk traffic is already large.
public enum AppAutoCalibrator {
    static let maximumSeconds: TimeInterval = 15
    static let maximumCandidates = 3

    /// A smaller expert cache can pay for more resident projections. Comparing
    /// caches while freezing projection residency misses that useful tradeoff.
    static func cacheTradeoff(_ candidates: [AppAutomaticLayoutPlanner.Candidate],
                              targetSlots: Int, baselineChunk: Int) -> AppAutomaticLayoutPlanner.Candidate? {
        candidates.min {
            let a = abs($0.slots - targetSlots), b = abs($1.slots - targetSlots)
            if a != b { return a < b }
            if $0.denseLayers.count != $1.denseLayers.count {
                return $0.denseLayers.count > $1.denseLayers.count
            }
            let first = abs($0.chunk - baselineChunk), second = abs($1.chunk - baselineChunk)
            if first != second { return first < second }
            if $0.selection.peakAllocatedBytes != $1.selection.peakAllocatedBytes {
                return $0.selection.peakAllocatedBytes < $1.selection.peakAllocatedBytes
            }
            return $0.selection.id < $1.selection.id
        }
    }

    public static func run(client: any AppInferenceClient, lifecycle: any AppModelLifecycleClient,
                    directory: URL, descriptor: AppModelInstallDescriptor,
                    device: TUFFDeviceCapabilities, summary: ModelWeightLayoutSummary,
                    baseline: AppAutomaticMemoryPlan, options: AppRuntimeOptions,
                    forceLogitsHead: Bool,
                    record: @Sendable (String, InferencePlanObservation) -> Void = AppAutoPerformanceRecords.record,
                    observations: @Sendable (String) -> [InferencePlanObservation] = AppAutoPerformanceRecords.observations) async throws -> AppAutomaticMemoryPlan {
        guard let catalog = descriptor.catalogID.flatMap(TUFFModelCatalog.model(id:)) else { return baseline }
        let heavy = baseline.streamedBytesPerToken > 512 << 20
        let all = AppAutomaticLayoutPlanner.candidates(catalog: catalog, descriptor: descriptor,
            summary: summary, budget: baseline.safeBudgetBytes, contextOverride: baseline.contextTokens,
            recommendedChunk: catalog.recommendedPrefillChunkTokens(on: device))
        let comparable = all.filter { $0.selection.contextTokens == baseline.contextTokens
            && (heavy || $0.estimate.streamedDenseBytesPerToken <= 512 << 20) }
        let baselineID = baseline.candidateID
        let ordered = comparable.sorted {
            if $0.selection.id == baselineID { return true }
            if $1.selection.id == baselineID { return false }
            let baseLayers = baseline.residentLayerCount ?? summary.layout.denseGroupBytes.count
            func distance(_ value: AppAutomaticLayoutPlanner.Candidate) -> Int {
                abs(value.slots - baseline.expertCacheSlots)
                    + abs(value.denseLayers.count - baseLayers) * 16
                    + abs(value.chunk - baseline.prefillChunkTokens) / 4
            }
            let first = distance($0), second = distance($1)
            return first == second ? $0.selection.id < $1.selection.id : first < second
        }
        // Probe distinct tradeoffs rather than spending the entire allowance on
        // adjacent slot counts. Keep the baseline, then try smaller and larger
        // caches (or projection sets), and a different prefill chunk.
        var candidates: [AppAutomaticLayoutPlanner.Candidate] = []
        func append(_ candidate: AppAutomaticLayoutPlanner.Candidate?) {
            guard let candidate, !candidates.contains(where: { $0.selection.id == candidate.selection.id }) else { return }
            candidates.append(candidate)
        }
        append(ordered.first)
        let baseLayers = baseline.residentLayerCount ?? summary.layout.denseGroupBytes.count
        if !summary.layout.expertLayers.isEmpty {
            for target in [max(1, baseline.expertCacheSlots / 2), baseline.expertCacheSlots * 2] {
                append(cacheTradeoff(comparable, targetSlots: target,
                    baselineChunk: baseline.prefillChunkTokens))
            }
        } else {
            for target in [0, baseLayers == 0 ? summary.layout.denseGroupBytes.count / 2 : baseLayers / 2] {
                append(comparable.filter { $0.chunk == baseline.prefillChunkTokens }
                    .min { abs($0.denseLayers.count - target) < abs($1.denseLayers.count - target) })
            }
        }
        append(ordered.first { $0.chunk != baseline.prefillChunkTokens
            && $0.slots == baseline.expertCacheSlots && $0.denseLayers.count == baseLayers })
        for candidate in ordered where candidates.count < maximumCandidates { append(candidate) }
        candidates = Array(candidates.prefix(maximumCandidates))
        let identity = AppAutoPerformanceRecords.identity(summary: summary, device: device,
            engineIdentity: (client as? any AppInferenceEngineReporting)?.currentEngineIdentity, modelDirectory: directory)
        let key = "calibration-short-t\(ProcessInfo.processInfo.thermalState.rawValue)"
        let deadline = Date().addingTimeInterval(maximumSeconds)
        let timer = Task {
            try? await Task.sleep(for: .seconds(maximumSeconds))
            if !Task.isCancelled { client.cancel() }
        }
        defer { timer.cancel() }
        for candidate in candidates {
            if Date() >= deadline { break }
            try Task.checkCancellation()
            var probeOptions = options
            probeOptions.expertCacheSlots = candidate.slots
            probeOptions.prefillChunkTokens = candidate.chunk
            probeOptions.prefillEnabled = candidate.slots >= 16
            probeOptions.retainedConversationBytes = Int(candidate.retainedBytes)
            probeOptions.modelVerification = .trustedInstall
            probeOptions.denseResidencyPolicy = candidate.denseLayers.count == summary.layout.denseGroupBytes.count
                ? .resident : .bounded(residentLayers: candidate.denseLayers)
            try await lifecycle.ensureLoaded(modelDirectory: directory, maxContextTokens: baseline.contextTokens,
                options: probeOptions, forceLogitsHead: false, onState: { _ in })
            for probe in 0..<InferencePlanSelector.minimumComparableObservations {
                if Date() >= deadline { break }
                try Task.checkCancellation()
                let before = AppAutoMemoryPressureMonitor.shared.snapshot
                let swap = AppAutoMemoryPressureMonitor.swapBytes()
                let swapWritten = AppAutoMemoryPressureMonitor.swapWrittenBytes()
                let request = AppGenerationRequest(modelDirectory: directory,
                    prompt: "Trial \(probe + 1). Write six numbered facts about the planet Earth. Include a short explanation after each fact.",
                    maxNewTokens: heavy ? 2 : 16, maxContextTokens: baseline.contextTokens,
                    temperature: 0, seed: 17, runtimeOptions: probeOptions,
                    conversationKey: "auto-probe-\(UUID().uuidString)")
                do {
                    for try await event in client.generate(request) {
                        if case .finished(let diagnostics) = event {
                            let after = AppAutoMemoryPressureMonitor.shared.snapshot
                            let currentSwap = AppAutoMemoryPressureMonitor.swapBytes()
                            record(identity,
                                .init(candidateID: candidate.selection.id, workloadKey: key,
                                    decodeTokens: diagnostics.generatedTokens, decodeSeconds: diagnostics.decodeSeconds,
                                    timeToFirstTokenSeconds: diagnostics.requestStartTimeToFirstTokenSeconds ?? 0,
                                    pressure: after.warnings > before.warnings ? .warning : after.pressure,
                                    swapGrowthBytes: AppAutoMemoryPressureMonitor.pagingBytes(
                                        startUsed: swap, endUsed: currentSwap, startWritten: swapWritten,
                                        endWritten: AppAutoMemoryPressureMonitor.swapWrittenBytes())))
                        }
                    }
                } catch {
                    try Task.checkCancellation()
                    // A timeout or unsupported probe leaves the calculated plan
                    // usable; never turn a tuning attempt into a broken model.
                    break
                }
                if AppAutoMemoryPressureMonitor.shared.snapshot.pressure != .normal { break }
            }
        }
        timer.cancel()
        try Task.checkCancellation()
        let selected = AppAutomaticLayoutPlanner.plan(catalog: catalog, descriptor: descriptor, device: device,
            profile: baseline.profile, summary: summary,
            observations: observations(identity), workloadKey: key, contextOverride: baseline.contextTokens) ?? baseline
        var restored = options
        restored.expertCacheSlots = selected.expertCacheSlots
        restored.prefillChunkTokens = selected.prefillChunkTokens
        restored.prefillEnabled = selected.expertCacheSlots >= 16
        restored.denseResidencyPolicy = selected.denseResidencyPolicy
        restored.retainedConversationBytes = selected.retainedConversationBytes
        try await lifecycle.ensureLoaded(modelDirectory: directory, maxContextTokens: selected.contextTokens,
            options: restored, forceLogitsHead: forceLogitsHead, onState: { _ in })
        return selected
    }
}
