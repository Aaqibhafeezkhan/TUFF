import Foundation
import Synchronization
import TUFFEngine
import TUFFModelCatalog

/// Installed catalog models, looked up by any name a client might send.
public struct ServerInstalledModels: Sendable {
    public let modelsRoot: URL
    public let device: TUFFDeviceCapabilities

    public init(modelsRoot: URL, device: TUFFDeviceCapabilities = .current()) {
        self.modelsRoot = modelsRoot.standardizedFileURL
        self.device = device
    }

    public func directory(for descriptor: TUFFModelDescriptor) -> URL {
        modelsRoot.appendingPathComponent(descriptor.installDirectoryName, isDirectory: true)
    }

    /// A model the app has finished installing and verifying.
    public func isInstalled(_ descriptor: TUFFModelDescriptor) -> Bool {
        let directory = directory(for: descriptor)
        let fileManager = FileManager.default
        struct Identity: Decodable { let modelID: String }
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("verified-install.json").path),
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let identity = try? JSONDecoder().decode(Identity.self, from: data),
              let architecture = try? ManifestReader.resolveArchitecture(directoryURL: directory)
        else { return false }
        return identity.modelID == descriptor.source.manifestModelID
            && architecture.variant.rawValue == descriptor.architecture.id.rawValue
    }

    /// Installed models this Mac meets the requirements for, in catalog order.
    public func available() -> [TUFFModelDescriptor] {
        TUFFModelCatalog.all.filter { isInstalled($0) && isEligible($0) }
    }

    public func isEligible(_ descriptor: TUFFModelDescriptor) -> Bool {
        descriptor.compatibility(
            with: device,
            contextTokens: descriptor.runtimeDefaults.contextTokens,
            expertCacheSlots: descriptor.runtimeDefaults.expertCacheSlots).isCompatible
        // Qualification determines whether a model can run alone. The runtime
        // estimate includes conservative overlapping-allocation reserves; use
        // it for cross-process admission, not to hide qualified models.
    }

    public static func descriptor(named name: String) -> TUFFModelDescriptor? {
        TUFFModelCatalog.all.first {
            $0.apiModelID == name || $0.selector == name || $0.aliases.contains(name)
                || $0.id.rawValue == name
        }
    }

    public func visionCapability(for descriptor: TUFFModelDescriptor) -> String {
        guard descriptor.capabilities.contains(.imageInput) else { return "missing" }
        guard let pack = try? VisionPackLocation.companionURL(
                  forTextModel: directory(for: descriptor)),
              FileManager.default.fileExists(atPath: pack.path) else { return "missing" }
        return "ready"
    }

    public func estimatedBytes(for descriptor: TUFFModelDescriptor) -> UInt64 {
        let plan = inferencePlan(for: descriptor)
        let estimate = descriptor.estimatedInferenceWorkingSetBytes(
            contextTokens: plan.contextTokens,
            expertCacheSlots: plan.expertCacheSlots,
            prefillChunkTokens: descriptor.recommendedPrefillChunkTokens(on: device))
        return visionCapability(for: descriptor) == "ready"
            ? max(device.safeAppMemoryBudgetBytes, estimate) : estimate
    }

    /// Tool inventories need more than the short qualification prompts. Grow
    /// to 16K (or 8K), and enable batched prefill where affordable, using the same
    /// allocation estimate and 75% budget as the app's automatic planner.
    /// Machines that cannot afford the growth retain the qualified settings.
    public func inferencePlan(for descriptor: TUFFModelDescriptor)
        -> (contextTokens: Int, expertCacheSlots: Int) {
        let defaults = descriptor.runtimeDefaults
        let chunk = descriptor.recommendedPrefillChunkTokens(on: device)
        func fits(context: Int, slots: Int) -> Bool {
            descriptor.estimatedInferenceWorkingSetBytes(contextTokens: context,
                expertCacheSlots: slots, prefillChunkTokens: chunk)
                <= device.safeAppMemoryBudgetBytes
        }
        let context = [16_384, 8_192].first {
            $0 >= defaults.contextTokens && fits(context: $0, slots: defaults.expertCacheSlots)
        } ?? defaults.contextTokens
        let floor = RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill
        let slots = descriptor.architecture.feedForwardKind == .mixtureOfExperts
            && defaults.expertCacheSlots < floor && fits(context: context, slots: floor)
            ? floor : defaults.expertCacheSlots
        return (context, slots)
    }

    /// The same settings `tuff serve` chooses for a model on this Mac.
    public func runtimeConfiguration(for descriptor: TUFFModelDescriptor) -> RuntimeConfiguration {
        let slots = inferencePlan(for: descriptor).expertCacheSlots
        return RuntimeConfiguration(
            expertCacheSlots: slots,
            expertCachePolicy: .lfu,
            rdadvisePolicy: .off,
            // GPT-OSS waits for each cache-sized expert group before reuse;
            // it does not require the affine runner's two top-8 tile banks.
            prefillEnabled: descriptor.family == .gptOss
                || slots >= RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill,
            prefillChunkTokens: descriptor.recommendedPrefillChunkTokens(on: device),
            forceLogitsHead: true)
    }

    public static func dialect(for descriptor: TUFFModelDescriptor) -> ChatDialect {
        switch descriptor.family {
        case .gemma4: .gemma
        case .qwen36, .qwen4Exp: .chatml
        case .gptOss: .harmony
        case .minimaxM2: .minimax
        }
    }
}

