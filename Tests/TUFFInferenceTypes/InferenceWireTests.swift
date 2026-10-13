import Foundation
import Testing
import TUFFInferenceTypes
import TUFFDecodeProtocol

@Suite struct InferenceWireTests {
    @Test func handshakeRequiresAnOverlappingProtocolAndDeclaredArchitecture() throws {
        let capabilities = DecodeEngineCapabilities(architectureIDs: ["ornith-1.5-9b"])
        let hello = DecodeEngineHello(architectureID: "ornith-1.5-9b")
        #expect(capabilities.accepts(hello))
        #expect(!capabilities.accepts(.init(minimumProtocolVersion: 2, maximumProtocolVersion: 3,
                                            architectureID: "ornith-1.5-9b")))
        #expect(!capabilities.accepts(.init(architectureID: "unknown")))
        #expect(!capabilities.accepts(.init(architectureID: "ornith-1.5-9b", modelFormatVersion: 2)))
        #expect(!DecodeEngineCapabilities(architectureIDs: ["ornith-1.5-9b"], features: nil)
            .accepts(.init(architectureID: "ornith-1.5-9b", requiredFeatures: ["bounded-retention"])))
        let encoded = try DecodeFrameCodec.encode(DecodeServiceCommand.hello(hello))
        #expect(encoded.count > 4)
        var event = DecodeServiceEvent(kind: .hello, generationID: hello.requestID)
        event.capabilities = capabilities
        let decoded = try JSONDecoder().decode(DecodeServiceEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded.capabilities == capabilities)
    }

    @Test func toolHistoryRetainsTheExistingWireShapeWithoutEngineTypes() throws {
        let oldJSON = Data("""
        {"thinking":"checking","content":"","calls":[{"id":"call-1",
         "name":"read_file","arguments":{"path":"example.txt","offset":2}}],
         "results":[{"callID":"call-1","name":"read_file","content":"hello"}]}
        """.utf8)
        let round = try JSONDecoder().decode(DecodeToolRound.self, from: oldJSON)
        #expect(round.calls == [InferenceToolCall(id: "call-1", name: "read_file",
            arguments: .object(["path": .string("example.txt"), "offset": .integer(2)]))])
        let encoded = try JSONEncoder().encode(round)
        let reread = try JSONDecoder().decode(DecodeToolRound.self, from: encoded)
        #expect(reread == round)
    }

    @Test func largeIntegerToolArgumentsSurviveTheProcessBoundary() throws {
        let original = InferenceToolCall(id: "n", name: "identity",
            arguments: .object(["value": .unsignedInteger(UInt64.max)]))
        let decoded = try JSONDecoder().decode(InferenceToolCall.self,
            from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(try decoded.arguments.encoded() == "{\"value\":18446744073709551615}")
    }

    @Test func generationToolsAndTerminalToolCallsUseSharedTypes() throws {
        var request = DecodeGenerationRequest(prompt: "read it", maxNewTokens: 32,
            maxContextTokens: 2048, temperature: 0)
        request.tools = [InferenceFunctionDefinition(name: "read_file",
            description: "Read a file", parameters: .object(["type": .string("object")]))]
        request.preservesFullHistory = true
        let decoded = try JSONDecoder().decode(DecodeGenerationRequest.self,
            from: JSONEncoder().encode(request))
        #expect(decoded.tools == request.tools)
        #expect(decoded.preservesFullHistory)
        var event = DecodeServiceEvent(kind: .finished, generationID: request.generationID)
        event.toolCalls = [InferenceToolCall(id: "1", name: "read_file",
            arguments: .object([:]))]
        let result = try JSONDecoder().decode(DecodeServiceEvent.self,
            from: JSONEncoder().encode(event))
        #expect(result.toolCalls == event.toolCalls)
    }
}
