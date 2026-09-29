import Foundation
import Metal
import Testing
@testable import TUFFEngine
import TUFFValidationSupport

@Suite struct MPPPrefillBF16MMTests {
    private static func view(_ buffer: MTLBuffer, offset: Int, count: Int) -> TensorView {
        TensorView(buffer: buffer, offset: UInt64(offset), length: UInt64(count * 2),
                   scaleOffset: 0, scaleLength: 0, biasOffset: 0, biasLength: 0,
                   shape: (UInt32(count), 1, 1, 1), dtype: 1)
    }

    /// The batched BF16 projection matches a CPU reference, including a
    /// weight tensor that starts mid-word and rows that pick the 32-row tile.
    @Test(arguments: [(70, 45, 192), (20, 96, 128), (129, 33, 64)])
    func bf16ProjectionMatchesTheCPUReference(_ c: (Int, Int, Int)) throws {
        let (m, n, k) = c
        let context = try MetalContext()
        guard let mm = MPPPrefillBF16MM(context: context) else {
            #expect(!context.device.supportsFamily(.apple8)
                    || ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26)
            return
        }
        let weights = (0..<(n * k)).map { Float(($0 * 7) % 23 - 11) / 256 }
        let bias = (0..<n).map { Float($0 % 5) / 16 - 0.1 }
        let x = (0..<(m * k)).map { Float16(Float(($0 * 11) % 29 - 14) / 64) }
        // Two bytes of padding before the weights; bias follows them.
        var bytes = [UInt16](repeating: 0, count: 1)
        bytes += weights.map(Quantization.bf16Bits)
        let biasStart = bytes.count
        bytes += bias.map(Quantization.bf16Bits)
        let device = context.device
        let blob = try #require(device.makeBuffer(bytes: bytes, length: bytes.count * 2))
        let xBuf = try #require(device.makeBuffer(bytes: x, length: x.count * 2))
        let yBuf = try #require(device.makeBuffer(length: m * n * 2, options: .storageModeShared))
        let cb = try #require(context.queue.makeCommandBuffer())
        #expect(mm.encode(commandBuffer: cb,
                          weights: Self.view(blob, offset: 2, count: n * k),
                          bias: Self.view(blob, offset: biasStart * 2, count: n),
                          x: xBuf, y: yBuf, m: m, n: n, k: k))
        cb.commit()
        cb.waitUntilCompleted()
        try checkCommandBufferError(cb)

        var reference = [Float](repeating: 0, count: m * n)
        for t in 0..<m {
            for row in 0..<n {
                var acc = Quantization.bf16ToFloat(Quantization.bf16Bits(bias[row]))
                for kk in 0..<k {
                    let w = Quantization.bf16ToFloat(Quantization.bf16Bits(weights[row * k + kk]))
                    acc += Float(Float16(w)) * Float(x[t * k + kk])
                }
                reference[t * n + row] = acc
            }
        }
        let pointer = yBuf.contents().bindMemory(to: Float16.self, capacity: m * n)
        let actual = (0..<(m * n)).map { Float(pointer[$0]) }
        let rel = RelError.compute(actual: actual, reference: reference)
        #expect(rel < 5e-3, "m=\(m) n=\(n) k=\(k) rel=\(rel)")
    }
}
