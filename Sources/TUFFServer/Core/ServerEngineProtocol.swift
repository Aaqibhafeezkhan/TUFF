import Foundation
import TUFFDecodeProtocol
import TUFFRuntimeDescriptions

public struct ServerEngineLoadRequest: Codable, Sendable {
    public let requestID: UUID
    public let modelPath: String
    public let maxContextTokens: Int
    public let retainedConversationBytes: Int
    public let runtimeConfiguration: RuntimeConfiguration
    public let denseResidencyPolicy: DenseResidencyPolicy?

    public init(requestID: UUID = UUID(), modelPath: String, maxContextTokens: Int,
                retainedConversationBytes: Int, runtimeConfiguration: RuntimeConfiguration,
                denseResidencyPolicy: DenseResidencyPolicy? = nil) {
        self.requestID = requestID
        self.modelPath = modelPath
        self.maxContextTokens = maxContextTokens
        self.retainedConversationBytes = retainedConversationBytes
        self.runtimeConfiguration = runtimeConfiguration
        self.denseResidencyPolicy = denseResidencyPolicy
    }

    public func validate() throws {
        guard (1...262_144).contains(maxContextTokens), retainedConversationBytes >= 0,
              retainedConversationBytes <= 1 << 30,
              RuntimeConfiguration.allowedExpertCacheSlots.contains(runtimeConfiguration.expertCacheSlots),
              RuntimeConfiguration.allowedPrefillChunkTokens.contains(runtimeConfiguration.prefillChunkTokens) else {
            throw ServerRequestError.modelUnavailable("invalid engine load configuration")
        }
    }
}

public enum ServerEngineCommand: Codable, Sendable {
    case hello(DecodeEngineHello)
    case load(ServerEngineLoadRequest)
    case prepare(UUID, ValidatedChatRequest)
    case generate(UUID, preparationID: UUID)
    case cancel(UUID)
    case shutdown
}

public struct ServerEngineEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hello, ready, prepared, progress, completed, failed
    }
    public let requestID: UUID
    public let kind: Kind
    public var capabilities: DecodeEngineCapabilities?
    public var defaultModelID: String?
    public var modelVariant: String?
    public var chatDialect: String?
    public var visionCapability: String?
    public var promptTokenCount: Int?
    public var inferenceEvent: ServerInferenceEvent?
    public var completion: ServerCompletion?
    public var requestError: ServerRequestError?
    public var error: String?
    public var cancelled: Bool?

    public init(requestID: UUID, kind: Kind) {
        self.requestID = requestID
        self.kind = kind
    }
}
