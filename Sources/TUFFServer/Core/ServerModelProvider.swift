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
