import Metal

/// MLX-affine INT4 projection for prefill blocks of 2 to 31 tokens.
///
/// Below 32 tokens the batched QMM paths do not run, and the prefill encoded
/// one `DequantInt4GEMV` dispatch per token, rereading the whole weight matrix
/// each time. This kernel keeps the GEMV's one-SIMD-per-row layout and
/// arithmetic but applies every weight chunk to a tile of 8, 4, 2 or 1
/// tokens, so each tile reads the weights once. A block is split into whole
/// tiles, largest first: 13 tokens run as one 8-tile, one 4-tile and one
/// 1-tile, in three dispatches instead of thirteen. Nothing is padded.
///
/// It is opt-in through `SmallBlockPrefillPolicy`. Whether it is faster on a
/// given shape is a measurement question, not something this type asserts.
final class DequantInt4SmallBlock {
    /// Tile widths compiled as function-constant variants, largest first.
    /// The token count inside a tile is a compile-time constant: a runtime
    /// bound kept the accumulators out of registers and measured slower than
    /// the per-token GEMV for small tiles on an M2.
    static let tileTokenSizes = [8, 4, 2, 1]
    /// Block sizes the kernel accepts. One token keeps the decode GEMV, and 32
    /// or more keep the batched paths.
    static let admittedTokens = 2...31

    private static let rowsPerThreadgroup = 8
    private static let tileFunctionConstantIndex = 27

    let groupSize: Int
    private let pipelines: [Int: MTLComputePipelineState]
    /// Projections this instance has encoded. Tests read it to confirm which
    /// path a prefill took.
    private(set) var encodedProjections = 0

    init(context: MetalContext, groupSize: Int = Quantization.groupSize) throws {
        precondition(Quantization.supportedGroupSizes.contains(groupSize),
                     "unsupported affine group size \(groupSize)")
        self.groupSize = groupSize
        // As in DequantInt4GEMV: the historical group of 64 sets no constant.
        let groupConstants: [MetalFunctionConstant] =
            groupSize == Quantization.groupSize
                ? []
                : [MetalFunctionConstant(index: Quantization.groupSizeFunctionConstantIndex,
                                         value: .uint32(UInt32(groupSize)))]
        var pipelines: [Int: MTLComputePipelineState] = [:]
        for tile in Self.tileTokenSizes {
            pipelines[tile] = try context.pipeline(
                "dequant_int4_small_block",
                constants: groupConstants + [
                    MetalFunctionConstant(index: Self.tileFunctionConstantIndex,
                                          value: .uint32(UInt32(tile))),
                ],
                maxTotalThreadsPerThreadgroup: 32 * Self.rowsPerThreadgroup)
        }
        self.pipelines = pipelines
    }

    /// The dispatches a block becomes: each entry is a tile width and how
    /// many whole tiles of it run, in token order.
    static func tilePlan(for tokenCount: Int) -> [(tileTokens: Int, tiles: Int)] {
        var remaining = max(0, tokenCount)
        var plan: [(tileTokens: Int, tiles: Int)] = []
        for tile in tileTokenSizes where remaining >= tile {
            plan.append((tile, remaining / tile))
            remaining %= tile
        }
        return plan
    }

    /// Whether `encode` would accept this projection. Everything it checks is
    /// a shape, stride or alignment fact; a refusal leaves the caller on its
    /// existing path.
    func supports(rows: Int, columns: Int, tokenCount: Int,
                  weightsOffset: Int,
                  xOffset: Int, xStrideElements: Int,
                  yOffset: Int, yStrideElements: Int) -> Bool {
        Self.admittedTokens.contains(tokenCount)
            && rows > 0 && columns > 0
            && columns.isMultiple(of: groupSize)
            // The kernel reads packed weights as ushorts and x as half4.
            && weightsOffset.isMultiple(of: 2)
            && xOffset.isMultiple(of: 8)
            && xStrideElements >= columns && xStrideElements.isMultiple(of: 4)
            && yOffset.isMultiple(of: MemoryLayout<Float16>.stride)
            && yStrideElements >= rows
    }

