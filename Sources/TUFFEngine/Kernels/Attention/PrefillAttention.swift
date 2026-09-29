import Foundation
import Metal

enum PrefillAttentionLayerKind: Sendable, Equatable {
    case full
    case slidingWindow
}

struct PrefillAttentionParams: Sendable, Equatable {
    var startPosition: UInt32
    var queryCount: UInt32
    var headDim: UInt32
    var numQHeads: UInt32
    var numKVHeads: UInt32
    var kvValidCount: UInt32
    var slidingWindow: UInt32
    var kvTokenStrideElements: UInt32
    var qTokenStrideElements: UInt32
    var oTokenStrideElements: UInt32
    var scale: Float
    var bidirectionalBlockStart: UInt32
    var bidirectionalBlockEnd: UInt32

    init(startPosition: UInt32,
                queryCount: UInt32,
                headDim: UInt32,
                numQHeads: UInt32,
                numKVHeads: UInt32,
                kvValidCount: UInt32,
                slidingWindow: UInt32,
                kvTokenStrideElements: UInt32,
                qTokenStrideElements: UInt32,
                oTokenStrideElements: UInt32,
                scale: Float,
                bidirectionalBlockStart: UInt32 = 0,
                bidirectionalBlockEnd: UInt32 = 0) {
        self.startPosition = startPosition
        self.queryCount = queryCount
        self.headDim = headDim
        self.numQHeads = numQHeads
        self.numKVHeads = numKVHeads
        self.kvValidCount = kvValidCount
        self.slidingWindow = slidingWindow
        self.kvTokenStrideElements = kvTokenStrideElements
        self.qTokenStrideElements = qTokenStrideElements
        self.oTokenStrideElements = oTokenStrideElements
        self.scale = scale
        self.bidirectionalBlockStart = bidirectionalBlockStart
        self.bidirectionalBlockEnd = bidirectionalBlockEnd
    }
}


/// One compiled shape of the grouped TensorOps full-attention kernel. Each
/// threadgroup computes eight rows: `headsPerGroup` query heads that read the
/// same KV head, for `tokensPerGroup` query tokens.
struct PrefillTensorOpsVariant: Hashable, Sendable {
    static let rowsPerThreadgroup = 8

    var headsPerGroup: Int
    var headDim: Int

    var tokensPerGroup: Int { Self.rowsPerThreadgroup / headsPerGroup }

    /// Every shape TUFF's full-attention layers use: Gemma 4 26B-A4B and
    /// 12B (512, groups of 8 and 16), E2B (512/8), E4B (512/4), Qwen 3.6
    /// (256/8) and Qwen 3.8 Flash Next (256/12). MiniMax (128/6) and GPT-OSS
    /// (sinks, separate runner) stay on their existing paths.
    static let all: [PrefillTensorOpsVariant] = [
        PrefillTensorOpsVariant(headsPerGroup: 8, headDim: 512),
        PrefillTensorOpsVariant(headsPerGroup: 4, headDim: 512),
        PrefillTensorOpsVariant(headsPerGroup: 8, headDim: 256),
        PrefillTensorOpsVariant(headsPerGroup: 4, headDim: 256),
    ]

    var functionName: String {
        if headsPerGroup == 8 && headDim == 512 {
            return "attention_prefill_full_tensorops_2d_validity_v2"
        }
        return "attention_prefill_full_tensorops_2d_g\(headsPerGroup)_d\(headDim)"
    }

    /// The variant for a dispatch, or nil when TensorOps cannot compute it
    /// exactly. The kernel starts every key loop at zero and has no ring or
    /// bidirectional-block addressing, so these are visibility guards as well
    /// as shape checks.
    static func select(params: PrefillAttentionParams,
                       kvRingCapacity: UInt32,
                       layerKind: PrefillAttentionLayerKind) -> PrefillTensorOpsVariant? {
        guard layerKind == .full,
              kvRingCapacity == 0,
              params.slidingWindow == 0 || params.slidingWindow >= params.kvValidCount,
              params.bidirectionalBlockEnd <= params.bidirectionalBlockStart,
              params.numKVHeads > 0,
              params.numQHeads % params.numKVHeads == 0 else {
            return nil
        }
        let queryHeadsPerKV = Int(params.numQHeads / params.numKVHeads)
        // Larger groups read each K/V tile for more heads, so prefer them.
        return all
            .filter { $0.headDim == Int(params.headDim)
                && queryHeadsPerKV % $0.headsPerGroup == 0 }
            .max { $0.headsPerGroup < $1.headsPerGroup }
    }
}

