import Testing
import Foundation
import Metal
@testable import TUFFEngine
import TUFFValidationSupport

/// A retained conversation must resume exactly where it stopped.
///
/// The toy checkpoints use uniform stand-in weights, so their logits barely
/// depend on carried state and cannot show whether a snapshot is complete.
/// These tests therefore compare the state itself: every captured byte after a
/// round trip through an unrelated sequence, and an inventory of what a
/// snapshot must contain for each architecture. Whether that inventory is
/// everything a real model carries is checked against real checkpoints by
/// `Scripts/benchmark_conversation_cache.py --verify-resume`.
@Suite(.serialized) struct RunnerStateSnapshotTests {
    private struct Fixture {
        let directory: URL
        let context: MetalContext
        let runner: any LogitProducer & StateSnapshottingRunner & ContinuableLogitProducer
        let vocab: Int
    }

    private static func run(_ tokens: [Int32], from start: Int,
                            on fixture: Fixture) async throws {
        let output = try #require(fixture.context.device.makeBuffer(
            length: fixture.vocab * MemoryLayout<Float16>.stride,
            options: .storageModeShared))
        for (offset, token) in tokens.enumerated() {
            try await fixture.runner.produce(token: token, position: start + offset,
                                             into: output)
        }
    }

    private static func bytes(_ snapshot: RunnerStateSnapshot) -> [String: Data] {
        var result: [String: Data] = [:]
        guard let storage = snapshot.storage else { return result }
        for segment in snapshot.segments {
            result[segment.label] = Data(
                bytes: storage.contents().advanced(by: segment.snapshotOffset),
                count: segment.length)
        }
        return result
    }

    /// Captures A, runs a longer unrelated B over the same runner, restores A
    /// and captures again. Every segment and host value must match, and B's
    /// own state must differ from A's, or the comparison would prove nothing.
    @discardableResult
    private static func expectRoundTrip(make: () throws -> Fixture) async throws
        -> RunnerStateSnapshot {
        let fixture = try make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await run(prefix, from: 0, on: fixture)
        let estimate = try #require(fixture.runner.stateSnapshotByteEstimate)
        let original = try fixture.runner.captureState()
        #expect(original.position == prefix.count)
        #expect(original.byteCount == estimate)

        fixture.runner.reset()
        try await run(other, from: 0, on: fixture)
        let intruder = try fixture.runner.captureState()
        #expect(bytes(intruder) != bytes(original),
                "the unrelated sequence left the state unchanged, so the test is blind")

        try fixture.runner.restoreState(original)
        #expect(fixture.runner.continuationPosition == prefix.count)
        let restored = try fixture.runner.captureState()
        #expect(restored.host == original.host)
        #expect(restored.segments.map(\.label) == original.segments.map(\.label))
        let expected = bytes(original), actual = bytes(restored)
        for label in expected.keys.sorted() where expected[label] != actual[label] {
            Issue.record("segment \(label) differs after restore")
        }
        // Decoding continues from the restored position.
        try await run(suffix, from: prefix.count, on: fixture)
        #expect(fixture.runner.continuationPosition == prefix.count + suffix.count)
        return original
    }

    private static let prefix: [Int32] = [5, 9, 3, 17, 11, 2, 8, 21, 4, 13, 6, 19, 7, 15]
    private static let suffix: [Int32] = [12, 3, 25, 9]
    /// Longer than `prefix`, so it overwrites every position the retained
    /// sequence wrote.
    private static let other: [Int32] = [30, 1, 27, 14, 22, 10, 16, 29, 18, 26, 23,
                                         28, 24, 31, 20, 0, 31, 2, 29, 4]

    @Test func qwen4ExpCarriesKVRecurrentIndexerAndNgramState() async throws {
        // A sparse budget of eight keys in blocks of four, so the indexer's
        // pooled blocks are live by the end of the prefix.
        let config = ArchConfig.qwen4ExpToy(
            ngramLayer: 1,
            indexer: AttentionIndexerConfig(budget: 8, compressRatio: 4, headDim: 32,
                                            numHeads: 2, numKVHeads: 1))
        let snapshot = try await Self.expectRoundTrip(make: {
            let directory = try Qwen4ExpToySynthetic.write(config: config)
            let context = try MetalContext()
            let model = try Model.load(directoryURL: directory, device: context.device,
                                       expecting: config)
            let runner = try RealForwardRunner(model: model, context: context, maxContext: 64)
            return Fixture(directory: directory, context: context, runner: runner,
                           vocab: config.vocabSize)
        })
        let labels = Set(snapshot.segments.map(\.label))
        for layer in 0..<config.numLayers {
            if config.layerIsLinear(layer) {
                #expect(labels.isSuperset(of: ["gdn.state.\(layer)", "gdn.conv.\(layer)"]))
            } else {
                #expect(labels.isSuperset(of: [
                    "kv.K.\(layer)", "kv.V.\(layer)", "qsa.keys.\(layer)",
                    "qsa.positions.\(layer)", "qsa.pooled.\(layer)"]))
            }
        }
        #expect(labels.contains("ngram.conv"))
        #expect(!snapshot.host.ngramContext.isEmpty)
    }

    @Test func qwen36CarriesKVAndRecurrentState() async throws {
        let snapshot = try await Self.expectRoundTrip(make: {
            let directory = try QwenToySynthetic.write()
            let context = try MetalContext()
            let model = try Model.load(directoryURL: directory, device: context.device,
                                       expecting: .qwen36Toy())
            let runner = try RealForwardRunner(model: model, context: context, maxContext: 64)
            return Fixture(directory: directory, context: context, runner: runner,
                           vocab: ArchConfig.qwen36Toy().vocabSize)
        })
        let config = ArchConfig.qwen36Toy()
        let labels = Set(snapshot.segments.map(\.label))
        for layer in 0..<config.numLayers {
            #expect(labels.contains(config.layerIsLinear(layer)
                ? "gdn.state.\(layer)" : "kv.K.\(layer)"))
        }
    }

    @Test func denseGemmaSkipsLayersThatShareKV() async throws {
        let snapshot = try await Self.expectRoundTrip(make: {
            let directory = try DenseGemmaToySynthetic.write()
            let context = try MetalContext()
            let model = try Model.load(directoryURL: directory, device: context.device,
                                       expecting: .gemma4E4BToy())
            let runner = try RealForwardRunner(model: model, context: context, maxContext: 64)
            return Fixture(directory: directory, context: context, runner: runner,
                           vocab: ArchConfig.gemma4E4BToy().vocabSize)
        })
        let config = ArchConfig.gemma4E4BToy()
        let labels = Set(snapshot.segments.map(\.label))
        for layer in 0..<config.numLayers {
            #expect(labels.contains("kv.K.\(layer)") == !config.layerSharesKV(layer))
        }
    }

    @Test func gptOssCarriesKV() async throws {
        let snapshot = try await Self.expectRoundTrip(make: {
            let directory = try GPTOSSToySynthetic.write()
            let context = try MetalContext()
            let model = try Model.load(directoryURL: directory, device: context.device,
                                       expecting: .gptOssToy(), streamingMode: .pread(slotCount: 8))
            let runner = try ModelForwardRunner(
                model: model, context: context, maxContext: 64,
                runtimeConfiguration: RuntimeConfiguration(
                    expertCacheSlots: 8, prefillEnabled: true, prefillChunkTokens: 32,
                    forceLogitsHead: true))
            return Fixture(directory: directory, context: context, runner: runner,
                           vocab: ArchConfig.gptOssToy().vocabSize)
        })
        #expect(snapshot.segments.contains { $0.label.hasPrefix("kv.K.") })
    }

    @Test func aSnapshotIsRefusedByAnotherRunner() throws {
        let directory = try QwenToySynthetic.write()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try MetalContext()
        let model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: .qwen36Toy())
        let first = try RealForwardRunner(model: model, context: context, maxContext: 64)
        let second = try RealForwardRunner(model: model, context: context, maxContext: 64)
        let snapshot = try first.captureState()
        #expect(throws: RunnerStateSnapshotError.foreignSnapshot) {
            try second.restoreState(snapshot)
        }
    }

    @Test func snapshotSizeFollowsTheSequenceNotTheAllocation() async throws {
        let directory = try QwenToySynthetic.write()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try MetalContext()
        let model = try Model.load(directoryURL: directory, device: context.device,
                                   expecting: .qwen36Toy())
        let runner = try RealForwardRunner(model: model, context: context, maxContext: 64)
        let fixture = Fixture(directory: directory, context: context, runner: runner,
                              vocab: ArchConfig.qwen36Toy().vocabSize)
        let empty = try #require(runner.stateSnapshotByteEstimate)
        try await Self.run(Array(Self.prefix.prefix(4)), from: 0, on: fixture)
        let short = try #require(runner.stateSnapshotByteEstimate)
        try await Self.run(Array(Self.prefix.dropFirst(4)), from: 4, on: fixture)
        let long = try #require(runner.stateSnapshotByteEstimate)
        // Recurrent state is fixed size, KV rows grow with the sequence.
        #expect(empty > 0)
        #expect(short > empty)
        #expect(long > short)
    }

    /// A ring layer that has wrapped holds its rows out of logical order; the
    /// copy keeps them in the same physical slots.
    @Test func wrappedRingRowsRoundTripInPlace() throws {
        let config = ArchConfig.gemma4E4BToy()
        let context = try MetalContext()
        let kv = try KVCacheManager(device: context.device, config: config, maxContext: 64,
                                    fp16RingEnabled: true, slidingWindow: 4,
                                    maxPrefillChunkTokens: 1, fp16RingCapacityOverride: 6)
        let layer = try #require((0..<config.numLayers).first { kv.layerKind($0) == .swa })
        #expect(kv.ringCapacity(layer: layer) == 6)
        let stride = kv.stride(layer: layer)
        for position in 0..<9 {
            let slot = kv.kSlot(layer: layer, position: position)
            memset(slot.buffer.contents().advanced(by: slot.offset), Int32(position + 1), stride)
            kv.advance()
        }
        var builder = RunnerStateSnapshotBuilder()
        kv.addSnapshotRanges(to: &builder, position: kv.position)
        let owner = NSObject()
        let snapshot = try builder.capture(owner: owner, queue: context.queue,
                                           host: .init(position: kv.position, ngramContext: [],
                                                       ropeDelta: 0))
        let before = Data(bytes: kv.keyView(layer: layer).buffer.contents(), count: 6 * stride)
        kv.reset()
        memset(kv.keyView(layer: layer).buffer.contents(), 0, 6 * stride)
        try builder.restore(snapshot, queue: context.queue)
        kv.restorePosition(snapshot.position)
        let after = Data(bytes: kv.keyView(layer: layer).buffer.contents(), count: 6 * stride)
        #expect(after == before)
        #expect(kv.position == 9)
    }
}
