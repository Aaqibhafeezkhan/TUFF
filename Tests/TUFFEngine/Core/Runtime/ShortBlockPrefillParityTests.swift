import Testing
import Foundation
import Metal
@testable import TUFFEngine
import TUFFValidationSupport

/// Prefill blocks of 2-31 tokens run the batched MPP projections and MLPs.
/// They must still agree with decoding the same tokens one at a time, leave
/// the recurrent, n-gram and KV state a later decode step reads, and never
/// change speculative verification, which keeps the per-token kernels.
///
/// The fixtures cover Flash Next's gated-DeltaNet, hyper-connections, n-gram
/// history and sparse indexer at group 32; Qwen 3.6's MoE shared expert; the
/// dense Qwen MLP (Ornith 1.5 9B's shape); and dense Gemma's shared KV and
/// per-layer inputs.
@Suite(.serialized) struct ShortBlockPrefillParityTests {

    enum Fixture: String, CaseIterable {
        case flashNext
        case qwen36
        case qwenDense
        case denseGemma
    }

    /// With 32-token chunks, 33 leaves a one-token tail (decode GEMV) and 40
    /// an eight-token tail (batched).
    static let lengths = [2, 3, 5, 8, 13, 26, 31, 33, 40]
    static let chunkTokens = 32

    private static let flashNextConfig = ArchConfig.qwen4ExpToy(
        ngramLayer: 1,
        indexer: .init(budget: 8, compressRatio: 4, headDim: 32, numHeads: 2, numKVHeads: 1))

    private struct Loaded {
        let directory: URL
        let context: MetalContext
        let runner: RealForwardRunner
        let vocab: Int
    }

