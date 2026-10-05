import Testing
import Foundation
import Metal
@testable import TUFFEngine
import TUFFValidationSupport

/// The small-block INT4 projection against two independent references: an
/// FP32 product of the bulk-dequantized weights, and the per-token
/// `DequantInt4GEMV` dispatch the prefill uses today. Shapes cover group 32
/// and 64, remainder groups, row counts that leave a partial threadgroup,
/// strided and offset views, partial token tiles and nonfinite inputs.
@Suite struct DequantInt4SmallBlockTests {

    private struct Weights {
        let weights: MTLBuffer
        let weightsOffset: Int
        let scales: MTLBuffer
        let biases: MTLBuffer
        let dequantized: [[Float]]
    }

    /// Token counts around each tile width and the batched threshold; 3, 7,
    /// 13 and 31 combine several tile widths in one projection.
    static let tokenCounts = [2, 3, 4, 5, 7, 8, 9, 13, 16, 31]
    /// Fill for every half the kernel must not write.
    static let sentinel = Float16(-7.25)

    private static func makeWeights(device: MTLDevice, m: Int, n: Int,
                                    groupSize: Int, seed: UInt64,
                                    weightsOffset: Int) throws -> Weights {
        var rng = SeedTree(seed).key("small-block-w-g\(groupSize)-\(m)x\(n)")
        var packed = [UInt8](repeating: 0, count: weightsOffset)
        var scales = [UInt16]()
        var biases = [UInt16]()
        var dequantized = [[Float]]()
        for _ in 0..<m {
            let row = (0..<n).map { _ in rng.uniform(-0.5, 0.5) }
            let quantized = Quantization.quantizeInt4Affine(row, groupSize: groupSize)
            packed.append(contentsOf: quantized.packed)
            scales.append(contentsOf: quantized.scales)
            biases.append(contentsOf: quantized.biases)
            dequantized.append(Quantization.dequantizeInt4Affine(
                quantized, n: n, groupSize: groupSize))
        }
        let w = try #require(device.makeBuffer(bytes: packed, length: packed.count,
                                               options: .storageModeShared))
        let s = try #require(device.makeBuffer(bytes: scales, length: scales.count * 2,
                                               options: .storageModeShared))
        let b = try #require(device.makeBuffer(bytes: biases, length: biases.count * 2,
                                               options: .storageModeShared))
        return Weights(weights: w, weightsOffset: weightsOffset, scales: s, biases: b,
                       dequantized: dequantized)
    }

    /// `tokens` rows of `n` inputs, `stride` halves apart. Padding between
    /// rows holds large values so a stride slip shows in the output.
    private static func makeInputs(tokens: Int, n: Int, stride: Int,
                                   seed: UInt64) -> [Float16] {
        var rng = SeedTree(seed).key("small-block-x-\(tokens)x\(n)-\(stride)")
        var values = [Float16](repeating: Float16(512), count: tokens * stride)
        for t in 0..<tokens {
            for i in 0..<n { values[t * stride + i] = Float16(rng.uniform(-1, 1)) }
        }
        return values
    }

    private static func cpuReference(_ w: Weights, x: [Float16], tokens: Int,
                                     n: Int, stride: Int) -> [[Float]] {
        (0..<tokens).map { t in
            w.dequantized.map { row in
                var acc: Float = 0
                for i in 0..<n { acc += row[i] * Float(x[t * stride + i]) }
                return acc
            }
        }
    }

    private struct Run {
        let smallBlock: [[Float]]
        let gemv: [[Float]]
        let untouchedOutsideRows: Bool
    }

    /// Runs one block through the small-block kernel and, separately, through
    /// one GEMV per token, with the same offsets and strides.
    private static func run(ctx: MetalContext, kernel: DequantInt4SmallBlock,
                            gemv: DequantInt4GEMV, w: Weights, x: [Float16],
                            m: Int, n: Int, tokens: Int,
                            xStride: Int, xOffset: Int,
                            yStride: Int, yOffset: Int) throws -> Run {
        let halfBytes = MemoryLayout<Float16>.stride
        var paddedX = [Float16](repeating: 0, count: xOffset / halfBytes)
        paddedX.append(contentsOf: x)
        let xBuffer = try #require(Fp16Buffer.make(ctx.device, halves: paddedX))
        // One spare token row past the block catches a write from a partial tile.
        let yCount = yOffset / halfBytes + (tokens + 1) * yStride
        let filler = [Float16](repeating: sentinel, count: yCount)
        let ySmall = try #require(Fp16Buffer.make(ctx.device, halves: filler))
        let yGEMV = try #require(Fp16Buffer.make(ctx.device, halves: filler))

        let cb = try #require(ctx.queue.makeCommandBuffer())
        let before = kernel.encodedProjections
        let accepted = kernel.encode(commandBuffer: cb,
                                     weights: w.weights, weightsOffset: w.weightsOffset,
                                     scales: w.scales, biases: w.biases,
                                     x: xBuffer, xOffset: xOffset, xStrideElements: xStride,
                                     y: ySmall, yOffset: yOffset, yStrideElements: yStride,
                                     rows: m, columns: n, tokenCount: tokens)
        #expect(accepted)
        #expect(kernel.encodedProjections == before + 1)
        for t in 0..<tokens {
            gemv.encode(commandBuffer: cb,
                        weights: w.weights, weightsOffset: w.weightsOffset,
                        scales: w.scales, biases: w.biases,
                        x: xBuffer, xOffset: xOffset + t * xStride * halfBytes,
                        y: yGEMV, yOffset: yOffset + t * yStride * halfBytes,
                        m: UInt32(m), n: UInt32(n))
        }
        cb.commit()
        cb.waitUntilCompleted()
        #expect(cb.status == .completed)

        let small = Fp16Buffer.readHalf(ySmall, count: yCount)
        let reference = Fp16Buffer.readHalf(yGEMV, count: yCount)
        let base = yOffset / halfBytes
        func rows(_ values: [Float16]) -> [[Float]] {
            (0..<tokens).map { t in (0..<m).map { Float(values[base + t * yStride + $0]) } }
        }
        var untouched = true
        for index in 0..<yCount {
            let relative = index - base
            let insideRow = relative >= 0 && relative / yStride < tokens
                && relative % yStride < m
            if !insideRow, small[index] != sentinel { untouched = false }
        }
        return Run(smallBlock: rows(small), gemv: rows(reference),
                   untouchedOutsideRows: untouched)
    }

    private static func check(m: Int, n: Int, groupSize: Int,
                              contiguous: Bool, seed: UInt64) throws {
        let ctx = try MetalContext()
        let kernel = try DequantInt4SmallBlock(context: ctx, groupSize: groupSize)
        let gemv = try DequantInt4GEMV(context: ctx, groupSize: groupSize)
        // A 2-byte weight offset is the resident-layout case the ushort loads
        // exist for; strides and offsets otherwise mirror strided prefill views.
        let w = try makeWeights(device: ctx.device, m: m, n: n, groupSize: groupSize,
                                seed: seed, weightsOffset: contiguous ? 0 : 2)
        let xStride = contiguous ? n : n + 8
        let yStride = contiguous ? m : m + 3
        let xOffset = contiguous ? 0 : 16
        let yOffset = contiguous ? 0 : 6
        for tokens in tokenCounts {
            let x = makeInputs(tokens: tokens, n: n, stride: xStride, seed: seed)
            let result = try run(ctx: ctx, kernel: kernel, gemv: gemv, w: w, x: x,
                                 m: m, n: n, tokens: tokens,
                                 xStride: xStride, xOffset: xOffset,
                                 yStride: yStride, yOffset: yOffset)
            let cpu = cpuReference(w, x: x, tokens: tokens, n: n, stride: xStride)
            let label = "g\(groupSize) \(m)x\(n) tokens=\(tokens) contiguous=\(contiguous)"
            #expect(result.untouchedOutsideRows, "\(label): wrote outside its rows")
            for t in 0..<tokens {
                let againstCPU = RelError.compute(actual: result.smallBlock[t], reference: cpu[t])
                #expect(againstCPU < Tolerance.fp16Reduction,
                        "\(label) token \(t): relErr vs CPU \(againstCPU)")
                // Same per-token arithmetic as the GEMV. On an M2 the two
                // were bit-identical; the bound allows for a compiler that
                // reassociates one of them differently.
                let againstGEMV = RelError.compute(actual: result.smallBlock[t],
                                                   reference: result.gemv[t])
                #expect(againstGEMV < 2e-3,
                        "\(label) token \(t): relErr vs GEMV \(againstGEMV)")
            }
        }
    }

    /// Group 32, Flash Next widths: hidden 2,560, the hyper-connection low
    /// rank 320 (ten groups, so the remainder loop runs), the stacked
    /// residual 10,240 with four inject rows, and the 160-wide n-gram row.
    /// 61 and 48 rows leave a partial threadgroup of SIMDs.
    @Test(arguments: [(48, 2_560), (61, 320), (4, 10_240), (64, 160)])
    func groupOf32MatchesBothReferences(shape: (m: Int, n: Int)) throws {
        try Self.check(m: shape.m, n: shape.n, groupSize: 32,
                       contiguous: false, seed: 0x5342_3332)
    }

    /// Group 64, Gemma 26B widths: hidden 2,816, the 704 expert width (eleven
    /// groups: two blocks and three remainder groups) and the 2,112 dense
    /// intermediate.
    @Test(arguments: [(40, 2_816), (37, 704), (24, 2_112)])
    func groupOf64MatchesBothReferences(shape: (m: Int, n: Int)) throws {
        try Self.check(m: shape.m, n: shape.n, groupSize: 64,
                       contiguous: false, seed: 0x5342_3634)
    }

    /// The contiguous layout most attention projections use.
    @Test(arguments: [32, 64])
    func contiguousRowsMatchBothReferences(groupSize: Int) throws {
        try Self.check(m: 72, n: groupSize == 32 ? 2_560 : 2_816, groupSize: groupSize,
                       contiguous: true, seed: 0x5342_4354)
    }

    /// A nonfinite input poisons only its own token, exactly as the per-token
    /// GEMV would, and the other tokens in the tile stay correct.
    @Test func nonfiniteInputsStayInTheirOwnToken() throws {
        let m = 16, n = 320, tokens = 5, groupSize = 32
        let ctx = try MetalContext()
        let kernel = try DequantInt4SmallBlock(context: ctx, groupSize: groupSize)
        let gemv = try DequantInt4GEMV(context: ctx, groupSize: groupSize)
        let w = try Self.makeWeights(device: ctx.device, m: m, n: n, groupSize: groupSize,
                                     seed: 0x4E41_4E00, weightsOffset: 0)
        var x = Self.makeInputs(tokens: tokens, n: n, stride: n, seed: 0x4E41_4E00)
        x[2 * n + 7] = .infinity
        x[3 * n + 300] = .nan       // in a remainder group
        let result = try Self.run(ctx: ctx, kernel: kernel, gemv: gemv, w: w, x: x,
                                  m: m, n: n, tokens: tokens,
                                  xStride: n, xOffset: 0, yStride: m, yOffset: 0)
        let cpu = Self.cpuReference(w, x: x, tokens: tokens, n: n, stride: n)
        for t in [0, 1, 4] {
            let finite = result.smallBlock[t].allSatisfy { $0.isFinite }
            #expect(finite, "token \(t) was contaminated")
            #expect(RelError.compute(actual: result.smallBlock[t], reference: cpu[t])
                    < Tolerance.fp16Reduction)
        }
        for t in [2, 3] {
            let poisoned = result.smallBlock[t].contains { !$0.isFinite }
            #expect(poisoned, "token \(t) lost its nonfinite input")
            for (actual, expected) in zip(result.smallBlock[t], result.gemv[t]) {
                #expect(actual.isNaN == expected.isNaN)
                #expect(actual.isInfinite == expected.isInfinite)
                if actual.isInfinite, expected.isInfinite { #expect(actual == expected) }
            }
        }
    }

    /// Blocks split into whole tiles, largest first, covering every token
    /// exactly once.
    @Test func blocksSplitIntoWholeTiles() {
        let expected: [Int: [[Int]]] = [
            2: [[2, 1]], 3: [[2, 1], [1, 1]], 4: [[4, 1]], 5: [[4, 1], [1, 1]],
            7: [[4, 1], [2, 1], [1, 1]], 8: [[8, 1]], 9: [[8, 1], [1, 1]],
            16: [[8, 2]], 31: [[8, 3], [4, 1], [2, 1], [1, 1]],
        ]
        for (tokens, tiles) in expected {
            let plan = DequantInt4SmallBlock.tilePlan(for: tokens).map { [$0.tileTokens, $0.tiles] }
            #expect(plan == tiles, "tokens=\(tokens)")
        }
        for tokens in DequantInt4SmallBlock.admittedTokens {
            let covered = DequantInt4SmallBlock.tilePlan(for: tokens)
                .reduce(0) { $0 + $1.tileTokens * $1.tiles }
            #expect(covered == tokens)
        }
        #expect(DequantInt4SmallBlock.admittedTokens == 2...31)
    }

    /// Every refusal happens before anything is encoded, so the caller's
    /// existing path runs instead.
    @Test func unsupportedShapesAreRefusedWithoutEncoding() throws {
        let ctx = try MetalContext()
        let kernel = try DequantInt4SmallBlock(context: ctx, groupSize: 64)
        let w = try Self.makeWeights(device: ctx.device, m: 8, n: 128, groupSize: 64,
                                     seed: 0x5245_4655, weightsOffset: 2)
        let x = try #require(Fp16Buffer.make(ctx.device, count: 64 * 256))
        let y = try #require(Fp16Buffer.make(ctx.device, count: 64 * 64))
        struct Case { let label: String; let n: Int; let tokens: Int; let weightsOffset: Int
                      let xOffset: Int; let xStride: Int; let yOffset: Int; let yStride: Int }
        let cases = [
            Case(label: "one token", n: 128, tokens: 1, weightsOffset: 2, xOffset: 0, xStride: 128, yOffset: 0, yStride: 8),
            Case(label: "batched threshold", n: 128, tokens: 32, weightsOffset: 2, xOffset: 0, xStride: 128, yOffset: 0, yStride: 8),
            Case(label: "partial group", n: 96, tokens: 4, weightsOffset: 2, xOffset: 0, xStride: 96, yOffset: 0, yStride: 8),
            Case(label: "odd weight offset", n: 128, tokens: 4, weightsOffset: 3, xOffset: 0, xStride: 128, yOffset: 0, yStride: 8),
            Case(label: "x stride breaks half4 alignment", n: 128, tokens: 4, weightsOffset: 2, xOffset: 0, xStride: 130, yOffset: 0, yStride: 8),
            Case(label: "x stride below columns", n: 128, tokens: 4, weightsOffset: 2, xOffset: 0, xStride: 64, yOffset: 0, yStride: 8),
            Case(label: "misaligned x offset", n: 128, tokens: 4, weightsOffset: 2, xOffset: 4, xStride: 128, yOffset: 0, yStride: 8),
            Case(label: "y stride below rows", n: 128, tokens: 4, weightsOffset: 2, xOffset: 0, xStride: 128, yOffset: 0, yStride: 7),
        ]
        for c in cases {
            #expect(!kernel.supports(rows: 8, columns: c.n, tokenCount: c.tokens,
                                     weightsOffset: c.weightsOffset,
                                     xOffset: c.xOffset, xStrideElements: c.xStride,
                                     yOffset: c.yOffset, yStrideElements: c.yStride), "\(c.label)")
            let cb = try #require(ctx.queue.makeCommandBuffer())
            let accepted = kernel.encode(commandBuffer: cb,
                                         weights: w.weights, weightsOffset: c.weightsOffset,
                                         scales: w.scales, biases: w.biases,
                                         x: x, xOffset: c.xOffset, xStrideElements: c.xStride,
                                         y: y, yOffset: c.yOffset, yStrideElements: c.yStride,
                                         rows: 8, columns: c.n, tokenCount: c.tokens)
            #expect(!accepted, "\(c.label)")
            cb.commit()
            cb.waitUntilCompleted()
        }
        #expect(kernel.encodedProjections == 0)
    }
}

