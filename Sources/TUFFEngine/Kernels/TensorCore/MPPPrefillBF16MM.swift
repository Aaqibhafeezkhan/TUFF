import Foundation
import Metal

/// Batched BF16-weight projection for chunked prefill: `Y[M, N] =
/// X[M, K] * W[N, K]^T + bias` on the MPP tensor path, FP16 in and out.
///
/// GPT-OSS keeps its attention projections resident in BF16. The batched GEMV
/// they used gave each (token, output row) pair its own SIMD group, so every
/// weight row was read once per token. This reads each weight tile once per
/// 32- or 64-token tile instead.
///
/// Nil where the MSL 4 tensor pipeline does not build; callers keep the GEMV.
final class MPPPrefillBF16MM {
    static let tileK = 64

    private let tiles: [(rows: Int, columns: Int, pso: MTLComputePipelineState)]

    init?(context: MetalContext) {
        guard let library = try? MetalContext.privateLibrary(device: context.device,
                                                             module: "tensorops")
        else { return nil }
        var tiles: [(rows: Int, columns: Int, pso: MTLComputePipelineState)] = []
        for (suffix, rows, columns) in [("_m32", 32, 32), ("", 64, 32)] {
            guard let function = library.makeFunction(name: "mpp_prefill_bf16_mm_f16\(suffix)"),
                  let pso = try? context.device.makeComputePipelineState(function: function)
            else { return nil }
            tiles.append((rows, columns, pso))
        }
        self.tiles = tiles
    }

    /// Encodes the projection, or returns false without encoding when K does
    /// not fill whole tiles or an offset is misaligned. X and Y rows are
    /// contiguous: row strides are K and N.
    @discardableResult
    func encode(commandBuffer: MTLCommandBuffer,
                weights: TensorView,
                bias: TensorView?,
                x: MTLBuffer, xOffset: Int = 0,
                y: MTLBuffer, yOffset: Int = 0,
                m: Int, n: Int, k: Int) -> Bool {
        let halfBytes = MemoryLayout<Float16>.stride
        guard m > 0, n > 0, k > 0, k.isMultiple(of: Self.tileK),
              let weightsOffset = Int(exactly: weights.offset),
              weightsOffset.isMultiple(of: 2),
              xOffset.isMultiple(of: halfBytes), yOffset.isMultiple(of: halfBytes),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }
        let tile = tiles.first { m <= $0.rows } ?? tiles[tiles.count - 1]
        encoder.setComputePipelineState(tile.pso)
        encoder.setBuffer(weights.buffer, offset: weightsOffset, index: 0)
        if let bias {
            encoder.setBuffer(bias.buffer, offset: Int(bias.offset), index: 1)
        } else {
            encoder.setBuffer(weights.buffer, offset: weightsOffset, index: 1)
        }
        encoder.setBuffer(x, offset: xOffset, index: 2)
        encoder.setBuffer(y, offset: yOffset, index: 3)
        var mValue = UInt32(m), nValue = UInt32(n), kValue = UInt32(k)
        var hasBias: UInt32 = bias == nil ? 0 : 1
        encoder.setBytes(&mValue, length: 4, index: 4)
        encoder.setBytes(&nValue, length: 4, index: 5)
        encoder.setBytes(&kValue, length: 4, index: 6)
        encoder.setBytes(&hasBias, length: 4, index: 7)
        encoder.dispatchThreadgroups(
            MTLSize(width: (n + tile.columns - 1) / tile.columns,
                    height: (m + tile.rows - 1) / tile.rows, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tile.pso.threadExecutionWidth * 4,
                                           height: 1, depth: 1))
        encoder.endEncoding()
        return true
    }
}
