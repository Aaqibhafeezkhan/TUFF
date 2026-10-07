import CoreFoundation
import Foundation

public struct TUFFDataVersions: Equatable, Sendable {
    public var chats: Int
    public var appSettings: Int
    public var backgroundSettings: Int
    public init(chats: Int, appSettings: Int, backgroundSettings: Int) {
        self.chats = chats; self.appSettings = appSettings; self.backgroundSettings = backgroundSettings
    }
    public static let current = TUFFDataVersions(chats: 3, appSettings: 7, backgroundSettings: 1)
}

public struct RecoveryUpdateMetadata: Equatable, Sendable {
    public let isRecovery: Bool
    public let supported: TUFFDataVersions?
    public let withdrawnVersion: String?

    public init(properties: [AnyHashable: Any]) {
        isRecovery = (properties["tuff:recovery"] as? String) == "true"
        withdrawnVersion = properties["tuff:withdrawnVersion"] as? String
        if let chats = Self.version(properties["tuff:chatsSchema"]),
           let app = Self.version(properties["tuff:appSettingsVersion"]),
           let server = Self.version(properties["tuff:backgroundSettingsVersion"]) {
            supported = TUFFDataVersions(chats: chats, appSettings: app, backgroundSettings: server)
        } else { supported = nil }
    }
    private static func version(_ value: Any?) -> Int? {
        guard let raw = value as? String, let number = Int(raw), number > 0 else { return nil }
        return number
    }
}

public enum RecoveryUpdatePolicy {
    public enum CompatibilityError: Error, LocalizedError, Equatable {
        case missingMetadata
        case newerData
        case unreadableData
        public var errorDescription: String? {
            switch self {
            case .missingMetadata: "This recovery update does not declare compatible data formats."
            case .newerData: "This recovery update cannot read this Mac's chats or settings. Your data has been kept."
            case .unreadableData: "Local data versions could not be checked. Your data has been kept."
            }
        }
    }

    public static func check(_ metadata: RecoveryUpdateMetadata, local: TUFFDataVersions) throws {
        guard metadata.isRecovery else { return }
        guard let supported = metadata.supported else { throw CompatibilityError.missingMetadata }
        guard local.chats <= supported.chats, local.appSettings <= supported.appSettings,
              local.backgroundSettings <= supported.backgroundSettings else { throw CompatibilityError.newerData }
    }

    public static func checkForRunningApp(_ metadata: RecoveryUpdateMetadata, local: TUFFDataVersions) throws {
        try check(metadata, local: local)
        // Prepared installations can wait until quit while the app saves data.
        try check(metadata, local: .current)
    }

    public static func localVersions(applicationSupport: URL) throws -> TUFFDataVersions {
        func stamp(_ relative: String, key: String, fallback: Int) throws -> Int {
            let url = applicationSupport.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let number = json[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.intValue > 0, number.doubleValue == Double(number.intValue)
            else { throw CompatibilityError.unreadableData }
            return number.intValue
        }
        return try TUFFDataVersions(
            chats: stamp("TUFF/Chats/v1/conversations.json", key: "schemaVersion",
                         fallback: TUFFDataVersions.current.chats),
            appSettings: stamp("TUFF/Models/mac-app-settings.json", key: "version",
                               fallback: TUFFDataVersions.current.appSettings),
            backgroundSettings: stamp("TUFF/Server/background-server.json", key: "version",
                                      fallback: TUFFDataVersions.current.backgroundSettings))
    }
}
