import Foundation
import NIOCore
import NIOPosix
import TUFFEngine
@testable import TUFFServerCore

/// One already-loaded model whose identifier requests must name exactly. The
/// shipped server always routes; this drives the HTTP layer against a fake
/// backend in tests.
struct FixedServerModelProvider: ServerModelProvider {
    let modelID: String
    let dialect: ChatDialect
    let visionCapability: String
    private let backend: any ServerInferenceBackend
    private let coordinator: ServerCoordinator

    init(modelID: String,
         backend: any ServerInferenceBackend,
         dialect: ChatDialect,
         visionCapability: String,
         queueLimit: Int,
         onActivity: @escaping @Sendable (ServerCoordinatorActivity) -> Void = { _ in }) {
        self.modelID = modelID
        self.backend = backend
        self.dialect = dialect
        self.visionCapability = visionCapability
        self.coordinator = ServerCoordinator(queueLimit: queueLimit, onActivity: onActivity)
    }

    var parserVisionCapability: String { visionCapability }

    func modelList() -> OpenAIModelList {
        OpenAIModelList(object: "list", data: [
            .init(id: modelID, object: "model", created: 0, ownedBy: "tuff",
                  capabilities: visionCapability == "ready" ? ["text", "image"] : ["text"]),
        ])
    }

    func health() -> [String: String] {
        ["status": "ok", "vision": visionCapability]
    }

    func route(_ requestedModel: String) throws -> ServerRoutedModel {
        guard requestedModel == modelID else { throw ServerRequestError.unknownModel }
        return ServerRoutedModel(id: modelID, requestedID: requestedModel,
                                 dialect: dialect, visionCapability: visionCapability)
    }

    func run<Prepared: Sendable, T: Sendable>(
        _ model: ServerRoutedModel,
        onQueued: @escaping @Sendable () -> Void,
        prepare: @escaping @Sendable (any ServerInferenceBackend) async throws -> Prepared,
        operation: @escaping @Sendable (any ServerInferenceBackend, Prepared) async throws -> T
    ) async throws -> T {
        let backend = self.backend
        // Preparation (tokenizing, image planning) happens before the slot is
        // taken, as it always has, so a queued request is ready to start.
        return try await coordinator.runPreparing(
            onQueued: onQueued,
            prepare: { try await prepare(backend) },
            operation: { try await operation(backend, $0) })
    }

    var queuedCount: Int { get async { await coordinator.queuedCount } }
    var isActive: Bool { get async { await coordinator.isActive } }
    func shutdown() async { await coordinator.shutdown() }
}

extension TUFFHTTPServer {
    init(modelID: String,
         queueLimit: Int,
         backend: any ServerInferenceBackend,
         chatDialect: ChatDialect = .gemma,
         heartbeatInterval: TimeAmount = .seconds(5),
         visionCapability: String = "missing",
         onRequestActivity: @escaping @Sendable
             (ServerCoordinatorActivity) -> Void = { _ in },
         onRequestError: @escaping @Sendable (String) -> Void = { _ in },
         attachmentRoot: URL = ServerAttachmentDirectory.root,
         idleTimeout: TimeAmount = TUFFHTTPServer.idleTimeout,
         group: MultiThreadedEventLoopGroup = .init(numberOfThreads: 1)) {
        self.init(
            provider: FixedServerModelProvider(
         modelID: modelID, backend: backend, dialect: chatDialect,
         visionCapability: visionCapability, queueLimit: queueLimit,
         onActivity: onRequestActivity),
            heartbeatInterval: heartbeatInterval,
            onRequestError: onRequestError,
            attachmentRoot: attachmentRoot,
            idleTimeout: idleTimeout,
            group: group)
    }
}
