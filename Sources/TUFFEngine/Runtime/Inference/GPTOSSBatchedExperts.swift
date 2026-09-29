import Foundation
import Metal

/// GPT-OSS routed experts for a prefill chunk as batched MPP projections.
///
/// Prefill used to encode every token-expert pair on its own: an MXFP4 GEMV
/// for mlp1, a capped-SwiGLU dispatch, and another GEMV for mlp2. On a 16 GB
/// M2 that was 86% of GPT-OSS 20B's prefill GPU time, most of it dispatch
/// overhead and repeated weight reads. Here the pairs routed to one expert are
/// gathered into contiguous rows, mlp1 and mlp2 each run once per expert with
/// their bias applied in the store, and one SwiGLU pass covers every row. The
/// scatter fills the same route partials `encodeFloatResidualReduce` weights
/// and sums, so the residual update is unchanged.
final class GPTOSSBatchedExperts {
    static let maxRows = 1_024
    static let tileM = 64
    static let tileN = 32
    static let tileK = 64

    private let mxfp4PSO: MTLComputePipelineState
    private let gatherPSO: MTLComputePipelineState
    private let scatterPSO: MTLComputePipelineState
    private let swigluPSO: MTLComputePipelineState
    let rows: MTLBuffer
    let mlp1: MTLBuffer
    let activation: MTLBuffer
    let down: MTLBuffer
    let hiddenSize: Int
    let intermediateSize: Int

    /// One expert's pairs: a contiguous run of the chunk's expert-sorted pairs.
    struct Group {
        let blob: TensorView
        let pairStart: Int
        let pairCount: Int
    }

    /// Nil where the MPP path is unavailable or the shape does not tile; the
    /// per-pair kernels serve then.
    init?(context: MetalContext, hiddenSize: Int, intermediateSize: Int) {
        guard hiddenSize.isMultiple(of: Self.tileK),
              intermediateSize.isMultiple(of: Self.tileK),
              let library = try? MetalContext.privateLibrary(device: context.device,
                                                             module: "tensorops"),
              let function = library.makeFunction(name: "mpp_prefill_mxfp4_qmm_f16"),
              let mxfp4 = try? context.device.makeComputePipelineState(function: function),
              let gather = try? context.pipeline("prefill_moe_gather_pair_rows"),
              let scatter = try? context.pipeline("prefill_moe_scatter_pair_rows"),
              let swiglu = try? context.pipeline("gptoss_capped_swiglu_interleaved")
        else { return nil }
        func buffer(_ elements: Int, _ label: String) -> MTLBuffer? {
            let buffer = context.device.makeBuffer(
                length: elements * MemoryLayout<Float16>.stride, options: .storageModePrivate)
            buffer?.label = label
            return buffer
        }
        guard let rows = buffer(Self.maxRows * hiddenSize, "gptoss.batched.rows"),
              let mlp1 = buffer(Self.maxRows * 2 * intermediateSize, "gptoss.batched.mlp1"),
              let activation = buffer(Self.maxRows * intermediateSize, "gptoss.batched.act"),
              let down = buffer(Self.maxRows * hiddenSize, "gptoss.batched.down")
        else { return nil }
        self.mxfp4PSO = mxfp4
        self.gatherPSO = gather
        self.scatterPSO = scatter
        self.swigluPSO = swiglu
        self.rows = rows
        self.mlp1 = mlp1
        self.activation = activation
        self.down = down
        self.hiddenSize = hiddenSize
        self.intermediateSize = intermediateSize
    }

    /// Encodes the groups' pairs in microbatches of at most `maxRows` rows.
    func encode(commandBuffer: MTLCommandBuffer,
                input: MTLBuffer,
                sortedPairs: MTLBuffer,
                groups: [Group],
                offsets: GPTOSSExpertOffsets,
                routePartials: MTLBuffer,
                topK: Int,
                swigluLimit: Float) throws {
        var segments: [(Group, Int, Int)] = []  // group, first pair, rows
        var batchStart = groups.first?.pairStart ?? 0
        var batchRows = 0
        func flush() throws {
            guard batchRows > 0 else { return }
            try encodeMicrobatch(commandBuffer: commandBuffer, input: input,
                                 sortedPairs: sortedPairs, pairStart: batchStart,
                                 rowCount: batchRows, segments: segments,
                                 offsets: offsets, routePartials: routePartials,
                                 topK: topK, swigluLimit: swigluLimit)
            batchStart += batchRows
            batchRows = 0
            segments.removeAll(keepingCapacity: true)
        }
        for group in groups {
            precondition(group.pairStart == batchStart + batchRows,
                         "expert groups must be contiguous in sorted-pair order")
            var taken = 0
            while taken < group.pairCount {
                if batchRows == Self.maxRows { try flush() }
                let count = min(group.pairCount - taken, Self.maxRows - batchRows)
                segments.append((group, batchRows, count))
                batchRows += count
                taken += count
            }
        }
        try flush()
    }

