import Metal
import Testing
import TUFFValidationSupport

@testable import TUFFEngine

extension PrefillGroupedRoutedMoETests {
  /// The batched MPP path against the CPU reference and the per-pair kernels,
  /// over more pairs than one microbatch holds so an expert's rows split
  /// across microbatches.
  @Test func batchedRoutedExpertsMatchPerPairKernelsAcrossMicrobatches() throws {
    let d = 128
    let f = 128
    let rows = 600
    let topK = 2
    let numExperts = 16
    var pairs: [PrefillTokenExpertPair] = []
    for token in 0..<rows {
      let first = (token * 7) % numExperts
      let second = (first + 1 + token % 5) % numExperts
      pairs.append(Self.pair(token: UInt32(token), expert: UInt32(first), rank: 0))
      pairs.append(Self.pair(token: UInt32(token), expert: UInt32(second), rank: 1))
    }
    let routes = try PrefillMoEGrouping.groupTokenExpertPairs(
      pairs, queryCount: rows, topK: topK, numExperts: numExperts, tileExpertCount: 16)
    #expect(routes.tiles.count == 1)
    #expect(routes.sortedPairs.count > PrefillBatchedRoutedExperts.maxRows)

    let pool = Self.makeSyntheticExpertPool(numExperts: numExperts, d: d, f: f)
    let hidden = (0..<(rows * d)).map { i in Float16(Float((i % 23) - 11) * 0.01) }
    let expected = Self.cpuSyntheticRoutePartials(
      routes: routes, hidden: hidden, hiddenStride: d, pool: pool, topK: topK, d: d, f: f)

    let ctx = try MetalContext()
    guard let batched = PrefillBatchedRoutedExperts(
      context: ctx, groupSize: Quantization.groupSize, siluActivation: false)
    else { return }
    let grouped = try PrefillGroupedRoutedMoE(context: ctx)
    let tile = routes.tiles[0]
    let groups = Array(routes.groups[Int(tile.groupStart)..<Int(tile.groupStart + tile.groupCount)])
    let expertIDs = groups.map { Int($0.expert) }
    let binding = try PrefillStreamedTileBinding(
      expertIDs: expertIDs,
      views: Self.streamedViewsWithNonzeroOffsets(
        device: ctx.device, pool: pool, expertIDs: expertIDs))

    let hiddenBuffer = try #require(Fp16Buffer.make(ctx.device, halves: hidden))
    let pairBuffer = try #require(ctx.device.makeBuffer(
      bytes: routes.sortedPairs,
      length: routes.sortedPairs.count * MemoryLayout<PrefillTokenExpertPair>.stride,
      options: .storageModeShared))

    func runBatched() throws -> [Float16] {
      let output = try #require(Fp16Buffer.make(
        ctx.device, halves: [Float16](repeating: -77, count: rows * topK * d)))
      let scratch = try PrefillBatchedRoutedExperts.makeScratch(device: ctx.device, d: d, f: f)
      let commandBuffer = try #require(ctx.queue.makeCommandBuffer())
      let microbatches = try batched.encodeTile(
        commandBuffer: commandBuffer, hidden: hiddenBuffer, hiddenStrideElements: d,
        sortedPairs: pairBuffer, groups: groups, views: binding.views,
        offsets: pool.offsets, routePartials: output, scratch: scratch,
        d: d, f: f, topK: topK)
      #expect(microbatches == 2)
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      try checkCommandBufferError(commandBuffer)
      return Fp16Buffer.readHalf(output, count: rows * topK * d)
    }

    func runPerPair() throws -> [Float16] {
      let output = try #require(Fp16Buffer.make(
        ctx.device, halves: [Float16](repeating: -77, count: rows * topK * d)))
      let activation = try #require(ctx.device.makeBuffer(
        length: 3 * 32 * f * MemoryLayout<Float16>.stride, options: .storageModePrivate))
      let down = try #require(ctx.device.makeBuffer(
        length: 32 * d * MemoryLayout<Float16>.stride, options: .storageModePrivate))
      let commandBuffer = try #require(ctx.queue.makeCommandBuffer())
      let params = PrefillGroupedRoutedMoEStreamedParams(
        pairStart: tile.pairStart, pairCount: tile.pairCount, d: UInt32(d),
        routedIntermediate: UInt32(f), topK: UInt32(topK), hiddenStrideElements: UInt32(d),
        binding: binding, offsets: pool.offsets)
      grouped.encodeStreamedBatched(
        commandBuffer: commandBuffer, hidden: hiddenBuffer, sortedPairs: pairBuffer,
        routePartials: output, gateUpActScratch: activation, downScratch: down,
        argumentBuffer: try grouped.makeStreamedArgumentBuffer(device: ctx.device, binding: binding),
        binding: binding, params: params, pairMicrobatchRows: 32)
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      try checkCommandBufferError(commandBuffer)
      return Fp16Buffer.readHalf(output, count: rows * topK * d)
    }

    let batchedOutput = try runBatched()
    let perPairOutput = try runPerPair()
    func maxError(_ a: [Float16], _ b: [Float16]) -> Float {
      zip(a, b).reduce(Float(0)) { max($0, abs(Float($1.0) - Float($1.1))) }
    }
    #expect(!batchedOutput.contains(-77), "every route slot is written")
    #expect(maxError(batchedOutput, expected) <= 0.003,
            "batched vs CPU \(maxError(batchedOutput, expected))")
    #expect(maxError(batchedOutput, perPairOutput) <= 0.003,
            "batched vs per-pair \(maxError(batchedOutput, perPairOutput))")
  }
}
