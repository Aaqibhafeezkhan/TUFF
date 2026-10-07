import Foundation

/// The conversations a loaded model keeps between requests.
///
/// One conversation is *active*: its state is the runner's own KV and
/// recurrent state, exactly as the single-prefix cache always kept it. Other
/// conversations are *retained* as compact snapshots of that state, copied out
/// when a different conversation needs the runner. A request that continues a
/// retained conversation has its snapshot restored instead of prefilling the
/// whole history again.
///
/// This does not run two generations at once. Requests stay serialized by the
/// session that owns this store; only state survives between them.
///
/// Every retained byte is charged against `budgetBytes`, which the session
/// takes from the memory plan when it loads the model. Snapshots are
/// allocated only when a conversation is displaced, sized to the tokens it
/// holds, and the least recently used are evicted to make room. A budget of
/// zero retains nothing, which is the single-prefix behavior.
///
/// A match is always decided from the conversation's messages and tokens.
/// A conversation key only orders the search and says which older state a
/// newer one replaces.
public final class ConversationStateStore {
    public struct Statistics: Sendable, Equatable {
        public var budgetBytes: Int
        public var retainedConversations: Int
        public var retainedBytes: Int
        public var activeHits: Int = 0
        public var retainedHits: Int = 0
        public var misses: Int = 0
        public var captures: Int = 0
        public var evictions: Int = 0
        /// Conversations not retained because they alone exceed the budget or
        /// the copy failed.
        public var declined: Int = 0
        public var restoreFailures: Int = 0
        public var lastMissReason: ConversationCacheMissReason?
        /// Wall times in the most recent plan. Nil means that operation was
        /// not attempted, so an active hit never inherits an older copy time.
        public var lastLookupSeconds: Double?
        public var lastCaptureSeconds: Double?
        public var lastRestoreSeconds: Double?
    }

    public enum Source: String, Sendable, Equatable {
        case active
        case retained
        case cold
    }

    public struct Plan: Sendable, Equatable {
        public let match: ConversationCacheMatch
        public let source: Source

        /// How the completion starts, for a text match. A
        /// `renderThenResume` match is resumed by the caller after rendering.
        public var start: RawCompletionStart {
            switch match {
            case .hit(_, let cached), .renderThenResume(let cached):
                return .resume(cachedPromptTokens: cached)
            case .miss:
                return .reset
            }
        }
    }

    private struct Retained {
        let entry: ConversationCacheEntry
        let snapshot: RunnerStateSnapshot
        var lastUse: UInt64
    }

    public let budgetBytes: Int
    public let maximumRetained: Int
    public private(set) var active: ConversationCacheEntry?
    private var retained: [Retained] = []
    private var clock: UInt64 = 0
    private var counters = Statistics(budgetBytes: 0, retainedConversations: 0, retainedBytes: 0)
    private let memoryIsPressured: @Sendable () -> Bool

    public convenience init(budgetBytes: Int, maximumRetained: Int = 4) {
        self.init(budgetBytes: budgetBytes, maximumRetained: maximumRetained,
                  memoryIsPressured: { ConversationMemoryPressure.shared.isPressured })
    }

    init(budgetBytes: Int, maximumRetained: Int = 4,
         memoryIsPressured: @escaping @Sendable () -> Bool) {
        self.budgetBytes = max(0, budgetBytes)
        self.maximumRetained = max(0, maximumRetained)
        self.memoryIsPressured = memoryIsPressured
    }

    public var statistics: Statistics {
        var value = counters
        value.budgetBytes = budgetBytes
        value.retainedConversations = retained.count
        value.retainedBytes = retainedBytes
        return value
    }

    public var retainedBytes: Int { retained.reduce(0) { $0 + $1.snapshot.byteCount } }
    public var retainedEntries: [ConversationCacheEntry] { retained.map(\.entry) }

