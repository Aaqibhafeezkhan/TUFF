import Foundation
import Metal

final class PrefillSharedExpert {
    private let shared: SharedExpertRuntime
    private let batched: MPPPrefillAffineQMM?
    /// Opt-in shared-weight path for 2-31 token blocks of an INT4 shared
    /// expert. Nil unless the runner's small-block policy enabled it.
    private let smallBlock: DequantInt4SmallBlock?
    private let activationPSO: MTLComputePipelineState

    /// Fewest tokens that take the batched path: the threshold TUFF's batched
    /// projections already use. Below it, including every speculative
    /// verification block, the per-token kernels decode uses keep their
    /// numerics.
    static let minimumBatchedTokens = 32

    init(context: MetalContext, weightBits: Int = 8,
         siluActivation: Bool = false,
         groupSize: Int = Quantization.groupSize,
         allowBatched: Bool = true,
         smallBlock: DequantInt4SmallBlock? = nil) throws {
        self.shared = try SharedExpertRuntime(context: context,
                                              weightBits: weightBits,
                                              siluActivation: siluActivation,
                                              groupSize: groupSize)
        // INT8 shared weights are grouped at 64 whatever the checkpoint's INT4
        // group, as `dequant_int8.metal` assumes.
        self.batched = allowBatched
            ? MPPPrefillAffineQMM(context: context, bits: weightBits,
                                  groupSize: weightBits == 8 ? Quantization.groupSize : groupSize)
            : nil
        // INT8 shared experts and a kernel built for another group size keep
        // the per-token path.
        self.smallBlock = weightBits == 4 && smallBlock?.groupSize == groupSize
            ? smallBlock : nil
        self.activationPSO = try context.pipeline(
            siluActivation ? "silu_mul_fp16" : "gelu_mul_fp16")
    }

    var usesBatchedPath: Bool { batched != nil }
    var usesSmallBlockPath: Bool { smallBlock != nil }

    /// Scratch elements each of gate, up and activation needs for `tokens`
    /// rows: a whole chunk on the batched path, one token otherwise.
    static func scratchElements(tokens: Int, intermediate: Int) -> Int {
        max(1, tokens) * intermediate
    }

    func encodeBlock(commandBuffer cb: MTLCommandBuffer,
                            x: MTLBuffer,
                            xOffset: Int = 0,
                            y: MTLBuffer,
                            yOffset: Int = 0,
                            gate: SharedExpertInt8Proj,
                            up: SharedExpertInt8Proj,
                            down: SharedExpertInt8Proj,
                            scratchGate: MTLBuffer,
                            scratchGateOffset: Int = 0,
                            scratchUp: MTLBuffer,
                            scratchUpOffset: Int = 0,
                            scratchAct: MTLBuffer,
                            scratchActOffset: Int = 0,
                            queryCount: Int,
                            d: Int,
                            intermediate: Int,
                            xStrideElements: Int,
                            yStrideElements: Int,
                            allowSmallBlock: Bool = false) throws {
        precondition(queryCount >= 0, "queryCount must be non-negative")
        precondition(d > 0, "d must be positive")
        precondition(intermediate > 0, "intermediate must be positive")
        precondition(xStrideElements >= d, "x stride is too small")
        precondition(yStrideElements >= d, "y stride is too small")
        guard gate.rows == UInt32(intermediate), gate.cols == UInt32(d),
              up.rows == UInt32(intermediate), up.cols == UInt32(d),
              down.rows == UInt32(d), down.cols == UInt32(intermediate) else {
            throw SharedExpertInt8Error.dimensionMismatch(
                "expected gate/up=(\(intermediate),\(d)) down=(\(d),\(intermediate))")
        }

        let halfBytes = MemoryLayout<Float16>.stride
        if queryCount >= Self.minimumBatchedTokens,
           xStrideElements == d, yStrideElements == d,
           try encodeBatched(commandBuffer: cb, x: x, xOffset: xOffset,
                             y: y, yOffset: yOffset,
                             gate: gate, up: up, down: down,
                             scratchGate: scratchGate, scratchGateOffset: scratchGateOffset,
                             scratchUp: scratchUp, scratchUpOffset: scratchUpOffset,
                             scratchAct: scratchAct, scratchActOffset: scratchActOffset,
                             queryCount: queryCount, d: d, intermediate: intermediate) {
            return
        }
        if allowSmallBlock,
           try encodeSmallBlock(commandBuffer: cb, x: x, xOffset: xOffset,
                                y: y, yOffset: yOffset,
                                gate: gate, up: up, down: down,
                                scratchGate: scratchGate, scratchGateOffset: scratchGateOffset,
                                scratchUp: scratchUp, scratchUpOffset: scratchUpOffset,
                                scratchAct: scratchAct, scratchActOffset: scratchActOffset,
                                queryCount: queryCount, d: d, intermediate: intermediate,
                                xStrideElements: xStrideElements,
                                yStrideElements: yStrideElements) {
            return
        }
        for row in 0..<queryCount {
            try shared.encode(commandBuffer: cb,
                              x: x,
                              xOffset: xOffset + row * xStrideElements * halfBytes,
                              gate: gate,
                              up: up,
                              down: down,
                              y: y,
                              yOffset: yOffset + row * yStrideElements * halfBytes,
                              scratchGate: scratchGate,
                              scratchGateOffset: scratchGateOffset,
                              scratchUp: scratchUp,
                              scratchUpOffset: scratchUpOffset,
                              scratchAct: scratchAct,
                              scratchActOffset: scratchActOffset)
        }
    }

