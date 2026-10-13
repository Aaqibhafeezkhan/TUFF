import Foundation

public enum DecodeEngineProtocol {
    public static let currentVersion = 1
}

public struct DecodeEngineHello: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let minimumProtocolVersion: Int
    public let maximumProtocolVersion: Int
    public let architectureID: String
    public let modelFormatVersion: Int
    public let requiredFeatures: [String]?

    public init(requestID: UUID = UUID(), minimumProtocolVersion: Int = DecodeEngineProtocol.currentVersion,
                maximumProtocolVersion: Int = DecodeEngineProtocol.currentVersion,
                architectureID: String, modelFormatVersion: Int = 1, requiredFeatures: [String]? = nil) {
        self.requestID = requestID
        self.minimumProtocolVersion = minimumProtocolVersion
        self.maximumProtocolVersion = maximumProtocolVersion
        self.architectureID = architectureID
        self.modelFormatVersion = modelFormatVersion
        self.requiredFeatures = requiredFeatures
    }
}

public struct DecodeEngineCapabilities: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let architectureIDs: [String]
    public let modelFormatVersions: [Int]
    public let residencyModes: [String]
    public let features: [String]?

    public init(protocolVersion: Int = DecodeEngineProtocol.currentVersion,
                architectureIDs: [String], modelFormatVersions: [Int] = [1],
                residencyModes: [String] = ["resident", "partial", "streamed"],
                features: [String]? = ["bounded-retention", "preserve-history"]) {
        self.protocolVersion = protocolVersion
        self.architectureIDs = architectureIDs
        self.modelFormatVersions = modelFormatVersions
        self.residencyModes = residencyModes
        self.features = features
    }

    public func accepts(_ request: DecodeEngineHello) -> Bool {
        request.minimumProtocolVersion > 0
            && request.minimumProtocolVersion <= protocolVersion
            && request.maximumProtocolVersion >= protocolVersion
            && architectureIDs.contains(request.architectureID)
            && modelFormatVersions.contains(request.modelFormatVersion)
            && Set(request.requiredFeatures ?? []).isSubset(of: Set(features ?? []))
    }
}
