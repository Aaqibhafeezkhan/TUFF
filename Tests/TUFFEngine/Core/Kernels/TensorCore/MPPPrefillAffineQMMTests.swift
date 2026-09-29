import Foundation
import Metal
import Testing
@testable import TUFFEngine
import TUFFValidationSupport

@Suite struct MPPPrefillAffineQMMTests {
    /// Every layout TUFF ships, with shapes that leave partial M and N tiles
    /// and K spanning several 64-wide tiles.
    @Test(arguments: [
        (4, 32, 70, 45, 192),
        (4, 64, 70, 45, 192),
        (8, 64, 70, 45, 192),
        (8, 32, 1, 33, 128),
        (4, 32, 129, 96, 640),
    ])
    func matchesTheCPUReference(_ c: (Int, Int, Int, Int, Int)) throws {
        let (bits, group, m, n, k) = c
        let context = try MetalContext()
        guard let qmm = MPPPrefillAffineQMM(context: context, bits: bits, groupSize: group)
        else {
            // Absent only where MSL 4 tensors are unavailable; the callers
            // keep their per-token path there.
            #expect(!context.device.supportsFamily(.apple8)
                    || ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26)
            return
        }

        let groups = k / group
        let rowBytes = k * bits / 8
        var packed = [UInt8](repeating: 0, count: n * rowBytes)
        for i in packed.indices { packed[i] = UInt8(truncatingIfNeeded: i &* 37 &+ 0x29) }
        var scales = [UInt16](repeating: 0, count: n * groups)
        var biases = [UInt16](repeating: 0, count: n * groups)
        let step: Float = bits == 4 ? 0.00025 : 0.00002
        for row in 0..<n {
            for g in 0..<groups {
                scales[row * groups + g] = Quantization.bf16Bits(
                    (bits == 4 ? 0.001 : 0.0001) + Float((row + g) % 5) * step)
                biases[row * groups + g] = Quantization.bf16Bits(
                    -0.01 + Float((row * 3 + g) % 7) * 0.002)
            }
        }
        var x = [Float16](repeating: 0, count: m * k)
        for i in x.indices { x[i] = Float16(Float((i * 11) % 29 - 14) / 64.0) }

        var reference = [Float](repeating: 0, count: m * n)
        for t in 0..<m {
            for row in 0..<n {
                var acc: Float = 0
                for kk in 0..<k {
                    let q: Float
                    if bits == 4 {
                        let byte = packed[row * rowBytes + kk / 2]
                        q = Float(kk % 2 == 0 ? byte & 0x0F : byte >> 4)
                    } else {
                        q = Float(packed[row * rowBytes + kk])
                    }
                    let g = row * groups + kk / group
                    // The kernel stages each dequantized weight as FP16.
                    let w = Float(Float16(q * Quantization.bf16ToFloat(scales[g])
                                          + Quantization.bf16ToFloat(biases[g])))
                    acc += w * Float(x[t * k + kk])
                }
                reference[t * n + row] = acc
            }
        }

        let device = context.device
        let wBuf = try #require(device.makeBuffer(bytes: packed, length: packed.count))
        let sBuf = try #require(device.makeBuffer(bytes: scales, length: scales.count * 2))
        let bBuf = try #require(device.makeBuffer(bytes: biases, length: biases.count * 2))
        let xBuf = try #require(device.makeBuffer(bytes: x, length: x.count * 2))
        let yBuf = try #require(device.makeBuffer(length: m * n * 2, options: .storageModeShared))
        let cb = try #require(context.queue.makeCommandBuffer())
        #expect(qmm.encode(commandBuffer: cb,
                           weights: wBuf, weightsOffset: 0,
                           scales: sBuf, scalesOffset: 0,
                           biases: bBuf, biasesOffset: 0,
                           x: xBuf, y: yBuf, m: m, n: n, k: k))
        cb.commit()
        cb.waitUntilCompleted()
        try checkCommandBufferError(cb)

        let pointer = yBuf.contents().bindMemory(to: Float16.self, capacity: m * n)
        let actual = (0..<(m * n)).map { Float(pointer[$0]) }
        let rel = RelError.compute(actual: actual, reference: reference)
        #expect(rel < 5e-3, "w\(bits)g\(group) m=\(m) n=\(n) k=\(k) rel=\(rel)")
    }

    @Test func refusesAShapeItCannotTile() throws {
        let context = try MetalContext()
        guard let qmm = MPPPrefillAffineQMM(context: context, bits: 4, groupSize: 32) else { return }
        let buffer = try #require(context.device.makeBuffer(length: 4_096))
        let cb = try #require(context.queue.makeCommandBuffer())
        #expect(!qmm.encode(commandBuffer: cb,
                            weights: buffer, weightsOffset: 0,
                            scales: buffer, scalesOffset: 0,
                            biases: buffer, biasesOffset: 0,
                            x: buffer, y: buffer, m: 4, n: 4, k: 96))
        #expect(MPPPrefillAffineQMM(context: context, bits: 3, groupSize: 64) == nil)
    }
}