    /// A 2-31 token block as three small-block projections around one
    /// activation pass, with the same scratch layout as the batched path:
    /// gate and up [T, I], activation [T, I], down [T, D]. Returns false
    /// before encoding anything when the kernel, the shape or the scratch
    /// cannot serve it, so the caller keeps the per-token loop.
    private func encodeSmallBlock(commandBuffer cb: MTLCommandBuffer,
                                  x: MTLBuffer, xOffset: Int,
                                  y: MTLBuffer, yOffset: Int,
                                  gate: SharedExpertInt8Proj,
                                  up: SharedExpertInt8Proj,
                                  down: SharedExpertInt8Proj,
                                  scratchGate: MTLBuffer, scratchGateOffset: Int,
                                  scratchUp: MTLBuffer, scratchUpOffset: Int,
                                  scratchAct: MTLBuffer, scratchActOffset: Int,
                                  queryCount: Int, d: Int, intermediate: Int,
                                  xStrideElements: Int,
                                  yStrideElements: Int) throws -> Bool {
        guard let smallBlock else { return false }
        let bytes = queryCount * intermediate * MemoryLayout<Float16>.stride
        guard scratchGateOffset + bytes <= scratchGate.length,
              scratchUpOffset + bytes <= scratchUp.length,
              scratchActOffset + bytes <= scratchAct.length else {
            return false
        }
        func accepts(_ projection: SharedExpertInt8Proj,
                     inputOffset: Int, inputStride: Int,
                     outputOffset: Int, outputStride: Int) -> Bool {
            smallBlock.supports(rows: Int(projection.rows), columns: Int(projection.cols),
                                tokenCount: queryCount,
                                weightsOffset: projection.weightsOffset,
                                xOffset: inputOffset, xStrideElements: inputStride,
                                yOffset: outputOffset, yStrideElements: outputStride)
        }
        guard accepts(gate, inputOffset: xOffset, inputStride: xStrideElements,
                      outputOffset: scratchGateOffset, outputStride: intermediate),
              accepts(up, inputOffset: xOffset, inputStride: xStrideElements,
                      outputOffset: scratchUpOffset, outputStride: intermediate),
              accepts(down, inputOffset: scratchActOffset, inputStride: intermediate,
                      outputOffset: yOffset, outputStride: yStrideElements) else {
            return false
        }
        func project(_ projection: SharedExpertInt8Proj,
                     _ input: MTLBuffer, _ inputOffset: Int, _ inputStride: Int,
                     _ output: MTLBuffer, _ outputOffset: Int, _ outputStride: Int) -> Bool {
            smallBlock.encode(commandBuffer: cb,
                              weights: projection.weights, weightsOffset: projection.weightsOffset,
                              scales: projection.scales, scalesOffset: projection.scalesOffset,
                              biases: projection.biases, biasesOffset: projection.biasesOffset,
                              x: input, xOffset: inputOffset, xStrideElements: inputStride,
                              y: output, yOffset: outputOffset, yStrideElements: outputStride,
                              rows: Int(projection.rows), columns: Int(projection.cols),
                              tokenCount: queryCount)
        }
        guard project(gate, x, xOffset, xStrideElements,
                      scratchGate, scratchGateOffset, intermediate),
              project(up, x, xOffset, xStrideElements,
                      scratchUp, scratchUpOffset, intermediate) else {
            throw SharedExpertInt8Error.dimensionMismatch(
                "small-block shared-expert projection refused after its shape was accepted")
        }
        guard let encoder = cb.makeComputeCommandEncoder() else {
            throw SharedExpertInt8Error.dimensionMismatch(
                "small-block shared-expert activation encoder could not be created")
        }
        encoder.setComputePipelineState(activationPSO)
        encoder.setBuffer(scratchGate, offset: scratchGateOffset, index: 0)
        encoder.setBuffer(scratchUp, offset: scratchUpOffset, index: 1)
        encoder.setBuffer(scratchAct, offset: scratchActOffset, index: 2)
        var count = UInt32(queryCount * intermediate)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 3)
        let width = min(activationPSO.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: Int(count), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        guard project(down, scratchAct, scratchActOffset, intermediate,
                      y, yOffset, yStrideElements) else {
            throw SharedExpertInt8Error.dimensionMismatch(
                "small-block shared-expert down projection refused after its shape was accepted")
        }
        return true
    }

