import Foundation
import Metal
import Testing
import TUFFValidationSupport
@testable import TUFFEngine

@Suite struct SharedExpertGatedPrecisionTests {
    @Test(arguments: [1, 4, 32])
    func batchedGatedProjectionUsesEachRowsGate(tokens: Int) throws {
        let context = try MetalContext()
        let d = 64
        let weights = [UInt8](repeating: 0x11, count: d * d / 2)
        let scales = [UInt16](repeating: 0x3f80, count: d * d / 32)
        let biases = [UInt16](repeating: 0, count: scales.count)
        let w = try #require(context.device.makeBuffer(bytes: weights, length: weights.count))
        let s = try #require(context.device.makeBuffer(bytes: scales, length: scales.count * 2))
        let b = try #require(context.device.makeBuffer(bytes: biases, length: biases.count * 2))
        let input = try #require(Fp16Buffer.make(context.device,
            values: [123] + Array(repeating: 4096, count: tokens * d)))
        let output = try #require(Fp16Buffer.make(context.device,
            values: [-7] + Array(repeating: 0, count: tokens * d) + [-7]))
        let gates = (0..<tokens).map { Float([-8, -4, -16][$0 % 3]) }
        let gate = try #require(Fp16Buffer.make(context.device, values: [123] + gates))
        let kernel = try DequantInt4GEMV(context: context, groupSize: 32)
        let cb = try #require(context.queue.makeCommandBuffer())
        kernel.encode(commandBuffer: cb, weights: w, scales: s, biases: b,
            x: input, xOffset: 2, y: output, yOffset: 2, m: UInt32(d), n: UInt32(d),
            outputGate: gate, outputGateOffset: 2, queryCount: tokens)
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.status == .completed)
        let values = Fp16Buffer.read(output, count: tokens * d + 2)
        #expect(values.first == -7 && values.last == -7)
        for row in 0..<tokens {
            let expected = Float(Float16(262_144 / (1 + exp(-gates[row]))))
            #expect(values[(1 + row * d)..<(1 + (row + 1) * d)].allSatisfy {
                $0.isFinite && abs($0 - expected) <= max(0.05, abs(expected) * 0.002)
            })
        }
    }

    /// The unscaled down projection is 262,144, beyond FP16's range, while
    /// every gated result fits. This reproduces the installed 397B failure.
    @Test(arguments: [1, 4, 32])
    func gatePrecedesHalfConversionInDecodeAndPrefill(tokens: Int) throws {
        let context = try MetalContext()
        let d = 64, f = 64, group = 32
        func projection(rows: Int, columns: Int) throws -> SharedExpertProjection {
            let weights = [UInt8](repeating: 0x11, count: rows * columns / 2)
            let scales = [UInt16](repeating: 0x3f80, count: rows * columns / group)
            let biases = [UInt16](repeating: 0, count: scales.count)
            return SharedExpertProjection(
                weights: try #require(context.device.makeBuffer(bytes: weights, length: weights.count)),
                scales: try #require(context.device.makeBuffer(bytes: scales, length: scales.count * 2)),
                biases: try #require(context.device.makeBuffer(bytes: biases, length: biases.count * 2)),
                rows: UInt32(rows), cols: UInt32(columns))
        }
        let gate = try projection(rows: f, columns: d)
        let up = try projection(rows: f, columns: d)
        let down = try projection(rows: d, columns: f)
        let x = try #require(Fp16Buffer.make(context.device, values: Array(repeating: 1, count: tokens * d)))
        let y = try #require(Fp16Buffer.make(context.device, count: tokens * d))
        let sg = try #require(Fp16Buffer.make(context.device, count: tokens * f))
        let su = try #require(Fp16Buffer.make(context.device, count: tokens * f))
        let sa = try #require(Fp16Buffer.make(context.device, count: tokens * f))
        let logits = (0..<tokens).map { Float([-8, -4, -16][$0 % 3]) }
        let scalar = try #require(Fp16Buffer.make(context.device, values: [123] + logits))
        let cb = try #require(context.queue.makeCommandBuffer())
        if tokens == 1 {
            let runtime = try SharedExpertInt4(context: context, siluActivation: true, groupSize: group)
            try runtime.encode(commandBuffer: cb, x: x, gate: gate, up: up, down: down, y: y,
                scratchGate: sg, scratchUp: su, scratchAct: sa,
                outputGate: scalar, outputGateOffset: 2)
        } else {
            let runtime = try PrefillSharedExpert(context: context, weightBits: 4,
                siluActivation: true, groupSize: group)
            try runtime.encodeBlock(commandBuffer: cb, x: x, y: y, gate: gate, up: up, down: down,
                scratchGate: sg, scratchUp: su, scratchAct: sa, queryCount: tokens, d: d,
                intermediate: f, xStrideElements: d, yStrideElements: d,
                outputGate: scalar, outputGateOffset: 2)
        }
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.status == .completed)
        let output = Fp16Buffer.read(y, count: tokens * d)
        for row in 0..<tokens {
            let expected = Float(Float16(262_144 / (1 + exp(-logits[row]))))
            for value in output[(row * d)..<((row + 1) * d)] {
                #expect(value.isFinite)
                #expect(abs(value - expected) <= max(0.05, abs(expected) * 0.002))
            }
        }
    }
}
