import Foundation
import CryptoKit
import Testing
import TUFFInferenceTypes
import TUFFRuntimeManagement

@Suite struct EngineManifestTests {
    private let key = Curve25519.Signing.PrivateKey()

    private func manifest(files: [InferenceEngineFile]? = nil,
                          archiveSHA256: String? = nil) -> InferenceEngineManifest {
        .init(packageID: "qwen-hybrid", version: .init(major: 9, minor: 0, patch: 0),
            minimumMacOSMajorVersion: 15, minimumProtocolVersion: 3, maximumProtocolVersion: 3,
            architectureIDs: ["qwen36-35b-a3b", "ornith-1.5-9b"], modelFormatVersions: [1],
            quantizationLayouts: ["affine"], residencyModes: [.resident, .partial, .streamed],
            executablePath: "bin/TUFFEngineService", archiveBytes: 100,
            archiveSHA256: archiveSHA256 ?? String(repeating: "a", count: 64),
            files: files ?? [.init(path: "bin/TUFFEngineService", bytes: 80,
                sha256: String(repeating: "b", count: 64), executable: true),
                .init(path: "resources/kernels.metallib", bytes: 20,
                    sha256: String(repeating: "c", count: 64))])
    }

    private func signed(_ manifest: InferenceEngineManifest) throws -> SignedInferenceEngineManifest {
        let payload = try JSONEncoder().encode(manifest)
        return .init(publisherKeyID: "release-1", payload: payload,
            signature: try key.signature(for: SignedInferenceEngineManifest.signatureMessage(for: payload)))
    }

    @Test func authenticManifestDeclaresSharedArchitectureSupport() throws {
        let original = manifest()
        let result = try signed(original).verifiedManifest(trustedPublisherKeys:
            ["release-1": key.publicKey.rawRepresentation])
        #expect(result == original)
        #expect(result.installedBytes == 100)
        for architecture in original.architectureIDs {
            try result.requireCompatibility(architectureID: architecture, modelFormatVersion: 1,
                quantizationLayout: "affine", protocolVersion: 3, macOSMajorVersion: 15)
        }
    }

    @Test func untrustedOrModifiedManifestsCannotActivate() throws {
        let signed = try signed(manifest())
        #expect(throws: InferenceEngineManifestError.untrustedPublisher) {
            try signed.verifiedManifest(trustedPublisherKeys: [:])
        }
        var changed = signed.payload
        changed.append(32)
        let forged = SignedInferenceEngineManifest(publisherKeyID: signed.publisherKeyID,
            payload: changed, signature: signed.signature)
        #expect(throws: InferenceEngineManifestError.invalidSignature) {
            try forged.verifiedManifest(trustedPublisherKeys: ["release-1": key.publicKey.rawRepresentation])
        }
        let otherKey = Curve25519.Signing.PrivateKey()
        #expect(throws: InferenceEngineManifestError.invalidSignature) {
            try signed.verifiedManifest(trustedPublisherKeys: ["release-1": otherKey.publicKey.rawRepresentation])
        }
    }

    @Test func unsafePathsAndConflictingFilesAreRejectedEvenWhenSigned() throws {
        let entry = InferenceEngineFile(path: "bin/TUFFEngineService", bytes: 80,
            sha256: String(repeating: "b", count: 64), executable: true)
        for path in ["../escape", "/absolute", "bin/../escape", "bin//file", "bin/./file",
                     "bin\\escape", "bin/file\n"] {
            let invalid = manifest(files: [entry, .init(path: path, bytes: 1,
                sha256: String(repeating: "a", count: 64))])
            #expect(throws: InferenceEngineManifestError.invalidManifest) {
                try signed(invalid).verifiedManifest(trustedPublisherKeys:
                    ["release-1": key.publicKey.rawRepresentation])
            }
        }
        for files in [[entry, entry], [entry, .init(path: "bin", bytes: 1,
                sha256: String(repeating: "a", count: 64))],
                [entry, .init(path: "BIN/TUFFEngineService", bytes: 80,
                    sha256: String(repeating: "b", count: 64))],
                [entry, .init(path: ".engine-receipt.json", bytes: 1,
                    sha256: String(repeating: "a", count: 64))]] {
            #expect(throws: InferenceEngineManifestError.invalidManifest) {
                try manifest(files: files).validate()
            }
        }
    }

    @Test func incompatibleEngineDoesNotFallBackToAnotherArchitecture() {
        let manifest = manifest()
        #expect(throws: InferenceEngineManifestError.incompatibleEngine) {
            try manifest.requireCompatibility(architectureID: "gpt-oss-20b", modelFormatVersion: 1,
                quantizationLayout: "affine", protocolVersion: 3, macOSMajorVersion: 15)
        }
        #expect(throws: InferenceEngineManifestError.incompatibleEngine) {
            try manifest.requireCompatibility(architectureID: "qwen36-35b-a3b", modelFormatVersion: 1,
                quantizationLayout: "affine", protocolVersion: 4, macOSMajorVersion: 15)
        }
        #expect(throws: InferenceEngineManifestError.incompatibleEngine) {
            try manifest.requireCompatibility(architectureID: "qwen36-35b-a3b", modelFormatVersion: 1,
                quantizationLayout: "mxfp4", protocolVersion: 3, macOSMajorVersion: 15)
        }
    }

    @Test func invalidDigestAndOversizedPayloadFailClosed() throws {
        #expect(throws: InferenceEngineManifestError.invalidManifest) {
            try manifest(archiveSHA256: "not-a-digest").validate()
        }
        let oversized = SignedInferenceEngineManifest(publisherKeyID: "release-1",
            payload: Data(repeating: 32, count: SignedInferenceEngineManifest.maximumPayloadBytes + 1),
            signature: Data(repeating: 0, count: 64))
        #expect(throws: InferenceEngineManifestError.invalidManifest) {
            try oversized.verifiedManifest(trustedPublisherKeys: ["release-1": key.publicKey.rawRepresentation])
        }
    }
}
