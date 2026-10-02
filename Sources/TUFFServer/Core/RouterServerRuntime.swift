import Darwin
import Foundation
import Synchronization
import TUFFEngine
import TUFFModelCatalog

/// Runs the model-routing server until SIGINT or SIGTERM.
public enum RouterServerRuntime {
    public static func applicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public static func logURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TUFF/background-server.log")
    }

    /// Sends this process's stderr to the background log, keeping one older
    /// file once it grows past `rotateBytes`.
    public static func redirectLog(to url: URL, rotateBytes: UInt64 = 5 << 20) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
           size > rotateBytes {
            let previous = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: url, to: previous)
        }
        freopen(url.path, "a", stderr)
        freopen(url.path, "a", stdout)
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    /// One Metal context for every model this process loads, created on the
    /// first load so an idle listener holds no GPU state.
    private final class SharedContext: @unchecked Sendable {
        private let lock = NSLock()
        private var context: MetalContext?
        func get() throws -> MetalContext {
            lock.lock()
            defer { lock.unlock() }
            if let context { return context }
            let created = try MetalContext()
            context = created
            return created
        }
    }

    /// Returns the exit status.
    public static func run(_ arguments: RouterServerArguments) async -> Int32 {
        let support = applicationSupportURL()
        let settingsURL = TUFFBackgroundServerSettingsStore.fileURL(applicationSupport: support)
        var saved: TUFFBackgroundServerSettings?
        if arguments.background {
            redirectLog(to: logURL())
            switch TUFFBackgroundServerSettingsStore.load(from: settingsURL) {
            case .loaded(let settings):
                guard settings.enabled else {
                    write("background API is turned off in TUFF; exiting")
                    return 0
                }
                saved = settings
            case .missing:
                write("no background API settings; exiting")
                return 0
            case .newer(let version):
                write("settings version \(version) is newer than this build; exiting without changing it")
                return 0
            case .unreadable:
                write("settings could not be read; exiting without starting the API")
                return 0
            }
        }
        let settings = arguments.resolvedSettings(saved: saved)
        let modelsRoot = arguments.modelsRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? support.appendingPathComponent("TUFF/Models", isDirectory: true)
        let installed = ServerInstalledModels(modelsRoot: modelsRoot)
        let source = ServerSettingsSource(
            url: arguments.background ? settingsURL : nil, fallback: settings)
        let residency = TUFFResidencyRegistry(
            directory: TUFFResidencyRegistry.directory(applicationSupport: support))
        let tokenURL = ServerControlToken.fileURL(applicationSupport: support)
        let token: String
        do {
            token = try ServerControlToken.read(at: tokenURL)
                ?? ServerControlToken.create(at: tokenURL)
        } catch {
            write("error: could not create the control token: \(error)")
            return 1
        }

        let sharedContext = SharedContext()
        let port = settings.port
        let provider = RoutedServerModelProvider(
            installed: installed,
            settings: source,
            residency: residency,
            controlPort: { port },
            loader: { descriptor, directory in
                let session = try await ServerModelSession.load(
                    modelDirectory: directory,
                    maxContext: descriptor.runtimeDefaults.contextTokens,
                    promptCacheMode: .singlePrefix,
                    runtimeConfiguration: installed.runtimeConfiguration(for: descriptor),
                    context: try sharedContext.get(),
                    // The app verified these packs when it installed them, and
                    // it loads them the same way.
                    integrityPolicy: .sizeCheckTrustedReceipt)
                guard session.defaultModelID == descriptor.apiModelID,
                      session.modelVariant.rawValue == descriptor.architecture.id.rawValue else {
                    throw ServerRequestError.modelUnavailable("The installed pack does not match the requested model.")
                }
                return session
            })
        let control = ServerControl(
            token: token,
            status: { await ServerControl.status(provider: provider, version: TUFFVersion.current) },
            unloadIfIdle: { await provider.scheduler.unloadIfIdle() })
        let server = TUFFHTTPServer(provider: provider, control: control)
        let signals = ServerTerminationSignals()
        do {
            _ = try await server.start(port: port)
        } catch {
            write("error: could not listen on 127.0.0.1:\(port): \(error)")
            await signals.cancel()
            return 1
        }
        let names = installed.available().map(\.apiModelID).joined(separator: ",")
        print("TUFFServer \(TUFFVersion.current) routing at http://127.0.0.1:\(port) "
            + "default=\(settings.defaultModel) unload_after=\(settings.unloadDelay.seconds)s "
            + "models=\(names.isEmpty ? "none" : names)")
        _ = await signals.wait()
        do {
            try await server.shutdown()
        } catch {
            write("error during shutdown: \(error)")
        }
        await signals.cancel()
        return 0
    }

    private static func write(_ message: String) {
        FileHandle.standardError.write(Data("[\(Date().formatted(.iso8601))] \(message)\n".utf8))
    }
}
