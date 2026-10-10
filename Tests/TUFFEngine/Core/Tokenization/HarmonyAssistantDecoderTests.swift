import Foundation
import Testing
@testable import TUFFEngine

@Suite("Harmony assistant decoder")
struct HarmonyAssistantDecoderTests {
    private let tokens = HarmonySpecialTokenIDs.official
    private let textToken: Int32 = 42

    private func decoder(
        allowedTools: Set<String> = ["get_weather"]
    ) -> HarmonyAssistantDecoder {
        HarmonyAssistantDecoder(
            tokens: tokens,
            allowedTools: allowedTools,
            idGenerator: { "call_fixed" })
    }

    private func visibleText(_ events: [StructuredAssistantEvent]) -> String {
        events.reduce(into: "") { result, event in
            if case .content(let delta) = event { result += delta }
        }
    }

    private func thinkingText(_ events: [StructuredAssistantEvent]) -> String {
        events.reduce(into: "") { result, event in
            if case .thinking(let delta) = event { result += delta }
        }
    }

    @Test("Analysis is separate and final text streams")
    func analysisThenFinal() throws {
        let decoder = decoder()
        var events: [StructuredAssistantEvent] = []
        events += try decoder.consume(tokenID: tokens.channel, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "analysis")
        events += try decoder.consume(tokenID: tokens.message, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "secret plan")
        events += try decoder.consume(tokenID: tokens.end, delta: "")
        events += try decoder.consume(tokenID: tokens.start, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "assistant")
        events += try decoder.consume(tokenID: tokens.channel, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "final")
        events += try decoder.consume(tokenID: tokens.message, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "Hello")
        events += try decoder.consume(tokenID: textToken, delta: " there")
        events += try decoder.consume(tokenID: tokens.return, delta: "!")
        #expect(visibleText(events) == "Hello there!")
        #expect(!visibleText(events).contains("secret"))
        #expect(thinkingText(events) == "secret plan")
        try decoder.finish()
    }

