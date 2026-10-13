import Foundation

public struct InferenceEnginePackageStatus: Sendable, Identifiable {
    public let reference: InferenceEnginePackageReference
    public let verified: Bool
    public let requiredModelCount: Int
    public let inUse: Bool
    public let installedBytes: UInt64?
    public var id: String { reference.packageID + ":" + reference.version.directoryName }

    public init(reference: InferenceEnginePackageReference, verified: Bool,
                requiredModelCount: Int, inUse: Bool, installedBytes: UInt64?) {
        self.reference = reference
        self.verified = verified
        self.requiredModelCount = requiredModelCount
        self.inUse = inUse
        self.installedBytes = installedBytes
    }
}
