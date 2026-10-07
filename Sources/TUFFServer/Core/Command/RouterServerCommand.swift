import Darwin
import Foundation
import TUFFEngine

/// The `TUFFServer` executable, callable from any binary that links the server.
public enum RouterServerCommand {
    public static func main(_ arguments: [String]) async -> Int32 {
        // Every request line goes to stderr, which is unbuffered, while the
        // ready line goes to stdout, which is fully buffered when it is not a
        // terminal. Line buffering puts the line where it is useful.
        setvbuf(stdout, nil, _IOLBF, 0)
        // Before anything in this process creates a Metal device.
        MetalContext.relaxInteractivityWatchdog()
        do {
            let parsed = try RouterServerArguments.parse(arguments)
            return await RouterServerRuntime.run(parsed)
        } catch ServerArgumentError.help {
            print(RouterServerArguments.usage)
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("error: \(error)\n\n\(RouterServerArguments.usage)\n".utf8))
            return 2
        }
    }
}
