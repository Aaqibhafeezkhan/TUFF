import Foundation
import Testing
import TUFFModelCatalog
import TUFFModelMetadata
@testable import TUFFAppCore

@Suite struct AppCustomCheckpointTests {
    private func record(name: String = "My fine tune", id: String = "custom-00000000-0000-0000-0000-000000000001") -> AppCustomCheckpoint {
        AppCustomCheckpoint(id: id, name: name, sourcePath: "/tmp/custom.gturbo",
            templateID: .gemma4_26B_A4B, sourceIndexSHA256: String(repeating: "a", count: 64),
            manifestSHA256: String(repeating: "b", count: 64), installedBytes: 123)
    }
    @Test func customIdentityKeepsTheSharedArchitectureButSeparatesProfiles() throws {
        let custom = record().descriptor
        #expect(custom.modelVariant == AppModelInstallDescriptor.default.modelVariant)
        #expect(custom.planningCatalogID == .gemma4_26B_A4B)
        #expect(custom.catalogID == nil)
        #expect(custom.apiModelID != AppModelInstallDescriptor.default.apiModelID)
        #expect(custom.settingsProfileKey != AppModelInstallDescriptor.default.settingsProfileKey)
        #expect(custom.id != AppModelInstallDescriptor.default.id)
        #expect(custom.shortName == "My fine tune")
        #expect(custom.usesExpertCache)
        #expect(!custom.supportsImageInput)
        #expect(custom.imageCompanion == nil)
        #expect(AppAutomaticMemoryPlanner.predictedLayout(for: custom) == nil)
        let layout = try #require(AppAutomaticMemoryPlanner.predictedLayout(for: .default))
        #expect(AppAutomaticMemoryPlanner.plan(for: custom,
            on: .init(unifiedMemoryBytes: 16 << 30, macOSMajorVersion: 26, appleSiliconGeneration: 2),
            layoutSummary: layout) != nil)
    }
    @Test func registryRoundTripsAndRejectsDuplicateIdentitiesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("registry.json")
        try AppCustomCheckpointStore.save([record()], at: file)
        #expect(try AppCustomCheckpointStore.load(at: file) == [record()])
        try AppCustomCheckpointStore.save([record(), record()], at: file)
        #expect(throws: (any Error).self) { try AppCustomCheckpointStore.load(at: file) }
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try AppCustomCheckpointStore.load(at: link) }
    }
    @Test func customProbeRejectsAChangedManifest() throws {
        let root = try makeCompleteModelInstall("custom-changed")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = AppModelInstallDescriptor.default
        let custom = AppModelInstallDescriptor(displayName: "Custom", repoID: "local/custom", revision: "local",
            sourceIndexSHA256: base.sourceIndexSHA256, approximateDownloadBytes: 0, installedBytes: 0,
            rangeStagingBytes: 0, reserveBytes: 0,
            customIdentity: record().id, customArchitectureTemplate: .gemma4_26B_A4B,
            customManifestSHA256: String(repeating: "f", count: 64))
        guard case .partial(let message) = AppModelInstallationProbe.status(at: root, descriptor: custom) else {
            Issue.record("A changed import must not become an installed checkpoint"); return
        }
        #expect(message.contains("changed"))
    }
    @Test func importerRejectsRawWeightsAndWrongArchitectureWithoutChangingTheReceipt() throws {
        #expect(throws: (any Error).self) {
            try AppCustomCheckpoint.inspect(directory: URL(fileURLWithPath: "/tmp/weights.safetensors"),
                name: "Custom", templateID: .gemma4_26B_A4B)
        }
        let root = try makeCompleteModelInstall("custom-wrong-architecture")
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("verified-install.json")
        let before = try Data(contentsOf: receipt)
        #expect(throws: (any Error).self) {
            try AppCustomCheckpoint.inspect(directory: root, name: "Custom", templateID: .gemma4_E2B)
        }
        #expect(try Data(contentsOf: receipt) == before)
    }
}
