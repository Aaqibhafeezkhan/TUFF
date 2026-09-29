import Foundation
import Metal

/// Batched affine-quantized projection for chunked prefill: `Y[M, N] =
/// X[M, K] * W[N, K]^T` on the MPP tensor path, for INT4 or INT8 weights at
/// group 32 or 64.
///
/// Prefill used to run the dense and shared MLPs, and every projection of a
/// group-32 checkpoint, as one GEMV per token. On a 16 GB M2 that was 96% of
/// Gemma 4 E4B's prefill GPU time and about 30% of Qwen 3.8 Flash Next's.
/// This reads each weight tile once per 64 tokens instead.
///
/// Nil where the MSL 4 tensor pipeline does not build (macOS 15, or a GPU
/// whose compiler rejects MPP cooperative tensors); callers keep their
/// per-token path there.
final class MPPPrefillAffineQMM {
    static let tileM = 64
    static let tileN = 32
    static let tileK = 64

    let bits: Int
    let groupSize: Int
    private let pso: MTLComputePipelineState

    init?(context: MetalContext, bits: Int, groupSize: Int) {
        guard [4, 8].contains(bits), [32, 64].contains(groupSize) else { return nil }
        let name = "mpp_prefill_affine_qmm_f16_w\(bits)g\(groupSize)"
        guard let library = try? MetalContext.privateLibrary(device: context.device,
                                                             module: "tensorops"),
              let function = library.makeFunction(name: name),
              let pso = try? context.device.makeComputePipelineState(function: function)
        else { return nil }
        self.bits = bits
        self.groupSize = groupSize
        self.pso = pso
    }

    /// Whether a projection of this shape can run here. K must fill whole
    /// 64-wide tiles; X and Y rows must be contiguous.
    static func supports(k: Int, n: Int, m: Int) -> Bool {
        m > 0 && n > 0 && k > 0 && k.isMultiple(of: tileK)
    }

    /// Encodes the projection, or returns false without encoding when the
    /// shape or an offset cannot be served.
    @discardableResult
    func encode(commandBuffer: MTLCommandBuffer,
                weights: MTLBuffer, weightsOffset: Int,
                scales: MTLBuffer, scalesOffset: Int,
                biases: MTLBuffer, biasesOffset: Int,
                x: MTLBuffer, xOffset: Int = 0,
                y: MTLBuffer, yOffset: Int = 0,
                m: Int, n: Int, k: Int) -> Bool {
        guard accepts(scalesOffset: scalesOffset, biasesOffset: biasesOffset,
                      xOffset: xOffset, yOffset: yOffset, m: m, n: n, k: k),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        encode(into: encoder,
               weights: weights, weightsOffset: weightsOffset,
               scales: scales, scalesOffset: scalesOffset,
               biases: biases, biasesOffset: biasesOffset,
               x: x, xOffset: xOffset, y: y, yOffset: yOffset,
               m: m, n: n, k: k)
        encoder.endEncoding()
        return true
    }

    /// Whether `encode(into:)` will serve these arguments.
    func accepts(scalesOffset: Int, biasesOffset: Int,
                 xOffset: Int, yOffset: Int, m: Int, n: Int, k: Int) -> Bool {
        let halfBytes = MemoryLayout<Float16>.stride
        return Self.supports(k: k, n: n, m: m)
            && k.isMultiple(of: groupSize)
            && scalesOffset.isMultiple(of: MemoryLayout<UInt16>.stride)
            && biasesOffset.isMultiple(of: MemoryLayout<UInt16>.stride)
            && xOffset.isMultiple(of: halfBytes)
            && yOffset.isMultiple(of: halfBytes)
    }

    /// Encodes into an encoder the caller owns, so many projections can share
    /// one concurrent pass. The caller checks `accepts` first.
    func encode(into encoder: MTLComputeCommandEncoder,
                weights: MTLBuffer, weightsOffset: Int,
                scales: MTLBuffer, scalesOffset: Int,
                biases: MTLBuffer, biasesOffset: Int,
                x: MTLBuffer, xOffset: Int,
                y: MTLBuffer, yOffset: Int,
                m: Int, n: Int, k: Int) {
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(weights, offset: weightsOffset, index: 0)
        encoder.setBuffer(scales, offset: scalesOffset, index: 1)
        encoder.setBuffer(biases, offset: biasesOffset, index: 2)
        encoder.setBuffer(x, offset: xOffset, index: 3)
        encoder.setBuffer(y, offset: yOffset, index: 4)
        var mValue = UInt32(m), nValue = UInt32(n), kValue = UInt32(k)
        encoder.setBytes(&mValue, length: MemoryLayout<UInt32>.size, index: 5)
        encoder.setBytes(&nValue, length: MemoryLayout<UInt32>.size, index: 6)
        encoder.setBytes(&kValue, length: MemoryLayout<UInt32>.size, index: 7)
        encoder.dispatchThreadgroups(
            MTLSize(width: (n + Self.tileN - 1) / Self.tileN,
                    height: (m + Self.tileM - 1) / Self.tileM,
                    depth: 1),
            threadsPerThreadgroup: MTLSize(width: pso.threadExecutionWidth * 4,
                                           height: 1, depth: 1))
    }
}
