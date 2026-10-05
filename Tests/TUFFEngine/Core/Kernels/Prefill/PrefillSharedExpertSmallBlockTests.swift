import Foundation
import Metal
import Testing
@testable import TUFFEngine
import TUFFValidationSupport

/// The INT4 shared expert over a 2-31 token block: three small-block
/// projections around one activation pass, against the per-token path the
/// prefill uses today and, for SwiGLU, an independent CPU MLP.
@Suite struct PrefillSharedExpertSmallBlockTests {
    private static let sentinel = Float16(-7.25)

    private struct Projection {
        let gpu: SharedExpertProjection
        let dequantized: [[Float]]
    }

    private static func makeProjection(ctx: MetalContext, rows: Int, cols: Int,
                                       groupSize: Int, rng: inout SplitMix64) throws -> Projection {
        var packed = [UInt8]()
        var scales = [UInt16]()
        var biases = [UInt16]()
        var dequantized = [[Float]]()
        for _ in 0..<rows {
            let row = (0..<cols).map { _ in rng.uniform(-0.25, 0.25) }
            let q = Quantization.quantizeInt4Affine(row, groupSize: groupSize)
            packed.append(contentsOf: q.packed)
            scales.append(contentsOf: q.scales)
            biases.append(contentsOf: q.biases)
            dequantized.append(Quantization.dequantizeInt4Affine(q, n: cols, groupSize: groupSize))
        }
        let w = try #require(ctx.device.makeBuffer(bytes: packed, length: packed.count,
                                                   options: .storageModeShared))
        let s = try #require(ctx.device.makeBuffer(bytes: scales, length: scales.count * 2,
                                                   options: .storageModeShared))
        let b = try #require(ctx.device.makeBuffer(bytes: biases, length: biases.count * 2,
                                                   options: .storageModeShared))
        return Projection(gpu: SharedExpertProjection(weights: w, scales: s, biases: b,
                                                      rows: UInt32(rows), cols: UInt32(cols)),
                          dequantized: dequantized)
    }

    private struct Shape {
        let groupSize: Int
        let silu: Bool
        let d: Int
        let intermediate: Int
    }

    private struct Outcome {
        let rows: [[Float]]
        let untouchedOutsideRows: Bool
    }

    private static func encode(_ prefill: PrefillSharedExpert, ctx: MetalContext,
                               x: MTLBuffer, gate: Projection, up: Projection, down: Projection,
                               shape: Shape, tokens: Int, xStride: Int, yStride: Int,
                               scratchTokens: Int, allowSmallBlock: Bool) throws -> Outcome {
        let yCount = (tokens + 1) * yStride
        let y = try #require(Fp16Buffer.make(ctx.device, halves: .init(repeating: sentinel, count: yCount)))
        let scratch = max(1, scratchTokens) * shape.intermediate
        let scratchGate = try #require(Fp16Buffer.make(ctx.device, count: scratch))
        let scratchUp = try #require(Fp16Buffer.make(ctx.device, count: scratch))
        let scratchAct = try #require(Fp16Buffer.make(ctx.device, count: scratch))
        let cb = try #require(ctx.queue.makeCommandBuffer())
        try prefill.encodeBlock(commandBuffer: cb, x: x, y: y,
                                gate: gate.gpu, up: up.gpu, down: down.gpu,
                                scratchGate: scratchGate, scratchUp: scratchUp, scratchAct: scratchAct,
                                queryCount: tokens, d: shape.d, intermediate: shape.intermediate,
                                xStrideElements: xStride, yStrideElements: yStride,
                                allowSmallBlock: allowSmallBlock)
        cb.commit()
        cb.waitUntilCompleted()
        #expect(cb.error == nil)
        let values = Fp16Buffer.readHalf(y, count: yCount)
        var untouched = true
        for index in 0..<yCount where index / yStride >= tokens || index % yStride >= shape.d {
            if values[index] != sentinel { untouched = false }
        }
        let rows = (0..<tokens).map { t in (0..<shape.d).map { Float(values[t * yStride + $0]) } }
        return Outcome(rows: rows, untouchedOutsideRows: untouched)
    }

    /// SwiGLU with FP16 rounding where the kernels store FP16 scratch.
    private static func cpuSwiGLU(x: [Float16], token: Int, xStride: Int,
                                  gate: Projection, up: Projection, down: Projection,
                                  shape: Shape) -> [Float] {
        let input = (0..<shape.d).map { Float(x[token * xStride + $0]) }
        func dot(_ row: [Float], _ v: [Float]) -> Float {
            var acc: Float = 0
            for i in 0..<v.count { acc += row[i] * v[i] }
            return acc
        }
        let act = (0..<shape.intermediate).map { i -> Float in
            let g = Float(Float16(dot(gate.dequantized[i], input)))
            let u = Float(Float16(dot(up.dequantized[i], input)))
            return Float(Float16((g / (1 + exp(-g))) * u))
        }
        return down.dequantized.map { dot($0, act) }
    }

    /// Flash Next's group 32 with SwiGLU, and Gemma's group 64 with GELU.
    /// Widths leave remainder groups (320 = 10 groups of 32; 704 = 11 of 64).
    private static let shapes = [
        Shape(groupSize: 32, silu: true, d: 320, intermediate: 640),
        Shape(groupSize: 64, silu: false, d: 704, intermediate: 128),
    ]

    @Test(arguments: [0, 1])
    func smallBlockMatchesThePerTokenPath(shapeIndex: Int) throws {
        let shape = Self.shapes[shapeIndex]
        var rng = SeedTree(0x5345_5342).key("shared-small-block-g\(shape.groupSize)")
        let ctx = try MetalContext()
        let kernel = try DequantInt4SmallBlock(context: ctx, groupSize: shape.groupSize)
        let perToken = try PrefillSharedExpert(context: ctx, weightBits: 4, siluActivation: shape.silu,
                                               groupSize: shape.groupSize, allowBatched: false)
        let small = try PrefillSharedExpert(context: ctx, weightBits: 4, siluActivation: shape.silu,
                                            groupSize: shape.groupSize, allowBatched: false,
                                            smallBlock: kernel)
        #expect(!perToken.usesSmallBlockPath)
        #expect(small.usesSmallBlockPath)
        let gate = try Self.makeProjection(ctx: ctx, rows: shape.intermediate, cols: shape.d,
                                           groupSize: shape.groupSize, rng: &rng)
        let up = try Self.makeProjection(ctx: ctx, rows: shape.intermediate, cols: shape.d,
                                         groupSize: shape.groupSize, rng: &rng)
        let down = try Self.makeProjection(ctx: ctx, rows: shape.d, cols: shape.intermediate,
                                           groupSize: shape.groupSize, rng: &rng)
        let xStride = shape.d + 8
        let yStride = shape.d + 4
        for tokens in [2, 3, 5, 8, 13, 31] {
            var values = [Float16](repeating: Float16(512), count: tokens * xStride)
            for t in 0..<tokens {
                for i in 0..<shape.d { values[t * xStride + i] = Float16(rng.uniform(-1, 1)) }
            }
            let x = try #require(Fp16Buffer.make(ctx.device, halves: values))
            let before = kernel.encodedProjections
            let reference = try Self.encode(perToken, ctx: ctx, x: x, gate: gate, up: up, down: down,
                                            shape: shape, tokens: tokens, xStride: xStride,
                                            yStride: yStride, scratchTokens: 1, allowSmallBlock: true)
            let actual = try Self.encode(small, ctx: ctx, x: x, gate: gate, up: up, down: down,
                                         shape: shape, tokens: tokens, xStride: xStride,
                                         yStride: yStride, scratchTokens: tokens, allowSmallBlock: true)
            #expect(kernel.encodedProjections == before + 3, "tokens=\(tokens): path not taken")
            #expect(actual.untouchedOutsideRows, "tokens=\(tokens): wrote outside its rows")
            #expect(reference.untouchedOutsideRows)
            for t in 0..<tokens {
                let error = RelError.compute(actual: actual.rows[t], reference: reference.rows[t])
                #expect(error < 5e-3, "g\(shape.groupSize) tokens=\(tokens) row \(t): relErr \(error)")
                if shape.silu {
                    let cpu = Self.cpuSwiGLU(x: values, token: t, xStride: xStride,
                                             gate: gate, up: up, down: down, shape: shape)
                    let cpuError = RelError.compute(actual: actual.rows[t], reference: cpu)
                    #expect(cpuError < 1e-2, "tokens=\(tokens) row \(t): relErr vs CPU \(cpuError)")
                }
            }
        }
    }

    /// Without permission, or without room for the whole block in scratch,
    /// the per-token path runs and nothing goes through the new kernel.
    @Test func refusedBlocksKeepThePerTokenPath() throws {
        let shape = Self.shapes[0]
        var rng = SeedTree(0x5345_4642).key("shared-small-block-fallback")
        let ctx = try MetalContext()
        let kernel = try DequantInt4SmallBlock(context: ctx, groupSize: shape.groupSize)
        let small = try PrefillSharedExpert(context: ctx, weightBits: 4, siluActivation: true,
                                            groupSize: shape.groupSize, allowBatched: false,
                                            smallBlock: kernel)
        let gate = try Self.makeProjection(ctx: ctx, rows: shape.intermediate, cols: shape.d,
                                           groupSize: shape.groupSize, rng: &rng)
        let up = try Self.makeProjection(ctx: ctx, rows: shape.intermediate, cols: shape.d,
                                         groupSize: shape.groupSize, rng: &rng)
        let down = try Self.makeProjection(ctx: ctx, rows: shape.d, cols: shape.intermediate,
                                           groupSize: shape.groupSize, rng: &rng)
        let tokens = 6
        let values = (0..<(tokens * shape.d)).map { _ in Float16(rng.uniform(-1, 1)) }
        let x = try #require(Fp16Buffer.make(ctx.device, halves: values))
        let notAllowed = try Self.encode(small, ctx: ctx, x: x, gate: gate, up: up, down: down,
                                         shape: shape, tokens: tokens, xStride: shape.d,
                                         yStride: shape.d, scratchTokens: tokens, allowSmallBlock: false)
        let shortScratch = try Self.encode(small, ctx: ctx, x: x, gate: gate, up: up, down: down,
                                           shape: shape, tokens: tokens, xStride: shape.d,
                                           yStride: shape.d, scratchTokens: tokens - 1, allowSmallBlock: true)
        #expect(kernel.encodedProjections == 0)
        for t in 0..<tokens {
            let cpu = Self.cpuSwiGLU(x: values, token: t, xStride: shape.d,
                                     gate: gate, up: up, down: down, shape: shape)
            #expect(RelError.compute(actual: notAllowed.rows[t], reference: cpu) < 1e-2)
            #expect(RelError.compute(actual: shortScratch.rows[t], reference: cpu) < 1e-2)
        }
    }

    @Test func onlyAMatchingInt4SharedExpertTakesTheKernel() throws {
        let ctx = try MetalContext()
        let g32 = try DequantInt4SmallBlock(context: ctx, groupSize: 32)
        let int8 = try PrefillSharedExpert(context: ctx, weightBits: 8, smallBlock: g32)
        let mismatched = try PrefillSharedExpert(context: ctx, weightBits: 4, groupSize: 64,
                                                 smallBlock: g32)
        let matched = try PrefillSharedExpert(context: ctx, weightBits: 4, groupSize: 32,
                                              smallBlock: g32)
        #expect(!int8.usesSmallBlockPath)
        #expect(!mismatched.usesSmallBlockPath)
        #expect(matched.usesSmallBlockPath)
    }
}
