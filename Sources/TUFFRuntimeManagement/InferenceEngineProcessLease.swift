import Foundation
import Darwin

/// Held by the helper itself. The host may quit or release its own lease while
/// inference is still shutting down; that must not make executable files removable.
public final class InferenceEngineProcessLease: @unchecked Sendable {
    private let descriptor: Int32

    /// Direct development/qualification launches also protect an installed
    /// package, even when the caller did not pass the host's lock argument.
    public static func forInstalledExecutable(_ executable: URL) throws -> InferenceEngineProcessLease? {
        let version = executable.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let receipt = version.appendingPathComponent(".engine-receipt.json")
        var info = stat()
        if lstat(receipt.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let package = version.deletingLastPathComponent()
        let parts = version.lastPathComponent.split(separator: ".")
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              InferenceEngineManifest.safeRelativePath(package.lastPathComponent),
              !package.lastPathComponent.hasPrefix("."), parts.count == 3,
              parts.allSatisfy({ part in Int(part).map { $0 >= 0 && String($0) == part } ?? false }) else {
            throw InferenceEngineStoreError.unsafeFile("installed engine lease")
        }
        let root = package.deletingLastPathComponent()
        return try .init(lockFileURL: root.appendingPathComponent(".locks/\(package.lastPathComponent)-\(version.lastPathComponent).lock"))
    }

    public init(lockFileURL: URL) throws {
        guard lockFileURL.isFileURL else { throw InferenceEngineStoreError.unsafeFile("engine lock") }
        let fd = open(lockFileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            throw InferenceEngineStoreError.unsafeFile(lockFileURL.path)
        }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw InferenceEngineStoreError.packageBusy }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
