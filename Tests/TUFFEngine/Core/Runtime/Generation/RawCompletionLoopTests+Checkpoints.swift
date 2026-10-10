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
        private(set) var continuationPosition = 0
        private(set) var prefillRanges: [Range<Int>] = []
        private(set) var checkpointPositions: [Int] = []

        init(vocabSize: Int, terminalToken: Int32) {
            self.vocabSize = vocabSize
            self.terminalToken = terminalToken
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
        func capturePrefixCheckpoint() throws -> RunnerStateSnapshot {
            checkpointPositions.append(continuationPosition)
            return RunnerStateSnapshot(
                owner: ObjectIdentifier(self), storage: nil, segments: [],
                host: .init(position: continuationPosition, ngramContext: [], ropeDelta: 0))
        }
        func rewind(to checkpoint: RunnerStateSnapshot) throws {}

        private func writeTerminal(to logits: MTLBuffer) {
            let pointer = logits.contents().bindMemory(to: Float16.self, capacity: vocabSize)
            for index in 0..<vocabSize { pointer[index] = -30 }
            pointer[Int(terminalToken)] = 30
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
