import Testing
import Foundation
import Metal
@testable import TUFFEngine
import TUFFValidationSupport

/// End-to-end A/B of the opt-in small-block prefill path. Two runners load
/// the same toy install, one with the policy on and one with it off, and must
/// agree on prefill logits and on the decode step after it, across block
/// sizes either side of every tile width and the 32-token threshold.
///
/// The fixtures cover the state the path must leave alone: Flash Next's
/// gated-DeltaNet recurrence and convolution tails, hyper-connection streams,
/// n-gram history and sparse-attention indexer at group 32; Qwen 3.6's MoE
/// shared expert at group 64; and dense Gemma's shared KV, per-layer inputs
/// and GELU MLP at group 64. The policy is forced on here because only the
/// Flash Next toy carries a qualified variant; variant gating has its own
/// tests in `SmallBlockPrefillPolicyTests`.
@Suite(.serialized) struct SmallBlockPrefillRunnerTests {

    enum Fixture: String, CaseIterable {
        case flashNext
        case qwen36
        case denseGemma
    }

    private static let flashNextConfig = ArchConfig.qwen4ExpToy(
        ngramLayer: 1,
        indexer: .init(budget: 8, compressRatio: 4, headDim: 32, numHeads: 2, numKVHeads: 1))

    /// Prompt lengths. With 32-token chunks, 33 leaves a one-token tail (GEMV)
    /// and 40 an eight-token tail (small block).
    static let lengths = [1, 2, 3, 4, 5, 8, 9, 16, 31, 32, 33, 40]
    static let chunkTokens = 32

    private func load(_ fixture: Fixture, context: MetalContext) throws -> (URL, Model) {
        switch fixture {
        case .flashNext:
            let config = Self.flashNextConfig
            let directory = try Qwen4ExpToySynthetic.write(config: config)
            return (directory, try Model.load(directoryURL: directory, device: context.device,
                                              expecting: config, streamingMode: .pread(slotCount: 16)))
        case .qwen36:
            let directory = try QwenToySynthetic.write()
            return (directory, try Model.load(directoryURL: directory, device: context.device,
                                              expecting: .qwen36Toy()))
        case .denseGemma:
            let directory = try DenseGemmaToySynthetic.write()
            return (directory, try Model.load(directoryURL: directory, device: context.device,
                                              expecting: .gemma4E4BToy()))
        }
    }

    private struct Pair {
        let directories: [URL]
        let context: MetalContext
        let off: RealForwardRunner
        let on: RealForwardRunner
        let vocab: Int
    }

    /// Logits are compared directly, so the default runners write them; the
    /// speculative test needs the fused greedy head instead.
    private func makePair(_ fixture: Fixture,
                          runtime: RuntimeConfiguration = RuntimeConfiguration(forceLogitsHead: true))
        throws -> Pair {
        let context = try MetalContext()
        let (offDirectory, offModel) = try load(fixture, context: context)
        let (onDirectory, onModel) = try load(fixture, context: context)
        let off = try RealForwardRunner(model: offModel, context: context, maxContext: 128,
                                        runtimeConfiguration: runtime,
                                        smallBlockPrefill: .disabled)
        let on = try RealForwardRunner(model: onModel, context: context, maxContext: 128,
                                       runtimeConfiguration: runtime,
                                       smallBlockPrefill: SmallBlockPrefillPolicy(enabled: true))
        return Pair(directories: [offDirectory, onDirectory], context: context,
                    off: off, on: on, vocab: offModel.config.vocabSize)
    }