    private func load(_ fixture: Fixture,
                      runtime: RuntimeConfiguration = RuntimeConfiguration(forceLogitsHead: true))
        throws -> Loaded {
        let context = try MetalContext()
        let directory: URL
        let model: Model
        switch fixture {
        case .flashNext:
            directory = try Qwen4ExpToySynthetic.write(config: Self.flashNextConfig)
            model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: Self.flashNextConfig,
                                   streamingMode: .pread(slotCount: 16))
        case .qwen36:
            directory = try QwenToySynthetic.write()
            model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: .qwen36Toy())
        case .qwenDense:
            directory = try QwenToySynthetic.write(dense: true)
            model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: .qwen36Toy(dense: true))
        case .denseGemma:
            directory = try DenseGemmaToySynthetic.write()
            model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: .gemma4E4BToy())
        }
        let runner = try RealForwardRunner(model: model, context: context, maxContext: 128,
                                           runtimeConfiguration: runtime)
        return Loaded(directory: directory, context: context, runner: runner,
                      vocab: model.config.vocabSize)
    }

    private func logitsBuffer(_ loaded: Loaded) throws -> MTLBuffer {
        try #require(loaded.context.device.makeBuffer(
            length: loaded.vocab * MemoryLayout<Float16>.stride, options: .storageModeShared))
    }

    private static func tokens(_ count: Int) -> [Int32] {
        (0..<count).map { Int32(($0 * 7 + 11) % 31) }
    }

    private static func argmax(_ values: [Float]) -> Int? {
        values.indices.max { values[$0] < values[$1] }
    }

    private func prefill(_ runner: RealForwardRunner, _ tokens: [Int32], startPosition: Int,
                         into logits: MTLBuffer) async throws {
        _ = try await runner.prefillChunked(tokens: tokens[...], startPosition: startPosition,
                                            outputMode: .logits,
                                            config: .production(chunkTokens: Self.chunkTokens),
                                            into: logits, onProgress: { _ in })
    }

    private var mppAvailable: Bool {
        guard let context = try? MetalContext() else { return false }
        return MPPPrefillAffineQMM(context: context, bits: 4, groupSize: 64) != nil
    }

    @Test(arguments: Fixture.allCases)
    func shortPrefillMatchesSequentialDecode(fixture: Fixture) async throws {
        let loaded = try load(fixture)
        defer { try? FileManager.default.removeItem(at: loaded.directory) }
        let runner = loaded.runner
        let logits = try logitsBuffer(loaded)
        for length in Self.lengths {
            let prompt = Self.tokens(length)
            runner.reset()
            for (position, token) in prompt.enumerated() {
                try await runner.produce(token: token, position: position, into: logits)
            }
            let reference = Fp16Buffer.read(logits, count: loaded.vocab)
            try await runner.produce(token: 5, position: length, into: logits)
            let referenceNext = Fp16Buffer.read(logits, count: loaded.vocab)

            runner.reset()
            let before = runner.batchedPrefillProjections
            try await prefill(runner, prompt, startPosition: 0, into: logits)
            let actual = Fp16Buffer.read(logits, count: loaded.vocab)
            if mppAvailable {
                #expect(runner.batchedPrefillProjections > before,
                        "\(fixture) length \(length): the short block did not batch")
            }
            try await runner.produce(token: 5, position: length, into: logits)
            let actualNext = Fp16Buffer.read(logits, count: loaded.vocab)

            let error = RelError.compute(actual: actual, reference: reference)
            let nextError = RelError.compute(actual: actualNext, reference: referenceNext)
            #expect(error < 0.025, "\(fixture) length \(length): prefill relErr vs decode \(error)")
            #expect(nextError < 0.025, "\(fixture) length \(length): next-token relErr \(nextError)")
            #expect(actual.allSatisfy(\.isFinite) && actualNext.allSatisfy(\.isFinite))
            #expect(Self.argmax(actual) == Self.argmax(reference), "\(fixture) length \(length)")
            #expect(Self.argmax(actualNext) == Self.argmax(referenceNext), "\(fixture) length \(length)")
        }
    }

    /// A chat follow-up: a short block that starts mid-sequence must extend
    /// the state the prefix left, as decoding those tokens would.
    @Test(arguments: Fixture.allCases)
    func shortFollowUpAfterAPrefixMatchesDecode(fixture: Fixture) async throws {
        let loaded = try load(fixture)
        defer { try? FileManager.default.removeItem(at: loaded.directory) }
        let runner = loaded.runner
        let logits = try logitsBuffer(loaded)
        let prefix = Self.tokens(37)
        let followUp: [Int32] = [4, 19, 2, 23, 8, 15]

        runner.reset()
        for (position, token) in (prefix + followUp).enumerated() {
            try await runner.produce(token: token, position: position, into: logits)
        }
        try await runner.produce(token: 9, position: prefix.count + followUp.count, into: logits)
        let reference = Fp16Buffer.read(logits, count: loaded.vocab)

        runner.reset()
        try await prefill(runner, prefix, startPosition: 0, into: logits)
        try await prefill(runner, followUp, startPosition: prefix.count, into: logits)
        try await runner.produce(token: 9, position: prefix.count + followUp.count, into: logits)
        let actual = Fp16Buffer.read(logits, count: loaded.vocab)

        let error = RelError.compute(actual: actual, reference: reference)
        #expect(error < 0.025, "\(fixture): follow-up relErr vs decode \(error)")
        #expect(Self.argmax(actual) == Self.argmax(reference))
    }

    /// Verification blocks are as short as prompt blocks but keep the
    /// per-token kernels their acceptance compares against.
    @Test func speculativeVerificationKeepsThePerTokenKernels() async throws {
        let loaded = try load(.denseGemma, runtime: .production)
        defer { try? FileManager.default.removeItem(at: loaded.directory) }
        let runner = loaded.runner
        try #require(runner.supportsSpeculativeVerification)
        let logits = try logitsBuffer(loaded)
        try await runner.produce(token: 3, position: 0, into: logits)
        let before = runner.batchedPrefillProjections
        _ = try await runner.verifySpeculativeBlock(tokens: [5, 8, 13, 21], startPosition: 1,
                                                    into: logits)
        #expect(runner.batchedPrefillProjections == before)
    }

    /// GPT-OSS batches its BF16 attention projections the same way; its
    /// routed experts keep their own threshold.
    @Test func gptOSSShortPrefillMatchesSequentialDecode() async throws {
        let config = ArchConfig.gptOssToy()
        let directory = try GPTOSSToySynthetic.write(config: config)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try MetalContext()
        let model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: config, streamingMode: .pread(slotCount: 8))
        let runner = try ModelForwardRunner(
            model: model, context: context, maxContext: 64,
            runtimeConfiguration: RuntimeConfiguration(expertCacheSlots: 8, prefillEnabled: true,
                                                       prefillChunkTokens: Self.chunkTokens,
                                                       forceLogitsHead: true))
        let logits = try #require(context.device.makeBuffer(
            length: config.vocabSize * MemoryLayout<Float16>.stride, options: .storageModeShared))
        for length in [2, 5, 13, 31] {
            let prompt = Self.tokens(length)
            runner.reset()
            for (position, token) in prompt.enumerated() {
                try await runner.produce(token: token, position: position, into: logits)
            }
            let reference = Fp16Buffer.read(logits, count: config.vocabSize)
            runner.reset()
            let before = runner.batchedPrefillProjections
            _ = try await runner.prefillChunked(tokens: prompt[...], startPosition: 0,
                                                outputMode: .logits,
                                                config: .production(chunkTokens: Self.chunkTokens),
                                                into: logits, onProgress: { _ in })
            let actual = Fp16Buffer.read(logits, count: config.vocabSize)
            if mppAvailable {
                #expect(runner.batchedPrefillProjections > before, "length \(length)")
            }
            let error = RelError.compute(actual: actual, reference: reference)
            #expect(error < 0.02, "length \(length): relErr vs decode \(error)")
            #expect(Self.argmax(actual) == Self.argmax(reference), "length \(length)")
        }
    }

    @Test func policyAdmitsShortPromptBlocksOnly() {
        #expect(!PrefillBatchingPolicy.batchesProjections(tokenCount: 1, speculativeVerification: false))
        for tokens in [2, 8, 31, 32, 2_048] {
            #expect(PrefillBatchingPolicy.batchesProjections(tokenCount: tokens,
                                                             speculativeVerification: false))
            #expect(!PrefillBatchingPolicy.batchesProjections(tokenCount: tokens,
                                                              speculativeVerification: true))
        }
    }
}
