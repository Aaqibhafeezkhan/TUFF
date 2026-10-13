import TUFFCLICore

public enum CLIEngineRuntime {
    public static func registerInProcessRunner() {
        CLIRuntimeRegistry.register { args, stdout, stderr in
            await TUFFCLIEngine.run(args: args, stdout: stdout, stderr: stderr)
        }
    }
}