    /// The whole chunk as three batched projections around one activation
    /// pass: gate and up [T, I], activation [T, I], down [T, D]. Returns false
    /// before encoding anything when the batched kernel or the scratch cannot
    /// serve it, so the caller falls back to the per-token loop.
    private func encodeBatched(commandBuffer cb: MTLCommandBuffer,
                               x: MTLBuffer, xOffset: Int,
                               y: MTLBuffer, yOffset: Int,
                               gate: SharedExpertInt8Proj,
                               up: SharedExpertInt8Proj,
                               down: SharedExpertInt8Proj,
                               scratchGate: MTLBuffer, scratchGateOffset: Int,
                               scratchUp: MTLBuffer, scratchUpOffset: Int,
                               scratchAct: MTLBuffer, scratchActOffset: Int,
                               queryCount: Int, d: Int, intermediate: Int) throws -> Bool {
        guard let batched,
              MPPPrefillAffineQMM.supports(k: d, n: intermediate, m: queryCount),
              MPPPrefillAffineQMM.supports(k: intermediate, n: d, m: queryCount),
              d.isMultiple(of: batched.groupSize),
              intermediate.isMultiple(of: batched.groupSize) else {
            return false
        }
        let bytes = queryCount * intermediate * MemoryLayout<Float16>.stride
        guard scratchGateOffset + bytes <= scratchGate.length,
              scratchUpOffset + bytes <= scratchUp.length,
              scratchActOffset + bytes <= scratchAct.length else {
            return false
        }
        func project(_ projection: SharedExpertInt8Proj,
                     _ input: MTLBuffer, _ inputOffset: Int,
                     _ output: MTLBuffer, _ outputOffset: Int) -> Bool {
            batched.encode(commandBuffer: cb,
                           weights: projection.weights, weightsOffset: projection.weightsOffset,
                           scales: projection.scales, scalesOffset: projection.scalesOffset,
                           biases: projection.biases, biasesOffset: projection.biasesOffset,
                           x: input, xOffset: inputOffset,
                           y: output, yOffset: outputOffset,
                           m: queryCount, n: Int(projection.rows), k: Int(projection.cols))
        }
        guard project(gate, x, xOffset, scratchGate, scratchGateOffset),
              project(up, x, xOffset, scratchUp, scratchUpOffset) else {
            throw SharedExpertInt8Error.dimensionMismatch(
                "batched shared-expert projection refused after its shape was accepted")
        }
        guard let encoder = cb.makeComputeCommandEncoder() else { return true }
        encoder.setComputePipelineState(activationPSO)
        encoder.setBuffer(scratchGate, offset: scratchGateOffset, index: 0)
        encoder.setBuffer(scratchUp, offset: scratchUpOffset, index: 1)
        encoder.setBuffer(scratchAct, offset: scratchActOffset, index: 2)
        var count = UInt32(queryCount * intermediate)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 3)
        let width = min(activationPSO.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: Int(count), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        guard project(down, scratchAct, scratchActOffset, y, yOffset) else {
            throw SharedExpertInt8Error.dimensionMismatch(
                "batched shared-expert down projection refused after its shape was accepted")
        }
        return true
    }
}
