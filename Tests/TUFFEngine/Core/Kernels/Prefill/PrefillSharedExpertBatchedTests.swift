import Foundation
import Metal
import Testing
@testable import TUFFEngine
import TUFFValidationSupport

/// The batched dense/shared MLP must agree with the per-token decode kernels
/// it replaces in prefill, for every weight layout TUFF ships.
@Suite struct PrefillSharedExpertBatchedTests {
    private static let d = 256
    private static let f = 192

    @Test(arguments: [
        // bits, group, silu, tokens
        (4, 64, false, 70),   // Gemma 4 dense / shared MLP
        (4, 32, true, 70),    // Qwen 3.8 Flash Next shared expert
        (8, 64, false, 70),   // Gemma 4 12B dense MLP
        (4, 64, true, 129),   // Qwen 3.6 shared expert, partial tiles
    ])
    func batchedMatchesPerTokenRows(_ c: (Int, Int, Bool, Int)) throws {
        let (bits, group, silu, tokens) = c
        let ctx = try MetalContext()
        let batched = try PrefillSharedExpert(context: ctx, weightBits: bits,
                                              siluActivation: silu, groupSize: group)
        guard batched.usesBatchedPath else { return }
        let perToken = try PrefillSharedExpert(context: ctx, weightBits: bits,
                                               siluActivation: silu, groupSize: group,
                                               allowBatched: false)
        var rng = SeedTree(0xB47C).key("shared-batched-\(bits)-\(group)-\(silu)")
        let gate = Self.projection(ctx, rows: Self.f, cols: Self.d, bits: bits, group: group, rng: &rng)
        let up = Self.projection(ctx, rows: Self.f, cols: Self.d, bits: bits, group: group, rng: &rng)
        let down = Self.projection(ctx, rows: Self.d, cols: Self.f, bits: bits, group: group, rng: &rng)
        let x = (0..<(tokens * Self.d)).map { _ in Float16(rng.uniform(-0.5, 0.5)) }

        func run(_ expert: PrefillSharedExpert) throws -> [Float] {
            let scratch = PrefillSharedExpert.scratchElements(tokens: tokens, intermediate: Self.f)
            guard let xBuf = Fp16Buffer.make(ctx.device, halves: x),
                  let y = Fp16Buffer.make(ctx.device, count: tokens * Self.d),
                  let g = Fp16Buffer.make(ctx.device, count: scratch),
                  let u = Fp16Buffer.make(ctx.device, count: scratch),
                  let a = Fp16Buffer.make(ctx.device, count: scratch),
                  let cb = ctx.queue.makeCommandBuffer() else {
                Issue.record("allocation failed")
                return []
            }
            try expert.encodeBlock(commandBuffer: cb, x: xBuf, y: y,
                                   gate: gate, up: up, down: down,
                                   scratchGate: g, scratchUp: u, scratchAct: a,
                                   queryCount: tokens, d: Self.d, intermediate: Self.f,
                                   xStrideElements: Self.d, yStrideElements: Self.d)
            cb.commit()
            cb.waitUntilCompleted()
            try checkCommandBufferError(cb)
            return Fp16Buffer.read(y, count: tokens * Self.d)
        }

        let expected = try run(perToken)
        let actual = try run(batched)
        let rel = RelError.compute(actual: actual, reference: expected)
        #expect(rel < 1e-2, "w\(bits)g\(group) silu=\(silu) t=\(tokens) rel=\(rel)")
    }

    /// Speculative verification blocks stay on the decode kernels, so their
    /// numerics are unchanged.
    @Test func shortBlocksKeepThePerTokenKernels() throws {
        let ctx = try MetalContext()
        let batched = try PrefillSharedExpert(context: ctx, weightBits: 4)
        let perToken = try PrefillSharedExpert(context: ctx, weightBits: 4, allowBatched: false)
        var rng = SeedTree(0xB47D).key("shared-short-block")
        let gate = Self.projection(ctx, rows: Self.f, cols: Self.d, bits: 4, group: 64, rng: &rng)
        let up = Self.projection(ctx, rows: Self.f, cols: Self.d, bits: 4, group: 64, rng: &rng)
        let down = Self.projection(ctx, rows: Self.d, cols: Self.f, bits: 4, group: 64, rng: &rng)
        let tokens = PrefillSharedExpert.minimumBatchedTokens - 1
        let x = (0..<(tokens * Self.d)).map { _ in Float16(rng.uniform(-0.5, 0.5)) }
        var outputs: [[Float16]] = []
        for expert in [batched, perToken] {
            let xBuf = try #require(Fp16Buffer.make(ctx.device, halves: x))
            let y = try #require(Fp16Buffer.make(ctx.device, count: tokens * Self.d))
            let g = try #require(Fp16Buffer.make(ctx.device, count: tokens * Self.f))
            let u = try #require(Fp16Buffer.make(ctx.device, count: tokens * Self.f))
            let a = try #require(Fp16Buffer.make(ctx.device, count: tokens * Self.f))
            let cb = try #require(ctx.queue.makeCommandBuffer())
            try expert.encodeBlock(commandBuffer: cb, x: xBuf, y: y,
                                   gate: gate, up: up, down: down,
                                   scratchGate: g, scratchUp: u, scratchAct: a,
                                   queryCount: tokens, d: Self.d, intermediate: Self.f,
                                   xStrideElements: Self.d, yStrideElements: Self.d)
            cb.commit()
            cb.waitUntilCompleted()
            try checkCommandBufferError(cb)
            outputs.append(Fp16Buffer.readHalf(y, count: tokens * Self.d))
        }
        #expect(outputs[0] == outputs[1])
    }

    private static func projection(_ ctx: MetalContext, rows: Int, cols: Int,
                                   bits: Int, group: Int,
                                   rng: inout SplitMix64) -> SharedExpertInt8Proj {
        let packed = (0..<(rows * cols * bits / 8)).map { _ in
            UInt8(truncatingIfNeeded: Int(rng.uniform(0, 255)))
        }
        let groups = rows * cols / group
        let scale: Float = bits == 4 ? 0.02 : 0.0015
        let scales = (0..<groups).map { _ in Quantization.bf16Bits(rng.uniform(0.5, 1.5) * scale) }
        let biases = (0..<groups).map { _ in
            Quantization.bf16Bits(-rng.uniform(0.5, 1.5) * scale * (bits == 4 ? 7.5 : 127.5))
        }
        let w = ctx.device.makeBuffer(bytes: packed, length: packed.count, options: .storageModeShared)!
        let s = ctx.device.makeBuffer(bytes: scales, length: scales.count * 2, options: .storageModeShared)!
        let b = ctx.device.makeBuffer(bytes: biases, length: biases.count * 2, options: .storageModeShared)!
        return SharedExpertInt8Proj(weights: w, scales: s, biases: b,
                                    rows: UInt32(rows), cols: UInt32(cols))
    }
}
