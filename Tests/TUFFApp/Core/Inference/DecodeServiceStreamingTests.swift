import Foundation
import Testing
import TUFFDecodeProtocol
@testable import TUFFAppCore

@Suite struct DecodeServiceStreamingTests {
    @Test(arguments: [DecodeServiceEventKind.finished, .cancelled, .failed])
    func incrementalTextSurvivesThrottlingAndTerminalEvents(
        terminal: DecodeServiceEventKind
    ) async throws {
        let commands = Pipe()
        let responses = Pipe()
        let client = DecodeServiceInferenceClient(
            input: commands.fileHandleForWriting,
            output: responses.fileHandleForReading)
        let request = AppGenerationRequest(
            modelDirectory: FileManager.default.temporaryDirectory,
            prompt: "List fruit", maxNewTokens: 32)
        let stream = client.generate(request)
        let service = Task.detached {
            defer { try? responses.fileHandleForWriting.close() }
            let command = try DecodeFrameCodec.read(
                DecodeServiceCommand.self, from: commands.fileHandleForReading)
            guard case .generate(let generation) = command else {
                Issue.record("Expected a generation command")
                return
            }
            // Several deltas arrive inside one publication interval, including
            // leading whitespace and multibyte text. The terminal event has no text.
            for (index, text) in [" ", "Mango", ", ", "pêche", ", pear"].enumerated() {
                try responses.fileHandleForWriting.write(contentsOf: DecodeFrameCodec.encode(
                    DecodeServiceEvent(kind: .snapshot,
                        generationID: generation.generationID,
                        sequence: UInt64(index + 1), textDelta: text,
                        tokenCount: index + 1, decodeSeconds: 0.01)))
            }
            try responses.fileHandleForWriting.write(contentsOf: DecodeFrameCodec.encode(
                DecodeServiceEvent(kind: terminal,
                    generationID: generation.generationID,
                    tokenCount: 5, decodeSeconds: 0.01)))
        }
        var text = ""
        var terminalSeen = false
        var failed = false
        do {
            for try await event in stream {
                switch event {
                case .token(let token):
                    #expect(!terminalSeen)
                    text += token.textDelta
                case .finished, .cancelled, .failed:
                    terminalSeen = true
                default: break
                }
            }
        } catch {
            failed = true
        }
        try await service.value
        #expect(text == " Mango, pêche, pear")
        #expect(terminalSeen)
        #expect(failed == (terminal == .failed))
        #expect(client.generationTranscriptMailbox.drain().completeText == text)
    }
}
