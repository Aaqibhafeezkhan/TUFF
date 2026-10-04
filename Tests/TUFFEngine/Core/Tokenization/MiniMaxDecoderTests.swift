import Foundation
import Testing
@testable import TUFFEngine

@Suite("MiniMax native tool calls")
struct MiniMaxDecoderTests {
    let tok: GFTokenizer

    init() async throws {
        let folder = try #require(Bundle.module.url(
            forResource: "MiniMaxTokenizer", withExtension: nil, subdirectory: "Fixtures"))
        tok = try await GFTokenizer.load(from: folder)
    }

    private let schemas: [String: JSONValue] = ["read": .object([
        "type": .string("object"), "properties": .object([
            "path": .object(["type": .string("string")]),
            "i": .object(["type": .string("string")]),
            "limit": .object(["type": .string("integer")]),
            "options": .object(["type": .string("object")]),
        ]),
    ])]

    private func parse(_ body: String) throws -> [ParsedToolCall] {
        try MiniMaxToolCallParser().parse(body, allowedTools: ["read"],
            parameterSchemas: schemas, idGenerator: { "call_test" })
    }

    private func feed(_ text: String, decoder: StructuredAssistantDecoder) throws -> [StructuredAssistantEvent] {
        var events: [StructuredAssistantEvent] = []
        var detok = GFDetokenizer(tokenizer: tok, barrierTokenIDs: tok.structuralMarkerIDs)
        for id in tok.encode(text, addBOS: false) {
            events += try decoder.consume(tokenID: id, delta: detok.push(id))
        }
        events += try decoder.consumeTail(detok.flush())
        return events
    }

    @Test("Real MiniMax ordinary-token flags still delimit native tool calls")
    func capturedReadCall() throws {
        #expect(tok.dialect == .minimax)
        #expect(tok.toolCallStartID == 200052)
        #expect(tok.toolCallEndID == 200053)
        let d = StructuredAssistantDecoder(tokenizer: tok, allowedTools: ["read"],
            promptOpensThinking: true, parameterSchemas: schemas, idGenerator: { "call_test" })
        let events = try feed("""
        private reasoning</think>

        <minimax:tool_call>
        <invoke name="read">
        <parameter name="i">Reading probe.txt</parameter>
        <parameter name="path">probe.txt</parameter>
        </invoke>
        </minimax:tool_call>
        """, decoder: d)
        let visible = events.compactMap { if case .content(let s) = $0 { s } else { nil } }.joined()
        let thoughts = events.compactMap { if case .thinking(let s) = $0 { s } else { nil } }.joined()
        let calls = events.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }
        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(thoughts == "private reasoning")
        #expect(calls.count == 1)
        #expect(calls.first?.arguments == .object([
            "i": .string("Reading probe.txt"), "path": .string("probe.txt"),
        ]))
        #expect(d.hasToolCalls)
        try d.finish()
    }

    @Test("Schema string arguments stay literal while JSON values keep their types")
    func argumentTypes() throws {
        let calls = try parse("""
        <invoke name="read"><parameter name="path">123</parameter><parameter name="i">{"x":1}&amp;</parameter><parameter name="limit">25</parameter><parameter name="options">{"active":true,"tags":["a"]}</parameter></invoke>
        """)
        #expect(calls.first?.arguments == .object([
            "path": .string("123"), "i": .string("{\"x\":1}&amp;"),
            "limit": .integer(25), "options": .object([
                "active": .bool(true), "tags": .array([.string("a")]),
            ]),
        ]))
    }

    @Test("Multiple invokes in one native wrapper are emitted together")
    func multipleInvokes() throws {
        let calls = try parse("<invoke name=\"read\"></invoke>\n<invoke name=\"read\"><parameter name=\"path\">b</parameter></invoke>")
        #expect(calls.count == 2)
        #expect(calls.last?.arguments == .object(["path": .string("b")]))
    }

    @Test("Malformed or incomplete invokes never emit partial calls", arguments: [
        "", "text", "<invoke name=\"read\">", "<invoke name=\"read\"></invoke>junk",
        "<invoke name=\"read\"><parameter name=\"path\">x</invoke>",
        "<invoke name=\"read\"><parameter name=\"path\">a</parameter><parameter name=\"path\">b</parameter></invoke>",
        "<invoke name=\"read\"><parameter name=\"limit\">oops</parameter></invoke>",
    ])
    func malformed(_ body: String) {
        #expect(throws: ToolCallParserError.malformed) { _ = try parse(body) }
    }

    @Test("An unknown later invoke fails the entire wrapper closed")
    func unknownLaterInvoke() {
        #expect(throws: ToolCallParserError.unknownTool("unknown")) {
            _ = try parse("<invoke name=\"read\"></invoke><invoke name=\"unknown\"></invoke>")
        }
    }

    @Test("Unclosed tool wrappers fail at completion without leaking markup")
    func incompleteWrapper() throws {
        let d = StructuredAssistantDecoder(tokenizer: tok, allowedTools: ["read"])
        let events = try feed("<minimax:tool_call><invoke name=\"read\">", decoder: d)
        #expect(events.isEmpty)
        #expect(throws: ToolCallParserError.malformed) { try d.finish() }
    }

    @Test("Explicit streaming barriers strip ordinary flagged controls only when requested")
    func ordinaryTokenBarrier() throws {
        let text = "a<think>b</think>c"
        let ids = tok.encode(text, addBOS: false)
        #expect(tok.decode(ids, skipSpecialTokens: false) == text)
        var detok = GFDetokenizer(tokenizer: tok, barrierTokenIDs: tok.structuralMarkerIDs)
        let plain = ids.map { detok.push($0) }.joined() + detok.flush()
        #expect(plain == "abc")
        var literal = GFDetokenizer(tokenizer: tok, skipSpecialTokens: false,
                                   barrierTokenIDs: tok.structuralMarkerIDs)
        #expect(ids.map { literal.push($0) }.joined() + literal.flush() == text)
    }

    @Test("Native template renders tool histories and results for the next request")
    func toolHistory() throws {
        let ids = try tok.encodeToolChat(messages: [
            .init(role: .user, content: "Read 123"),
            .init(role: .assistant, content: nil, toolCalls: [
                .init(id: "call_1", name: "read", arguments: .object(["path": .string("123")])),
            ]),
            .init(role: .tool, content: "cobalt-47", toolCallID: "call_1"),
        ], tools: [.init(name: "read", description: "Read a file", parameters: schemas["read"]!)])
        let text = tok.decode(ids, skipSpecialTokens: false)
        #expect(text.contains("<invoke name=\"read\">\n<parameter name=\"path\">123</parameter>\n</invoke>"))
        #expect(text.contains("<response>cobalt-47</response>"))
        #expect(text.hasSuffix("]~b]ai\n<think>\n"))
    }

    @Test("Oversized native payloads are rejected")
    func oversized() {
        #expect(throws: ToolCallParserError.oversized) {
            _ = try parse(String(repeating: "x", count: MiniMaxToolCallParser.maximumBytes + 1))
        }
    }
}
