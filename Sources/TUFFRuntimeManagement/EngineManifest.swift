import Foundation
import TUFFInferenceTypes
import CryptoKit

public struct InferenceEngineVersion: Codable, Sendable, Equatable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var directoryName: String { "\(major).\(minor).\(patch)" }
}

public struct InferenceEngineFile: Codable, Sendable, Equatable {
    public let path: String
    public let bytes: UInt64
    public let sha256: String
    public let executable: Bool

    public init(path: String, bytes: UInt64, sha256: String, executable: Bool = false) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
        self.executable = executable
    }
}

public struct InferenceEngineManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let packageID: String
    public let version: InferenceEngineVersion
    public let platform: String
    public let minimumMacOSMajorVersion: Int
    public let minimumProtocolVersion: Int
    public let maximumProtocolVersion: Int
    public let architectureIDs: Set<String>
    public let modelFormatVersions: Set<Int>
    public let quantizationLayouts: Set<String>
    public let residencyModes: Set<InferenceResidencyMode>
    public let executablePath: String
    public let archiveBytes: UInt64
    public let archiveSHA256: String
    public let files: [InferenceEngineFile]

    public init(packageID: String, version: InferenceEngineVersion,
                minimumMacOSMajorVersion: Int, minimumProtocolVersion: Int,
                maximumProtocolVersion: Int, architectureIDs: Set<String>,
                modelFormatVersions: Set<Int>, quantizationLayouts: Set<String>,
                residencyModes: Set<InferenceResidencyMode>, executablePath: String,
                archiveBytes: UInt64, archiveSHA256: String, files: [InferenceEngineFile],
                schemaVersion: Int = 1, platform: String = "macos-arm64") {
        self.schemaVersion = schemaVersion
        self.packageID = packageID
        self.version = version
        self.platform = platform
        self.minimumMacOSMajorVersion = minimumMacOSMajorVersion
        self.minimumProtocolVersion = minimumProtocolVersion
        self.maximumProtocolVersion = maximumProtocolVersion
        self.architectureIDs = architectureIDs
        self.modelFormatVersions = modelFormatVersions
        self.quantizationLayouts = quantizationLayouts
        self.residencyModes = residencyModes
        self.executablePath = executablePath
        self.archiveBytes = archiveBytes
        self.archiveSHA256 = archiveSHA256
        self.files = files
    }

    public func validate() throws {
        guard schemaVersion == 1, platform == "macos-arm64",
              Self.safeIdentifier(packageID),
              version.major >= 0, version.minor >= 0, version.patch >= 0,
              minimumMacOSMajorVersion >= 15, minimumProtocolVersion > 0,
              maximumProtocolVersion >= minimumProtocolVersion,
              !architectureIDs.isEmpty, architectureIDs.allSatisfy(Self.safeIdentifier),
              !modelFormatVersions.isEmpty, modelFormatVersions.allSatisfy({ $0 > 0 }),
              !quantizationLayouts.isEmpty, quantizationLayouts.allSatisfy(Self.safeIdentifier),
              !residencyModes.isEmpty, archiveBytes > 0, Self.validSHA256(archiveSHA256),
              !files.isEmpty, files.count <= 4096,
              Set(files.map(\.path)).count == files.count,
              Set(files.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }).count == files.count,
              Self.safeRelativePath(executablePath),
              files.contains(where: { $0.path == executablePath && $0.executable && $0.bytes > 0 }),
              files.allSatisfy({ Self.safeRelativePath($0.path) && Self.validSHA256($0.sha256)
                  && $0.path != ".engine-receipt.json" }) else {
            throw InferenceEngineManifestError.invalidManifest
        }
        let paths = Set(files.map(\.path))
        for file in files {
            let parts = file.path.split(separator: "/")
            for length in 1..<parts.count {
                if paths.contains(parts.prefix(length).joined(separator: "/")) {
                    throw InferenceEngineManifestError.invalidManifest
                }
            }
        }
        _ = try EngineByteMath.sum(files.map(\.bytes))
    }

    public func requireCompatibility(architectureID: String, modelFormatVersion: Int,
                                     quantizationLayout: String, protocolVersion: Int,
                                     macOSMajorVersion: Int) throws {
        try validate()
        guard architectureIDs.contains(architectureID),
              modelFormatVersions.contains(modelFormatVersion),
              quantizationLayouts.contains(quantizationLayout),
              (minimumProtocolVersion...maximumProtocolVersion).contains(protocolVersion),
              macOSMajorVersion >= minimumMacOSMajorVersion else {
            throw InferenceEngineManifestError.incompatibleEngine
        }
    }

    public var installedBytes: UInt64? { try? EngineByteMath.sum(files.map(\.bytes)) }

    public static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              !value.utf8.contains(where: { $0 < 32 || $0 == 127 }), value.utf8.count <= 1024 else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix(".") && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        } && value != "." && value != ".."
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public enum InferenceEngineManifestError: Error, Equatable {
    case invalidManifest
    case untrustedPublisher
    case invalidSignature
    case incompatibleEngine
}

/// The signature authenticates the original payload bytes, avoiding JSON
/// reserialization differences. Trusted publisher keys come from the host.
public struct SignedInferenceEngineManifest: Codable, Sendable, Equatable {
    public let publisherKeyID: String
    public let payload: Data
    public let signature: Data
    public static let maximumPayloadBytes = 512 * 1024

    public init(publisherKeyID: String, payload: Data, signature: Data) {
        self.publisherKeyID = publisherKeyID
        self.payload = payload
        self.signature = signature
    }

    public static func signatureMessage(for payload: Data) -> Data {
        Data("tuff-engine-manifest-v1\n".utf8) + payload
    }

    public func verifiedManifest(trustedPublisherKeys: [String: Data]) throws
        -> InferenceEngineManifest {
        guard !payload.isEmpty, payload.count <= Self.maximumPayloadBytes,
              signature.count == 64 else { throw InferenceEngineManifestError.invalidManifest }
        guard let keyBytes = trustedPublisherKeys[publisherKeyID],
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            throw InferenceEngineManifestError.untrustedPublisher
        }
        guard key.isValidSignature(signature, for: Self.signatureMessage(for: payload)) else {
            throw InferenceEngineManifestError.invalidSignature
        }
        let manifest = try JSONDecoder().decode(InferenceEngineManifest.self, from: payload)
        try manifest.validate()
        return manifest
    }
}
