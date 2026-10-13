import Foundation
import CryptoKit
import Darwin
import Testing
import TUFFInferenceTypes
import TUFFRuntimeManagement

@Suite struct InferenceEngineStoreTests {
    private struct Fixture {
        let root: URL
        let source: URL
        let store: InferenceEngineStore
        let signed: SignedInferenceEngineManifest
        let publicKey: Data
        let signingKey: Curve25519.Signing.PrivateKey
        let version = InferenceEngineVersion(major: 9, minor: 0, patch: 0)
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TUFF-EngineStoreTests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let bytes = Data("#!/bin/sh\nexit 0\n".utf8)
        let executable = source.appendingPathComponent("helper")
        try bytes.write(to: executable)
        guard chmod(executable.path, 0o755) == 0 else {
            throw POSIXError(.EIO)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        let manifest = InferenceEngineManifest(packageID: "qwen-hybrid",
            version: .init(major: 9, minor: 0, patch: 0), minimumMacOSMajorVersion: 15,
            minimumProtocolVersion: 3, maximumProtocolVersion: 3,
            architectureIDs: ["ornith-1.5-9b", "ornith-1.5-35b-a3b"], modelFormatVersions: [1],
            quantizationLayouts: ["affine"], residencyModes: [.resident, .streamed],
            executablePath: "helper", archiveBytes: UInt64(bytes.count), archiveSHA256: digest,
            files: [.init(path: "helper", bytes: UInt64(bytes.count), sha256: digest, executable: true)])
        let payload = try JSONEncoder().encode(manifest)
        let signed = SignedInferenceEngineManifest(publisherKeyID: "test-key", payload: payload,
            signature: try key.signature(for: SignedInferenceEngineManifest.signatureMessage(for: payload)))
        return Fixture(root: root, source: source,
            store: InferenceEngineStore(root: root.appendingPathComponent("engines"),
                    trustedPublisherKeys: ["test-key": key.publicKey.rawRepresentation]), signed: signed,
            publicKey: key.publicKey.rawRepresentation, signingKey: key)
    }

    private func acquire(_ fixture: Fixture, architecture: String) async throws -> InferenceEngineLease {
        try await fixture.store.acquire(packageID: "qwen-hybrid", version: fixture.version,
            architectureID: architecture, modelFormatVersion: 1, quantizationLayout: "affine",
            protocolVersion: 3, macOSMajorVersion: 15)
    }

    @Test func acquisitionRecoversAnInterruptedRepairWithoutADownload() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let parent = fixture.root.appendingPathComponent("engines/qwen-hybrid")
        let target = parent.appendingPathComponent(fixture.version.directoryName)
        let backup = parent.appendingPathComponent(".repair-backup-\(fixture.version.directoryName)")
        try FileManager.default.moveItem(at: target, to: backup)
        let lease = try await acquire(fixture, architecture: "ornith-1.5-9b")
        #expect(FileManager.default.fileExists(atPath: lease.executableURL.path))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        try await fixture.store.release(lease)
    }

