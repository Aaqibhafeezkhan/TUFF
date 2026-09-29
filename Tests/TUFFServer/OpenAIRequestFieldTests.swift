import Foundation
import Testing
@testable import TUFFEngine
@testable import TUFFServerCore

/// Top-level request keys are swept before the typed decode, so a key the
/// server does not declare is refused instead of silently ignored.
@Suite("OpenAI request fields")
struct OpenAIRequestFieldTests {
    private static func decode(_ extra: String) throws -> OpenAIChatRequest {
        let separator = extra.isEmpty ? "" : ","
        return try JSONDecoder().decode(OpenAIChatRequest.self, from: Data("""
        {"model":"m","messages":[{"role":"user","content":"x"}]\(separator)\(extra)}
        """.utf8))
    }

    private static func rejection(_ extra: String) throws
        -> (message: String, param: String?, code: String) {
        do {
            _ = try decode(extra)
        } catch ServerRequestError.invalid(let message, let param, let code) {
            return (message, param, code)
        }
        Issue.record("expected \(extra) to be refused")
        return ("", nil, "")
    }

    @Test func aMisspelledOptionIsRefusedWithTheFieldItMeant() throws {
        let refused = try Self.rejection(#""max_token":64"#)
        #expect(refused.code == "unknown_parameter")
        #expect(refused.param == "max_token")
        #expect(refused.message == #"unrecognized request field "max_token"; did you mean max_tokens?"#)
    }

    @Test func aKeyNearTwoDeclaredFieldsGetsNoGuess() {
        // "top_x" is one edit from both top_p and top_k.
        #expect(OpenAIChatRequest.closestDeclaredKey(to: "top_x") == nil)
        #expect(OpenAIChatRequest.closestDeclaredKey(to: "temprature") == "temperature")
        #expect(OpenAIChatRequest.closestDeclaredKey(to: "completely_unrelated") == nil)
    }

    @Test func otherLocalServersFieldsPointAtTheTUFFEquivalent() throws {
        let kwargs = try Self.rejection(#""chat_template_kwargs":{"enable_thinking":true}"#)
        #expect(kwargs.code == "unknown_parameter")
        #expect(kwargs.message.hasSuffix("; use enable_thinking"))

        let predict = try Self.rejection(#""num_predict":32"#)
        #expect(predict.message.hasSuffix("; use max_tokens"))
    }

    @Test func severalUnknownKeysAreSortedAndBounded() throws {
        let keys = (0..<11).map { #""zz\#($0)":1"# }.reversed().joined(separator: ",")
        let refused = try Self.rejection(keys)
        #expect(refused.param == "zz0")
        #expect(refused.message.hasPrefix(#"unrecognized request fields "zz0", "zz1", "zz10""#))
        #expect(refused.message.hasSuffix(", and 3 more"))
        #expect(!refused.message.contains("did you mean"))
    }

    @Test func aHostileKeyIsEchoedOnlyInBoundedForm() throws {
        let long = String(repeating: "k", count: 10_000)
        let refused = try Self.rejection(#""\#(long)":1"#)
        #expect((refused.param?.utf8.count ?? .max) <= 67)
        #expect(refused.message.utf8.count < 200)

        // One Character carrying a thousand combining marks.
        let marks = "a" + String(repeating: "\u{0301}", count: 1_000)
        let combining = try Self.rejection(#""\#(marks)":1"#)
        #expect((combining.param?.utf8.count ?? .max) <= 67)
    }

    @Test func aNullUnknownKeyAsksForNothingAndIsAccepted() throws {
        _ = try Self.decode(#""logit_bias":null,"something_new":null"#)
    }

    @Test func bookkeepingKeysAreTolerated() throws {
        _ = try Self.decode(#"""
        "user":"u","store":false,"metadata":{"a":"b"},"service_tier":"auto",
        "prompt_cache_key":"k","safety_identifier":"s"
        """#)
    }

    @Test func realOpenAIParametersAreUnsupportedNotUnknown() throws {
        let bias = try Self.rejection(#""logit_bias":{"50256":-100}"#)
        #expect(bias.code == "unsupported_value")
        #expect(bias.param == "logit_bias")

        let functions = try Self.rejection(#""functions":[]"#)
        #expect(functions.code == "unsupported_value")
        #expect(functions.message == "legacy functions are not supported; use tools")
    }

    /// The sweep wins over a type error elsewhere, so the answer names the
    /// real problem whatever order the decoder would have met them in.
    @Test func theSweepRunsBeforeTypedDecoding() throws {
        let refused = try Self.rejection(#""temperature":"hot","logit_bias":{}"#)
        #expect(refused.param == "logit_bias")
        let unknown = try Self.rejection(#""temperature":"hot","max_token":3"#)
        #expect(unknown.param == "max_token")
    }

    @Test func tuffsOwnReasoningControlsStillDecode() throws {
        let harmony = try Self.decode(#""reasoning_effort":"low""#)
        #expect(harmony.reasoningEffort == .low)
        let validated = try OpenAIRequestValidator.validate(
            harmony, modelID: "m", dialect: .harmony)
        #expect(validated.reasoningEffort == .low)

        // Other families still refuse it through the validator's own message.
        #expect(throws: ServerRequestError.invalid(
            message: "reasoning_effort is only supported by GPT-OSS",
            param: "reasoning_effort",
            code: "unsupported_parameter")) {
            try OpenAIRequestValidator.validate(harmony, modelID: "m", dialect: .gemma)
        }

        let thinking = try Self.decode(#""enable_thinking":true"#)
        #expect(thinking.enableThinking == true)
    }

    @Test func responseFormatTextIsAcceptedAndStructuredOutputIsRefused() throws {
        let text = try Self.decode(#""response_format":{"type":"text"}"#)
        _ = try OpenAIRequestValidator.validate(text, modelID: "m")

        let cases: [(String, String)] = [
            (#"{"type":"json_object"}"#, "unsupported_value"),
            (#"{"type":"json_schema","json_schema":{"name":"x"}}"#, "unsupported_value"),
            (#"{"type":"yaml"}"#, "invalid_value"),
            (#"{"type":3}"#, "invalid_value"),
            (#"{}"#, "invalid_value"),
            (#""text""#, "invalid_value"),
        ]
        for (format, code) in cases {
            let request = try Self.decode(#""response_format":\#(format)"#)
            do {
                _ = try OpenAIRequestValidator.validate(request, modelID: "m")
                Issue.record("expected response_format \(format) to be refused")
            } catch ServerRequestError.invalid(_, let param, let actual) {
                #expect(param == "response_format")
                #expect(actual == code, "\(format)")
            }
        }
    }

    @Test func capturedClientRequestsStillDecode() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(!names.isEmpty)
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            _ = try JSONDecoder().decode(OpenAIChatRequest.self, from: data)
        }
    }
}
