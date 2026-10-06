import Foundation
import Metal
import Testing
@testable import TUFFEngine
@testable import TUFFServerCore

/// The boundary token that ends a completion is replayed into the structured
/// decoder only when the raw loop withheld it from `.token` progress. These
/// tests drive the server's production decode path with a scripted producer
/// and real dialect tokenizers.
@Suite("Server structured decode boundary", .serialized)
struct ServerStructuredBoundaryTests {
    /// Emits a fixed token script after the prompt, one greedy token per step.
    private final class ScriptedProducer: LogitProducer, @unchecked Sendable {
        let vocabSize: Int
        let promptCount: Int
        let script: [Int32]
        let filler: Int32

        init(vocabSize: Int, promptCount: Int, script: [Int32], filler: Int32) {
            self.vocabSize = vocabSize
            self.promptCount = promptCount
            self.script = script
            self.filler = filler
        }

        func reset() {}

        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {
            let index = position - (promptCount - 1)
            let next = index >= 0 && index < script.count ? script[index] : filler
            let pointer = logits.contents().bindMemory(to: Float16.self, capacity: vocabSize)
            for i in 0..<vocabSize { pointer[i] = Float16(-30.0) }
            pointer[Int(next)] = Float16(30.0)
        }
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ServerInferenceEvent] = []
        func append(_ event: ServerInferenceEvent) {
            lock.withLock { stored.append(event) }
        }
        var events: [ServerInferenceEvent] { lock.withLock { stored } }
        var calls: [ParsedToolCall] {
            events.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
        }
        var content: String {
            events.reduce(into: "") { text, event in
                if case .content(let delta) = event { text += delta }
            }
        }
    }

    private static let readTool = GFTokenizer.FunctionDefinition(
        name: "read",
        description: "Read a file",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["path": .object(["type": .string("string")])]),
        ]))

    private static func fixture(_ name: String) async throws -> GFTokenizer {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TUFFEngine/Core/Tokenization/Fixtures")
            .appendingPathComponent(name)
        return try await GFTokenizer.load(from: folder)
    }

    private static func gemma() async throws -> GFTokenizer {
        try await GFTokenizer.load()
    }

    private static func qwen() async throws -> GFTokenizer {
        try await fixture("ChatMLTokenizer")
    }

    private static func minimax() async throws -> GFTokenizer {
        try await fixture("MiniMaxTokenizer")
    }

    private static func harmony() async throws -> GFTokenizer {
        try await fixture("HarmonyTokenizer")
    }

    /// Runs `script` through the production server decode path. A
    /// `maxNewTokens` of nil allows one token more than the script.
    private func decode(
        tokenizer: GFTokenizer,
        script: [Int32],
        maxNewTokens: Int? = nil,
        stopStrings: [String] = [],
        tools: [GFTokenizer.FunctionDefinition] = [readTool],
        reasoning: ChatReasoning = .off,
        log: EventLog
    ) async throws -> ServerStructuredDecodeOutcome {
        let context = try MetalContext()
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)
        let prompt = Array(tokenizer.encode("go", addBOS: false).prefix(1))
        let producer = ScriptedProducer(
            vocabSize: tokenizer.vocabSize,
            promptCount: prompt.count,
            script: script,
            filler: tokenizer.eosID)
        let decoder = ServerModelSession.assistantDecoder(
            tokenizer: tokenizer, tools: tools, reasoning: reasoning)
        let config = GenerationConfig(
            maxNewTokens: maxNewTokens ?? script.count + 1,
            temperature: 0)
        return try await ServerModelSession.decodeStructuredCompletion(
            producer: producer,
            tokenizer: tokenizer,
            decoder: decoder,
            renderedPromptIDs: prompt,
            effectivePromptIDs: prompt,
            multimodalInput: nil,
            config: config,
            stopStrings: stopStrings,
            needsToolTemplate: !tools.isEmpty,
            context: context,
            scratch: scratch,
            prefillConfig: .off,
            start: .reset,
            onEvent: { log.append($0) })
    }

    private func expectSingleReadCall(_ outcome: ServerStructuredDecodeOutcome, _ log: EventLog) {
        #expect(outcome.calls.count == 1)
        #expect(log.calls.count == 1)
        #expect(outcome.calls.first?.name == "read")
        #expect(outcome.calls.first?.arguments == .object(["path": .string("notes.txt")]))
    }

    // MARK: Tool closure exactly at the output limit

    private func expectClosureAtLimit(tokenizer: GFTokenizer, text: String) async throws {
        let script = tokenizer.encode(text, addBOS: false)
        #expect(script.last == tokenizer.toolCallEndID)
        let log = EventLog()
        let outcome = try await decode(
            tokenizer: tokenizer, script: script, maxNewTokens: script.count, log: log)
        expectSingleReadCall(outcome, log)
        #expect(outcome.result.reason == .maxTokens)
        #expect(outcome.result.newTokens == script.count)
        // The closing token is still the uncommitted KV boundary, but it was
        // delivered through `.token` and must not be replayed.
        #expect(outcome.result.uncommittedBoundaryTokenIDs == [tokenizer.toolCallEndID])
        #expect(outcome.result.undeliveredBoundaryTokenIDs.isEmpty)
    }

    @Test func gemmaToolClosureAtTheLimitDecodesOnce() async throws {
        let tokenizer = try await Self.gemma()
        try await expectClosureAtLimit(
            tokenizer: tokenizer,
            text: #"<|tool_call>call:read{path:<|"|>notes.txt<|"|>}<tool_call|>"#)
    }

    @Test func qwenToolClosureAtTheLimitDecodesOnce() async throws {
        let tokenizer = try await Self.qwen()
        try await expectClosureAtLimit(
            tokenizer: tokenizer,
            text: "<tool_call>\n<function=read>\n<parameter=path>\nnotes.txt\n</parameter>\n</function>\n</tool_call>")
    }

    @Test func minimaxToolClosureAtTheLimitDecodesOnce() async throws {
        let tokenizer = try await Self.minimax()
        try await expectClosureAtLimit(
            tokenizer: tokenizer,
            text: """
            checking</think>

            <minimax:tool_call>
            <invoke name="read">
            <parameter name="path">notes.txt</parameter>
            </invoke>
            </minimax:tool_call>
            """)
    }

    // MARK: Harmony call boundary

    private static let harmonyCall =
        #" to=functions.read<|channel|>commentary <|constrain|>json<|message|>{"path":"notes.txt"}<|call|>"#

    @Test func harmonyCallBoundaryIsConsumedOnce() async throws {
        let tokenizer = try await Self.harmony()
        #expect(tokenizer.dialect == .harmony)
        let call = try #require(tokenizer.harmonyTokenIDs?.call)
        let script = tokenizer.encode(Self.harmonyCall, addBOS: false)
        #expect(script.last == call)
        let log = EventLog()
        let outcome = try await decode(tokenizer: tokenizer, script: script, log: log)
        expectSingleReadCall(outcome, log)
        #expect(outcome.result.reason == .toolCalls)
        #expect(outcome.result.uncommittedBoundaryTokenIDs == [call])
        #expect(outcome.result.undeliveredBoundaryTokenIDs == [call])
    }

    @Test func harmonyCallAtTheLimitIsStillAStopBoundary() async throws {
        let tokenizer = try await Self.harmony()
        let call = try #require(tokenizer.harmonyTokenIDs?.call)
        let script = tokenizer.encode(Self.harmonyCall, addBOS: false)
        let log = EventLog()
        let outcome = try await decode(
            tokenizer: tokenizer, script: script, maxNewTokens: script.count, log: log)
        expectSingleReadCall(outcome, log)
        #expect(outcome.result.reason == .toolCalls)
        #expect(outcome.result.undeliveredBoundaryTokenIDs == [call])
    }

    // MARK: Existing behavior

    @Test func gemmaToolResponseStopIsReplayedAfterTheCall() async throws {
        let tokenizer = try await Self.gemma()
        let script = tokenizer.encode(
            #"<|tool_call>call:read{path:<|"|>notes.txt<|"|>}<tool_call|><|tool_response>"#,
            addBOS: false)
        let log = EventLog()
        let outcome = try await decode(tokenizer: tokenizer, script: script, log: log)
        expectSingleReadCall(outcome, log)
        #expect(outcome.result.reason == .toolCalls)
        #expect(outcome.result.undeliveredBoundaryTokenIDs == [tokenizer.toolResponseID])
    }

    @Test func endOfTurnAndEOSKeepTheirText() async throws {
        let gemma = try await Self.gemma()
        let gemmaLog = EventLog()
        let gemmaOutcome = try await decode(
            tokenizer: gemma,
            script: gemma.encode("Hello there", addBOS: false) + [gemma.endOfTurnID],
            log: gemmaLog)
        #expect(gemmaOutcome.content == "Hello there")
        #expect(gemmaLog.content == "Hello there")
        #expect(gemmaOutcome.result.reason == .endOfTurn)
        #expect(gemmaOutcome.result.undeliveredBoundaryTokenIDs == [gemma.endOfTurnID])

        let qwen = try await Self.qwen()
        let qwenLog = EventLog()
        let qwenOutcome = try await decode(
            tokenizer: qwen,
            script: qwen.encode("Hello there", addBOS: false) + [qwen.eosID],
            log: qwenLog)
        #expect(qwenOutcome.content == "Hello there")
        #expect(qwenOutcome.result.reason == .eos)
        #expect(qwenOutcome.calls.isEmpty)
    }

    @Test func lengthLimitedTextIsNotRepeated() async throws {
        let tokenizer = try await Self.gemma()
        let script = tokenizer.encode("one two three four", addBOS: false)
        let limit = script.count - 1
        let log = EventLog()
        let outcome = try await decode(
            tokenizer: tokenizer, script: script, maxNewTokens: limit, log: log)
        let expected = tokenizer.decode(Array(script.prefix(limit)), skipSpecialTokens: true)
        #expect(outcome.content == expected)
        #expect(log.content == expected)
        #expect(outcome.result.reason == .maxTokens)
        #expect(outcome.result.uncommittedBoundaryTokenIDs == [script[limit - 1]])
        #expect(outcome.result.undeliveredBoundaryTokenIDs.isEmpty)
    }

    @Test func incompleteCallsStillFailAtFinish() async throws {
        let cases: [(GFTokenizer, String)] = [
            (try await Self.gemma(), #"<|tool_call>call:read{path:<|"|>notes"#),
            (try await Self.qwen(), "<tool_call>\n<function=read>\n<parameter=path>\nnotes"),
            (try await Self.minimax(), "</think>\n<minimax:tool_call>\n<invoke name=\"read\">"),
        ]
        for (tokenizer, text) in cases {
            let script = tokenizer.encode(text, addBOS: false)
            let log = EventLog()
            do {
                _ = try await decode(
                    tokenizer: tokenizer, script: script, maxNewTokens: script.count, log: log)
                Issue.record("an unterminated \(tokenizer.dialect) call was accepted")
            } catch let failure as StructuredOutputFailure {
                #expect(failure.kind == .decoderFinish)
            }
            #expect(log.calls.isEmpty)
        }
    }

    @Test func stopStringFilteringIsUnchanged() async throws {
        let tokenizer = try await Self.gemma()
        let script = tokenizer.encode("keep this STOP drop that", addBOS: false)
        let log = EventLog()
        let outcome = try await decode(
            tokenizer: tokenizer, script: script, stopStrings: ["STOP"], tools: [], log: log)
        #expect(outcome.content == "keep this ")
        #expect(log.content == "keep this ")
        #expect(outcome.stopStringFiltered)
        #expect(outcome.result.reason == .cancelled)
        #expect(outcome.result.undeliveredBoundaryTokenIDs.isEmpty)
    }
}
