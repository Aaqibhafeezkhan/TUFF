import Testing
import Foundation
import Metal
@testable import TUFFEngine

/// Resuming from where a user turn began. GPT-OSS's template drops a finished
/// turn's reasoning from the next render, so its generated tokens are never a
/// prefix of the next prompt; the tokens before the turn still are.
@Suite(.serialized) struct ConversationCheckpointTests {
    /// A runner whose state is a position and a tag, and which records rewinds.
    final class CheckpointRunner: StateSnapshottingRunner, ContinuableLogitProducer,
        PrefixCheckpointingRunner, @unchecked Sendable {
        var position = 0
        var tag = "empty"
        var failRewind = false
        var tagsBySnapshot: [ObjectIdentifier: String] = [:]
        private(set) var rewinds: [Int] = []

        var continuationPosition: Int { position }
        func prepareForContinuation(expectedPosition: Int) throws {}
        func reset() { position = 0; tag = "empty" }
        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {}

        var stateSnapshotByteEstimate: Int? { 16 }
        func captureState() throws -> RunnerStateSnapshot {
            let snapshot = snapshot(at: position)
            tagsBySnapshot[ObjectIdentifier(snapshot)] = tag
            return snapshot
        }
        func restoreState(_ snapshot: RunnerStateSnapshot) throws {
            position = snapshot.position
            tag = tagsBySnapshot[ObjectIdentifier(snapshot)] ?? "unknown"
        }

        var supportsPrefixCheckpoints: Bool { true }
        func capturePrefixCheckpoint() throws -> RunnerStateSnapshot { snapshot(at: position) }
        func rewind(to checkpoint: RunnerStateSnapshot) throws {
            guard !failRewind, checkpoint.position <= position else {
                reset()
                throw RunnerStateSnapshotError.layoutMismatch("injected")
            }
            position = checkpoint.position
            rewinds.append(checkpoint.position)
        }

        func snapshot(at position: Int) -> RunnerStateSnapshot {
            RunnerStateSnapshot(owner: ObjectIdentifier(self), storage: nil, segments: [],
                                host: .init(position: position, ngramContext: [], ropeDelta: 0))
        }
    }

    static let domain = ConversationCacheDomain(
        modelID: "gpt-oss", sourceSnapshotHash: nil, runtimeProfileHash: "r",
        maximumContext: 4_096, kvStorage: "fp16", fp16RingEnabled: true,
        templateSHA256: "t")
    static let date = "2026-10-09"

    static func harmony() async throws -> GFTokenizer {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tokenization/Fixtures/HarmonyTokenizer")
        return try await GFTokenizer.load(from: folder)
    }

    static func transcript(_ messages: [GFTokenizer.Message]) -> ConversationTranscript {
        ConversationTranscript(messages: messages, imageIdentities: messages.map { _ in [] },
                               reasoningEffort: .low, harmonyCurrentDate: date)
    }

    static func render(_ tokenizer: GFTokenizer, _ messages: [GFTokenizer.Message]) throws -> [Int32] {
        try tokenizer.encodeHarmonyChat(messages: messages, reasoningEffort: .low, currentDate: date)
    }

    static let firstTurn: [GFTokenizer.Message] = [
        .init(role: .system, content: "Be brief."),
        .init(role: .user, content: "What is the capital of France?"),
    ]
    static let answer = GFTokenizer.Message(role: .assistant, content: "Paris.")
    static let followUp: [GFTokenizer.Message] =
        firstTurn + [answer, .init(role: .user, content: "And of Spain?")]

