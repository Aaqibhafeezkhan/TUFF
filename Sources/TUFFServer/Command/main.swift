import Darwin
import Foundation
import TUFFEngine
import TUFFServerCore

// Every request line goes to stderr, which is unbuffered, while the ready line
// goes to stdout, which is fully buffered when it is not a terminal. A server
// started with its output redirected therefore showed an empty log for its
// whole life and printed "ready" only as it exited - exactly inverted from
// what an operator needs. Line buffering puts the line where it is useful.
setvbuf(stdout, nil, _IOLBF, 0)
// Before anything in this process creates a Metal device.
MetalContext.relaxInteractivityWatchdog()

do {
    let arguments = try RouterServerArguments.parse(Array(CommandLine.arguments.dropFirst()))
    exit(await RouterServerRuntime.run(arguments))
} catch ServerArgumentError.help {
    print(RouterServerArguments.usage)
    exit(0)
} catch {
    FileHandle.standardError.write(
        Data("error: \(error)\n\n\(RouterServerArguments.usage)\n".utf8))
    exit(2)
}
