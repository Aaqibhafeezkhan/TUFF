import Testing
import Foundation
import Metal
@testable import TUFFEngine

/// The retained-conversation store against a runner whose "state" is a
/// position and a tag, so every decision the store makes is visible.
@Suite(.serialized) struct ConversationStateStoreTests {
    /// A runner that records what it holds. A snapshot is `bytesPerToken` per
    /// position, allocated for real so the budget arithmetic is exercised.
    final class FakeRunner: StateSnapshottingRunner, ContinuableLogitProducer,
        @unchecked Sendable {
        let device = MTLCreateSystemDefaultDevice()!
        var position = 0
        var tag = "empty"
        var bytesPerToken = 1_024
        var failRestore = false
        var tagsBySnapshot: [ObjectIdentifier: String] = [:]
        private(set) var restores: [String] = []
        private(set) var captures = 0

        var continuationPosition: Int { position }
        func prepareForContinuation(expectedPosition: Int) throws {}
        func reset() { position = 0; tag = "empty" }
        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {}

        var stateSnapshotByteEstimate: Int? {
            RunnerStateSnapshotBuilder.aligned(max(1, position) * bytesPerToken)
        }

        func captureState() throws -> RunnerStateSnapshot {
            captures += 1
            let bytes = stateSnapshotByteEstimate!
            let snapshot = RunnerStateSnapshot(
                owner: ObjectIdentifier(self),
                storage: device.makeBuffer(length: bytes, options: .storageModeShared),
                segments: [], host: .init(position: position, ngramContext: [], ropeDelta: 0))
            tagsBySnapshot[ObjectIdentifier(snapshot)] = tag
            return snapshot
        }

        func restoreState(_ snapshot: RunnerStateSnapshot) throws {
            reset()
            if failRestore { throw RunnerStateSnapshotError.layoutMismatch("injected") }
            position = snapshot.position
            tag = tagsBySnapshot[ObjectIdentifier(snapshot)] ?? "unknown"
            restores.append(tag)
        }
    }

    static let domain = ConversationCacheDomain(
        modelID: "toy", sourceSnapshotHash: nil, runtimeProfileHash: "r",
        maximumContext: 4_096, kvStorage: "fp16", fp16RingEnabled: true,
        templateSHA256: "t")

    static func tokenizer() async throws -> GFTokenizer {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tokenization/Fixtures/ChatMLTokenizer")
        return try await GFTokenizer.load(from: folder)
    }

    /// A finished conversation whose KV holds `tokens`, published as the
    /// runner's active state.
    static func finish(_ store: ConversationStateStore, runner: FakeRunner,
                       tag: String, tokens: [Int32], key: String? = nil) {
        runner.position = tokens.count
        runner.tag = tag
        let transcript = ConversationTranscript(
            messages: [.init(role: .user, content: tag)])
        let result = RawDecodeResult(
            prefillTokens: tokens.count, cachedPromptTokens: 0,
            computedPrefillTokens: tokens.count, prefillSeconds: 0, newTokens: 1,
            decodeSeconds: 0, reason: .endOfTurn, kvPosition: tokens.count,
            kvBackedTokenIDs: tokens, uncommittedBoundaryTokenIDs: [99])
        store.publish(ConversationCache.entry(
            domain: domain, transcript: transcript, content: "answer", calls: [],
            result: result, conversationKey: key))
    }

    /// A request whose rendered prompt extends `tokens`.
    static func plan(_ store: ConversationStateStore, runner: FakeRunner,
                     tokenizer: GFTokenizer, extending tokens: [Int32],
                     key: String? = nil) -> ConversationStateStore.Plan {
        store.plan(domain: domain,
                   transcript: ConversationTranscript(messages: [.init(role: .user, content: "x")]),
                   renderedPromptIDs: tokens + [7, 7, 7],
                   tokenizer: tokenizer, modelVariant: nil,
                   conversationKey: key, runner: runner)
    }