    /// Encodes `y[t, 0..<rows] = W · x[t, 0..<columns]` for every token of the
    /// block. Returns false, having encoded nothing, when `supports` refuses.
    @discardableResult
    func encode(commandBuffer: MTLCommandBuffer,
                weights: MTLBuffer,
                weightsOffset: Int = 0,
                scales: MTLBuffer,
                scalesOffset: Int = 0,
                biases: MTLBuffer,
                biasesOffset: Int = 0,
                x: MTLBuffer,
                xOffset: Int = 0,
                xStrideElements: Int,
                y: MTLBuffer,
                yOffset: Int = 0,
                yStrideElements: Int,
                rows: Int,
                columns: Int,
                tokenCount: Int) -> Bool {
        guard supports(rows: rows, columns: columns, tokenCount: tokenCount,
                       weightsOffset: weightsOffset,
                       xOffset: xOffset, xStrideElements: xStrideElements,
                       yOffset: yOffset, yStrideElements: yStrideElements) else {
            return false
        }
        let plan = Self.tilePlan(for: tokenCount)
        guard plan.allSatisfy({ pipelines[$0.tileTokens] != nil }),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        let halfBytes = MemoryLayout<Float16>.stride
        let rowGroups = (rows + Self.rowsPerThreadgroup - 1) / Self.rowsPerThreadgroup
        encoder.setBuffer(weights, offset: weightsOffset, index: 0)
        encoder.setBuffer(scales, offset: scalesOffset, index: 1)
        encoder.setBuffer(biases, offset: biasesOffset, index: 2)
        var shape = [UInt32(rows), UInt32(columns)]
        encoder.setBytes(&shape[0], length: MemoryLayout<UInt32>.size, index: 5)
        encoder.setBytes(&shape[1], length: MemoryLayout<UInt32>.size, index: 6)
        var strides = [UInt32(xStrideElements), UInt32(yStrideElements)]
        encoder.setBytes(&strides[0], length: MemoryLayout<UInt32>.size, index: 8)
        encoder.setBytes(&strides[1], length: MemoryLayout<UInt32>.size, index: 9)
        // Tiles write disjoint token rows, so the dispatches are independent.
        var start = 0
        for (tile, tiles) in plan {
            encoder.setComputePipelineState(pipelines[tile]!)
            encoder.setBuffer(x, offset: xOffset + start * xStrideElements * halfBytes, index: 3)
            encoder.setBuffer(y, offset: yOffset + start * yStrideElements * halfBytes, index: 4)
            var tokens = UInt32(tile * tiles)
            encoder.setBytes(&tokens, length: MemoryLayout<UInt32>.size, index: 7)
            encoder.dispatchThreadgroups(
                MTLSize(width: rowGroups, height: tiles, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 32 * Self.rowsPerThreadgroup, height: 1, depth: 1))
            start += tile * tiles
        }
        encoder.endEncoding()
        encodedProjections += 1
        return true
    }
}

/// Opt-in selection of `DequantInt4SmallBlock` for short prefill blocks.
///
/// Off unless the environment sets `TUFF_SMALL_BLOCK_PREFILL=on` when a runner
/// is created, and then only for Gemma 4 26B-A4B and Qwen3.8 Flash Next. It
/// exists so the new path can be compared with the existing one on the same
/// build; it is not an app setting. Speculative verification blocks always
/// keep the per-token GEMV their acceptance checks were written against.
public struct SmallBlockPrefillPolicy: Sendable, Equatable {
    public static let environmentKey = "TUFF_SMALL_BLOCK_PREFILL"
    static let qualifiedVariants: Set<ModelVariant> = [.gemma4_26B_A4B, .qwen38FlashNext]

    public let enabled: Bool

    public static let disabled = SmallBlockPrefillPolicy(enabled: false)

    /// Tests use this to exercise the path on other toy architectures.
    init(enabled: Bool) {
        self.enabled = enabled
    }

    public init(environment: [String: String], variant: ModelVariant) {
        self.enabled = environment[Self.environmentKey] == "on"
            && Self.qualifiedVariants.contains(variant)
    }

    /// The value a run reports in its resolved settings.
    public static func resolvedSetting(environment: [String: String],
                                       variant: ModelVariant) -> String {
        guard environment[environmentKey] == "on" else { return "off" }
        return qualifiedVariants.contains(variant) ? "on" : "off (model not qualified)"
    }

    func admits(family: PrefillProjectionFamily,
                tokenCount: Int,
                speculativeVerification: Bool) -> Bool {
        enabled
            && !speculativeVerification
            && family != .routed
            && DequantInt4SmallBlock.admittedTokens.contains(tokenCount)
    }
}