    private func logitsBuffer(_ pair: Pair) throws -> MTLBuffer {
        try #require(pair.context.device.makeBuffer(
            length: pair.vocab * MemoryLayout<Float16>.stride, options: .storageModeShared))
    }

    private static func tokens(_ count: Int) -> [Int32] {
        (0..<count).map { Int32(($0 * 7 + 11) % 31) }
    }

    /// Prefill logits, then the logits of one decode step after the prompt.
    private func prefillThenDecode(_ runner: RealForwardRunner, tokens: [Int32],
                                   logits: MTLBuffer, vocab: Int) async throws -> ([Float], [Float]) {
        runner.reset()
        _ = try await runner.prefillChunked(tokens: tokens[...], startPosition: 0,
                                            outputMode: .logits,
                                            config: .production(chunkTokens: Self.chunkTokens),
                                            into: logits, onProgress: { _ in })
        let prefill = Fp16Buffer.read(logits, count: vocab)
        let projectionsAfterPrefill = runner.smallBlockEncodedProjections
        try await runner.produce(token: 5, position: tokens.count, into: logits)
        #expect(runner.smallBlockEncodedProjections == projectionsAfterPrefill,
                "ordinary decode must not use the small-block prefill path")
        return (prefill, Fp16Buffer.read(logits, count: vocab))
    }

    @Test(arguments: Fixture.allCases)
    func smallBlockPrefillMatchesTheExistingPath(fixture: Fixture) async throws {
        let pair = try makePair(fixture)
        defer { pair.directories.forEach { try? FileManager.default.removeItem(at: $0) } }
        let logitsOff = try logitsBuffer(pair)
        let logitsOn = try logitsBuffer(pair)
        for length in Self.lengths {
            let prompt = Self.tokens(length)
            let before = pair.on.smallBlockEncodedProjections
            let reference = try await prefillThenDecode(pair.off, tokens: prompt,
                                                        logits: logitsOff, vocab: pair.vocab)
            let actual = try await prefillThenDecode(pair.on, tokens: prompt,
                                                     logits: logitsOn, vocab: pair.vocab)
            let chunks = stride(from: 0, to: length, by: Self.chunkTokens)
                .map { min(Self.chunkTokens, length - $0) }
            let engaged = chunks.contains { DequantInt4SmallBlock.admittedTokens.contains($0) }
            let used = pair.on.smallBlockEncodedProjections - before
            #expect(engaged == (used > 0),
                    "\(fixture) length \(length): chunks \(chunks), small-block projections \(used)")
            #expect(pair.off.smallBlockEncodedProjections == 0)

            let prefillError = RelError.compute(actual: actual.0, reference: reference.0)
            let decodeError = RelError.compute(actual: actual.1, reference: reference.1)
            #expect(prefillError < 2e-3, "\(fixture) length \(length): prefill relErr \(prefillError)")
            #expect(decodeError < 2e-3, "\(fixture) length \(length): next-token relErr \(decodeError)")
            #expect(actual.0.allSatisfy(\.isFinite) && actual.1.allSatisfy(\.isFinite))
            #expect(actual.0.indices.max(by: { actual.0[$0] < actual.0[$1] })
                    == reference.0.indices.max(by: { reference.0[$0] < reference.0[$1] }))
            #expect(actual.1.indices.max(by: { actual.1[$0] < actual.1[$1] })
                    == reference.1.indices.max(by: { reference.1[$0] < reference.1[$1] }))
        }
    }

    /// The small-block runner's prefill still agrees with decoding the same
    /// tokens one at a time, the invariant the existing prefill tests hold.
    @Test(arguments: Fixture.allCases)
    func smallBlockPrefillMatchesSequentialDecode(fixture: Fixture) async throws {
        let pair = try makePair(fixture)
        defer { pair.directories.forEach { try? FileManager.default.removeItem(at: $0) } }
        let logits = try logitsBuffer(pair)
        for length in [9, 31] {
            let prompt = Self.tokens(length)
            pair.off.reset()
            for (position, token) in prompt.enumerated() {
                try await pair.off.produce(token: token, position: position, into: logits)
            }
            let reference = Fp16Buffer.read(logits, count: pair.vocab)
            pair.on.reset()
            _ = try await pair.on.prefillChunked(tokens: prompt[...], startPosition: 0,
                                                 outputMode: .logits,
                                                 config: .production(chunkTokens: Self.chunkTokens),
                                                 into: logits, onProgress: { _ in })
            let actual = Fp16Buffer.read(logits, count: pair.vocab)
            let error = RelError.compute(actual: actual, reference: reference)
            #expect(error < 0.025, "\(fixture) length \(length): relErr vs decode \(error)")
        }
        #expect(pair.on.smallBlockEncodedProjections > 0)
    }

    /// A follow-up turn appended to an existing prefix: a short block that
    /// starts mid-sequence must read and extend the recurrent, n-gram and KV
    /// state exactly as the existing path does.
    @Test(arguments: Fixture.allCases)
    func shortContinuationAfterAPrefixMatches(fixture: Fixture) async throws {
        let pair = try makePair(fixture)
        defer { pair.directories.forEach { try? FileManager.default.removeItem(at: $0) } }
        let logitsOff = try logitsBuffer(pair)
        let logitsOn = try logitsBuffer(pair)
        let prefix = Self.tokens(37)
        let followUp: [Int32] = [4, 19, 2, 23, 8, 15]
        var results: [[Float]] = []
        for (runner, logits) in [(pair.off, logitsOff), (pair.on, logitsOn)] {
            runner.reset()
            _ = try await runner.prefillChunked(tokens: prefix[...], startPosition: 0,
                                                outputMode: .logits,
                                                config: .production(chunkTokens: Self.chunkTokens),
                                                into: logits, onProgress: { _ in })
            _ = try await runner.prefillChunked(tokens: followUp[...], startPosition: prefix.count,
                                                outputMode: .logits,
                                                config: .production(chunkTokens: Self.chunkTokens),
                                                into: logits, onProgress: { _ in })
            try await runner.produce(token: 9, position: prefix.count + followUp.count, into: logits)
            results.append(Fp16Buffer.read(logits, count: pair.vocab))
        }
        let error = RelError.compute(actual: results[1], reference: results[0])
        #expect(error < 2e-3, "\(fixture): continuation relErr \(error)")
    }

    /// Speculative verification blocks keep the per-token GEMV even with the
    /// policy on.
    @Test func speculativeVerificationNeverTakesTheSmallBlockPath() async throws {
        let pair = try makePair(.denseGemma, runtime: .production)
        defer { pair.directories.forEach { try? FileManager.default.removeItem(at: $0) } }
        try #require(pair.on.supportsSpeculativeVerification)
        let logits = try logitsBuffer(pair)
        try await pair.on.produce(token: 3, position: 0, into: logits)
        _ = try await pair.on.verifySpeculativeBlock(tokens: [5, 8, 13, 21], startPosition: 1,
                                                     into: logits)
        #expect(pair.on.smallBlockEncodedProjections == 0)
    }
}
