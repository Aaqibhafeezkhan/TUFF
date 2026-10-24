import Metal
import Testing

@testable import TUFFEngine

extension RawCompletionLoopTests {
    /// A chunked producer that can take prefix checkpoints and records the
    /// position of each one.
    final class CheckpointingProducer: ChunkedPrefillRunner, ContinuableLogitProducer,
        PrefixCheckpointingRunner, @unchecked Sendable
    {
        let vocabSize: Int
        private let terminalToken: Int32
        private let checkpointBytes: Int
        private let device: MTLDevice?
        private(set) var continuationPosition = 0
        private(set) var prefillRanges: [Range<Int>] = []
        private(set) var checkpointPositions: [Int] = []

        init(vocabSize: Int, terminalToken: Int32, checkpointBytes: Int = 0, device: MTLDevice? = nil) {
            self.vocabSize = vocabSize
            self.terminalToken = terminalToken
            self.checkpointBytes = checkpointBytes
            self.device = device
        }

        func reset() { continuationPosition = 0 }
        func prepareForContinuation(expectedPosition: Int) throws {}
        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {
            continuationPosition += 1
            writeTerminal(to: logits)
        }

        func prefillChunked(tokens: ArraySlice<Int32>, startPosition: Int,
                            outputMode: PrefillOutputMode, config: PrefillRuntimeConfig,
                            into logits: MTLBuffer,
                            onProgress: (Int) -> Void) async throws -> PrefillResult {
            guard continuationPosition == startPosition else {
                throw PrefillError.prefillCursorMismatch("test prefill cursor mismatch")
            }
            prefillRanges.append(startPosition..<(startPosition + tokens.count))
            continuationPosition += tokens.count
            onProgress(tokens.count)
            writeTerminal(to: logits)
            return PrefillResult(newPosition: continuationPosition, seed: .logitsWritten)
        }

        var supportsPrefixCheckpoints: Bool { true }
        var prefixCheckpointByteEstimate: Int { checkpointBytes }
        func capturePrefixCheckpoint() throws -> RunnerStateSnapshot {
            checkpointPositions.append(continuationPosition)
            return RunnerStateSnapshot(
                owner: ObjectIdentifier(self), storage: checkpointBytes > 0
                    ? device?.makeBuffer(length: checkpointBytes, options: .storageModeShared) : nil, segments: [],
                host: .init(position: continuationPosition, ngramContext: [], ropeDelta: 0))
        }
        func rewind(to checkpoint: RunnerStateSnapshot) throws {}

        private func writeTerminal(to logits: MTLBuffer) {
            let pointer = logits.contents().bindMemory(to: Float16.self, capacity: vocabSize)
            for index in 0..<vocabSize { pointer[index] = -30 }
            pointer[Int(terminalToken)] = 30
        }
    }