    /// Decides how a request starts and puts the runner in that state.
    ///
    /// On a retained hit the active conversation is first copied out (when it
    /// fits), then the matching snapshot is restored. On a miss the active
    /// conversation is copied out and the runner is left for a cold prefill;
    /// the caller resets it through `RawCompletionStart.reset`.
    public func plan(
        domain: ConversationCacheDomain,
        transcript: ConversationTranscript,
        renderedPromptIDs: [Int32]?,
        tokenizer: GFTokenizer,
        modelVariant: ModelVariant?,
        conversationKey: String?,
        runner: any StateSnapshottingRunner & ContinuableLogitProducer,
        allowsTextBridge: Bool = true
    ) -> Plan {
        counters.lastLookupSeconds = nil
        counters.lastCaptureSeconds = nil
        counters.lastRestoreSeconds = nil
        let lookupStarted = ContinuousClock.now
        clock &+= 1
        // A plan's static budget does not anticipate another application's
        // allocations. Keep the active runner usable but discard optional
        // snapshots and stop making new ones while macOS reports pressure.
        if memoryIsPressured() { releaseRetained() }
        // An active entry is only as good as the runner's agreement with it.
        if let entry = active, runner.continuationPosition != entry.kvPosition {
            active = nil
        }
        let activeMatch = ConversationCache.match(
            entry: active, domain: domain, transcript: transcript,
            renderedPromptIDs: renderedPromptIDs, tokenizer: tokenizer,
            modelVariant: modelVariant, allowsTextBridge: allowsTextBridge)
        if activeMatch.isHit {
            counters.lastLookupSeconds = Self.seconds(since: lookupStarted)
            counters.activeHits += 1
            log(.active, activeMatch)
            return Plan(match: activeMatch, source: .active)
        }

        var chosen: (index: Int, match: ConversationCacheMatch)?
        let order = retained.indices.sorted { lhs, rhs in
            let left = retained[lhs], right = retained[rhs]
            let leftKey = conversationKey != nil && left.entry.conversationKey == conversationKey
            let rightKey = conversationKey != nil && right.entry.conversationKey == conversationKey
            if leftKey != rightKey { return leftKey }
            return left.lastUse > right.lastUse
        }
        for index in order {
            let match = ConversationCache.match(
                entry: retained[index].entry, domain: domain, transcript: transcript,
                renderedPromptIDs: renderedPromptIDs, tokenizer: tokenizer,
                modelVariant: modelVariant, allowsTextBridge: allowsTextBridge)
            if match.isHit {
                chosen = (index, match)
                break
            }
        }
        counters.lastLookupSeconds = Self.seconds(since: lookupStarted)

        let restoring = chosen.map { retained.remove(at: $0.index) }
        displaceActive(runner: runner, reservedBytes: restoring?.snapshot.byteCount ?? 0)

        guard let restoring, let match = chosen?.match else {
            counters.misses += 1
            counters.lastMissReason = activeMatch.missReason
            let plan = Plan(match: activeMatch.missReason.map { .miss($0) } ?? .miss, source: .cold)
            log(.cold, plan.match)
            return plan
        }
        do {
            let started = ContinuousClock.now
            defer { counters.lastRestoreSeconds = Self.seconds(since: started) }
            try runner.restoreState(restoring.snapshot)
            counters.lastRestoreSeconds = Self.seconds(since: started)
            active = restoring.entry
            counters.retainedHits += 1
            log(.retained, match)
            return Plan(match: match, source: .retained)
        } catch {
            counters.restoreFailures += 1
            counters.misses += 1
            logConversationCacheMiss("retained conversation restore failed: \(error)")
            return Plan(match: .miss(.unusableEntry), source: .cold)
        }
    }

    /// Records the conversation the runner now holds, after a completed
    /// request. Nil says the runner's state cannot be continued.
    public func publish(_ entry: ConversationCacheEntry?) {
        active = entry
        guard let key = entry?.conversationKey else { return }
        // The same conversation's older state is superseded by this one.
        let before = retained.count
        retained.removeAll { $0.entry.conversationKey == key }
        counters.evictions += before - retained.count
    }

