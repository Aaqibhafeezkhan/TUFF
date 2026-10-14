import Foundation
import TUFFModelCatalog
import TUFFRuntimeManagement

/// What deleting a catalog model handles beside its own folder: a Background
/// API still holding it, its saved prompt snapshots, and an engine nothing
/// else uses any more.
public struct AppModelDeletionCleanup: Sendable {
    /// Asks every Background API holding the model to unload it. False when
    /// one is answering or has queued a request, since unloading never
    /// interrupts a request.
    public var releaseFromBackgroundAPI: @Sendable (_ apiModelID: String) async -> Bool
    /// Runs after the folder is gone. Best effort: a leftover cache or engine
    /// is not worth failing a delete the user asked for.
    public var afterDeletion: @Sendable (_ descriptor: AppModelInstallDescriptor) async -> Void

    public init(releaseFromBackgroundAPI: @escaping @Sendable (String) async -> Bool,
                afterDeletion: @escaping @Sendable (AppModelInstallDescriptor) async -> Void) {
        self.releaseFromBackgroundAPI = releaseFromBackgroundAPI
        self.afterDeletion = afterDeletion
    }

    /// Does nothing, for tests that must not reach a real server or engine store.
    public static let none = Self(releaseFromBackgroundAPI: { _ in true }, afterDeletion: { _ in })

    public static let standard = Self(
        releaseFromBackgroundAPI: { apiModelID in
            await release(apiModelID, from: .current())
        },
        afterDeletion: { descriptor in
            guard let model = descriptor.catalogID.flatMap(TUFFModelCatalog.model(id:)) else { return }
            removePrefixSnapshots(modelID: model.source.manifestModelID)
            await removeEnginesNoLongerUsed(architectureID: model.architecture.id.rawValue)
        })

    static func release(_ apiModelID: String, from residency: AppResidencyCoordinator) async -> Bool {
        let holders = residency.registry.activeRecords().filter {
            $0.owner == .backgroundServer && $0.modelID == apiModelID
        }
        for holder in holders {
            guard let port = holder.controlPort,
                  (try? await residency.reclaim(port)) == true else { return false }
        }
        return true
    }

    static func removePrefixSnapshots(modelID: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let directory = TUFFPrefixSnapshotLocation.modelDirectory(
            modelID: modelID, environment: environment) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Only this model's engine family is considered; other families' unused
    /// engines stay until the person removes them in Settings. A version kept
    /// for rollback is bound to its model, so it counts as required and stays.
    static func removeEnginesNoLongerUsed(architectureID: String) async {
        guard let controller = try? InferenceEngineEnvironment.controller() else { return }
        let families = Set(controller.catalog.releases
            .filter { $0.architectureIDs.contains(architectureID) }
            .map(\.packageID))
        // `statuses()` first drops the bindings of model folders that are gone.
        guard let statuses = try? await controller.statuses() else { return }
        for status in statuses where families.contains(status.reference.packageID)
            && status.requiredModelCount == 0 && !status.inUse {
            _ = try? await controller.removeUnused(status.reference)
        }
    }
}
