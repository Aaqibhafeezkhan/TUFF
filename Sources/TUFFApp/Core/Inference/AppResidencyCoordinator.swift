import Foundation
import TUFFModelCatalog
import TUFFEngine

/// Reserves the decode service's working set and asks idle API models to yield.
public struct AppResidencyCoordinator: Sendable {
    public let registry: TUFFResidencyRegistry
    public let budgetBytes: UInt64
    public let reclaim: @Sendable (Int) async throws -> Bool

    public init(registry: TUFFResidencyRegistry, budgetBytes: UInt64,
                reclaim: @escaping @Sendable (Int) async throws -> Bool) {
        self.registry = registry
        self.budgetBytes = budgetBytes
        self.reclaim = reclaim
    }

    public static func current() -> Self {
        let support = AppSupportMigration.applicationSupportURL()
        return Self(registry: TUFFResidencyRegistry(
            directory: TUFFResidencyRegistry.directory(applicationSupport: support)),
            budgetBytes: TUFFDeviceCapabilities.current().safeAppMemoryBudgetBytes,
            reclaim: { port in
                let tokenURL = support.appendingPathComponent("TUFF/Server/control-token")
                guard let token = try? String(contentsOf: tokenURL, encoding: .utf8),
                      (1...65_535).contains(port), token.trimmingCharacters(in: .whitespacesAndNewlines).count == 64
                else { return false }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tuff/v1/unload")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 5
                request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
                                 forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode == 200
            })
    }

    public func reserve(model: TUFFModelDescriptor, context: Int, slots: Int,
                        chunk: Int = 128) async throws -> TUFFResidencyLease {
        let record = TUFFResidencyRecord(owner: .app, modelID: model.apiModelID,
            estimatedBytes: model.estimatedInferenceWorkingSetBytes(contextTokens: context,
                expertCacheSlots: slots, prefillChunkTokens: chunk))
        return try await reserve(record: record)
    }

    public func reserve(directory: URL, context: Int, slots: Int,
                        chunk: Int = 128) async throws -> TUFFResidencyLease {
        struct ManifestIdentity: Decodable { let modelID: String }
        let identity = try JSONDecoder().decode(ManifestIdentity.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        if let model = TUFFModelCatalog.model(manifestModelID: identity.modelID) {
            if let companion = try? VisionPackLocation.companionURL(forTextModel: directory),
               FileManager.default.fileExists(atPath: companion.path) {
                // Vision towers can allocate a transient encoding working set.
                // Serialize cross-process residency until a combined text/vision
                // peak has been qualified, rather than guessing that it fits.
                let estimate = model.estimatedInferenceWorkingSetBytes(contextTokens: context,
                    expertCacheSlots: slots, prefillChunkTokens: chunk)
                return try await reserve(record: .init(owner: .app, modelID: model.apiModelID,
                    estimatedBytes: max(budgetBytes, estimate)))
            }
            return try await reserve(model: model, context: context, slots: slots, chunk: chunk)
        }
        // A custom pack still participates in admission, without publishing its path.
        return try await reserve(record: .init(owner: .app, modelID: "custom", estimatedBytes: budgetBytes))
    }

    private func reserve(record: TUFFResidencyRecord) async throws -> TUFFResidencyLease {
        do {
            return try registry.reserve(record, budgetBytes: budgetBytes)
        } catch let busy as TUFFResidencyRegistry.MemoryBusy {
            for holder in busy.holders where holder.owner == .backgroundServer {
                if let port = holder.controlPort {
                    guard (try? await reclaim(port)) == true else {
                        throw AppInferenceError.modelLoadFailed(
                            "The Background API is busy or unavailable. Wait for its requests to finish, then load the model again.")
                    }
                }
            }
            do {
                return try registry.reserve(record, budgetBytes: budgetBytes)
            } catch is TUFFResidencyRegistry.MemoryBusy {
                throw AppInferenceError.modelLoadFailed(
                    "Another TUFF process holds model memory. Unload its model before loading this one.")
            }
        }
    }
}
