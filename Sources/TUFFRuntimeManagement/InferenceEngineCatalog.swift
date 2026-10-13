import Foundation

public struct InferenceEngineRelease: Codable, Sendable, Equatable {
    public let packageID: String
    public let version: InferenceEngineVersion
    public let architectureIDs: Set<String>
    public let minimumMacOSMajorVersion: Int
    public let manifestURL: URL
    public let archiveURL: URL
    public let archiveBytes: UInt64
    public let installedBytes: UInt64

    public init(packageID: String, version: InferenceEngineVersion, architectureIDs: Set<String>,
                minimumMacOSMajorVersion: Int, manifestURL: URL, archiveURL: URL,
                archiveBytes: UInt64, installedBytes: UInt64) {
        self.packageID = packageID
        self.version = version
        self.architectureIDs = architectureIDs
        self.minimumMacOSMajorVersion = minimumMacOSMajorVersion
        self.manifestURL = manifestURL
        self.archiveURL = archiveURL
        self.archiveBytes = archiveBytes
        self.installedBytes = installedBytes
    }
}

/// Shipped with the signed host app. Keys are trust anchors; downloaded signed
/// manifests remain authoritative for compatibility, paths, sizes and digests.
public struct InferenceEngineCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let localPackageRoot: URL?
    public let publisherKeys: [String: Data]
    public let releases: [InferenceEngineRelease]

    public init(publisherKeys: [String: Data], releases: [InferenceEngineRelease], schemaVersion: Int = 1,
                localPackageRoot: URL? = nil) {
        self.schemaVersion = schemaVersion
        self.localPackageRoot = localPackageRoot
        self.publisherKeys = publisherKeys
        self.releases = releases
    }

    public func validate() throws {
        guard schemaVersion == 1, !publisherKeys.isEmpty, publisherKeys.count <= 16,
              publisherKeys.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.count == 32 }),
              releases.count <= 64 else { throw InferenceEngineCatalogError.invalidCatalog }
        var identities: Set<String> = []
        for release in releases {
            guard InferenceEngineManifest.safeRelativePath(release.packageID),
                  !release.packageID.contains("/"), !release.packageID.hasPrefix("."),
                  release.version.major >= 0, release.version.minor >= 0, release.version.patch >= 0,
                  release.minimumMacOSMajorVersion >= 15, !release.architectureIDs.isEmpty,
                  release.architectureIDs.count <= 64,
                  release.archiveBytes > 0, release.archiveBytes <= InferenceEngineArchive.maximumArchiveBytes,
                  release.installedBytes > 0, release.installedBytes <= InferenceEngineArchive.maximumArchiveBytes,
                  identities.insert("\(release.packageID):\(release.version.directoryName)").inserted else {
                throw InferenceEngineCatalogError.invalidCatalog
            }
        }
    }

    public func release(architectureID: String, macOSMajorVersion: Int) throws -> InferenceEngineRelease {
        try validate()
        guard let selected = releases.filter({
            $0.architectureIDs.contains(architectureID) && $0.minimumMacOSMajorVersion <= macOSMajorVersion
        }).sorted(by: { $0.version > $1.version }).first else {
            throw InferenceEngineCatalogError.noCompatibleEngine(architectureID)
        }
        return selected
    }
}

public enum InferenceEngineCatalogError: Error, Equatable {
    case invalidCatalog
    case noCompatibleEngine(String)
    case localSourceOutsideRoot
}
