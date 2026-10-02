import Foundation
import TUFFModelCatalog

/// Arguments for the model-routing server: `TUFFServer --all-models` in the
/// foreground, or `TUFFServer --background` as the login item the app
/// registers. Fixed-model serving keeps `ServerArguments`.
public struct RouterServerArguments: Equatable, Sendable {
    public var background: Bool
    public var modelsRoot: String?
    public var port: Int?
    public var defaultModel: String?
    public var unloadDelay: TUFFModelUnloadDelay?
    public var queueLimit: Int?

    public static let usage = """
    usage: TUFFServer --all-models [options]
           TUFFServer --background

    Serves every installed model on one loopback endpoint. A model loads when a
    request names it and unloads after it has been idle. Requests that name
    `default` use the default model.

      --all-models               Route requests by their "model" field.
      --background               Run as TUFF's background API: read settings from
                                 Application Support/TUFF/Server and log to
                                 ~/Library/Logs/TUFF. The app starts this mode.
      --models-root <dir>        Installed models (default Application
                                 Support/TUFF/Models).
      --port <1...65535>         Loopback port (default 8080, or the saved setting).
      --default-model <name>     Model for requests that name `default`.
      --unload-after <seconds|immediately>
                                 Idle time before the model unloads (default 300).
      --queue-limit <count>      Maximum queued requests, 1-16 (default 4).
      --help                     Show this help.
    """

    public static func isRouterInvocation(_ input: [String]) -> Bool {
        input.contains("--all-models") || input.contains("--background")
    }

    public static func parse(_ input: [String]) throws -> RouterServerArguments {
        var arguments = RouterServerArguments(background: false)
        var sawMode = false
        var index = 0
        while index < input.count {
            let flag = input[index]
            index += 1
            switch flag {
            case "--help", "-h":
                throw ServerArgumentError.help
            case "--all-models":
                sawMode = true
                continue
            case "--background":
                sawMode = true
                arguments.background = true
                continue
            default:
                break
            }
            guard index < input.count else {
                throw ServerArgumentError.invalid("\(flag) requires a value")
            }
            let value = input[index]
            index += 1
            switch flag {
            case "--models-root":
                arguments.modelsRoot = value
            case "--port":
                guard let parsed = Int(value), (1...65_535).contains(parsed) else {
                    throw ServerArgumentError.invalid("--port must be between 1 and 65535")
                }
                arguments.port = parsed
            case "--default-model":
                guard ServerInstalledModels.descriptor(named: value) != nil else {
                    throw ServerArgumentError.invalid("unknown model: \(value)")
                }
                arguments.defaultModel = value
            case "--unload-after":
                if value == "immediately" {
                    arguments.unloadDelay = .immediately
                } else if let seconds = Int(value), seconds >= 0 {
                    arguments.unloadDelay = seconds == 0 ? .immediately : .seconds(seconds)
                } else {
                    throw ServerArgumentError.invalid(
                        "--unload-after must be a number of seconds or immediately")
                }
            case "--queue-limit":
                guard let parsed = Int(value), (1...16).contains(parsed) else {
                    throw ServerArgumentError.invalid("--queue-limit must be between 1 and 16")
                }
                arguments.queueLimit = parsed
            default:
                throw ServerArgumentError.invalid("unknown flag: \(flag)")
            }
        }
        guard sawMode else {
            throw ServerArgumentError.invalid("--all-models or --background is required")
        }
        return arguments
    }

    /// Settings this run uses: the saved file in background mode, with any
    /// explicit flag taking precedence.
    public func resolvedSettings(saved: TUFFBackgroundServerSettings?) -> TUFFBackgroundServerSettings {
        var settings = saved ?? TUFFBackgroundServerSettings()
        if let port { settings.port = port }
        if let defaultModel { settings.defaultModel = defaultModel }
        if let unloadDelay { settings.unloadDelay = unloadDelay }
        if let queueLimit { settings.queueLimit = queueLimit }
        return settings
    }
}
