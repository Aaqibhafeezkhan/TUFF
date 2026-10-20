import Testing
import Metal

@testable import TUFFEngine

extension RawCompletionLoopTests {
    @Test(arguments: [UInt32.max, UInt32(262_144)])
    func invalidHeadTokenIsRejectedBeforeItIsDelivered(token: UInt32) async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load()
        let producer = InvalidTokenProducer(token: token)
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)
        var delivered = 0
        do {
            _ = try await runRawCompletion(producer: producer, tokenizer: tokenizer,
                promptIds: [tokenizer.bosID],
                config: GenerationConfig(maxNewTokens: 1, temperature: 0),
                context: context, scratch: scratch, prefillConfig: .off) {
                    if case .token = $0 { delivered += 1 }
                }
            Issue.record("an out-of-vocabulary token was accepted")
        } catch {
            #expect(String(describing: error).contains("valid next token"))
        }
        #expect(delivered == 0)
        #expect(producer.produceCalls == 1)
    }

    final class InvalidTokenProducer: LogitProducer, GreedyHeadReporting, @unchecked Sendable {
        let lastGreedyToken: UInt32
        var usesFusedGreedyHead: Bool { true }
        private(set) var produceCalls = 0
        init(token: UInt32) { lastGreedyToken = token }
        func reset() {}
        func selectHead(pureGreedy: Bool) {}
        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {
            produceCalls += 1
        }
    }

    @Test(arguments: [0, 0.2])
    func nonfiniteLogitsStopBeforeAnotherForward(temperature: Float) async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load()
        let values = [Float](repeating: .nan, count: tokenizer.vocabSize)
        let producer = CountingProducer(vocabSize: tokenizer.vocabSize, step: { _, _ in .vector(values) })
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)
        var delivered = 0
        do {
            _ = try await runRawCompletion(producer: producer, tokenizer: tokenizer,
                promptIds: [tokenizer.bosID],
                config: GenerationConfig(maxNewTokens: 4, temperature: temperature, topK: 64),
                context: context, scratch: scratch, prefillConfig: .off) {
                    if case .token = $0 { delivered += 1 }
                }
            Issue.record("invalid model arithmetic was accepted")
        } catch let error as GeneratorError {
            #expect(error == .invalidModelOutput)
        }
        #expect(delivered == 0)
        #expect(producer.produceCalls == 1)
    }

    @Test func rawCompletionRejectsContextOverflowBeforeReset() async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load()
        let tokenA = tokenizer.encode("a", addBOS: false).first!
        let promptIDs = tokenizer.encode("one two three", addBOS: true)
        let producer = CountingProducer(
            vocabSize: tokenizer.vocabSize,
            maxContext: promptIDs.count,
            step: automaton([tokenA], end: tokenizer.eosID))
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)

        do {
            _ = try await runRawCompletion(
                producer: producer,
                tokenizer: tokenizer,
                promptIds: promptIDs,
                config: GenerationConfig(maxNewTokens: 1, temperature: 0),
                context: context,
                scratch: scratch,
                prefillConfig: .off) { _ in }
            Issue.record("expected context overflow")
        } catch let error as GeneratorError {
            guard case .contextOverflow(let prompt, let maxNew, let maxContext) = error else {
                Issue.record("unexpected GeneratorError \(error)")
                return
            }
            #expect(prompt == promptIDs.count)
            #expect(maxNew == 1)
            #expect(maxContext == promptIDs.count)
        }

        #expect(producer.resetCalls == 0)
        #expect(producer.produceCalls == 0)
    }

    @Test func rawCompletionRejectsZeroMaxNewBeforeReset() async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load()
        let tokenA = tokenizer.encode("a", addBOS: false).first!
        let promptIDs = tokenizer.encode("one two three", addBOS: true)
        let producer = CountingProducer(
            vocabSize: tokenizer.vocabSize,
            step: automaton([tokenA], end: tokenizer.eosID))
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)

        do {
            _ = try await runRawCompletion(
                producer: producer,
                tokenizer: tokenizer,
                promptIds: promptIDs,
                config: GenerationConfig(maxNewTokens: 0, temperature: 0),
                context: context,
                scratch: scratch,
                prefillConfig: .off) { _ in }
            Issue.record("expected invalid generation config")
        } catch let error as GeneratorError {
            guard case .invalidGenerationConfig(let reason) = error else {
                Issue.record("unexpected GeneratorError \(error)")
                return
            }
            #expect(reason.contains("maxNewTokens"))
        }

        #expect(producer.resetCalls == 0)
        #expect(producer.produceCalls == 0)
    }

    @Test func rawCompletionRejectsEmptyPromptBeforeReset() async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load()
        let tokenA = tokenizer.encode("a", addBOS: false).first!
        let producer = CountingProducer(
            vocabSize: tokenizer.vocabSize,
            step: automaton([tokenA], end: tokenizer.eosID))
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)

        do {
            _ = try await runRawCompletion(
                producer: producer,
                tokenizer: tokenizer,
                promptIds: [],
                config: GenerationConfig(maxNewTokens: 1, temperature: 0),
                context: context,
                scratch: scratch,
                prefillConfig: .off) { _ in }
            Issue.record("expected empty prompt rejection")
        } catch let error as GeneratorError {
            #expect(error == .emptyPrompt)
        }

        #expect(producer.resetCalls == 0)
        #expect(producer.produceCalls == 0)
    }
}
