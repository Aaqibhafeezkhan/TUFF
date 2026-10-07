import Darwin
import TUFFEngine
import Foundation
import TUFFAppCore
import TUFFDecodeProtocol

enum DecodeServiceError: Error, CustomStringConvertible {
    case attachmentOutsideStore(path: String)

    var description: String {
        switch self {
        case .attachmentOutsideStore(let path):
            "image attachment is not a staged attachment: \(path)"
        }
    }
}

public enum TUFFDecodeServiceMain {
    public static func main() async {
        // Before anything in this process creates a Metal device.
        MetalContext.relaxInteractivityWatchdog()
        let socketPath = argument(after: "--socket")
        let launchLabel = argument(after: "--launch-label")
        let handles: (input: FileHandle, output: FileHandle)
        do {
            handles = if let socketPath {
                try DecodeUnixSocket.listenAndAccept(path: socketPath)
            } else {
                (.standardInput, .standardOutput)
            }
        } catch {
            FileHandle.standardError.write(Data("Decode service transport failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
        defer {
            if let socketPath { unlink(socketPath) }
            if let launchLabel { retireLaunchJob(launchLabel) }
        }

        DecodeUnixSocket.ignoreSIGPIPEProcessWide()
        let service = DecodeService(
            client: RealInferenceClient(residencyCoordinator: .current()),
            input: handles.input,
            output: handles.output)
        if let loss = await service.run() {
            FileHandle.standardError.write(Data(
                "Decode service stopped after transport loss: \(loss)\n".utf8))
        }
    }

    private static func argument(after name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func retireLaunchJob(_ label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
