import Foundation
import Testing
import TUFFModelCatalog
import TUFFModelMetadata
@testable import TUFFAppCore

@Suite struct AppModelInstallationProbeTests {
    @Test func sharedArchitectureUsesManifestCheckpointIdentityWhenNoDescriptorIsGiven() throws {
        let derivative = AppModelInstallDescriptor(catalog: TUFFModelCatalog.gemma4_26B_Heretic)
        let url = try makeCompleteModelInstall("heretic-probe", stampedAs: derivative)
        defer { try? FileManager.default.removeItem(at: url) }
        let manifestURL = url.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["modelID"] = TUFFModelCatalog.gemma4_26B_Heretic.source.manifestModelID
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: manifestURL)
        let receiptURL = url.appendingPathComponent("verified-install.json")
        var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
        receipt["manifestSha256"] = Sha256Verifier.hashData(data)
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: receiptURL)
        #expect(AppModelInstallationProbe.status(at: url) == .complete)
        #expect(AppModelInstallationProbe.status(at: url, descriptor: derivative) == .complete)
        let image = RepackVisionPackInstallerClient.resolvedDescriptor(.visionCompanion, for: url)
        #expect(image.repoID == derivative.repoID)
        #expect(image.revision == derivative.revision)
        guard case .partial = AppModelInstallationProbe.status(at: url, descriptor: .default) else {
            Issue.record("ordinary Gemma must reject the derivative checkpoint")
            return
        }
    }
    @Test func missingDirectoryIsMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuff-missing-\(UUID().uuidString).gturbo")
        #expect(AppModelInstallationProbe.status(at: url) == .missing)
    }

    @Test func manifestWithoutFinalMetadataIsPartial() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuff-partial-\(UUID().uuidString).gturbo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{}".utf8).write(to: url.appendingPathComponent("manifest.json"))
        guard case .partial = AppModelInstallationProbe.status(at: url) else {
            Issue.record("expected partial status")
            return
        }
    }

    @Test func validBoundedMetadataIsComplete() throws {
        let url = try makeCompleteModelInstall("probe")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AppModelInstallationProbe.status(at: url) == .complete)
    }

    @Test func receiptBoundToDifferentPathIsPartial() throws {
        let url = try makeCompleteModelInstall("wrong-path")
        defer { try? FileManager.default.removeItem(at: url) }
        let receiptURL = url.appendingPathComponent("verified-install.json")
        var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
        receipt["modelDirectoryPath"] = "/different/model.gturbo"
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: receiptURL)
        guard case .partial = AppModelInstallationProbe.status(at: url) else {
            Issue.record("expected partial status")
            return
        }
    }

    @Test func differentCheckpointIsPartial() throws {
        let url = try makeCompleteModelInstall("wrong-checkpoint")
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = AppModelInstallDescriptor(
            displayName: "different",
            repoID: "example/different",
            revision: "revision",
            sourceIndexSHA256: String(repeating: "f", count: 64),
            approximateDownloadBytes: 1,
            installedBytes: 1,
            rangeStagingBytes: 1,
            reserveBytes: 1)
        guard case .partial = AppModelInstallationProbe.status(at: url, descriptor: descriptor) else {
            Issue.record("expected checkpoint mismatch to be partial")
            return
        }
    }
}