@Suite struct SmallBlockPrefillPolicyTests {

    @Test func offUnlessRequestedForAQualifiedModel() {
        let on = [SmallBlockPrefillPolicy.environmentKey: "on"]
        #expect(!SmallBlockPrefillPolicy(environment: [:], variant: .gemma4_26B_A4B).enabled)
        #expect(!SmallBlockPrefillPolicy(environment: [:], variant: .qwen38FlashNext).enabled)
        #expect(SmallBlockPrefillPolicy(environment: on, variant: .gemma4_26B_A4B).enabled)
        #expect(SmallBlockPrefillPolicy(environment: on, variant: .qwen38FlashNext).enabled)
        for variant: ModelVariant in [.gemma4_E2B, .gemma4_E4B, .gemma4_12B_QAT,
                                      .qwen36_35B_A3B, .minimaxM27, .gptOss_20B, .gptOss_120B] {
            #expect(!SmallBlockPrefillPolicy(environment: on, variant: variant).enabled,
                    "\(variant) is not qualified")
        }
        for value in ["1", "ON", "true", "yes", "off", ""] {
            #expect(!SmallBlockPrefillPolicy(
                environment: [SmallBlockPrefillPolicy.environmentKey: value],
                variant: .qwen38FlashNext).enabled, "'\(value)' must not enable it")
        }
    }

    @Test func admitsOnlyShortNonRoutedNonSpeculativeBlocks() {
        let policy = SmallBlockPrefillPolicy(enabled: true)
        for family: PrefillProjectionFamily in [.q, .kv, .o, .shared] {
            #expect(!policy.admits(family: family, tokenCount: 1, speculativeVerification: false))
            #expect(policy.admits(family: family, tokenCount: 2, speculativeVerification: false))
            #expect(policy.admits(family: family, tokenCount: 3, speculativeVerification: false))
            #expect(policy.admits(family: family, tokenCount: 31, speculativeVerification: false))
            #expect(!policy.admits(family: family, tokenCount: 32, speculativeVerification: false))
            #expect(!policy.admits(family: family, tokenCount: 8, speculativeVerification: true))
        }
        #expect(!policy.admits(family: .routed, tokenCount: 8, speculativeVerification: false))
        #expect(!SmallBlockPrefillPolicy.disabled.admits(
            family: .q, tokenCount: 8, speculativeVerification: false))
    }

    @Test func resolvedSettingNamesTheEffectiveState() {
        let on = [SmallBlockPrefillPolicy.environmentKey: "on"]
        #expect(SmallBlockPrefillPolicy.resolvedSetting(environment: [:], variant: .gemma4_26B_A4B) == "off")
        #expect(SmallBlockPrefillPolicy.resolvedSetting(environment: on, variant: .qwen38FlashNext) == "on")
        #expect(SmallBlockPrefillPolicy.resolvedSetting(environment: on, variant: .gemma4_E2B)
                == "off (model not qualified)")
    }

    /// The fallback the small-block path sits in front of is unchanged.
    @Test func existingDispatchPolicyIsUnchanged() {
        for family: PrefillProjectionFamily in [.q, .kv, .o, .shared, .routed] {
            for tokens in [1, 2, 8, 31] {
                #expect(PrefillProjectionDispatchPolicy.selectedDispatch(
                    for: family, chunkTokens: tokens) == .repeatedGEMV)
            }
        }
        #expect(PrefillProjectionDispatchPolicy.selectedDispatch(for: .q, chunkTokens: 32) == .repeatedGEMV)
        for family: PrefillProjectionFamily in [.kv, .o, .shared, .routed] {
            #expect(PrefillProjectionDispatchPolicy.selectedDispatch(for: family, chunkTokens: 32) == .qmm)
        }
    }
}