    static let a: [Int32] = Array(1...40)
    static let b: [Int32] = Array(100...160)
    static let c: [Int32] = Array(200...230)

    @Test func theActiveConversationContinuesWithoutACopy() async throws {
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { false })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a)
        let plan = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.a)
        #expect(plan.source == .active)
        #expect(plan.start == .resume(cachedPromptTokens: Self.a.count))
        #expect(runner.captures == 0)
    }

    @Test func alternatingConversationsResumeFromRetainedState() async throws {
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { false })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a)

        // B is new: A is copied out and B prefills cold.
        let toB = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b)
        #expect(toB.source == .cold)
        #expect(store.statistics.retainedConversations == 1)
        Self.finish(store, runner: runner, tag: "B", tokens: Self.b)

        // Back to A: B is copied out, A restored and resumed.
        let toA = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.a)
        #expect(toA.source == .retained)
        #expect(toA.start == .resume(cachedPromptTokens: Self.a.count))
        #expect(runner.tag == "A")
        #expect(runner.position == Self.a.count)
        #expect(store.statistics.retainedConversations == 1)
        #expect(store.retainedEntries.first?.kvBackedTokenIDs == Self.b)
        #expect(store.statistics.retainedHits == 1)
        #expect(store.statistics.lastLookupSeconds != nil)
        #expect(store.statistics.lastCaptureSeconds != nil)
        #expect(store.statistics.lastRestoreSeconds != nil)
        _ = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.a)
        #expect(store.statistics.lastLookupSeconds != nil)
        #expect(store.statistics.lastCaptureSeconds == nil)
        #expect(store.statistics.lastRestoreSeconds == nil)
    }

    @Test func aZeroBudgetIsTheSinglePrefixBehavior() async throws {
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 0, memoryIsPressured: { false })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a)
        _ = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b)
        Self.finish(store, runner: runner, tag: "B", tokens: Self.b)
        let back = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.a)
        #expect(back.source == .cold)
        #expect(runner.captures == 0)
        #expect(store.statistics.retainedBytes == 0)
    }

    @Test func memoryPressureKeepsTheActiveStateAndRefusesOptionalSnapshots() async throws {
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { true })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a)
        let active = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.a)
        #expect(active.source == .active)
        #expect(runner.tag == "A")
        let cold = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b)
        #expect(cold.source == .cold)
        #expect(runner.captures == 0)
        #expect(store.statistics.retainedBytes == 0)
    }

    @Test func pressureDiscardsAlreadyRetainedConversationsAtTheNextBoundary() async throws {
        final class Pressure: @unchecked Sendable {
            let lock = NSLock()
            private var value = false
            var isPressured: Bool { lock.withLock { value } }
            func warn() { lock.withLock { value = true } }
        }
        let pressure = Pressure()
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 1 << 20,
                                           memoryIsPressured: { pressure.isPressured })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a)
        _ = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b)
        Self.finish(store, runner: runner, tag: "B", tokens: Self.b)
        #expect(store.statistics.retainedConversations == 1)
        pressure.warn()
        let active = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b)
        #expect(active.source == .active)
        #expect(store.statistics.retainedConversations == 0)
        #expect(store.statistics.evictions == 1)
        #expect(runner.tag == "B")
    }

    @Test func theLeastRecentlyUsedConversationIsEvictedToFitTheBudget() async throws {
        let tokenizer = try await Self.tokenizer()
        // Room for A (40 KiB) and B (61 KiB) but not C as well.
        let store = ConversationStateStore(budgetBytes: 110 * 1_024, memoryIsPressured: { false })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a)
        _ = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b)
        Self.finish(store, runner: runner, tag: "B", tokens: Self.b)
        _ = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.c)
        Self.finish(store, runner: runner, tag: "C", tokens: Self.c)
        #expect(store.statistics.retainedConversations == 2)
        // Displacing C needs 32 KiB more; A is the oldest and goes.
        _ = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: [1_000])
        #expect(store.statistics.retainedBytes <= store.budgetBytes)
        #expect(!store.retainedEntries.contains { $0.kvBackedTokenIDs == Self.a })
        #expect(store.retainedEntries.contains { $0.kvBackedTokenIDs == Self.c })
        #expect(store.statistics.evictions >= 1)
    }

    @Test func aConversationLargerThanTheBudgetIsNotRetained() async throws {
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 8 * 1_024, memoryIsPressured: { false })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a)
        let plan = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b)
        #expect(plan.source == .cold)
        #expect(runner.captures == 0)
        #expect(store.statistics.declined == 1)
        #expect(store.statistics.retainedConversations == 0)
    }

    @Test func aFailedRestoreFallsBackToColdPrefill() async throws {
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { false })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a)
        _ = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b)
        Self.finish(store, runner: runner, tag: "B", tokens: Self.b)
        runner.failRestore = true
        let plan = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.a)
        #expect(plan.source == .cold)
        #expect(plan.start == .reset)
        #expect(store.statistics.restoreFailures == 1)
        #expect(store.active == nil)
    }

    @Test func aKeyIsAPreferenceNotAMatch() async throws {
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { false })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a, key: "chat-1")
        _ = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b,
                      key: "chat-2")
        Self.finish(store, runner: runner, tag: "B", tokens: Self.b, key: "chat-2")
        // Same key as A, different tokens: nothing matches, nothing restored.
        let plan = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.c,
                             key: "chat-1")
        #expect(plan.source == .cold)
        #expect(runner.restores.isEmpty)
    }

    @Test func publishingAKeyReplacesThatConversationsOlderState() async throws {
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { false })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a, key: "chat-1")
        _ = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.b,
                      key: "chat-1")
        #expect(store.statistics.retainedConversations == 1)
        // The same conversation, edited: its new state supersedes the old.
        Self.finish(store, runner: runner, tag: "A2", tokens: Self.b, key: "chat-1")
        #expect(store.statistics.retainedConversations == 0)
    }

    @Test func anActiveClaimTheRunnerNoLongerHoldsIsDropped() async throws {
        let tokenizer = try await Self.tokenizer()
        let store = ConversationStateStore(budgetBytes: 1 << 20, memoryIsPressured: { false })
        let runner = FakeRunner()
        Self.finish(store, runner: runner, tag: "A", tokens: Self.a)
        runner.reset()
        let plan = Self.plan(store, runner: runner, tokenizer: tokenizer, extending: Self.a)
        #expect(plan.source == .cold)
        #expect(runner.captures == 0)
    }

    @Test func theBudgetComesFromThePlanAndAnOverrideCanOnlyLowerIt() {
        let gib: UInt64 = 1 << 30
        #expect(ConversationStateStore.budget(safeBudgetBytes: 12 * gib,
                                              workingSetBytes: 9 * gib,
                                              environment: [:]) == Int(gib))
        #expect(ConversationStateStore.budget(safeBudgetBytes: 12 * gib,
                                              workingSetBytes: 11_800 << 20,
                                              environment: [:]) == 488 << 20)
        #expect(ConversationStateStore.budget(safeBudgetBytes: 8 * gib,
                                              workingSetBytes: 9 * gib,
                                              environment: [:]) == 0)
        #expect(ConversationStateStore.budget(
            safeBudgetBytes: 12 * gib, workingSetBytes: 9 * gib,
            environment: ["TUFF_CONVERSATION_CACHE_MB": "0"]) == 0)
        #expect(ConversationStateStore.budget(
            safeBudgetBytes: 12 * gib, workingSetBytes: 9 * gib,
            environment: ["TUFF_CONVERSATION_CACHE_MB": "256"]) == 256 << 20)
        #expect(ConversationStateStore.budget(
            safeBudgetBytes: 12 * gib, workingSetBytes: 11_800 << 20,
            environment: ["TUFF_CONVERSATION_CACHE_MB": "4096"]) == 488 << 20)
    }
}
