import Darwin
import Foundation

/// The `TUFFCLI` executable, callable from any binary that links the CLI.
public enum CLICommand {
    public static func main(_ rawArgv: [String]) -> Int32 {
        let parsedArgs: Args
        do {
            parsedArgs = try Args.parse(rawArgv)
        } catch ArgsError.helpRequested {
            print(Args.usage)
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n\n".utf8))
            FileHandle.standardError.write(Data(Args.usage.utf8))
            FileHandle.standardError.write(Data("\n".utf8))
            return 2
        }
        return drive(parsedArgs)
    }

    // Keep the cancellable task off the top-level executor so the blocking
    // signal bridge cannot prevent it from starting.
    private final class RunBox: @unchecked Sendable {
        var code: Int32 = 0
        var task: Task<Void, Never>?
    }

    private static func drive(_ args: Args) -> Int32 {
        let box = RunBox()
        let sem = DispatchSemaphore(value: 0)
        box.task = Task(priority: .userInitiated) {
            let result = await run(args: args)
            box.code = result.exitCode
            sem.signal()
        }

        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler { box.task?.cancel() }
        sigintSource.resume()

        sem.wait()
        return box.code
    }
}