/// Reads the background-server settings file when it changes, so the app can
/// change the default model or unload delay without restarting the server.
public final class ServerSettingsSource: Sendable {
    private struct State {
        var settings: TUFFBackgroundServerSettings
        var modified: Date?
    }

    public let url: URL?
    private let state: Mutex<State>

    public init(url: URL?, fallback: TUFFBackgroundServerSettings) {
        self.url = url
        state = Mutex(State(settings: fallback, modified: nil))
    }

    public var current: TUFFBackgroundServerSettings {
        guard let url else { return state.withLock { $0.settings } }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate] as? Date
        return state.withLock { state in
            if modified != state.modified {
                state.modified = modified
                if case .loaded(let settings) = TUFFBackgroundServerSettingsStore.load(from: url) {
                    state.settings = settings
                }
            }
            return state.settings
        }
    }
}

/// Serves every installed model through one scheduler. Models load when a
/// request reaches the front of the queue and unload when idle.
public final class RoutedServerModelProvider: ServerModelProvider {
    public static let defaultModelAlias = "default"

    public let installed: ServerInstalledModels
    public let settings: ServerSettingsSource
    public let scheduler: ServerModelScheduler
    private let residency: TUFFResidencyRegistry?

    /// - Parameters:
    ///   - loader: Builds a backend for a model directory. Tests inject fakes.
    ///   - residency: Coordinates memory with the app; nil disables it.
    public init(installed: ServerInstalledModels,
                settings: ServerSettingsSource,
                residency: TUFFResidencyRegistry?,
                controlPort: @escaping @Sendable () -> Int? = { nil },
                loader: @escaping @Sendable (TUFFModelDescriptor, URL) async throws
                    -> any ServerInferenceBackend,
                onActivity: @escaping @Sendable (ServerSchedulerActivity) -> Void = { _ in }) {
        self.installed = installed
        self.settings = settings
        self.residency = residency
        scheduler = ServerModelScheduler(
            queueLimit: settings.current.queueLimit,
            unloadDelaySeconds: { settings.current.unloadDelay.seconds },
            loader: { apiID in
                guard let descriptor = ServerInstalledModels.descriptor(named: apiID),
                      installed.isInstalled(descriptor) else {
                    throw ServerRequestError.unknownModel
                }
                let needed = installed.estimatedBytes(for: descriptor)
                var reservation: TUFFResidencyLease?
                if let residency {
                    do {
                        reservation = try residency.reserve(TUFFResidencyRecord(
                            owner: .backgroundServer, modelID: descriptor.apiModelID,
                            estimatedBytes: needed, controlPort: controlPort()),
                            budgetBytes: installed.device.safeAppMemoryBudgetBytes)
                    } catch let busy as TUFFResidencyRegistry.MemoryBusy {
                        throw ServerRequestError.modelMemoryBusy(
                            Self.memoryBusyMessage(model: descriptor, holders: busy.holders))
                    }
                }
                let backend = try await loader(descriptor, installed.directory(for: descriptor))
                ServerLog.modelLoaded(descriptor.apiModelID)
                if let reservation { return LeasedServerBackend(backend, lease: reservation) }
                return backend
            },
            unloader: { apiID, _ in
                ServerLog.modelUnloaded(apiID)
            },
            onActivity: onActivity)
    }

