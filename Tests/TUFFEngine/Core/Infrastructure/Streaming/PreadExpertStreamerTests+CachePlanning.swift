import Darwin
import Foundation
import Metal
import Testing

@testable import TUFFEngine

extension PreadExpertStreamerTests {
  @Test(arguments: [ExpertCachePolicy.lru, .lfu])
  func allHitPlanPreservesBytesAndUpdatesEvictionPolicy(policy: ExpertCachePolicy) throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: MetalContext().device,
      slotCount: 2, cachePolicy: policy)
    let warmed = try streamer.loadExpertsCached(experts: [0, 1])
    let hit = streamer.planExpertsCached(experts: [0], avoidingSlots: [0, 1])
    #expect(hit.hits == 1)
    #expect(hit.misses.isEmpty)
    let cached = try streamer.executeExpertCachePlan(hit)
    #expect(cached[0].buffer === warmed[0].buffer)
    #expect(Self.bytes(of: cached[0].buffer, offset: 0, count: Self.expertStride)
      .allSatisfy { $0 == Self.tagByte(0) })

    // The hit must still count as a use under both LRU and LFU.
    let replacement = streamer.planExpertsCached(experts: [2])
    #expect(replacement.assignedSlots == [1])
    _ = try streamer.executeExpertCachePlan(replacement)
    #expect(streamer.planExpertsCached(experts: [0, 2]).hits == 2)
  }

  @Test func failedSingleMissIsNotPublishedAsACacheHit() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: MetalContext().device, slotCount: 2)
    _ = try streamer.loadExpertsCached(experts: [0])
    #expect(truncate(url.path, off_t(Self.streamOffset + UInt64(Self.expertStride))) == 0)
    let plan = streamer.planExpertsCached(experts: [0, 1])
    #expect(plan.misses == [1])
    #expect(throws: StreamerError.self) {
      _ = try streamer.executeExpertCachePlan(plan)
    }
    let retry = streamer.planExpertsCached(experts: [0, 1])
    #expect(retry.hits == 1)
    #expect(retry.misses == [1])
  }

  @Test func cachedBatchWithoutExecutorLoadsTaggedBytes() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: device, slotCount: 4)

    let results = try streamer.loadExpertsCached(experts: [3, 1, 2])
    for (index, result) in results.enumerated() {
      let expert = [3, 1, 2][index]
      let got = Self.bytes(of: result.buffer, offset: 0, count: Self.expertStride)
      #expect(got.allSatisfy { $0 == Self.tagByte(expert) })
    }
  }

  @Test func adviseExpertsDoesNotChangeLoadedBytes() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: device, slotCount: 4)
    let experts = [0, 2, 3]

    let advice = streamer.adviseExperts(experts: experts)
    #expect(advice.requested == experts.count)
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
      #expect(advice.failed == 0)
    #else
      #expect(advice.failed == experts.count)
    #endif

    let results = try streamer.loadExpertsCached(experts: experts)
    for (index, result) in results.enumerated() {
      let got = Self.bytes(of: result.buffer, offset: 0, count: Self.expertStride)
      #expect(got.allSatisfy { $0 == Self.tagByte(experts[index]) })
    }
  }

  @Test func adviseExpertMissesSkipsResidentSlots() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: device, slotCount: 4)

    _ = try streamer.loadExpertsCached(experts: [0])
    let advice = streamer.adviseExpertMisses(experts: [0, 1, 2])

    #expect(advice.requested == 2)
    #expect(advice.calls == 1)
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
      #expect(advice.failed == 0)
    #else
      #expect(advice.failed == 1)
    #endif
  }

  @Test func plannedCacheLoadExecutesSameMisses() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: device, slotCount: 4)

    _ = try streamer.loadExpertsCached(experts: [0])
    let experts = [0, 1, 2]
    let plan = streamer.planExpertsCached(experts: experts)

    #expect(plan.hits == 1)
    #expect(plan.misses.map { experts[$0] } == [1, 2])

    let results = try streamer.executeExpertCachePlan(plan)
    for (index, result) in results.enumerated() {
      let got = Self.bytes(of: result.buffer, offset: 0, count: Self.expertStride)
      #expect(got.allSatisfy { $0 == Self.tagByte(experts[index]) })
    }
  }

  @Test func plannedCacheBuffersExposeReservedSlotsBeforeExecute() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: device, slotCount: 4)

    _ = try streamer.loadExpertsCached(experts: [0])
    let experts = [0, 1, 2]
    let plan = streamer.planExpertsCached(experts: experts)
    let reserved = streamer.expertCachePlanBuffers(plan)

    let hitBytes = Self.bytes(of: reserved[0].buffer, offset: 0, count: Self.expertStride)
    #expect(hitBytes.allSatisfy { $0 == Self.tagByte(0) })

    let executed = try streamer.executeExpertCachePlan(plan)
    for i in 0..<experts.count {
      #expect(reserved[i].buffer === executed[i].buffer)
      let got = Self.bytes(of: executed[i].buffer, offset: 0, count: Self.expertStride)
      #expect(got.allSatisfy { $0 == Self.tagByte(experts[i]) })
    }
  }

  @Test func plannedCacheAvoidsInFlightSlotsForHitsAndMisses() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: device, slotCount: 4)

    let warmed = try streamer.loadExpertsCached(experts: [0, 1])
    let plan = streamer.planExpertsCached(
      experts: [0, 2],
      avoidingSlots: [0, 1])

    #expect(plan.assignedSlots == [0, 2])
    #expect(plan.hits == 1)
    #expect(plan.misses == [1])

    let executed = try streamer.executeExpertCachePlan(plan)
    for (index, expert) in plan.experts.enumerated() {
      let got = Self.bytes(of: executed[index].buffer, offset: 0, count: Self.expertStride)
      #expect(got.allSatisfy { $0 == Self.tagByte(expert) })
    }

    let avoidedBytes = Self.bytes(of: warmed[0].buffer, offset: 0, count: Self.expertStride)
    #expect(avoidedBytes.allSatisfy { $0 == Self.tagByte(0) })
  }

  @Test func plannedCacheReturnsNilWhenMissesCannotAvoidInFlightSlots() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: device, slotCount: 4)

    _ = try streamer.loadExpertsCached(experts: [0, 1])
    let plan = streamer.planExpertsCachedIfPossible(
      experts: [0, 2, 3, 4],
      avoidingSlots: [0, 1])

    #expect(plan == nil)
  }

  @Test(arguments: [ExpertCachePolicy.lru, .lfu])
  func demandFrequencyIsSeparateWhileQualifiedPlanRankingIsPreserved(policy: ExpertCachePolicy) throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try PreadExpertStreamer(layout: Self.makeLayout(path: url.path),
      device: MetalContext().device, slotCount: 2, cachePolicy: policy)
    _ = try streamer.loadExpertsCached(experts: [0, 1])
    _ = try streamer.loadExpertsCached(experts: [0])
    for _ in 0..<32 {
      let plan = streamer.planExpertsCached(experts: [1], purpose: .prefetch)
      _ = try streamer.executeExpertCachePlan(plan)
    }
    #expect(streamer.diagnosticExpertUseCounts(expert: 0).demand == 2)
    #expect(streamer.diagnosticExpertUseCounts(expert: 0).prediction == 0)
    #expect(streamer.diagnosticExpertUseCounts(expert: 1).demand == 1)
    #expect(streamer.diagnosticExpertUseCounts(expert: 1).prediction == 32)
    #expect(streamer.readMetrics.demandRequests == 3)
    #expect(streamer.readMetrics.predictionRequests == 32)
    let demand = streamer.planExpertsCached(experts: [2])
    #expect(demand.assignedSlots == [0])
    let bytes = try streamer.executeExpertCachePlan(demand)
    #expect(Self.bytes(of: bytes[0].buffer, offset: 0, count: Self.expertStride)
      .allSatisfy { $0 == Self.tagByte(2) })
    #expect(streamer.readMetrics.usefulPrefetchReads == 0)
  }

  @Test(arguments: [ExpertCachePolicy.lru, .lfu])
  func anUnusedPrefetchEvictionIsCountedDespiteOldDemandFrequency(policy: ExpertCachePolicy) throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try PreadExpertStreamer(layout: Self.makeLayout(path: url.path),
      device: MetalContext().device, slotCount: 3, cachePolicy: policy)
    _ = try streamer.loadExpertsCached(experts: [0, 1, 2])
    for _ in 0..<20 { _ = try streamer.loadExpertsCached(experts: [1]) }
    _ = try streamer.executeExpertCachePlan(
      streamer.planExpertsCached(experts: [3], avoidingSlots: [0, 2]))
    let prefetched = streamer.planExpertsCached(experts: [1], avoidingSlots: [0, 2], purpose: .prefetch)
    _ = try streamer.executeExpertCachePlan(prefetched)
    let replacement = streamer.planExpertsCached(experts: [3], avoidingSlots: [0, 2])
    #expect(replacement.assignedSlots == [1])
    #expect(streamer.readMetrics.prefetchReads == 1)
    #expect(streamer.readMetrics.unusedPrefetchEvictions == 1)
    let results = try streamer.executeExpertCachePlan(replacement)
    #expect(Self.bytes(of: results[0].buffer, offset: 0, count: Self.expertStride)
      .allSatisfy { $0 == Self.tagByte(3) })
  }

  @Test func originalCacheFunctionValuesRemainAvailable() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try PreadExpertStreamer(layout: Self.makeLayout(path: url.path),
      device: MetalContext().device, slotCount: 2)
    let plan: ([Int], Set<Int>) -> ExpertCachePlan = streamer.planExpertsCached
    let possible: ([Int], Set<Int>) -> ExpertCachePlan? = streamer.planExpertsCachedIfPossible
    let execute: (ExpertCachePlan, ExpertReadPurpose) throws
      -> [(buffer: MTLBuffer, offset: UInt64, size: UInt64)] = streamer.executeExpertCachePlan
    let make: ([Int], [Int], [Int], Int) -> ExpertCachePlan = ExpertCachePlan.init
    #expect(make([], [], [], 0).purpose == .demand)
    let demand = plan([0], [])
    let values = try execute(demand, .demand)
    #expect(Self.bytes(of: values[0].buffer, offset: 0, count: Self.expertStride)
      .allSatisfy { $0 == Self.tagByte(0) })
    #expect(possible([0], [])?.hits == 1)
  }

  @Test(arguments: [ExpertCachePolicy.lfu, .lru])
  func mixedDemandAndPredictionsMatchTheQualifiedSortedReference(policy: ExpertCachePolicy) throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try PreadExpertStreamer(layout: Self.makeLayout(path: url.path),
      device: MetalContext().device, slotCount: 2, cachePolicy: policy)
    var resident: [Int?] = [nil, nil]
    var touched = [0, 0]
    var frequency = [Int](repeating: 0, count: Self.numExperts)
    var demand = frequency
    var prediction = frequency
    var clock = 0
    func reference(_ experts: [Int], avoiding: Set<Int>) -> (slots: [Int], misses: [Int])? {
      var assigned: [Int: Int] = [:]
      for (index, expert) in experts.enumerated() {
        if let slot = resident.indices.first(where: { resident[$0] == expert }) { assigned[index] = slot }
      }
      var available = Set(resident.indices).subtracting(avoiding.union(assigned.values))
      let misses = experts.indices.filter { assigned[$0] == nil }
      guard misses.count <= available.count else { return nil }
      clock += 1
      for expert in experts { frequency[expert] += 1 }
      for slot in assigned.values { touched[slot] = clock }
      for index in misses {
        func key(_ slot: Int) -> (Int, Int, Int, Int) {
          if policy == .lru { return (0, 0, touched[slot], slot) }
          return (resident[slot] == nil ? 0 : 1,
                  resident[slot].map { frequency[$0] } ?? 0, touched[slot], slot)
        }
        let slot = available.sorted { key($0) < key($1) }[0]
        available.remove(slot)
        assigned[index] = slot
        resident[slot] = experts[index]
        touched[slot] = clock
      }
      return (experts.indices.map { assigned[$0]! }, misses)
    }
    let requests = [[0, 1], [2], [1, 3], [0], [3], [1, 2], [2, 0], [3, 1]]
    for step in 0..<64 {
      let experts = requests[step % requests.count]
      let avoiding: Set<Int> = step % 5 == 0 ? [0] : []
      let purpose: ExpertReadPurpose = step % 3 == 0 ? .prefetch : .demand
      let expected = reference(experts, avoiding: avoiding)
      let planned = streamer.planExpertsCachedIfPossible(experts: experts,
        avoidingSlots: avoiding, purpose: purpose)
      if expected == nil { #expect(planned == nil); continue }
      let expectedPlan = try #require(expected)
      let plan = try #require(planned)
      #expect(plan.assignedSlots == expectedPlan.slots)
      #expect(plan.misses == expectedPlan.misses)
      let values = try streamer.executeExpertCachePlan(plan)
      for (index, value) in values.enumerated() {
        #expect(Self.bytes(of: value.buffer, offset: value.offset, count: Self.expertStride)
          .allSatisfy { $0 == Self.tagByte(experts[index]) })
        if purpose == .demand { demand[experts[index]] += 1 }
        else { prediction[experts[index]] += 1 }
      }
    }
    for expert in 0..<Self.numExperts {
      let counts = streamer.diagnosticExpertUseCounts(expert: expert)
      #expect(counts.demand == demand[expert])
      #expect(counts.prediction == prediction[expert])
    }
    #expect(streamer.readMetrics.demandRequests == UInt64(demand.reduce(0, +)))
    #expect(streamer.readMetrics.predictionRequests == UInt64(prediction.reduce(0, +)))
  }

  @Test func aUsefulPrefetchCountsOnceAndProtectsItsDemandedRecord() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try PreadExpertStreamer(layout: Self.makeLayout(path: url.path),
      device: MetalContext().device, slotCount: 2)
    _ = try streamer.loadExpertsCached(experts: [0])
    let prefetch = streamer.planExpertsCached(experts: [1], purpose: .prefetch)
    _ = try streamer.executeExpertCachePlan(prefetch)
    for _ in 0..<4 { _ = try streamer.loadExpertsCached(experts: [1]) }
    #expect(streamer.readMetrics.usefulPrefetchReads == 1)
    #expect(streamer.readMetrics.prefetchBytes == UInt64(Self.expertStride))
    #expect(streamer.planExpertsCached(experts: [2]).assignedSlots == [0])
    #expect(streamer.readMetrics.unusedPrefetchEvictions == 0)
  }

  @Test func failedPrefetchIsRetriedAndNeverCountsAsUseful() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try PreadExpertStreamer(layout: Self.makeLayout(path: url.path),
      device: MetalContext().device, slotCount: 2)
    #expect(truncate(url.path, off_t(Self.streamOffset + UInt64(Self.expertStride))) == 0)
    let prefetch = streamer.planExpertsCached(experts: [1], purpose: .prefetch)
    #expect(throws: StreamerError.self) { _ = try streamer.executeExpertCachePlan(prefetch) }
    let demand = streamer.planExpertsCached(experts: [1])
    #expect(demand.hits == 0)
    #expect(demand.misses == [0])
    #expect(streamer.readMetrics.prefetchFailures == 1)
    #expect(streamer.readMetrics.usefulPrefetchReads == 0)
    #expect(streamer.readMetrics.unusedPrefetchEvictions == 0)
    #expect(streamer.diagnosticExpertUseCounts(expert: 1).demand == 1)
    #expect(streamer.diagnosticExpertUseCounts(expert: 1).prediction == 1)
  }

  @Test func impossibleDemandPlanDoesNotConsumeOrEvictAPrefetch() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let streamer = try PreadExpertStreamer(layout: Self.makeLayout(path: url.path),
      device: MetalContext().device, slotCount: 2)
    _ = try streamer.loadExpertsCached(experts: [0])
    let prefetch = streamer.planExpertsCached(experts: [1], purpose: .prefetch)
    _ = try streamer.executeExpertCachePlan(prefetch)
    let failed = streamer.planExpertsCachedIfPossible(experts: [1, 2], avoidingSlots: [0])
    #expect(failed == nil)
    #expect(streamer.readMetrics.usefulPrefetchReads == 0)
    #expect(streamer.readMetrics.unusedPrefetchEvictions == 0)
    #expect(streamer.diagnosticExpertUseCounts(expert: 1).demand == 0)
    #expect(streamer.diagnosticExpertUseCounts(expert: 1).prediction == 1)
    _ = try streamer.loadExpertsCached(experts: [1])
    #expect(streamer.readMetrics.usefulPrefetchReads == 1)
  }

}
