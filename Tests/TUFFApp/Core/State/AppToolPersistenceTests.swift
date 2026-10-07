import Foundation
import Testing
import TUFFEngine
import TUFFDecodeProtocol
@testable import TUFFAppCore

/// Tool rounds, sources and capabilities survive a restart exactly, so a
/// continued chat renders the prompt the model saw; older archives still load.
@Suite(.serialized) struct AppToolPersistenceTests {
    private func makeRepository() -> (URL, AppConversationRepository) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuff-tool-chats-\(UUID().uuidString)", isDirectory: true)
        return (root, AppConversationRepository(rootURL: root))
    }

    static let round = AppToolRound(
        thinking: "Search.", content: "Checking.",
        calls: [AppToolCall(id: "call_1", name: "web_search",
                            arguments: .object(["query": .string("tides"), "max_results": .integer(3)]))],
        results: [AppToolResult(callID: "call_1", name: "web_search", status: .succeeded,
                                modelText: "[1] Tides\nhttps://sea.example/tides\nTwice a day.",
                                summary: "1 result from DuckDuckGo", sourceIDs: [1])])
    static let source = AppSource(id: 1, kind: .web, title: "Tides", url: "https://sea.example/tides",
                                  excerpt: "Twice a day.", origin: "DuckDuckGo")

    @MainActor
    @Test func roundsSourcesAndCapabilitiesSurviveARestart() {
        let (root, repository) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppConversationStore(repository: repository)
        store.beginTurn(AppChatTurn(prompt: "When are the tides?", response: "",
                                    capabilities: .init(web: true)),
                        attachments: [], modelID: "gemma4-26b-a4b")
        store.completeTurn(response: "Twice a day [1].", thinking: "Done.",
                           toolRounds: [Self.round], sources: [Self.source])

        let restored = AppConversationStore(repository: repository)
        let turn = restored.conversation.first
        #expect(turn?.toolRounds == [Self.round])
        #expect(turn?.sources == [Self.source])
        #expect(turn?.capabilities == .init(web: true))
        #expect(restored.nextSourceID == 2)
        let data = try? Data(contentsOf: repository.archiveURL)
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(text.contains("\"schemaVersion\" : 3"))
    }

    @MainActor
    @Test func aChatWithoutToolsStaysReadableByTUFF7() throws {
        let (root, repository) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppConversationStore(repository: repository)
        store.beginTurn(AppChatTurn(prompt: "Hi", response: ""), attachments: [],
                        modelID: "gemma4-26b-a4b")
        store.completeTurn(response: "Hello.", thinking: nil, toolRounds: [], sources: [])
        let text = String(decoding: try Data(contentsOf: repository.archiveURL), as: UTF8.self)
        #expect(text.contains("\"schemaVersion\" : 2"))

        // Turning search on for a later turn is what moves the archive to 3.
        store.beginTurn(AppChatTurn(prompt: "Tides?", response: "", capabilities: .init(web: true)),
                        attachments: [], modelID: "gemma4-26b-a4b")
        store.completeTurn(response: "Twice a day.", thinking: nil, toolRounds: [], sources: [])
        let later = String(decoding: try Data(contentsOf: repository.archiveURL), as: UTF8.self)
        #expect(later.contains("\"schemaVersion\" : 3"))
        #expect(AppConversationStore(repository: repository).persistenceError == nil)
    }

    @MainActor
    @Test func aSchemaTwoArchiveLoadsWithoutTools() throws {
        let (root, repository) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let legacy = """
        {"schemaVersion": 2, "selectedConversationID": "\(id.uuidString)",
         "conversations": [{"id": "\(id.uuidString)", "title": "Old", "modelID": "gemma4",
           "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:01Z",
           "turns": [{"id": "\(UUID().uuidString)", "prompt": "hi", "response": "hello",
                      "attachments": [], "documents": [], "modelID": "gemma4"}]}]}
        """
        try Data(legacy.utf8).write(to: repository.archiveURL)
        let store = AppConversationStore(repository: repository)
        #expect(store.persistenceError == nil)
        #expect(store.conversation.first?.toolRounds.isEmpty == true)
        #expect(store.conversation.first?.sources.isEmpty == true)
        #expect(store.conversation.first?.capabilities == AppChatCapabilities.none)
    }

    @Test func aTurnEncodedBeforeToolsStillDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","prompt":"p","response":"r","documents":[],"images":[]}"#
        let turn = try JSONDecoder().decode(AppChatTurn.self, from: Data(json.utf8))
        #expect(turn.toolRounds.isEmpty)
        let encoded = try JSONEncoder().encode(AppChatTurn(prompt: "p", response: "r",
                                                           toolRounds: [Self.round]))
        #expect(try JSONDecoder().decode(AppChatTurn.self, from: encoded).toolRounds == [Self.round])
    }

    @Test func toolRoundsCrossTheServiceBoundaryIntact() throws {
        var request = DecodeGenerationRequest(prompt: "When are the tides?",
                                              history: [DecodeChatTurn(
                                                prompt: "Earlier", response: "Answer",
                                                toolRounds: [DecodeServiceInferenceClient.decodeToolRound(Self.round)])],
                                              maxNewTokens: 64, maxContextTokens: 4_096,
                                              temperature: 0)
        request.tools = AppToolCatalog.definitions(for: .init(web: true))
        request.currentRounds = [DecodeServiceInferenceClient.decodeToolRound(Self.round)]
        request.conversationKey = "chat-1"
        let decoded = try JSONDecoder().decode(DecodeGenerationRequest.self,
                                               from: JSONEncoder().encode(request))
        #expect(decoded.tools == request.tools)
        #expect(decoded.currentRounds == request.currentRounds)
        #expect(decoded.history.first?.toolRounds == request.history.first?.toolRounds)
        #expect(decoded.conversationKey == "chat-1")
        #expect(decoded.currentRounds?.first?.results.first?.content == Self.round.results[0].modelText)

        // A request from a client before 8.0 has none of these.
        let old = #"{"prompt":"p","maxNewTokens":1,"maxContextTokens":8,"temperature":0,"repetitionPenalty":1,"runtimeOptions":{"expertCacheSlots":16,"expertCachePolicy":"lfu","prefillEnabled":true,"prefillChunkTokens":128,"rdadvisePolicy":"off","modelVerification":"full-sha256"},"generationID":"\#(UUID().uuidString)"}"#
        let legacy = try JSONDecoder().decode(DecodeGenerationRequest.self, from: Data(old.utf8))
        #expect(legacy.tools == nil && legacy.currentRounds == nil && legacy.conversationKey == nil)
    }

    @Test func toolCallsAndMalformedFailuresCrossBackToTheApp() throws {
        var event = DecodeServiceEvent(kind: .finished, generationID: UUID(), stopReason: "toolCalls")
        event.toolCalls = Self.round.calls.map(\.historical)
        event.cachedPromptTokens = 812
        event.conversationCacheSource = "retained"
        let decoded = try JSONDecoder().decode(DecodeServiceEvent.self,
                                               from: JSONEncoder().encode(event))
        #expect(decoded.toolCalls == event.toolCalls)
        #expect(decoded.cachedPromptTokens == 812)
        #expect(decoded.conversationCacheSource == "retained")
    }
}
