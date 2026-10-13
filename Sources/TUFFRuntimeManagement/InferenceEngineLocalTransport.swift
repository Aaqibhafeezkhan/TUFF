import Foundation
import Darwin

/// Used by an explicitly configured local development catalogue. Release HTTP
/// downloads retain their HTTPS host policy; file URLs never use URLSession.
public struct InferenceEngineLocalDownloadTransport: InferenceEngineDownloadTransport {
    private let root: URL
    public init(allowedRoot: URL) { root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath() }

    public func download(from url: URL, maximumBytes: UInt64) async throws -> URL {
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL, source.path.hasPrefix(root.path + "/") else {
            throw InferenceEngineCatalogError.localSourceOutsideRoot
        }
        let input = open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, UInt64(info.st_size) <= maximumBytes else {
            throw InferenceEngineStoreError.unsafeFile(source.path)
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("TUFF-EngineLocal-\(UUID())")
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var completed = false
        defer { close(output); if !completed { try? FileManager.default.removeItem(at: destination) } }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset: Int64 = 0
        while offset < info.st_size {
            try Task.checkCancellation()
            let count = min(buffer.count, Int(info.st_size - offset))
            let got = buffer.withUnsafeMutableBytes { pread(input, $0.baseAddress!, count, off_t(offset)) }
            if got < 0 && errno == EINTR { continue }
            guard got > 0 else { throw InferenceEngineStoreError.unsafeFile(source.path) }
            var written = 0
            while written < got {
                let amount = buffer.withUnsafeBytes { write(output, $0.baseAddress!.advanced(by: written), got - written) }
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += amount
            }
            offset += Int64(got)
        }
        guard fsync(output) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        completed = true
        return destination
    }
}

public struct InferenceEngineSourceTransport: InferenceEngineDownloadTransport {
    private let local: InferenceEngineLocalDownloadTransport?
    private let http = InferenceEngineHTTPTransport()
    public init(localRoot: URL? = nil) { local = localRoot.map(InferenceEngineLocalDownloadTransport.init(allowedRoot:)) }
    public func download(from url: URL, maximumBytes: UInt64) async throws -> URL {
        if url.isFileURL {
            guard let local else { throw InferenceEngineCatalogError.localSourceOutsideRoot }
            return try await local.download(from: url, maximumBytes: maximumBytes)
        }
        return try await http.download(from: url, maximumBytes: maximumBytes)
    }
}
