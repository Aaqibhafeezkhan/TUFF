import Foundation
import Synchronization

public enum InferenceEngineDownloadError: Error, Equatable {
    case unsupportedURL
    case oversizedDownload
    case unexpectedHTTPStatus(Int)
}

/// Returns a caller-owned temporary file, not an in-memory archive.
public protocol InferenceEngineDownloadTransport: Sendable {
    func download(from url: URL, maximumBytes: UInt64) async throws -> URL
}

public struct InferenceEngineHTTPTransport: InferenceEngineDownloadTransport {
    public static let releaseHosts: Set<String> = [
        "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
    ]

    public init() {}

    public static func permits(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && url.host.map { releaseHosts.contains($0.lowercased()) } == true
    }

    public func download(from url: URL, maximumBytes: UInt64) async throws -> URL {
        guard Self.permits(url), maximumBytes > 0,
              maximumBytes <= InferenceEngineArchive.maximumArchiveBytes else {
            throw InferenceEngineDownloadError.unsupportedURL
        }
        try Task.checkCancellation()
        let delegate = EngineDownloadDelegate(maximumBytes: maximumBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("TUFF-EngineInstaller", forHTTPHeaderField: "User-Agent")
        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await session.download(for: request, delegate: delegate)
        } catch {
            if delegate.exceededLimit { throw InferenceEngineDownloadError.oversizedDownload }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InferenceEngineDownloadError.unexpectedHTTPStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: downloaded.path)
        guard let count = (attributes[.size] as? NSNumber)?.uint64Value,
              count <= maximumBytes, !delegate.exceededLimit else {
            throw InferenceEngineDownloadError.oversizedDownload
        }
        try Task.checkCancellation()
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("TUFF-EngineDownload-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: downloaded, to: owned)
        return owned
    }
}

private final class EngineDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: UInt64
    private let state = Mutex((redirects: 0, exceededLimit: false))
    var exceededLimit: Bool { state.withLock { $0.exceededLimit } }

    init(maximumBytes: UInt64) { self.maximumBytes = maximumBytes }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = state.withLock { state -> Bool in
            state.redirects += 1
            return state.redirects <= 5
        }
        guard allowed, let url = request.url, InferenceEngineHTTPTransport.permits(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 0 && UInt64(totalBytesWritten) > maximumBytes
            || totalBytesExpectedToWrite > 0 && UInt64(totalBytesExpectedToWrite) > maximumBytes {
            state.withLock { $0.exceededLimit = true }
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

public struct InferenceEngineInstallRequest: Sendable {
    public let packageID: String
    public let version: InferenceEngineVersion
    public let manifestURL: URL
    public let archiveURL: URL
    public let architectureID: String
    public let modelFormatVersion: Int
    public let quantizationLayout: String
    public let protocolVersion: Int
    public let macOSMajorVersion: Int
    public let repairCorrupt: Bool

    public init(packageID: String, version: InferenceEngineVersion, manifestURL: URL,
                archiveURL: URL, architectureID: String, modelFormatVersion: Int,
                quantizationLayout: String, protocolVersion: Int, macOSMajorVersion: Int,
                repairCorrupt: Bool = false) {
        self.packageID = packageID
        self.version = version
        self.manifestURL = manifestURL
        self.archiveURL = archiveURL
        self.architectureID = architectureID
        self.modelFormatVersion = modelFormatVersion
        self.quantizationLayout = quantizationLayout
        self.protocolVersion = protocolVersion
        self.macOSMajorVersion = macOSMajorVersion
        self.repairCorrupt = repairCorrupt
    }
}

public struct InferenceEngineInstaller: Sendable {
    private let transport: any InferenceEngineDownloadTransport
    private let store: InferenceEngineStore
    private let publisherKeys: [String: Data]

    public init(store: InferenceEngineStore, trustedPublisherKeys: [String: Data],
                transport: any InferenceEngineDownloadTransport = InferenceEngineHTTPTransport()) {
        self.store = store
        self.publisherKeys = trustedPublisherKeys
        self.transport = transport
    }

    public func install(_ request: InferenceEngineInstallRequest) async throws -> InferenceEngineManifest {
        try Task.checkCancellation()
        let manifestFile = try await transport.download(from: request.manifestURL,
            maximumBytes: UInt64(2 * SignedInferenceEngineManifest.maximumPayloadBytes))
        defer { try? FileManager.default.removeItem(at: manifestFile) }
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestFile.path)
        let manifestLimit = UInt64(2 * SignedInferenceEngineManifest.maximumPayloadBytes)
        guard let manifestSize = (attributes[.size] as? NSNumber)?.uint64Value,
              manifestSize <= manifestLimit else { throw InferenceEngineDownloadError.oversizedDownload }
        let signed = try JSONDecoder().decode(SignedInferenceEngineManifest.self,
            from: Data(contentsOf: manifestFile))
        let manifest = try signed.verifiedManifest(trustedPublisherKeys: publisherKeys)
        guard manifest.packageID == request.packageID, manifest.version == request.version else {
            throw InferenceEngineStoreError.conflictingVersion
        }
        try manifest.requireCompatibility(architectureID: request.architectureID,
            modelFormatVersion: request.modelFormatVersion, quantizationLayout: request.quantizationLayout,
            protocolVersion: request.protocolVersion, macOSMajorVersion: request.macOSMajorVersion)
        guard manifest.archiveBytes <= InferenceEngineArchive.maximumArchiveBytes else {
            throw InferenceEngineArchiveError.archiveTooLarge
        }
        try await store.requireInstallationSpace(for: manifest)
        try Task.checkCancellation()
        let archive = try await transport.download(from: request.archiveURL, maximumBytes: manifest.archiveBytes)
        defer { try? FileManager.default.removeItem(at: archive) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("TUFF-EngineExtraction-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Task.checkCancellation()
        _ = try InferenceEngineArchive.extract(archiveURL: archive, destination: destination,
            signedManifest: signed, trustedPublisherKeys: publisherKeys)
        try Task.checkCancellation()
        try await store.install(extractedDirectory: destination, signedManifest: signed, repairCorrupt: request.repairCorrupt)
        return manifest
    }
}