    static func memoryBusyMessage(model: TUFFModelDescriptor,
                                  holders: [TUFFResidencyRecord]) -> String {
        let names = holders.map { record -> String in
            let name = ServerInstalledModels.descriptor(named: record.modelID)?.displayName
                ?? record.modelID
            return record.owner == .app ? "the TUFF app (\(name))" : name
        }
        return "Not enough memory to load \(model.displayName) while "
            + names.joined(separator: " and ")
            + " is loaded. Unload that model, or retry when it is idle."
    }

    public var parserVisionCapability: String {
        installed.available().contains { installed.visionCapability(for: $0) == "ready" }
            ? "ready" : "missing"
    }

    public func modelList() -> OpenAIModelList {
        OpenAIModelList(object: "list", data: installed.available().map { descriptor in
            let context = installed.inferencePlan(for: descriptor).contextTokens
            return .init(id: descriptor.apiModelID, object: "model", created: 0, ownedBy: "tuff",
                  capabilities: installed.visionCapability(for: descriptor) == "ready"
                    ? ["text", "image"] : ["text"],
                  contextLength: context, maxOutputTokens: min(4_096, context / 4))
        })
    }

    public func health() -> [String: String] {
        ["status": "ok", "mode": "router", "vision": parserVisionCapability]
    }

    public func route(_ requestedModel: String) throws -> ServerRoutedModel {
        let name = requestedModel == Self.defaultModelAlias
            ? settings.current.defaultModel : requestedModel
        guard let descriptor = ServerInstalledModels.descriptor(named: name) else {
            throw ServerRequestError.unknownModel
        }
        guard installed.isInstalled(descriptor) else {
            throw ServerRequestError.modelUnavailable(
                "\(descriptor.displayName) is not installed. Download it in TUFF first.")
        }
        guard installed.isEligible(descriptor) else {
            throw ServerRequestError.modelUnavailable(
                "\(descriptor.displayName) needs more memory than this Mac has.")
        }
        return ServerRoutedModel(
            id: descriptor.apiModelID, requestedID: requestedModel,
            dialect: ServerInstalledModels.dialect(for: descriptor),
            visionCapability: installed.visionCapability(for: descriptor))
    }

    public func run<Prepared: Sendable, T: Sendable>(
        _ model: ServerRoutedModel,
        onQueued: @escaping @Sendable () -> Void,
        prepare: @escaping @Sendable (any ServerInferenceBackend) async throws -> Prepared,
        operation: @escaping @Sendable (any ServerInferenceBackend, Prepared) async throws -> T
    ) async throws -> T {
        // The model may not be loaded yet, so preparation (which needs its
        // tokenizer) runs inside the turn, after loading.
        try await scheduler.run(model: model.id, onQueued: onQueued) { backend in
            let prepared = try await prepare(backend)
            return try await operation(backend, prepared)
        }
    }

    public var queuedCount: Int { get async { await scheduler.queuedCount } }
    public var isActive: Bool { get async { await scheduler.isActive } }

    public func shutdown() async {
        await scheduler.shutdown()
    }
}

/// The lease follows the backend's actual lifetime, including temporary
/// references held while a completed request returns to its caller.
private final class LeasedServerBackend: @unchecked Sendable, ServerInferenceBackend {
    // Immutable during use. Only deinit clears the backend, before releasing
    // admission, so an incoming app load cannot race live model allocations.
    private var backend: (any ServerInferenceBackend)?
    private let lease: TUFFResidencyLease
    init(_ backend: any ServerInferenceBackend, lease: TUFFResidencyLease) {
        self.backend = backend
        self.lease = lease
    }
    deinit { backend = nil; lease.release() }
    var visionCapability: String { backend!.visionCapability }
    func prepare(_ request: ValidatedChatRequest) async throws -> ServerPreparedRequest {
        try await backend!.prepare(request)
    }
    func generate(_ request: ValidatedChatRequest,
                  onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void) async throws -> ServerCompletion {
        try await backend!.generate(request, onEvent: onEvent)
    }
    func generate(_ prepared: ServerPreparedRequest,
                  onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void) async throws -> ServerCompletion {
        try await backend!.generate(prepared, onEvent: onEvent)
    }
}
