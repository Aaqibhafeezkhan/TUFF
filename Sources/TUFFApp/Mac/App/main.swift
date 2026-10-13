import Darwin
import Foundation
import TUFFAppCore
import TUFFCLICore
import TUFFServerCore

// The host serves app, HTTP and CLI roles. Inference runs in installed helpers.
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
    FileHandle.standardError.write(Data("Inference helpers are installed with each model in TUFF 9.0.\n".utf8))
    exit(1)
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
