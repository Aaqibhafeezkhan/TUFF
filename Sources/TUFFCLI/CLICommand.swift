@_exported import TUFFCLIArguments
import Darwin
import Foundation
import TUFFRuntimeManagement

/// The `TUFFCLI` executable, callable from any binary that links the CLI.
public enum CLICommand {
    public static func main(_ rawArgv: [String]) -> Int32 {
        if rawArgv == ["--engine-status"] {
            return driveOperation {
                do {
                    let statuses = try await InferenceEngineEnvironment.controller().statuses()
                    for status in statuses {
                        print("\(status.reference.packageID) \(status.reference.version.directoryName) verified=\(status.verified) models=\(status.requiredModelCount) inUse=\(status.inUse)")
                    }
                    return 0
                } catch {
                    try? FileHandle.standardError.write(contentsOf: Data("error: \(error)\n".utf8))
                    return 1
                }
            }
        }
        if rawArgv.first == "--engine-info" {
            guard rawArgv.count == 3, rawArgv[1] == "--model" else {
                FileHandle.standardError.write(Data("usage: TUFFCLI --engine-info --model MODEL.gturbo\n".utf8))
                return 2
            }
            let directory = URL(fileURLWithPath: rawArgv[2])
            return driveOperation {
                do {
                    let installation = try await InferenceEngineEnvironment.acquireModel(at: directory)
                    struct Info: Encodable {
                        let manifest: InferenceEngineManifest
                        let executablePath: String
                        let lockFilePath: String
                    }
                    let data = try JSONEncoder().encode(Info(manifest: installation.lease.manifest,
                        executablePath: installation.executableURL.path, lockFilePath: installation.lockFileURL.path))
                    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
                    await installation.release()
                    return 0
                } catch {
                    try? FileHandle.standardError.write(contentsOf: Data("error: \(error)\n".utf8))
                    return 1
                }
            }
        }
        let parsedArgs: Args
        do {
            parsedArgs = try Args.parse(rawArgv)
        } catch ArgsError.helpRequested {
            print(Args.usage)
            return 0
        } catch {
            // One line and a pointer: the whole usage after every typo
            // pushed the actual error off the screen.
            FileHandle.standardError.write(Data(
                "error: \(error)\nRun with --help for the options.\n".utf8))
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
        driveOperation { await run(args: args).exitCode }
    }

    private static func driveOperation(_ operation: @escaping @Sendable () async -> Int32) -> Int32 {
        let box = RunBox()
        let sem = DispatchSemaphore(value: 0)
        box.task = Task(priority: .userInitiated) {
            box.code = await operation()
            sem.signal()
        }

        // Shell timeouts commonly send SIGTERM rather than Ctrl-C. Forward
        // all normal shutdown requests through task cancellation so the
        // separately launched helper stops instead of continuing to page.
        let sources = [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { box.task?.cancel() }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }

        sem.wait()
        return box.code
    }
}
