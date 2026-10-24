import Darwin
import Foundation
import TUFFModelCatalog

/// Remembers files that passed a full SHA-256 check, so loading the same
/// unchanged model again doesn't read every weight byte just to hash it.
///
/// A record is the file's identity when it was hashed: device, inode, size,
/// and modification and change times. Any write, truncate, replacement or
/// permission change moves the change time, and nothing outside the kernel can
/// set it back, so a changed file is always hashed again. Records are keyed by
/// the expected hash. A missing or stale record only means hashing as before.
///
/// The engine reads records when it loads a model; the installer writes them
/// for the files it has just hashed, so the first load after an install skips
/// the hash too.
public struct VerifiedFileMemo: Sendable {
    public let directory: URL?

    public init(directory: URL?) { self.directory = directory }

    public static let standard = VerifiedFileMemo(directory: defaultDirectory())

    /// `Caches/TUFF/VerifiedFiles`, beside the prefix snapshots.
    /// `TUFF_VERIFIED_FILE_MEMO=off` hashes every load, as before 9.5.0.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if environment["TUFF_VERIFIED_FILE_MEMO"] == "off" { return nil }
        return TUFFPrefixSnapshotLocation.rootDirectory(environment: environment)?
            .deletingLastPathComponent()
            .appendingPathComponent("VerifiedFiles", isDirectory: true)
    }

    public struct Identity: Codable, Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        public init?(fileDescriptor fd: Int32) {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            device = Int64(info.st_dev)
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    /// Same contract as `Sha256Verifier.verifyFile`, without the read when
    /// this exact file already matched `expectedHex`.
    public func verifyFile(fileDescriptor fd: Int32, named name: String, expectedHex: String) throws {
        let key = expectedHex.lowercased()
        let before = Identity(fileDescriptor: fd)
        if let before, recorded(key) == before { return }
        try Sha256Verifier.verifyFile(fileDescriptor: fd, named: name, expectedHex: expectedHex)
        // A file written to while it was read proves nothing about its bytes now.
        if let before, Identity(fileDescriptor: fd) == before { record(key, before) }
    }

    private func url(for key: String) -> URL? {
        guard let directory, key.utf8.count == 64, key.allSatisfy(\.isHexDigit) else { return nil }
        return directory.appendingPathComponent(key + ".json")
    }

    private func recorded(_ key: String) -> Identity? {
        guard let url = url(for: key),
              let data = try? Data(contentsOf: url), data.count <= 4_096 else { return nil }
        return try? JSONDecoder().decode(Identity.self, from: data)
    }

    /// Records that the file with `identity` hashed to `hex`. The caller
    /// hashed it itself and checked the identity didn't change meanwhile.
    public func record(_ identity: Identity, hashedTo hex: String) {
        record(hex.lowercased(), identity)
    }

    private func record(_ key: String, _ identity: Identity) {
        guard let directory, let url = url(for: key),
              let data = try? JSONEncoder().encode(identity) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