    @Test func giantExpertWorkingSetsAvoidDuplicateFileCachesOnlyOnConstrainedDevices() {
        let stride: UInt64 = 7_864_320
        #expect(Model.shouldBypassExpertFilesystemCache(expertStride: stride, minimumSlots: 10,
            layers: 60, physicalMemory: 16 << 30))
        #expect(!Model.shouldBypassExpertFilesystemCache(expertStride: stride, minimumSlots: 10,
            layers: 60, physicalMemory: 32 << 30))
        #expect(!Model.shouldBypassExpertFilesystemCache(expertStride: 1 << 20, minimumSlots: 8,
            layers: 30, physicalMemory: 16 << 30))
        #expect(Model.shouldBypassExpertFilesystemCache(expertStride: .max, minimumSlots: 10,
            layers: 60, physicalMemory: 16 << 30))
    }

    /// Ornith 1.5 122B's 65 GB of experts outgrow a 16 or 24 GB Mac's file
    /// cache but not a 64 GB one's. Ornith 35B's 18 GB never do.
    @Test func expertPayloadsFarLargerThanMemoryReadPastTheFileCache() {
        let ornith122: UInt64 = 5_308_416, ornith35: UInt64 = 1_769_472
        #expect(Model.expertPayloadOutgrowsFileCache(expertStride: ornith122, expertsPerLayer: 256,
            layers: 48, physicalMemory: 16 << 30))
        #expect(Model.expertPayloadOutgrowsFileCache(expertStride: ornith122, expertsPerLayer: 256,
            layers: 48, physicalMemory: 24 << 30))
        #expect(!Model.expertPayloadOutgrowsFileCache(expertStride: ornith122, expertsPerLayer: 256,
            layers: 48, physicalMemory: 64 << 30))
        #expect(!Model.expertPayloadOutgrowsFileCache(expertStride: ornith35, expertsPerLayer: 256,
            layers: 40, physicalMemory: 16 << 30))
        #expect(Model.expertPayloadOutgrowsFileCache(expertStride: .max, expertsPerLayer: 256,
            layers: 48, physicalMemory: 16 << 30))
        #expect(!Model.expertPayloadOutgrowsFileCache(expertStride: ornith122, expertsPerLayer: 0,
            layers: 48, physicalMemory: 16 << 30))
        // Only the 122B, where it was measured to help: Flash Next is as large
        // and decoded slower without the cache.
        #expect(Model.readsExpertsPastFileCache(variant: .ornith15_122B, expertStride: ornith122,
            expertsPerLayer: 256, layers: 48, physicalMemory: 16 << 30))
        #expect(!Model.readsExpertsPastFileCache(variant: .qwen38FlashNext, expertStride: ornith122,
            expertsPerLayer: 256, layers: 48, physicalMemory: 16 << 30))
        #expect(!Model.readsExpertsPastFileCache(variant: .ornith15_122B, expertStride: ornith122,
            expertsPerLayer: 256, layers: 48, physicalMemory: 64 << 30))
    }

    @Test func checkpointCopiesRespectTheBudgetBeforeAllocation() async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load()
        for budget in [0, 16] {
            let producer = CheckpointingProducer(vocabSize: tokenizer.vocabSize,
                terminalToken: tokenizer.eosID, checkpointBytes: 16, device: context.device)
            let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)
            let result = try await runRawCompletion(producer: producer, tokenizer: tokenizer,
                promptIds: Array(repeating: tokenizer.encode("a", addBOS: false)[0], count: 40),
                config: GenerationConfig(maxNewTokens: 4, temperature: 0), context: context, scratch: scratch,
                prefillConfig: .production(chunkTokens: 32), prefixCheckpointPositions: [25, 40],
                checkpointBudgetBytes: budget) { _ in }
            #expect(producer.checkpointPositions == (budget == 0 ? [] : [25]))
            #expect(result.prefixCheckpoints.reduce(0) { $0 + $1.byteCount } <= budget)
            #expect(producer.continuationPosition == 40)
        }
    }

    /// A checkpoint inside the prompt splits the prefill there, so the runner
    /// is exactly at that position when it is taken, and progress still
    /// counts the whole prompt.
    @Test func prefixCheckpointsSplitThePrefillAtEachPosition() async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load()
        let producer = CheckpointingProducer(vocabSize: tokenizer.vocabSize,
                                             terminalToken: tokenizer.eosID)
        let promptIDs = Array(repeating: tokenizer.encode("a", addBOS: false)[0], count: 40)
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)
        var progress: [Int] = []

        let result = try await runRawCompletion(
            producer: producer, tokenizer: tokenizer, promptIds: promptIDs,
            config: GenerationConfig(maxNewTokens: 4, temperature: 0),
            context: context, scratch: scratch,
            prefillConfig: .production(chunkTokens: 32),
            // Out of order, repeated, past the prompt and at zero: only the
            // positions inside the prompt count, once each.
            prefixCheckpointPositions: [40, 25, 0, 25, 99]) { event in
                if case .prefill(let done, _) = event { progress.append(done) }
            }

        #expect(producer.prefillRanges == [0..<25, 25..<40])
        #expect(producer.checkpointPositions == [25, 40])
        #expect(result.prefixCheckpoints.map(\.position) == [25, 40])
        #expect(progress == [25, 40])
    }
}
