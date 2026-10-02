import Foundation
import Testing
import TUFFModelCatalog
@testable import TUFFAppCore

@Suite(.serialized) struct AppResidencyCoordinatorTests {
    @Test func renamedAndCustomPacksAlwaysHoldLeases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TUFFAppResidency-\(UUID())")
        let pack = root.appendingPathComponent("private-name")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TUFFResidencyRegistry(directory: root.appendingPathComponent("leases"))
        let coordinator = AppResidencyCoordinator(registry: registry, budgetBytes: 123,
            reclaim: { _ in false })
        for identity in [TUFFModelCatalog.gemma4_E2B.source.manifestModelID, "custom"] {
            try JSONEncoder().encode(["modelID": identity]).write(to: pack.appendingPathComponent("manifest.json"))
            let lease = try await coordinator.reserve(directory: pack, context: 4096, slots: 16)
            #expect(registry.activeRecords().count == 1)
            #expect(registry.activeRecords()[0].modelID == (identity == "custom" ? "custom" : TUFFModelCatalog.gemma4_E2B.apiModelID))
            lease.release()
        }
    }
    @Test func idleServerYieldsBeforeAppReservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TUFFAppResidency-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TUFFResidencyRegistry(directory: root)
        let model = TUFFModelCatalog.gemma4_E2B
        let needed = model.memory.estimatedWorkingSetBytes(contextTokens: 4096, expertCacheSlots: 16)
        let server = try registry.reserve(.init(owner: .backgroundServer, modelID: model.apiModelID,
            estimatedBytes: needed, controlPort: 9999), budgetBytes: needed)
        let coordinator = AppResidencyCoordinator(registry: registry, budgetBytes: needed, reclaim: { port in
            #expect(port == 9999)
            server.release()
            return true
        })
        let app = try await coordinator.reserve(model: model, context: 4096, slots: 16)
        #expect(registry.activeRecords().map(\.owner) == [.app])
        app.release()
        #expect(registry.activeRecords().isEmpty)
    }
    @Test func busyServerIsNotInterrupted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TUFFAppResidency-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TUFFResidencyRegistry(directory: root)
        let server = try registry.reserve(.init(owner: .backgroundServer, modelID: "other",
            estimatedBytes: 100, controlPort: 9999), budgetBytes: 100)
        defer { server.release() }
        let coordinator = AppResidencyCoordinator(registry: registry, budgetBytes: 100, reclaim: { _ in false })
        await #expect(throws: AppInferenceError.self) {
            try await coordinator.reserve(model: TUFFModelCatalog.gemma4_E2B, context: 4096, slots: 16)
        }
        #expect(registry.activeRecords().map(\.owner) == [.backgroundServer])
    }
}
