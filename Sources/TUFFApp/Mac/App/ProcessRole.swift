import Foundation

/// What this process is, from the name it was started under. The packaged
/// bundle ships one executable and links the other names to it; launchd starts
/// the Background API with `TUFFServer` as its first argument.
enum ProcessRole: Equatable {
    case app
    case decodeService
    case server
    case commandLine

    init(invokedAs path: String) {
        switch URL(fileURLWithPath: path).lastPathComponent {
        case "TUFFDecodeService": self = .decodeService
        case "TUFFServer": self = .server
        case "TUFFCLI": self = .commandLine
        default: self = .app
        }
    }
}
