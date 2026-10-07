import Foundation
import Metal
import Testing
@testable import TUFFEngine

/// Loading a model compiles only the kernel groups its architecture uses, and
/// the prediction is complete: running decode and prefill asks for nothing
/// that was not prepared.
@Suite(.serialized) struct MetalKernelGroupTests {
    @Test func everyGroupCompilesOnItsOwn() throws {
        for group in MetalKernelGroup.allCases {
            let context = try MetalContext(kernelGroups: [group], environment: [:])
            #expect(context.compiledKernelGroups == [group], "\(group)")
        }
    }

    @Test func everyKernelBelongsToExactlyOneGroup() {
        var owners: [String: [MetalKernelGroup]] = [:]
        for group in MetalKernelGroup.allCases {
            for module in group.modules {
                let url = Bundle.module.url(forResource: module, withExtension: "metal",
                                            subdirectory: nil)
                    ?? Self.sourceURL(module)
                let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                #expect(!source.isEmpty, "missing \(module)")
                for name in MetalContext.kernelNames(in: source) {
                    owners[name, default: []].append(group)
                }
            }
        }
        #expect(owners.count > 100)
        #expect(owners.filter { $0.value.count > 1 }.isEmpty)
        for (name, groups) in owners {
            #expect(MetalContext.functionGroups[name] == groups.first, "\(name)")
        }
    }

    private static func sourceURL(_ module: String) -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TUFFEngine/Metal")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        return enumerator.compactMap { $0 as? URL }.first { $0.lastPathComponent == module + ".metal" }!
    }

    @Test func aPipelineFromAnUnpreparedGroupStillWorksAndIsRecorded() throws {
        let context = try MetalContext(kernelGroups: [.core], environment: [:])
        #expect(context.lateKernelGroups.isEmpty, "late: \(context.lateKernelGroups.sorted())")
        _ = try context.pipeline("gdn_qk_norm")
        #expect(context.compiledKernelGroups == [.core, .linearAttention])
        #expect(context.lateKernelGroups == [.linearAttention])
        #expect(throws: MetalError.self) { _ = try context.pipeline("no_such_kernel") }
    }

    @Test func combinedModeCompilesOneLibraryForEveryGroup() throws {
        let context = try MetalContext(kernelGroups: [.core],
                                       environment: ["TUFF_KERNEL_GROUPS": "combined"])
        #expect(context.combinesAllGroups)
        #expect(context.compiledKernelGroups == Set(MetalKernelGroup.allCases))
        _ = try context.pipeline("gdn_qk_norm")
        _ = try context.pipeline("vision_add_position")
        #expect(context.lateKernelGroups.isEmpty, "late: \(context.lateKernelGroups.sorted())")
    }

    @Test func selectionFollowsArchitectureFeatures() {
        #expect(MetalKernelGroup.required(for: .gemma4E4BToy()) == [.core])
        #expect(MetalKernelGroup.required(for: .qwen36Toy())
            .isSuperset(of: [.core, .mixtureOfExperts, .linearAttention, .int8]))
        #expect(MetalKernelGroup.required(for: .gptOssToy()) == [.core, .mixtureOfExperts, .mxfp4])
        let indexed = ArchConfig.qwen4ExpToy(
            ngramLayer: 1,
            indexer: AttentionIndexerConfig(budget: 8, compressRatio: 4, headDim: 32,
                                            numHeads: 2, numKVHeads: 1))
        #expect(MetalKernelGroup.required(for: indexed, maxContext: 64)
            .isSuperset(of: [.sparseAttention, .residualStreams, .linearAttention]))
        // The indexer is not built below its budget, so its kernels are not needed.
        #expect(!MetalKernelGroup.required(for: indexed, maxContext: 8).contains(.sparseAttention))
    }

    /// Runs decode and one prefill chunk, then checks nothing was compiled late.
    private static func exercise(_ runner: any ChunkedPrefillRunner, vocab: Int,
                                 context: MetalContext) async throws {
        let logits = context.device.makeBuffer(length: vocab * MemoryLayout<Float16>.stride,
                                               options: .storageModeShared)!
        _ = try await runner.prefillChunked(
            tokens: [2, 5, 8, 13, 21, 3, 9, 4][...], startPosition: 0, outputMode: .logits,
            config: .production(chunkTokens: 32), into: logits, onProgress: { _ in })
        for position in 8..<11 {
            try await runner.produce(token: Int32(position % 7 + 2), position: position, into: logits)
        }
    }

    @Test func denseGemmaLoadsOnlyItsGroups() async throws {
        let directory = try DenseGemmaToySynthetic.write()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try MetalContext(kernelGroups: [], environment: [:])
        let model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: .gemma4E4BToy())
        let runner = try RealForwardRunner(model: model, context: context, maxContext: 64)
        try await Self.exercise(runner, vocab: ArchConfig.gemma4E4BToy().vocabSize, context: context)
        #expect(context.lateKernelGroups.isEmpty, "late: \(context.lateKernelGroups.sorted())")
        #expect(context.compiledKernelGroups.isDisjoint(
            with: [.mixtureOfExperts, .mxfp4, .linearAttention, .sparseAttention, .vision]))
    }

    @Test func qwenHybridLoadsOnlyItsGroups() async throws {
        let directory = try QwenToySynthetic.write()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try MetalContext(kernelGroups: [], environment: [:])
        let model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: .qwen36Toy())
        let runner = try RealForwardRunner(model: model, context: context, maxContext: 64)
        try await Self.exercise(runner, vocab: ArchConfig.qwen36Toy().vocabSize, context: context)
        #expect(context.lateKernelGroups.isEmpty, "late: \(context.lateKernelGroups.sorted())")
        #expect(context.compiledKernelGroups.isDisjoint(with: [.mxfp4, .vision]))
    }

    @Test func qwen4ExpLoadsOnlyItsGroups() async throws {
        let config = ArchConfig.qwen4ExpToy(
            ngramLayer: 1,
            indexer: AttentionIndexerConfig(budget: 8, compressRatio: 4, headDim: 32,
                                            numHeads: 2, numKVHeads: 1))
        let directory = try Qwen4ExpToySynthetic.write(config: config)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try MetalContext(kernelGroups: [], environment: [:])
        let model = try Model.load(directoryURL: directory, device: context.device, expecting: config)
        let runner = try RealForwardRunner(model: model, context: context, maxContext: 64)
        try await Self.exercise(runner, vocab: config.vocabSize, context: context)
        #expect(context.lateKernelGroups.isEmpty, "late: \(context.lateKernelGroups.sorted())")
        #expect(context.compiledKernelGroups.isDisjoint(with: [.mxfp4, .vision]))
    }

    @Test func gptOssLoadsOnlyItsGroups() async throws {
        let directory = try GPTOSSToySynthetic.write()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try MetalContext(kernelGroups: [], environment: [:])
        let model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: .gptOssToy(), streamingMode: .pread(slotCount: 8))
        let runner = try ModelForwardRunner(
            model: model, context: context, maxContext: 64,
            runtimeConfiguration: RuntimeConfiguration(
                expertCacheSlots: 8, prefillEnabled: true, prefillChunkTokens: 32,
                forceLogitsHead: true))
        try await Self.exercise(runner, vocab: ArchConfig.gptOssToy().vocabSize, context: context)
        #expect(context.lateKernelGroups.isEmpty, "late: \(context.lateKernelGroups.sorted())")
        #expect(context.compiledKernelGroups == [.core, .mixtureOfExperts, .mxfp4])
    }
}
