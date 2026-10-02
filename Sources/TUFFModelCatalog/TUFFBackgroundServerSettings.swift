import Foundation

/// How long the background server keeps a model in memory after its last
/// request finishes. Requests that are running or queued always keep it.
public enum TUFFModelUnloadDelay: Codable, Equatable, Hashable, Sendable {
    /// Unload as soon as a response finishes and nothing else is queued.
    case immediately
    case seconds(Int)

    public static let choices: [TUFFModelUnloadDelay] = [
        .immediately, .seconds(60), .seconds(300), .seconds(900), .seconds(3_600),
    ]
    public static let `default`: TUFFModelUnloadDelay = .seconds(300)

    public var seconds: Int {
        switch self {
        case .immediately: 0
        case .seconds(let value): max(0, value)
        }
    }

    public var label: String {
        switch self {
        case .immediately: return "Immediately after each response"
        case .seconds(let value):
            if value <= 0 { return "Immediately after each response" }
            if value % 3_600 == 0 {
                let hours = value / 3_600
                return hours == 1 ? "After 1 hour" : "After \(hours) hours"
            }
            if value % 60 == 0 {
                let minutes = value / 60
                return minutes == 1 ? "After 1 minute" : "After \(minutes) minutes"
            }
            return "After \(value) seconds"
        }
    }

    /// Stored as a number of seconds so the file stays readable and a later
    /// build can add choices without a schema change.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int.self)
        self = value <= 0 ? .immediately : .seconds(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(seconds)
    }
}

/// Settings shared by the app, which writes them, and the background server,
/// which reads them. A newer file this build does not understand is left
/// untouched and the server keeps its defaults, the same rule the app's own
/// settings follow.
public struct TUFFBackgroundServerSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultPort = 8_080
    public static let defaultQueueLimit = 4

    public var version: Int
    public var enabled: Bool
    public var port: Int
    /// Catalog selector of the model used when a request names `default`, or
    /// a model this server does not know by its own identifier.
    public var defaultModel: String
    public var unloadDelay: TUFFModelUnloadDelay
    public var queueLimit: Int

    public init(version: Int = currentVersion,
                enabled: Bool = false,
                port: Int = defaultPort,
                defaultModel: String = TUFFModelCatalog.default.selector,
                unloadDelay: TUFFModelUnloadDelay = .default,
                queueLimit: Int = defaultQueueLimit) {
        self.version = version
        self.enabled = enabled
        self.port = port
        self.defaultModel = defaultModel
        self.unloadDelay = unloadDelay
        self.queueLimit = queueLimit
    }

    public var isValid: Bool {
        (1...65_535).contains(port) && (1...16).contains(queueLimit)
            && !defaultModel.isEmpty
    }
}

public enum TUFFBackgroundServerSettingsStore {
    public enum SaveError: Error, Equatable, Sendable {
        case invalidSettings
        /// The file on disk was written by a newer TUFF.
        case newerVersionOnDisk(Int)
    }

    public enum LoadResult: Equatable, Sendable {
        case missing
        case loaded(TUFFBackgroundServerSettings)
        /// Written by a newer TUFF. Leave it alone.
        case newer(version: Int)
        case unreadable
    }

    public static func directory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("TUFF/Server", isDirectory: true)
    }

    public static func fileURL(applicationSupport: URL) -> URL {
        directory(applicationSupport: applicationSupport)
            .appendingPathComponent("background-server.json", isDirectory: false)
    }

    public static func load(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
        struct Stamp: Decodable { let version: Int }
        guard let stamp = try? JSONDecoder().decode(Stamp.self, from: data) else {
            return .unreadable
        }
        guard stamp.version <= TUFFBackgroundServerSettings.currentVersion else {
            return .newer(version: stamp.version)
        }
        guard let settings = try? JSONDecoder().decode(
                  TUFFBackgroundServerSettings.self, from: data),
              settings.isValid else { return .unreadable }
        return .loaded(settings)
    }

    /// Refuses to overwrite a file written by a newer build.
    public static func save(_ settings: TUFFBackgroundServerSettings, to url: URL) throws {
        guard settings.isValid else { throw SaveError.invalidSettings }
        if case .newer(let version) = load(from: url) {
            throw SaveError.newerVersionOnDisk(version)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(settings)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}
