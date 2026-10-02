import Metal
import Testing
import TUFFValidationSupport

@testable import TUFFEngine

extension PrefillGroupedRoutedMoETests {
  @Test(arguments: [4, 8, 16])
  func streamedBatchedMatchesReferenceAcrossTilesAndPartialMicrobatches(tileExperts: Int) throws {
    let d = 64
    let f = 64
    let rows = 11
    let topK = 3
    let routes = try PrefillMoEGrouping.groupTokenExpertPairs(
      (0..<rows).flatMap { token in
        (0..<topK).map { rank in
          Self.pair(token: UInt32(token), expert: UInt32((token * topK + rank) % 16), rank: UInt32(rank))
        }
      },
      queryCount: rows,
      topK: topK,
      numExperts: 16,
      tileExpertCount: tileExperts)
    let pool = Self.makeSyntheticExpertPool(numExperts: 16, d: d, f: f)
    let hidden = (0..<(rows * d)).map { i in
      Float16(Float((i % 17) - 8) * 0.01)
    }
    let expected = Self.cpuSyntheticRoutePartials(
      routes: routes,
      hidden: hidden,
      hiddenStride: d,
      pool: pool,
      topK: topK,
      d: d,
      f: f)

    let ctx = try MetalContext()
    let grouped = try PrefillGroupedRoutedMoE(context: ctx)
    guard let hiddenBuffer = Fp16Buffer.make(ctx.device, halves: hidden),
      let pairBuffer = ctx.device.makeBuffer(
        bytes: routes.sortedPairs,
        length: routes.sortedPairs.count * MemoryLayout<PrefillTokenExpertPair>.stride,
        options: .storageModeShared),
      let outputBuffer = Fp16Buffer.make(
        ctx.device,
        halves: [Float16](repeating: -77, count: rows * topK * d)),
      let activationScratch = ctx.device.makeBuffer(
        length: 3 * 4 * f * MemoryLayout<Float16>.stride,
        options: .storageModePrivate),
      let downScratch = ctx.device.makeBuffer(
        length: 4 * d * MemoryLayout<Float16>.stride,
        options: .storageModePrivate),
      let commandBuffer = ctx.queue.makeCommandBuffer()
    else {
      Issue.record("allocation failed")
      return
    }

    var bindings = [PrefillStreamedTileBinding]()
    var arguments = [PrefillStreamedTileArgumentBuffer]()
    var microbatches = 0
    for tile in routes.tiles {
      let first = Int(tile.groupStart)
      let expertIDs = routes.groups[first..<(first + Int(tile.groupCount))].map { Int($0.expert) }
      let binding = try PrefillStreamedTileBinding(
        expertIDs: expertIDs,
        views: Self.streamedViewsWithNonzeroOffsets(device: ctx.device, pool: pool, expertIDs: expertIDs))
      let params = PrefillGroupedRoutedMoEStreamedParams(
        pairStart: tile.pairStart, pairCount: tile.pairCount,
        d: UInt32(d), routedIntermediate: UInt32(f), topK: UInt32(topK),
        hiddenStrideElements: UInt32(d), binding: binding, offsets: pool.offsets)
      let argumentBuffer = try grouped.makeStreamedArgumentBuffer(device: ctx.device, binding: binding)
      microbatches += grouped.encodeStreamedBatched(
        commandBuffer: commandBuffer, hidden: hiddenBuffer, sortedPairs: pairBuffer,
        routePartials: outputBuffer, gateUpActScratch: activationScratch, downScratch: downScratch,
        argumentBuffer: argumentBuffer, binding: binding, params: params, pairMicrobatchRows: 4)
      // Keep every binding and argument buffer alive until all tile work finishes.
      bindings.append(binding)
      arguments.append(argumentBuffer)
    }

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if let error = commandBuffer.error { throw error }

    let actual = Fp16Buffer.readHalf(outputBuffer, count: rows * topK * d)
    let maxAbsoluteError = zip(actual, expected).reduce(Float(0)) {
      max($0, abs(Float($1.0) - Float($1.1)))
    }
    #expect(microbatches == routes.tiles.reduce(0) { $0 + (Int($1.pairCount) + 3) / 4 })
    #expect(arguments.count == routes.tiles.count)
    #expect(maxAbsoluteError <= 0.0015, "maxAbsoluteError=\(maxAbsoluteError)")
    #expect(bindings.flatMap(\.views).allSatisfy { $0.offset > 0 })
  }

}