    @Test("Function call buffers JSON and emits one validated call")
    func toolCall() throws {
        let decoder = decoder()
        var events: [StructuredAssistantEvent] = []
        events += try decoder.consume(
            tokenID: textToken, delta: " to=functions.get_weather")
        events += try decoder.consume(tokenID: tokens.channel, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "commentary")
        events += try decoder.consume(tokenID: tokens.constrain, delta: " ")
        events += try decoder.consume(tokenID: textToken, delta: "json")
        events += try decoder.consume(tokenID: tokens.message, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: #"{"city":"Paris"}"#)
        events += try decoder.consume(tokenID: tokens.call, delta: "")
        #expect(events == [.toolCall(ParsedToolCall(
            id: "call_fixed",
            name: "get_weather",
            arguments: .object(["city": .string("Paris")]),
            argumentsJSON: #"{"city":"Paris"}"#))])
        #expect(decoder.hasToolCalls)
        try decoder.finish()
    }

    @Test("A buffered byte tail at call belongs to the JSON payload")
    func callBoundaryTail() throws {
        let decoder = decoder()
        _ = try decoder.consume(tokenID: textToken, delta: " to=functions.get_weather")
        _ = try decoder.consume(tokenID: tokens.channel, delta: "")
        _ = try decoder.consume(tokenID: textToken, delta: "commentary json")
        _ = try decoder.consume(tokenID: tokens.message, delta: "")
        _ = try decoder.consume(tokenID: textToken, delta: #"{"city":"Par"#)
        let events = try decoder.consume(tokenID: tokens.call, delta: #"is"}"#)
        #expect(events == [.toolCall(ParsedToolCall(
            id: "call_fixed",
            name: "get_weather",
            arguments: .object(["city": .string("Paris")]),
            argumentsJSON: #"{"city":"Paris"}"#))])
    }

    @Test("Channel-first recipients and JSON constraints parse across token splits")
    func channelFirstToolCall() throws {
        for constrained in [false, true] {
            let decoder = decoder()
            var events: [StructuredAssistantEvent] = []
            events += try decoder.consume(tokenID: tokens.channel, delta: "")
            for part in ["comment", "ary to=", "functions.", "get_weather"] {
                events += try decoder.consume(tokenID: textToken, delta: part)
            }
            if constrained {
                events += try decoder.consume(tokenID: tokens.constrain, delta: " ")
                events += try decoder.consume(tokenID: textToken, delta: "json")
            }
            events += try decoder.consume(tokenID: tokens.message, delta: "")
            events += try decoder.consume(tokenID: textToken, delta: #"{"city":"Paris"}"#)
            events += try decoder.consume(tokenID: tokens.call, delta: "")
            #expect(events.count == 1)
            #expect(decoder.hasToolCalls)
            if case .toolCall(let call) = events.first {
                #expect(call.name == "get_weather")
                #expect(call.arguments == .object(["city": .string("Paris")]))
            } else { Issue.record("tool call was not emitted") }
            try decoder.finish()
        }
    }

    /// GPT-OSS 20B wrote `<|channel|>analysis to=functions.read_file<|message|>`
    /// in a real agent loop. It is a call, not reasoning, and refusing it
    /// failed the request with a 500.
    @Test("A call addressed from the analysis channel is still a call")
    func analysisChannelToolCall() throws {
        let decoder = decoder()
        var events: [StructuredAssistantEvent] = []
        events += try decoder.consume(tokenID: tokens.channel, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "analysis")
        events += try decoder.consume(tokenID: tokens.message, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "Need the file.")
        events += try decoder.consume(tokenID: tokens.end, delta: "")
        events += try decoder.consume(tokenID: tokens.start, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "assistant")
        events += try decoder.consume(tokenID: tokens.channel, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "analysis to=functions.get_weather")
        events += try decoder.consume(tokenID: tokens.message, delta: "")
        #expect(!decoder.isInAnalysis)
        events += try decoder.consume(tokenID: textToken, delta: #"{"city":"Paris"}"#)
        events += try decoder.consume(tokenID: tokens.call, delta: "")
        #expect(thinkingText(events) == "Need the file.")
        #expect(events.last == .toolCall(ParsedToolCall(
            id: "call_fixed", name: "get_weather",
            arguments: .object(["city": .string("Paris")]),
            argumentsJSON: #"{"city":"Paris"}"#)))
        try decoder.finish()
    }

    @Test("Unaddressed commentary is visible and can precede a final message")
    func commentaryThenFinal() throws {
        let decoder = decoder()
        var events: [StructuredAssistantEvent] = []
        _ = try decoder.consume(tokenID: tokens.channel, delta: "")
        _ = try decoder.consume(tokenID: textToken, delta: "commentary")
        _ = try decoder.consume(tokenID: tokens.message, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "Reading the file.\n")
        _ = try decoder.consume(tokenID: tokens.end, delta: "")
        _ = try decoder.consume(tokenID: tokens.start, delta: "")
        _ = try decoder.consume(tokenID: textToken, delta: "assistant")
        _ = try decoder.consume(tokenID: tokens.channel, delta: "")
        _ = try decoder.consume(tokenID: textToken, delta: "final")
        _ = try decoder.consume(tokenID: tokens.message, delta: "")
        events += try decoder.consume(tokenID: textToken, delta: "Done.")
        _ = try decoder.consume(tokenID: tokens.return, delta: "")
        #expect(visibleText(events) == "Reading the file.\nDone.")
        #expect(thinkingText(events).isEmpty)
        try decoder.finish()
    }

    @Test("Duplicate recipients, unknown channels and malformed format hints fail closed")
    func invalidHeaderMetadata() throws {
        for header in ["commentary to=functions.get_weather to=functions.other",
                       "final to=functions.get_weather", "unknown", "commentary json",
                       "commentary to=", "commentary to=functions.get_weather xml"] {
            let decoder = decoder()
            _ = try decoder.consume(tokenID: tokens.channel, delta: "")
            _ = try decoder.consume(tokenID: textToken, delta: header)
            #expect(throws: ToolCallParserError.malformed) {
                _ = try decoder.consume(tokenID: tokens.message, delta: "")
            }
        }
    }

    @Test("Unknown tools and malformed JSON fail closed")
    func invalidCalls() throws {
        let unknown = decoder(allowedTools: [])
        _ = try unknown.consume(tokenID: textToken, delta: " to=functions.get_weather")
        _ = try unknown.consume(tokenID: tokens.channel, delta: "")
        _ = try unknown.consume(tokenID: textToken, delta: "commentary json")
        _ = try unknown.consume(tokenID: tokens.message, delta: "")
        _ = try unknown.consume(tokenID: textToken, delta: "{}")
        #expect(throws: ToolCallParserError.unknownTool("get_weather")) {
            _ = try unknown.consume(tokenID: tokens.call, delta: "")
        }

        let malformed = decoder()
        _ = try malformed.consume(tokenID: textToken, delta: " to=functions.get_weather")
        _ = try malformed.consume(tokenID: tokens.channel, delta: "")
        _ = try malformed.consume(tokenID: textToken, delta: "commentary json")
        _ = try malformed.consume(tokenID: tokens.message, delta: "")
        _ = try malformed.consume(tokenID: textToken, delta: "not json")
        #expect(throws: ToolCallParserError.malformed) {
            _ = try malformed.consume(tokenID: tokens.call, delta: "")
        }
    }

    @Test("Illegal channel transitions fail closed")
    func invalidTransitions() throws {
        let decoder = decoder()
        #expect(throws: ToolCallParserError.malformed) {
            _ = try decoder.consume(tokenID: tokens.message, delta: "")
        }

        let incomplete = self.decoder()
        _ = try incomplete.consume(tokenID: tokens.channel, delta: "")
        _ = try incomplete.consume(tokenID: textToken, delta: "final")
        #expect(throws: ToolCallParserError.malformed) {
            try incomplete.finish()
        }
    }

    @Test("Oversized function payloads are rejected")
    func oversized() {
        let payload = "{\"value\":\""
            + String(repeating: "x", count: HarmonyToolCallParser.maximumBytes)
            + "\"}"
        #expect(throws: ToolCallParserError.oversized) {
            _ = try HarmonyToolCallParser().parse(
                recipient: "functions.get_weather",
                argumentsJSON: payload,
                allowedTools: ["get_weather"],
                id: "call_fixed")
        }
    }
}
