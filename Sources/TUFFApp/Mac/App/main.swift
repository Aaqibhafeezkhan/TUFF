import Darwin
import Foundation
import TUFFAppCore
import TUFFCLICore
import TUFFDecodeServiceCore
import TUFFServerCore

// One executable serves the app, the decode service, the server and the
// command-line runner. See `ProcessRole`.
if let status = AppWebPDFWorker.runIfRequested(arguments: CommandLine.arguments) {
    exit(status)
}
// `tuff bench` and the Benchmarks screen run the app executable this way.
if let status = AppBenchmarkCommand.runIfRequested(
    arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}

switch ProcessRole(invokedAs: CommandLine.arguments[0]) {
case .decodeService:
    Task {
        await TUFFDecodeServiceMain.main()
        exit(0)
    }
    dispatchMain()
case .server:
    Task {
        exit(await RouterServerCommand.main(Array(CommandLine.arguments.dropFirst())))
    }
    dispatchMain()
case .commandLine:
    exit(CLICommand.main(Array(CommandLine.arguments.dropFirst())))
case .app:
    TUFFMacApp.main()
}
