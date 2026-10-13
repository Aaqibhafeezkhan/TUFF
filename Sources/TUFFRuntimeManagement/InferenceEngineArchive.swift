import Foundation
import CryptoKit
import Darwin

public enum InferenceEngineArchiveError: Error, Equatable {
    case invalidArchive
    case archiveTooLarge
    case archiveDigestMismatch
    case destinationExists
}

/// Engine releases use uncompressed POSIX ustar. Restricting the format avoids
/// delegating path handling, links or extraction limits to an external utility.
public enum InferenceEngineArchive {
    public static let maximumArchiveBytes: UInt64 = 128 << 20
    private static let blockBytes = 512

    public static func extract(archiveURL: URL, destination: URL,
                               signedManifest: SignedInferenceEngineManifest,
                               trustedPublisherKeys: [String: Data]) throws
        -> InferenceEngineManifest {
        try Task.checkCancellation()
        let manifest = try signedManifest.verifiedManifest(trustedPublisherKeys: trustedPublisherKeys)
        guard manifest.archiveBytes <= maximumArchiveBytes else {
            throw InferenceEngineArchiveError.archiveTooLarge
        }
        let fd = open(archiveURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw InferenceEngineArchiveError.invalidArchive }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, UInt64(info.st_size) == manifest.archiveBytes,
              info.st_size % Int64(blockBytes) == 0 else {
            throw InferenceEngineArchiveError.invalidArchive
        }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256()
        var readCount: UInt64 = 0
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            let total = readCount.addingReportingOverflow(UInt64(data.count))
            guard !total.overflow, total.partialValue <= manifest.archiveBytes else {
                throw InferenceEngineArchiveError.invalidArchive
            }
            readCount = total.partialValue
            hash.update(data: data)
        }
        guard readCount == manifest.archiveBytes,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.archiveSHA256 else {
            throw InferenceEngineArchiveError.archiveDigestMismatch
        }
        try input.seek(toOffset: 0)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw InferenceEngineArchiveError.destinationExists
        }
        var destinationInfo = stat()
        if lstat(destination.path, &destinationInfo) == 0 {
            throw InferenceEngineArchiveError.destinationExists
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }

        let expected = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        var permittedDirectories: Set<String> = []
        for file in manifest.files {
            let parts = file.path.split(separator: "/")
            for count in 1..<parts.count {
                permittedDirectories.insert(parts.prefix(count).joined(separator: "/"))
            }
        }
        var seenFiles: Set<String> = []
        var zeroBlocks = 0
        var consumed: UInt64 = 0
        while consumed < manifest.archiveBytes {
            try Task.checkCancellation()
            let headerData = try readExactly(input, count: blockBytes)
            consumed += UInt64(blockBytes)
            let header = Array(headerData)
            if header.allSatisfy({ $0 == 0 }) {
                zeroBlocks += 1
                continue
            }
            guard zeroBlocks == 0,
                  Array(header[257..<263]) == Array("ustar\0".utf8),
                  Array(header[263..<265]) == Array("00".utf8) else {
                throw InferenceEngineArchiveError.invalidArchive
            }
            let checksum = try octal(Array(header[148..<156]))
            let actualChecksum = header.enumerated().reduce(UInt64(0)) { total, pair in
                total + UInt64((148..<156).contains(pair.offset) ? 32 : pair.element)
            }
            guard checksum == actualChecksum else { throw InferenceEngineArchiveError.invalidArchive }
            let name = try text(Array(header[0..<100]))
            let prefix = try text(Array(header[345..<500]))
            var path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let type = header[156]
            let bytes = try octal(Array(header[124..<136]))
            if type == 53, path.hasSuffix("/") { path.removeLast() }
            guard InferenceEngineManifest.safeRelativePath(path) else {
                throw InferenceEngineArchiveError.invalidArchive
            }
            if type == 53 {
                guard bytes == 0, permittedDirectories.contains(path) else {
                    throw InferenceEngineArchiveError.invalidArchive
                }
                try createDirectories(path: path, under: destination)
                continue
            }
            guard type == 48 || type == 0,
                  let file = expected[path], bytes == file.bytes,
                  seenFiles.insert(path).inserted else {
                throw InferenceEngineArchiveError.invalidArchive
            }
            let padding = (UInt64(blockBytes) - bytes % UInt64(blockBytes)) % UInt64(blockBytes)
            let remaining = manifest.archiveBytes - consumed
            guard bytes <= remaining, padding <= remaining - bytes else {
                throw InferenceEngineArchiveError.invalidArchive
            }
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            if !parent.isEmpty { try createDirectories(path: parent, under: destination) }
            let outputURL = destination.appendingPathComponent(path)
            let outputFD = open(outputURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                file.executable ? 0o755 : 0o644)
            guard outputFD >= 0 else { throw InferenceEngineArchiveError.invalidArchive }
            let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)
            do {
                var pending = bytes
                var fileHash = SHA256()
                while pending > 0 {
                    try Task.checkCancellation()
                    let tile = try readExactly(input, count: Int(min(pending, 1 << 20)))
                    try output.write(contentsOf: tile)
                    fileHash.update(data: tile)
                    pending -= UInt64(tile.count)
                }
                guard fileHash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256,
                      fsync(outputFD) == 0 else { throw InferenceEngineArchiveError.invalidArchive }
                close(outputFD)
            } catch {
                close(outputFD)
                throw error
            }
            if padding > 0 {
                let pad = try readExactly(input, count: Int(padding))
                guard pad.allSatisfy({ $0 == 0 }) else { throw InferenceEngineArchiveError.invalidArchive }
            }
            consumed += bytes + padding
        }
        guard zeroBlocks >= 2, seenFiles == Set(expected.keys) else {
            throw InferenceEngineArchiveError.invalidArchive
        }
        succeeded = true
        return manifest
    }

    private static func createDirectories(path: String, under root: URL) throws {
        var directory = root
        for part in path.split(separator: "/") {
            directory.appendPathComponent(String(part), isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                throw InferenceEngineArchiveError.invalidArchive
            }
        }
    }

    private static func readExactly(_ input: FileHandle, count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let piece = try input.read(upToCount: count - result.count), !piece.isEmpty else {
                throw InferenceEngineArchiveError.invalidArchive
            }
            result.append(piece)
        }
        return result
    }

    private static func text(_ bytes: [UInt8]) throws -> String {
        let body = bytes.prefix { $0 != 0 }
        guard bytes.dropFirst(body.count).allSatisfy({ $0 == 0 }),
              let text = String(bytes: body, encoding: .utf8) else {
            throw InferenceEngineArchiveError.invalidArchive
        }
        return text
    }

    private static func octal(_ bytes: [UInt8]) throws -> UInt64 {
        let field = bytes.drop(while: { $0 == 32 || $0 == 0 })
        let digits = field.prefix { $0 != 32 && $0 != 0 }
        guard field.dropFirst(digits.count).allSatisfy({ $0 == 32 || $0 == 0 }) else {
            throw InferenceEngineArchiveError.invalidArchive
        }
        var value: UInt64 = 0
        for digit in digits {
            guard (48...55).contains(digit) else { throw InferenceEngineArchiveError.invalidArchive }
            let multiplied = value.multipliedReportingOverflow(by: 8)
            let added = multiplied.partialValue.addingReportingOverflow(UInt64(digit - 48))
            guard !multiplied.overflow, !added.overflow else { throw InferenceEngineArchiveError.invalidArchive }
            value = added.partialValue
        }
        return value
    }
}
