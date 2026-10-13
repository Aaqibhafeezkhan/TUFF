import Foundation

public struct InferenceEnginePackageReference: Codable, Sendable, Equatable {
    public let packageID: String
    public let version: InferenceEngineVersion

    public init(packageID: String, version: InferenceEngineVersion) {
        self.packageID = packageID
        self.version = version
    }
}

struct InferenceEngineModelBindings: Codable {
    var schemaVersion = 1
    var models: [String: [InferenceEnginePackageReference]] = [:]
    var modelPaths: [String: String]?
    var knownGood: [String: InferenceEnginePackageReference]?
}