    /// The runner's state no longer matches any claim; called after a failed
    /// or cancelled completion, before the runner is reset.
    public func invalidateActive() {
        active = nil
    }

    /// Drops every retained conversation and the active claim, for example
    /// when the model or its runtime changes.
    public func clear() {
        active = nil
        retained.removeAll()
    }

    /// Releases retained conversations without touching the active one, for
    /// memory pressure.
    public func releaseRetained() {
        counters.evictions += retained.count
        retained.removeAll()
    }

    private func displaceActive(runner: any StateSnapshottingRunner & ContinuableLogitProducer,
                                reservedBytes: Int) {
        defer { active = nil }
        guard let entry = active, maximumRetained > 0, budgetBytes > 0 else { return }
        guard !memoryIsPressured() else { return }
        guard let bytes = runner.stateSnapshotByteEstimate,
              bytes + reservedBytes <= budgetBytes else {
            counters.declined += 1
            return
        }
        // Make room: the snapshot being restored is still alive until the
        // restore finishes, so it counts against the budget here too.
        while !retained.isEmpty,
              retained.count >= maximumRetained
                || retainedBytes + reservedBytes + bytes > budgetBytes {
            let oldest = retained.indices.min { retained[$0].lastUse < retained[$1].lastUse }!
            retained.remove(at: oldest)
            counters.evictions += 1
        }
        do {
            let started = ContinuousClock.now
            defer { counters.lastCaptureSeconds = Self.seconds(since: started) }
            let snapshot = try runner.captureState()
            retained.append(Retained(entry: entry, snapshot: snapshot, lastUse: clock))
            counters.captures += 1
        } catch {
            counters.declined += 1
            logConversationCacheMiss("conversation could not be retained: \(error)")
        }
    }
}

extension ConversationStateStore {
    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// One line per plan when `TFF_LOG_CACHE` is set.
    private func log(_ source: Source, _ match: ConversationCacheMatch) {
        guard ProcessInfo.processInfo.environment["TFF_LOG_CACHE"] != nil else { return }
        let cached: Int
        switch match {
        case .hit(_, let count), .renderThenResume(let count): cached = count
        case .miss: cached = 0
        }
        let stats = statistics
        FileHandle.standardError.write(Data(
            ("[cache] source=\(source.rawValue) cached=\(cached) "
             + "retained=\(stats.retainedConversations) bytes=\(stats.retainedBytes) "
             + "budget=\(stats.budgetBytes) capture=\(stats.lastCaptureSeconds.map { String(format: "%.3f", $0) } ?? "-") "
             + "restore=\(stats.lastRestoreSeconds.map { String(format: "%.3f", $0) } ?? "-")\n").utf8))
    }

    /// Retained bytes the session can afford: what the memory plan leaves
    /// between the model's working set and the safe budget, capped at
    /// `capBytes`. `TUFF_CONVERSATION_CACHE_MB` can lower the figure for A/B
    /// measurement, and zero disables retention; it can never raise it above
    /// what the plan leaves.
    public static func budget(safeBudgetBytes: UInt64,
                              workingSetBytes: UInt64,
                              capBytes: UInt64 = defaultCapBytes,
                              environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Int {
        guard safeBudgetBytes > workingSetBytes else { return 0 }
        var budget = min(capBytes, safeBudgetBytes - workingSetBytes)
        if let override = environment["TUFF_CONVERSATION_CACHE_MB"],
           let megabytes = UInt64(override.trimmingCharacters(in: .whitespaces)) {
            let requested = megabytes.multipliedReportingOverflow(by: 1 << 20)
            if !requested.overflow { budget = min(budget, requested.partialValue) }
        }
        return Int(clamping: budget)
    }

    /// 1 GiB. Three or four ordinary Gemma 26B conversations at a few
    /// thousand tokens, or several Flash Next ones, whose recurrent state is
    /// 119 MB at any length.
    public static let defaultCapBytes: UInt64 = 1 << 30
}
