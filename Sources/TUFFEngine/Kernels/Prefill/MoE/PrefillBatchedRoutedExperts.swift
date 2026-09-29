import Foundation
import Metal

/// Routed experts for a chunked-prefill tile as batched MPP projections.
///
/// The per-pair kernels compute every output element of every token-expert
/// pair from a fresh read of that expert's weight row; an expert's gate and up
/// matrices (about 2 MB on Gemma 4 26B) do not fit in GPU cache, so weights
/// came from memory once per pair. Here the tile's pairs, already sorted by
/// expert, are gathered into contiguous rows and each expert runs one
/// `[rows, D] x [F, D]^T` gate and up projection, one activation pass, and one
/// `[rows, F] x [D, F]^T` down projection. The scatter writes the same
/// `route_partials` slots the per-pair kernels do, so the reduction after the
/// tile is unchanged.
///
/// Rows are processed in microbatches of at most `maxRows`, which bounds the
/// scratch whatever the chunk size and routing skew.
final class PrefillBatchedRoutedExperts {
    static let maxRows = 1_024

    private let qmm: MPPPrefillAffineQMM
    private let gatherPSO: MTLComputePipelineState
    private let scatterPSO: MTLComputePipelineState
    private let activationPSO: MTLComputePipelineState

    struct Scratch {
        let rows: MTLBuffer
        let gate: MTLBuffer
        let up: MTLBuffer
        let act: MTLBuffer
        let down: MTLBuffer

        static func bytes(d: Int, f: Int) -> Int {
            PrefillBatchedRoutedExperts.maxRows * (2 * d + 3 * f) * MemoryLayout<Float16>.stride
        }
    }

    /// Nil where the MPP path is unavailable; the per-pair kernels serve then.
    init?(context: MetalContext, groupSize: Int, siluActivation: Bool) {
        guard let qmm = MPPPrefillAffineQMM(context: context, bits: 4, groupSize: groupSize),
              let gather = try? context.pipeline("prefill_moe_gather_pair_rows"),
              let scatter = try? context.pipeline("prefill_moe_scatter_pair_rows"),
              let activation = try? context.pipeline(
                siluActivation ? "silu_mul_fp16" : "gelu_mul_fp16") else {
            return nil
        }
        self.qmm = qmm
        self.gatherPSO = gather
        self.scatterPSO = scatter
        self.activationPSO = activation
    }

