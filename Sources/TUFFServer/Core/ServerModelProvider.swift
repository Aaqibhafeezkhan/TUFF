import Foundation
import TUFFEngine

/// A model a request was routed to.
public struct ServerRoutedModel: Equatable, Sendable {
    /// The canonical API identifier echoed in responses.
    public let id: String
    /// What the client sent. Validation compares the request against this, so
    /// an alias such as `default` is accepted where the router allows it.
    public let requestedID: String
    public let dialect: ChatDialect
    /// `ready`, `missing`, `disabled` or `unsupported`. For a model that is not
    /// loaded yet this is the best pre-load answer; the loaded session's own
    /// capability is checked again before generation.
    public let visionCapability: String

    public init(id: String, requestedID: String, dialect: ChatDialect, visionCapability: String) {
        self.id = id
        self.requestedID = requestedID
        self.dialect = dialect
        self.visionCapability = visionCapability
    }
}

/// Everything the HTTP layer needs from whatever owns the models: which ones
/// exist, how a request's `model` resolves, and a scheduled slot to run in.
public protocol ServerModelProvider: Sendable {
    /// Vision capability the body parser stages images against, before the
    /// request's model is known. A router answers `ready` when any of its
    /// models could take images; the routed model is checked afterwards.
    var parserVisionCapability: String { get }
    func modelList() -> OpenAIModelList
    func health() -> [String: String]
    func route(_ requestedModel: String) throws -> ServerRoutedModel
    func run<Prepared: Sendable, T: Sendable>(
        _ model: ServerRoutedModel,
        onQueued: @escaping @Sendable () -> Void,
        prepare: @escaping @Sendable (any ServerInferenceBackend) async throws -> Prepared,
        operation: @escaping @Sendable (any ServerInferenceBackend, Prepared) async throws -> T
    ) async throws -> T
    var queuedCount: Int { get async }
    var isActive: Bool { get async }
    func shutdown() async
}

/// One model that is already loaded, as `tuff serve --model` and the app's
/// hosted server have always run: requests must name its identifier exactly.
public struct FixedServerModelProvider: ServerModelProvider {
    public let modelID: String
    public let dialect: ChatDialect
    public let visionCapability: String
    private let backend: any ServerInferenceBackend
    private let coordinator: ServerCoordinator

    public init(modelID: String,
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

    public var parserVisionCapability: String { visionCapability }

    public func modelList() -> OpenAIModelList {
        OpenAIModelList(object: "list", data: [
            .init(id: modelID, object: "model", created: 0, ownedBy: "tuff",
                  capabilities: visionCapability == "ready" ? ["text", "image"] : ["text"]),
        ])
    }

    public func health() -> [String: String] {
        ["status": "ok", "vision": visionCapability]
    }

    public func route(_ requestedModel: String) throws -> ServerRoutedModel {
        guard requestedModel == modelID else { throw ServerRequestError.unknownModel }
        return ServerRoutedModel(id: modelID, requestedID: requestedModel,
                                 dialect: dialect, visionCapability: visionCapability)
    }

    public func run<Prepared: Sendable, T: Sendable>(
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

    public var queuedCount: Int { get async { await coordinator.queuedCount } }
    public var isActive: Bool { get async { await coordinator.isActive } }
    public func shutdown() async { await coordinator.shutdown() }
}