    private func encodeMicrobatch(commandBuffer: MTLCommandBuffer,
                                  input: MTLBuffer,
                                  sortedPairs: MTLBuffer,
                                  pairStart: Int,
                                  rowCount: Int,
                                  segments: [(Group, Int, Int)],
                                  offsets: GPTOSSExpertOffsets,
                                  routePartials: MTLBuffer,
                                  topK: Int,
                                  swigluLimit: Float) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .concurrent) else {
            throw GPTOSSExpertRuntimeError.invalidScratchLayout
        }
        encoder.label = "gptoss.prefill.batched_experts"
        let half = MemoryLayout<Float16>.stride
        let d = hiddenSize, i = intermediateSize
        var start = UInt32(pairStart), count = UInt32(rowCount)
        var dValue = UInt32(d), strideValue = UInt32(d), kValue = UInt32(topK)

        encoder.setComputePipelineState(gatherPSO)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(sortedPairs, offset: 0, index: 1)
        encoder.setBuffer(rows, offset: 0, index: 2)
        encoder.setBytes(&start, length: 4, index: 3)
        encoder.setBytes(&count, length: 4, index: 4)
        encoder.setBytes(&dValue, length: 4, index: 5)
        encoder.setBytes(&strideValue, length: 4, index: 6)
        encoder.dispatchThreads(MTLSize(width: d, height: rowCount, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 4, depth: 1))
        encoder.memoryBarrier(scope: .buffers)

        func project(_ blob: TensorView, weights: Int, scales: Int, bias: Int,
                     x: MTLBuffer, xOffset: Int, y: MTLBuffer, yOffset: Int,
                     m: Int, n: Int, k: Int) throws {
            guard let base = Int(exactly: blob.offset) else {
                throw GPTOSSExpertRuntimeError.invalidBlobRange("blob")
            }
            encoder.setComputePipelineState(mxfp4PSO)
            encoder.setBuffer(blob.buffer, offset: base + weights, index: 0)
            encoder.setBuffer(blob.buffer, offset: base + scales, index: 1)
            encoder.setBuffer(blob.buffer, offset: base + bias, index: 2)
            encoder.setBuffer(x, offset: xOffset, index: 3)
            encoder.setBuffer(y, offset: yOffset, index: 4)
            var mValue = UInt32(m), nValue = UInt32(n), kValue = UInt32(k), hasBias: UInt32 = 1
            encoder.setBytes(&mValue, length: 4, index: 5)
            encoder.setBytes(&nValue, length: 4, index: 6)
            encoder.setBytes(&kValue, length: 4, index: 7)
            encoder.setBytes(&hasBias, length: 4, index: 8)
            encoder.dispatchThreadgroups(
                MTLSize(width: (n + Self.tileN - 1) / Self.tileN,
                        height: (m + Self.tileM - 1) / Self.tileM, depth: 1),
                threadsPerThreadgroup: MTLSize(width: mxfp4PSO.threadExecutionWidth * 4,
                                               height: 1, depth: 1))
        }

        for (group, rowStart, rows) in segments {
            try project(group.blob, weights: offsets.mlp1Weights, scales: offsets.mlp1Scales,
                        bias: offsets.mlp1Bias,
                        x: self.rows, xOffset: rowStart * d * half,
                        y: mlp1, yOffset: rowStart * 2 * i * half,
                        m: rows, n: 2 * i, k: d)
        }
        encoder.memoryBarrier(scope: .buffers)

        // The interleaved kernel pairs output j with inputs 2j and 2j + 1, so
        // it spans every row's [2I] -> [I] at once.
        var elements = UInt32(rowCount * i)
        var limit = swigluLimit
        encoder.setComputePipelineState(swigluPSO)
        encoder.setBuffer(mlp1, offset: 0, index: 0)
        encoder.setBuffer(activation, offset: 0, index: 1)
        encoder.setBytes(&elements, length: 4, index: 2)
        encoder.setBytes(&limit, length: 4, index: 3)
        encoder.dispatchThreads(MTLSize(width: rowCount * i, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(
                                    width: min(256, swigluPSO.maxTotalThreadsPerThreadgroup),
                                    height: 1, depth: 1))
        encoder.memoryBarrier(scope: .buffers)

        for (group, rowStart, rows) in segments {
            try project(group.blob, weights: offsets.mlp2Weights, scales: offsets.mlp2Scales,
                        bias: offsets.mlp2Bias,
                        x: activation, xOffset: rowStart * i * half,
                        y: down, yOffset: rowStart * d * half,
                        m: rows, n: d, k: i)
        }
        encoder.memoryBarrier(scope: .buffers)

        encoder.setComputePipelineState(scatterPSO)
        encoder.setBuffer(down, offset: 0, index: 0)
        encoder.setBuffer(sortedPairs, offset: 0, index: 1)
        encoder.setBuffer(routePartials, offset: 0, index: 2)
        encoder.setBytes(&start, length: 4, index: 3)
        encoder.setBytes(&count, length: 4, index: 4)
        encoder.setBytes(&dValue, length: 4, index: 5)
        encoder.setBytes(&kValue, length: 4, index: 6)
        encoder.dispatchThreads(MTLSize(width: d, height: rowCount, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 4, depth: 1))
        encoder.endEncoding()
    }
}