final class PrefillAttention {
    private let context: MetalContext
    private let psoCausalTiled: MTLComputePipelineState
    private let psoParamsSmoke: MTLComputePipelineState
    private let tensorOpsPipelines: [PrefillTensorOpsVariant: MTLComputePipelineState]

    convenience init(context: MetalContext) throws {
        try self.init(context: context, simulatingMissingTensorOps: false)
    }

    /// Tests can force the tiled fallback on a host where TensorOps builds.
    init(context: MetalContext, simulatingMissingTensorOps: Bool) throws {
        self.context = context
        self.psoCausalTiled = try context.pipeline("attention_prefill_causal_tiled")
        self.psoParamsSmoke = try context.pipeline("prefill_attention_params_smoke")
        // Capability is whether the MSL 4 pipeline builds, not a family
        // check: it compiles and dispatches on the Apple8 M2 as well as on
        // Apple10. macOS 15 compiles MSL 3.2, where these kernels are absent,
        // and a virtual GPU below Apple8 rejects them at pipeline build; both
        // use the tiled path.
        var pipelines: [PrefillTensorOpsVariant: MTLComputePipelineState] = [:]
        if !simulatingMissingTensorOps {
            for variant in PrefillTensorOpsVariant.all {
                do {
                    pipelines[variant] = try context.pipeline(variant.functionName)
                } catch {
                    Self.reportUnavailable(variant, error: error)
                }
            }
        }
        self.tensorOpsPipelines = pipelines
    }

    func tensorOpsAvailable(_ variant: PrefillTensorOpsVariant) -> Bool {
        tensorOpsPipelines[variant] != nil
    }

    private static let reportLock = NSLock()
    private static nonisolated(unsafe) var reportedUnavailable: Set<PrefillTensorOpsVariant> = []

    /// Once per variant per process, so a variant that should have built is
    /// visible in logs without repeating for every runner. macOS 15 compiles
    /// MSL 3.2, where these kernels are absent by design, so it stays quiet.
    private static func reportUnavailable(_ variant: PrefillTensorOpsVariant, error: any Error) {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        reportLock.lock()
        let first = reportedUnavailable.insert(variant).inserted
        reportLock.unlock()
        guard first else { return }
        FileHandle.standardError.write(Data(
            ("PrefillAttention: \(variant.functionName) unavailable; "
             + "using causal-tiled fallback: \(error)\n").utf8))
    }