    static func makeScratch(device: MTLDevice, d: Int, f: Int) throws -> Scratch {
        func buffer(_ elements: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: elements * MemoryLayout<Float16>.stride,
                                                 options: .storageModePrivate) else {
                throw PrefillGroupedRoutedMoEError.allocationFailed(label)
            }
            buffer.label = label
            return buffer
        }
        return Scratch(rows: try buffer(maxRows * d, "prefill.routed.rows"),
                       gate: try buffer(maxRows * f, "prefill.routed.gate"),
                       up: try buffer(maxRows * f, "prefill.routed.up"),
                       act: try buffer(maxRows * f, "prefill.routed.act"),
                       down: try buffer(maxRows * d, "prefill.routed.down"))
    }

    /// Whether every projection of this expert shape can run batched.
    func supports(d: Int, f: Int) -> Bool {
        MPPPrefillAffineQMM.supports(k: d, n: f, m: 1)
            && MPPPrefillAffineQMM.supports(k: f, n: d, m: 1)
            && d.isMultiple(of: qmm.groupSize)
            && f.isMultiple(of: qmm.groupSize)
    }

    private struct Segment {
        let view: TensorView
        let rowStart: Int
        let rowCount: Int
    }

    /// Encodes one tile. `groups` are the tile's expert groups in sorted-pair
    /// order; `views` holds each group's expert blob, in the same order.
    /// Returns the number of microbatches encoded.
    @discardableResult
    func encodeTile(commandBuffer: MTLCommandBuffer,
                    hidden: MTLBuffer,
                    hiddenStrideElements: Int,
                    sortedPairs: MTLBuffer,
                    groups: [PrefillMoEGroup],
                    views: [TensorView],
                    offsets: MoEExpertOffsets,
                    routePartials: MTLBuffer,
                    scratch: Scratch,
                    d: Int, f: Int, topK: Int) throws -> Int {
        precondition(groups.count == views.count, "one expert view per group")
        var microbatches = 0
        var segments: [Segment] = []
        var batchPairStart = groups.first.map { Int($0.pairStart) } ?? 0
        var batchRows = 0

        func flush() throws {
            guard batchRows > 0 else { return }
            try encodeMicrobatch(commandBuffer: commandBuffer, hidden: hidden,
                                 hiddenStrideElements: hiddenStrideElements,
                                 sortedPairs: sortedPairs, pairStart: batchPairStart,
                                 rows: batchRows, segments: segments, offsets: offsets,
                                 routePartials: routePartials, scratch: scratch,
                                 d: d, f: f, topK: topK)
            microbatches += 1
            batchPairStart += batchRows
            batchRows = 0
            segments.removeAll(keepingCapacity: true)
        }

        for (group, view) in zip(groups, views) {
            precondition(Int(group.pairStart) == batchPairStart + batchRows,
                         "tile groups must be contiguous in sorted-pair order")
            var remaining = Int(group.pairCount)
            while remaining > 0 {
                if batchRows == Self.maxRows { try flush() }
                let take = min(remaining, Self.maxRows - batchRows)
                segments.append(Segment(view: view, rowStart: batchRows, rowCount: take))
                batchRows += take
                remaining -= take
            }
        }
        try flush()
        return microbatches
    }

    private func encodeMicrobatch(commandBuffer: MTLCommandBuffer,
                                  hidden: MTLBuffer,
                                  hiddenStrideElements: Int,
                                  sortedPairs: MTLBuffer,
                                  pairStart: Int,
                                  rows: Int,
                                  segments: [Segment],
                                  offsets: MoEExpertOffsets,
                                  routePartials: MTLBuffer,
                                  scratch: Scratch,
                                  d: Int, f: Int, topK: Int) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .concurrent) else {
            throw PrefillGroupedRoutedMoEError.allocationFailed("routed batched encoder")
        }
        encoder.label = "prefill.routed.batched"
        let half = MemoryLayout<Float16>.stride
        var start = UInt32(pairStart), count = UInt32(rows)
        var dValue = UInt32(d), strideValue = UInt32(hiddenStrideElements), kValue = UInt32(topK)

        encoder.setComputePipelineState(gatherPSO)
        encoder.setBuffer(hidden, offset: 0, index: 0)
        encoder.setBuffer(sortedPairs, offset: 0, index: 1)
        encoder.setBuffer(scratch.rows, offset: 0, index: 2)
        encoder.setBytes(&start, length: 4, index: 3)
        encoder.setBytes(&count, length: 4, index: 4)
        encoder.setBytes(&dValue, length: 4, index: 5)
        encoder.setBytes(&strideValue, length: 4, index: 6)
        encoder.dispatchThreads(MTLSize(width: d, height: rows, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 4, depth: 1))
        encoder.memoryBarrier(scope: .buffers)

        func project(_ segment: Segment, w: UInt32, s: UInt32, b: UInt32,
                     x: MTLBuffer, xStride: Int, y: MTLBuffer, yStride: Int,
                     n: Int, k: Int) throws {
            let base = Int(segment.view.offset)
            let xOffset = segment.rowStart * xStride * half
            let yOffset = segment.rowStart * yStride * half
            guard qmm.accepts(scalesOffset: base + Int(s), biasesOffset: base + Int(b),
                              xOffset: xOffset, yOffset: yOffset,
                              m: segment.rowCount, n: n, k: k) else {
                throw PrefillGroupedRoutedMoEError.invalidStreamedTileBinding(
                    "batched routed projection refused (n=\(n) k=\(k))")
            }
            qmm.encode(into: encoder,
                       weights: segment.view.buffer, weightsOffset: base + Int(w),
                       scales: segment.view.buffer, scalesOffset: base + Int(s),
                       biases: segment.view.buffer, biasesOffset: base + Int(b),
                       x: x, xOffset: xOffset, y: y, yOffset: yOffset,
                       m: segment.rowCount, n: n, k: k)
        }

        for segment in segments {
            try project(segment, w: offsets.gateWOff, s: offsets.gateSOff, b: offsets.gateBOff,
                        x: scratch.rows, xStride: d, y: scratch.gate, yStride: f, n: f, k: d)
            try project(segment, w: offsets.upWOff, s: offsets.upSOff, b: offsets.upBOff,
                        x: scratch.rows, xStride: d, y: scratch.up, yStride: f, n: f, k: d)
        }
        encoder.memoryBarrier(scope: .buffers)

        var elements = UInt32(rows * f)
        encoder.setComputePipelineState(activationPSO)
        encoder.setBuffer(scratch.gate, offset: 0, index: 0)
        encoder.setBuffer(scratch.up, offset: 0, index: 1)
        encoder.setBuffer(scratch.act, offset: 0, index: 2)
        encoder.setBytes(&elements, length: 4, index: 3)
        encoder.dispatchThreads(MTLSize(width: rows * f, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(
                                    width: min(256, activationPSO.maxTotalThreadsPerThreadgroup),
                                    height: 1, depth: 1))
        encoder.memoryBarrier(scope: .buffers)

        for segment in segments {
            try project(segment, w: offsets.downWOff, s: offsets.downSOff, b: offsets.downBOff,
                        x: scratch.act, xStride: f, y: scratch.down, yStride: d, n: d, k: f)
        }
        encoder.memoryBarrier(scope: .buffers)

        encoder.setComputePipelineState(scatterPSO)
        encoder.setBuffer(scratch.down, offset: 0, index: 0)
        encoder.setBuffer(sortedPairs, offset: 0, index: 1)
        encoder.setBuffer(routePartials, offset: 0, index: 2)
        encoder.setBytes(&start, length: 4, index: 3)
        encoder.setBytes(&count, length: 4, index: 4)
        encoder.setBytes(&dValue, length: 4, index: 5)
        encoder.setBytes(&kValue, length: 4, index: 6)
        encoder.dispatchThreads(MTLSize(width: d, height: rows, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 4, depth: 1))
        encoder.endEncoding()
    }
}