    /// The entry a finished first turn leaves: its prompt, then reasoning and
    /// an answer the next render will rewrite, ended by `<|return|>`.
    static func finishedTurn(_ tokenizer: GFTokenizer, runner: CheckpointRunner,
                             checkpoint: Bool = true) throws -> ConversationCacheEntry? {
        let prompt = try render(tokenizer, firstTurn)
        let generated = tokenizer.encode(
            "<|channel|>analysis<|message|>Easy one.<|end|>"
                + "<|start|>assistant<|channel|>final<|message|>Paris.", addBOS: false)
        let kv = prompt + generated
        runner.position = kv.count
        let result = RawDecodeResult(
            prefillTokens: prompt.count, cachedPromptTokens: 0,
            computedPrefillTokens: prompt.count, prefillSeconds: 0,
            newTokens: generated.count + 1, decodeSeconds: 0, reason: .eos,
            kvPosition: kv.count, kvBackedTokenIDs: kv,
            uncommittedBoundaryTokenIDs: [try #require(tokenizer.harmonyTokenIDs?.return)])
        return ConversationCache.entry(
            domain: domain, transcript: transcript(firstTurn), content: "Paris.",
            thinking: "Easy one.", calls: [], result: result,
            prefixCheckpoint: checkpoint
                ? ConversationPrefixCheckpoint(tokenIDs: prompt,
                                               snapshot: runner.snapshot(at: prompt.count))
                : nil)
    }

    @Test func aFollowUpAfterAFinalAnswerResumesWhereTheTurnBegan() async throws {
        let tokenizer = try await Self.harmony()
        let runner = CheckpointRunner()
        let entry = try #require(try Self.finishedTurn(tokenizer, runner: runner))
        let rendered = try Self.render(tokenizer, Self.followUp)
        let prompt = try Self.render(tokenizer, Self.firstTurn)
        let match = ConversationCache.match(
            entry: entry, domain: Self.domain, transcript: Self.transcript(Self.followUp),
            renderedPromptIDs: rendered, tokenizer: tokenizer, allowsTextBridge: false)
        // The whole fresh render is prefilled from the checkpoint on, so the
        // prompt is exactly what a cold request would process.
        #expect(match == .hit(effectivePromptIDs: rendered, cachedPromptTokens: prompt.count))
    }

    @Test func aRewrittenEarlierTurnDoesNotResume() async throws {
        let tokenizer = try await Self.harmony()
        let runner = CheckpointRunner()
        let entry = try #require(try Self.finishedTurn(tokenizer, runner: runner))
        var edited = Self.followUp
        edited[1] = .init(role: .user, content: "What is the capital of Italy?")
        let match = ConversationCache.match(
            entry: entry, domain: Self.domain, transcript: Self.transcript(edited),
            renderedPromptIDs: try Self.render(tokenizer, edited), tokenizer: tokenizer,
            allowsTextBridge: false)
        #expect(!match.isHit)
    }

    /// `<|return|>` ends a GPT-OSS answer as an EOS. Without a checkpoint
    /// nothing can continue past it, so nothing is kept.
    @Test func anAnswerEndedByReturnIsKeptOnlyWithACheckpoint() async throws {
        let tokenizer = try await Self.harmony()
        let runner = CheckpointRunner()
        #expect(try Self.finishedTurn(tokenizer, runner: runner, checkpoint: false) == nil)
        #expect(try Self.finishedTurn(tokenizer, runner: runner) != nil)
    }

    @Test func aCheckpointOutsideTheKVIsDropped() async throws {
        let tokenizer = try await Self.harmony()
        let runner = CheckpointRunner()
        let prompt = try Self.render(tokenizer, Self.firstTurn)
        let result = RawDecodeResult(
            prefillTokens: prompt.count, cachedPromptTokens: 0,
            computedPrefillTokens: prompt.count, prefillSeconds: 0, newTokens: 2,
            decodeSeconds: 0, reason: .toolCalls, kvPosition: prompt.count + 1,
            kvBackedTokenIDs: prompt + [5], uncommittedBoundaryTokenIDs: [6])
        var other = prompt
        other[3] = other[3] &+ 1
        let entry = ConversationCache.entry(
            domain: Self.domain, transcript: Self.transcript(Self.firstTurn), content: "",
            calls: [ParsedToolCall(id: "c", name: "f", arguments: .object([:]),
                                   argumentsJSON: "{}")],
            result: result,
            prefixCheckpoint: ConversationPrefixCheckpoint(
                tokenIDs: other, snapshot: runner.snapshot(at: other.count)))
        #expect(entry != nil)
        #expect(entry?.prefixCheckpoint == nil)
    }

    @Test func theStoreRewindsTheRunnerBeforeResuming() async throws {
        let tokenizer = try await Self.harmony()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { false })
        let runner = CheckpointRunner()
        store.publish(try Self.finishedTurn(tokenizer, runner: runner))
        let prompt = try Self.render(tokenizer, Self.firstTurn)
        let plan = store.plan(
            domain: Self.domain, transcript: Self.transcript(Self.followUp),
            renderedPromptIDs: try Self.render(tokenizer, Self.followUp),
            tokenizer: tokenizer, modelVariant: nil, conversationKey: nil,
            runner: runner, allowsTextBridge: false)
        #expect(plan.source == .active)
        #expect(plan.start == .resume(cachedPromptTokens: prompt.count))
        #expect(runner.rewinds == [prompt.count])
        #expect(runner.position == prompt.count)
    }

    @Test func aFailedRewindFallsBackToAColdPrefill() async throws {
        let tokenizer = try await Self.harmony()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { false })
        let runner = CheckpointRunner()
        store.publish(try Self.finishedTurn(tokenizer, runner: runner))
        runner.failRewind = true
        let plan = store.plan(
            domain: Self.domain, transcript: Self.transcript(Self.followUp),
            renderedPromptIDs: try Self.render(tokenizer, Self.followUp),
            tokenizer: tokenizer, modelVariant: nil, conversationKey: nil,
            runner: runner, allowsTextBridge: false)
        #expect(plan.source == .cold)
        #expect(plan.start == .reset)
        #expect(store.active == nil)
    }

    @Test func aRetainedConversationIsRestoredThenRewound() async throws {
        let tokenizer = try await Self.harmony()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { false })
        let runner = CheckpointRunner()
        runner.tag = "A"
        store.publish(try Self.finishedTurn(tokenizer, runner: runner))
        // Another conversation takes the runner, so A is copied out.
        let other: [GFTokenizer.Message] = [.init(role: .user, content: "Unrelated")]
        let cold = store.plan(
            domain: Self.domain, transcript: Self.transcript(other),
            renderedPromptIDs: try Self.render(tokenizer, other),
            tokenizer: tokenizer, modelVariant: nil, conversationKey: nil,
            runner: runner, allowsTextBridge: false)
        #expect(cold.source == .cold)
        runner.reset()
        runner.position = 3
        runner.tag = "B"

        let prompt = try Self.render(tokenizer, Self.firstTurn)
        let plan = store.plan(
            domain: Self.domain, transcript: Self.transcript(Self.followUp),
            renderedPromptIDs: try Self.render(tokenizer, Self.followUp),
            tokenizer: tokenizer, modelVariant: nil, conversationKey: nil,
            runner: runner, allowsTextBridge: false)
        #expect(plan.source == .retained)
        #expect(plan.start == .resume(cachedPromptTokens: prompt.count))
        #expect(runner.tag == "A")
        #expect(runner.position == prompt.count)
    }
}