    func encodeCausal(commandBuffer: MTLCommandBuffer,
                             q: MTLBuffer, qOffset: Int = 0,
                             k: MTLBuffer, kOffset: Int = 0,
                             v: MTLBuffer, vOffset: Int = 0,
                             out: MTLBuffer, outOffset: Int = 0,
                             params: PrefillAttentionParams,
                             kvRingCapacity: UInt32 = 0,
                             layerKind: PrefillAttentionLayerKind = .full,
                             allowsBidirectionalFullAttention: Bool = false,
                             path: RuntimePrefillAttentionPath = .causalTiled) {
        var effectiveParams = params
        // Only sliding-window layers make an image block bidirectional;
        // full-attention layers stay causal. Zeroed here as well as at the
        // call site so a caller cannot widen visibility by mistake.
        if layerKind == .full && !allowsBidirectionalFullAttention {
            effectiveParams.bidirectionalBlockStart = 0
            effectiveParams.bidirectionalBlockEnd = 0
        }
        validate(effectiveParams)

        let requestsTensorOps = path == .fullTensorOps2DPreferred
            || path == .fullTensorOps2DValidityV2
        let variant = requestsTensorOps
            ? PrefillTensorOpsVariant.select(params: effectiveParams,
                                             kvRingCapacity: kvRingCapacity,
                                             layerKind: layerKind)
            : nil
        let tensorOpsPipeline = variant.flatMap { tensorOpsPipelines[$0] }
        let useTensorOps = tensorOpsPipeline != nil
        let pipeline: MTLComputePipelineState
        if let tensorOpsPipeline {
            pipeline = tensorOpsPipeline
        } else if let variant, path == .fullTensorOps2DValidityV2 {
            preconditionFailure(
                "TensorOps 2D prefill attention pipeline \(variant.functionName) "
                + "is unavailable on this Metal stack")
        } else {
            // Explicit mode also falls back for ineligible shapes. Benchmark
            // fixtures must use an eligible full-attention shape to prove
            // that TensorOps ran.
            pipeline = causalTiledPipeline(kvRingCapacity: kvRingCapacity)
        }
        let headDim = Int(effectiveParams.headDim)
        let threadWidth = max(1, pipeline.threadExecutionWidth)
        let threadCount = useTensorOps
            ? 128
            : roundUp(max(threadWidth, headDim), toMultipleOf: threadWidth)
        precondition(threadCount <= pipeline.maxTotalThreadsPerThreadgroup,
                     "tiled prefill attention requires headDim <= maxTotalThreadsPerThreadgroup")

        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(q, offset: qOffset, index: 0)
        enc.setBuffer(k, offset: kOffset, index: 1)
        enc.setBuffer(v, offset: vOffset, index: 2)
        enc.setBuffer(out, offset: outOffset, index: 3)
        var p = effectiveParams
        enc.setBytes(&p, length: MemoryLayout<PrefillAttentionParams>.stride, index: 4)
        let groups = useTensorOps
            ? MTLSize(width: (Int(effectiveParams.queryCount) + variant!.tokensPerGroup - 1)
                          / variant!.tokensPerGroup,
                      height: Int(effectiveParams.numQHeads) / variant!.headsPerGroup,
                      depth: 1)
            : MTLSize(width: Int(effectiveParams.queryCount),
                      height: Int(effectiveParams.numQHeads),
                      depth: 1)
        enc.dispatchThreadgroups(
            groups,
            threadsPerThreadgroup: MTLSize(width: threadCount, height: 1, depth: 1))
        enc.endEncoding()
    }


    private func validate(_ params: PrefillAttentionParams) {
        precondition(params.headDim > 0, "headDim must be positive")
        precondition(params.queryCount > 0, "queryCount must be positive")
        precondition(params.numQHeads > 0, "numQHeads must be positive")
        precondition(params.numKVHeads > 0, "numKVHeads must be positive")
        precondition(params.numQHeads % params.numKVHeads == 0,
                     "numQHeads must be divisible by numKVHeads")
        precondition(params.qTokenStrideElements >= params.numQHeads * params.headDim,
                     "q token stride is too small")
        precondition(params.oTokenStrideElements >= params.numQHeads * params.headDim,
                     "output token stride is too small")
        precondition(params.kvTokenStrideElements >= params.numKVHeads * params.headDim,
                     "KV token stride is too small")
        precondition(params.startPosition + params.queryCount <= params.kvValidCount,
                     "kvValidCount must include all in-flight query rows")
        precondition(params.bidirectionalBlockStart <= params.bidirectionalBlockEnd,
                     "bidirectional block range is invalid")
        precondition(params.bidirectionalBlockEnd <= params.kvValidCount,
                     "bidirectional block exceeds valid KV rows")
    }


    private func roundUp(_ value: Int, toMultipleOf multiple: Int) -> Int {
        ((value + multiple - 1) / multiple) * multiple
    }


    /// Reads every field back through the MSL struct. `PrefillAttentionParams`
    /// is mirrored by hand in `prefill.metal`, and a field added on one side
    /// only shifts every later field silently.
    func encodeParamsSmoke(commandBuffer: MTLCommandBuffer,
                           params: PrefillAttentionParams,
                           out: MTLBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(psoParamsSmoke)
        var p = params
        enc.setBytes(&p, length: MemoryLayout<PrefillAttentionParams>.stride, index: 0)
        enc.setBuffer(out, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: 13, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 13, height: 1, depth: 1))
        enc.endEncoding()
    }

    private func causalTiledPipeline(kvRingCapacity: UInt32) -> MTLComputePipelineState {
        guard kvRingCapacity > 0 else { return psoCausalTiled }
        do {
            return try context.pipeline(
                "attention_prefill_causal_tiled",
                constants: [MetalFunctionConstant(index: 76, value: .uint32(kvRingCapacity))])
        } catch {
            preconditionFailure("failed to build FP16 KV ring prefill attention pipeline: \(error)")
        }
    }
}
