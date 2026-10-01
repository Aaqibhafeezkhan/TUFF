import Testing
import Foundation
import Metal
@testable import TUFFEngine

@Suite struct ExpertReadMetricsTests {
    @Test func demandAndPrefetchCountSuccessfulLogicalBytesAndHitsReadNothing() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try PreadExpertStreamerTests.writeSyntheticLayer()
        defer { try? FileManager.default.removeItem(at: url) }
        let streamer = try PreadExpertStreamer(
            layout: PreadExpertStreamerTests.makeLayout(path: url.path), device: device, slotCount: 4)
        _ = try streamer.executeExpertCachePlan(streamer.planExpertsCached(experts: [0, 1]), purpose: .prefetch)
        _ = try streamer.executeExpertCachePlan(streamer.planExpertsCached(experts: [0, 2]))
        let metrics = streamer.readMetrics
        #expect(metrics.prefetchReads == 2)
        #expect(metrics.prefetchBytes == 2 * UInt64(PreadExpertStreamerTests.expertStride))
        #expect(metrics.demandReads == 1)
        #expect(metrics.demandBytes == UInt64(PreadExpertStreamerTests.expertStride))
        #expect(metrics.prefetchFailures == 0)
        #expect(metrics.demandFailures == 0)
        _ = try streamer.loadExpertsCached(experts: [0, 1, 2])
        #expect(streamer.readMetrics == metrics)
    }

    @Test func failedShortReadCountsOnlyBytesActuallyReturned() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try PreadExpertStreamerTests.writeSyntheticLayer()
        defer { try? FileManager.default.removeItem(at: url) }
        let streamer = try PreadExpertStreamer(
            layout: PreadExpertStreamerTests.makeLayout(path: url.path), device: device, slotCount: 4)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: PreadExpertStreamerTests.streamOffset + 17)
        try file.close()
        #expect(throws: (any Error).self) {
            _ = try streamer.loadExpert(layer: 0, expert: 0, slot: 0, purpose: .prefetch)
        }
        #expect(streamer.readMetrics.prefetchFailures == 1)
        #expect(streamer.readMetrics.prefetchReads == 0)
        #expect(streamer.readMetrics.prefetchBytes == 17)
    }

    @Test func requestDeltaExcludesEarlierReads() {
        var baseline = ExpertReadMetrics()
        baseline.demandBytes = 1024
        baseline.prefetchReads = 2
        var end = baseline
        end.demandReads += 1
        end.demandBytes += 512
        end.prefetchBytes += 768
        end.prefetchFailures += 1
        let delta = end.subtracting(baseline)
        #expect(delta.demandReads == 1)
        #expect(delta.demandBytes == 512)
        #expect(delta.prefetchReads == 0)
        #expect(delta.prefetchBytes == 768)
        #expect(delta.prefetchFailures == 1)
    }

    @Test func drainMeasuresAnExposedWaitButCompletedReadsDoNotWait() throws {
        var lookahead = ExpertLookahead()
        let group = DispatchGroup()
        group.enter()
        lookahead.pending = .init(layer: 1, experts: [0], reads: group)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { group.leave() }
        #expect(lookahead.drain()?.layer == 1)
        #expect(lookahead.exposedWaitNanos > 0)
        let before = lookahead.exposedWaitNanos
        lookahead.pending = .init(layer: 2, experts: [1], reads: group)
        _ = lookahead.drain()
        #expect(lookahead.exposedWaitNanos == before)
    }
}