    @Test func authenticatedRepairRefusesALeaseAndReplacesCorruptPayloads() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let lease = try await acquire(fixture, architecture: "ornith-1.5-9b")
        try Data("corrupt".utf8).write(to: lease.executableURL, options: .atomic)
        await #expect(throws: InferenceEngineStoreError.packageBusy) {
            try await fixture.store.install(extractedDirectory: fixture.source,
                signedManifest: fixture.signed, repairCorrupt: true)
        }
        try await fixture.store.release(lease)
        try await fixture.store.install(extractedDirectory: fixture.source,
            signedManifest: fixture.signed, repairCorrupt: true)
        let repaired = try await acquire(fixture, architecture: "ornith-1.5-9b")
        #expect(try Data(contentsOf: repaired.executableURL) == Data("#!/bin/sh\nexit 0\n".utf8))
        try await fixture.store.release(repaired)
    }

    @Test func installedModelBindingsProtectSharedEnginesAcrossManagers() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let reference = InferenceEnginePackageReference(packageID: "qwen-hybrid", version: fixture.version)
        try await fixture.store.bindModel("ornith9", to: [reference])
        try await fixture.store.bindModel("ornith35", to: [reference])
        let second = InferenceEngineStore(root: fixture.root.appendingPathComponent("engines"),
            trustedPublisherKeys: ["test-key": fixture.publicKey])
        #expect(try await second.requirements(for: "ornith9") == [reference])
        #expect(try await second.remove(packageID: "qwen-hybrid", version: fixture.version,
                                        requiredByInstalledModel: false) == false)
        try await fixture.store.unbindModel("ornith9")
        #expect(try await second.remove(packageID: "qwen-hybrid", version: fixture.version,
                                        requiredByInstalledModel: false) == false)
        try await second.unbindModel("ornith35")
        #expect(try await fixture.store.remove(packageID: "qwen-hybrid", version: fixture.version,
                                               requiredByInstalledModel: false))
    }

    @Test func helperLeaseSurvivesReleaseOfTheHostsLease() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let host = try await acquire(fixture, architecture: "ornith-1.5-9b")
        var helper: InferenceEngineProcessLease? = try InferenceEngineProcessLease.forInstalledExecutable(host.executableURL)
        try await fixture.store.release(host)
        #expect(try await fixture.store.remove(packageID: "qwen-hybrid", version: fixture.version,
            requiredByInstalledModel: false) == false)
        #expect(helper != nil)
        helper = nil
        #expect(try await fixture.store.remove(packageID: "qwen-hybrid", version: fixture.version,
            requiredByInstalledModel: false))
    }

    @Test func compatibleModelsShareAnEngineAndLeasesPreventRemoval() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        // A second installation is idempotent; no duplicate family directory.
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let first = try await acquire(fixture, architecture: "ornith-1.5-9b")
        let second = try await acquire(fixture, architecture: "ornith-1.5-35b-a3b")
        #expect(first.executableURL == second.executableURL)
        #expect(first.id != second.id)
        #expect(try await fixture.store.remove(packageID: "qwen-hybrid", version: fixture.version,
            requiredByInstalledModel: false) == false)
        try await fixture.store.release(first)
        #expect(try await fixture.store.remove(packageID: "qwen-hybrid", version: fixture.version,
            requiredByInstalledModel: false) == false)
        try await fixture.store.release(second)
        #expect(try await fixture.store.remove(packageID: "qwen-hybrid", version: fixture.version,
            requiredByInstalledModel: true) == false)
        #expect(try await fixture.store.remove(packageID: "qwen-hybrid", version: fixture.version,
            requiredByInstalledModel: false))
        #expect(!FileManager.default.fileExists(atPath: first.executableURL.path))
    }

    @Test func alteredInstalledCodeIsRejectedBeforeLaunch() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let first = try await acquire(fixture, architecture: "ornith-1.5-9b")
        try await fixture.store.release(first)
        let modified = Data("#!/bin/sh\nexit 1\n".utf8)
        try modified.write(to: first.executableURL)
        await #expect(throws: InferenceEngineStoreError.digestMismatch("helper")) {
            try await acquire(fixture, architecture: "ornith-1.5-9b")
        }
    }

    @Test func unlistedFilesAndSymbolicLinksDoNotActivate() async throws {
        for useLink in [false, true] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let extra = fixture.source.appendingPathComponent("extra")
            if useLink {
                try FileManager.default.createSymbolicLink(at: extra,
                    withDestinationURL: fixture.source.appendingPathComponent("helper"))
                await #expect(throws: InferenceEngineStoreError.unsafeFile("extra")) {
                    try await fixture.store.install(extractedDirectory: fixture.source,
                        signedManifest: fixture.signed)
                }
            } else {
                try Data("extra".utf8).write(to: extra)
                await #expect(throws: InferenceEngineStoreError.unexpectedFile("extra")) {
                    try await fixture.store.install(extractedDirectory: fixture.source,
                        signedManifest: fixture.signed)
                }
            }
            let version = fixture.root.appendingPathComponent("engines/qwen-hybrid/9.0.0")
            #expect(!FileManager.default.fileExists(atPath: version.path))
        }
    }

    @Test func offlineReopenVerifiesTheReceiptAndPayload() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        try FileManager.default.removeItem(at: fixture.source)
        let lease = try await acquire(fixture, architecture: "ornith-1.5-9b")
        #expect(FileManager.default.isExecutableFile(atPath: lease.executableURL.path))
        try await fixture.store.release(lease)
    }

    @Test func missingModelPruningReleasesOnlyItsBindingsAndKnownGood() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let reference = InferenceEnginePackageReference(packageID: "qwen-hybrid", version: fixture.version)
        let first = fixture.root.appendingPathComponent("model-one")
        let second = fixture.root.appendingPathComponent("model-two")
        for directory in [first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try await fixture.store.bindModel("one", to: [reference], directory: first)
        try await fixture.store.bindModel("two", to: [reference], directory: second)
        try await fixture.store.markKnownGood("one", reference: reference)
        #expect(try await fixture.store.knownGood(for: "one") == reference)
        try FileManager.default.removeItem(at: first)
        try await fixture.store.pruneMissingModelBindings()
        #expect(try await fixture.store.knownGood(for: "one") == nil)
        #expect(try await fixture.store.requirements(for: "one").isEmpty)
        #expect(try await fixture.store.requirements(for: "two") == [reference])
        #expect(try await fixture.store.status(packageID: "qwen-hybrid", version: fixture.version).requiredModelCount == 1)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func inventoryDetectsCorruptionAndAllowsUnusedCorruptPackageCleanup() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let lease = try await acquire(fixture, architecture: "ornith-1.5-9b")
        #expect(try await fixture.store.status(packageID: "qwen-hybrid", version: fixture.version).inUse)
        try await fixture.store.release(lease)
        try Data("corrupt".utf8).write(to: lease.executableURL)
        let status = try await fixture.store.status(packageID: "qwen-hybrid", version: fixture.version)
        #expect(!status.verified)
        #expect(!status.inUse)
        #expect(try await fixture.store.remove(packageID: "qwen-hybrid", version: fixture.version, requiredByInstalledModel: false))
    }

    @Test func engineUpdateRetainsThePreviousKnownGoodUntilSuccessfulInference() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let old = InferenceEnginePackageReference(packageID: "qwen-hybrid", version: fixture.version)
        try await fixture.store.bindModel("model", to: [old])
        try await fixture.store.markKnownGood("model", reference: old)
        let next = InferenceEngineVersion(major: 9, minor: 0, patch: 1)
        var payload = try #require(JSONSerialization.jsonObject(with: fixture.signed.payload) as? [String: Any])
        payload["version"] = ["major": 9, "minor": 0, "patch": 1]
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        let signed = SignedInferenceEngineManifest(publisherKeyID: "test-key", payload: bytes,
            signature: try fixture.signingKey.signature(for: SignedInferenceEngineManifest.signatureMessage(for: bytes)))
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: signed)
        let catalog = InferenceEngineCatalog(publisherKeys: ["test-key": fixture.publicKey], releases: [
            .init(packageID: "qwen-hybrid", version: next, architectureIDs: ["ornith-1.5-9b"],
                minimumMacOSMajorVersion: 15, manifestURL: URL(string: "https://github.com/fixture/manifest")!,
                archiveURL: URL(string: "https://github.com/fixture/archive")!, archiveBytes: 17, installedBytes: 17)
        ])
        let controller = try InferenceEngineDistributionController(root: fixture.root.appendingPathComponent("engines"), catalog: catalog)
        let updated = try await controller.acquire(architectureID: "ornith-1.5-9b", quantizationLayout: "affine",
            protocolVersion: 3, macOSMajorVersion: 15)
        try await controller.bindModel("model", engine: updated)
        #expect(try await fixture.store.requirements(for: "model") == [.init(packageID: "qwen-hybrid", version: next), old])
        let rollback = try #require(try await controller.acquireKnownGood("model", architectureID: "ornith-1.5-9b",
            quantizationLayout: "affine", protocolVersion: 3, macOSMajorVersion: 15))
        #expect(rollback.manifest.version == fixture.version)
        try await controller.release(rollback)
        try await controller.markKnownGood("model", engine: updated)
        #expect(try await fixture.store.knownGood(for: "model")?.version == next)
        try await controller.release(updated)
    }

    @Test func aSeparateManagerCannotRemoveAnotherManagersLeasedEngine() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.install(extractedDirectory: fixture.source, signedManifest: fixture.signed)
        let lease = try await acquire(fixture, architecture: "ornith-1.5-9b")
        let other = InferenceEngineStore(root: fixture.root.appendingPathComponent("engines"),
            trustedPublisherKeys: ["test-key": fixture.publicKey])
        #expect(try await other.remove(packageID: "qwen-hybrid", version: fixture.version,
            requiredByInstalledModel: false) == false)
        try await fixture.store.release(lease)
        #expect(try await other.remove(packageID: "qwen-hybrid", version: fixture.version,
            requiredByInstalledModel: false))
    }
}
