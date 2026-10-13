import Darwin
import Foundation
import Synchronization

public protocol SourceByteProvider {
    func copyBatch(
        _ copies: [CoalescedRangeCopy],
        completedRangeIDs: Set<String>,
        partialDirectory: String,
        temporaryPath: String,
        audit: RepackAudit,
        progress: @escaping @Sendable (UInt64) -> Void,
        commit: (RemoteCompletedRange) throws -> Void
    ) async throws
}

public final class HTTPRangeSourceByteProvider: SourceByteProvider, Sendable {
    private let remote: HuggingFaceRemoteSource
    private let files: [String: RemoteFileInfo]
    private let writeTileBytes: Int
    private let concurrentTransfers: Int

    public init(remote: HuggingFaceRemoteSource,
                files: [String: RemoteFileInfo],
                writeTileBytes: Int = WriterCore.tileBytes, concurrentTransfers: Int = 2) {
        self.remote = remote
        self.files = files
        self.writeTileBytes = writeTileBytes
        self.concurrentTransfers = concurrentTransfers
    }

    private struct WorkResult: Sendable {
        let completed: RemoteCompletedRange
        let sourceRead: UInt64, outputWritten: UInt64, intentional: UInt64, tiles: UInt64
        let largestScratch: Int, largestTransfer: Int, largestHeap: Int
        let rangeRequests: UInt64, downloaded: UInt64, rangeRetries: UInt64
        let retries: [RepackAudit.RemoteRetryRecord]
    }
    private final class Progress: Sendable {
        let state = Mutex((values: [String: UInt64](), hasCommit: false))
        let report: @Sendable (UInt64) -> Void
        init(_ report: @escaping @Sendable (UInt64) -> Void) { self.report = report }
        func update(_ id: String, bytes: UInt64) {
            state.withLock { value in
                value.values[id] = max(value.values[id] ?? 0, bytes)
                if value.hasCommit { report(value.values.values.reduce(0, +)) }
            }
        }
        func committed() {
            state.withLock { value in
                value.hasCommit = true
                report(value.values.values.reduce(0, +))
            }
        }
    }
    public func copyBatch(
        _ copies: [CoalescedRangeCopy], completedRangeIDs: Set<String>,
        partialDirectory: String, temporaryPath: String, audit: RepackAudit,
        progress: @escaping @Sendable (UInt64) -> Void,
        commit: (RemoteCompletedRange) throws -> Void
    ) async throws {
        guard (1...4).contains(concurrentTransfers), writeTileBytes > 0,
              writeTileBytes <= BoundedScratch.defaultLimitBytes else {
            throw RepackError.configurationInvalid(detail: "invalid bounded range concurrency or tile size")
        }
        if concurrentTransfers == 1 {
            try await copyBatchSerial(copies, completedRangeIDs: completedRangeIDs,
                partialDirectory: partialDirectory, temporaryPath: temporaryPath, audit: audit,
                progress: progress, commit: commit)
            return
        }
        // Parallel writes are permitted only after proving that every output
        // interval is disjoint, including transformed scale/bias destinations.
        try RangeCopyPlanner.validateDestinationIntervals(copies.flatMap(\.destinations), outputRoot: partialDirectory)
        let previous = try Posix.entryKind(temporaryPath)
        if previous == .regular { try FileManager.default.removeItem(atPath: temporaryPath) }
        else if previous != .absent { throw RepackError.configurationInvalid(detail: "unsafe stale range temporary") }
        let prefix = (temporaryPath as NSString).lastPathComponent + ".worker-"
        let parent = (temporaryPath as NSString).deletingLastPathComponent
        for name in try FileManager.default.contentsOfDirectory(atPath: parent) where name.hasPrefix(prefix) {
            let path = (parent as NSString).appendingPathComponent(name)
            guard try Posix.entryKind(path) == .regular else {
                throw RepackError.configurationInvalid(detail: "unsafe stale range temporary")
            }
            try FileManager.default.removeItem(atPath: path)
        }
        let pending = copies.filter { !completedRangeIDs.contains($0.id) }
        let reporting = Progress(progress)
        try await withThrowingTaskGroup(of: WorkResult.self) { group in
            var next = 0
            func submit(_ copy: CoalescedRangeCopy) {
                group.addTask { [self] in
                    let local = RepackAudit()
                    let completion = Mutex<RemoteCompletedRange?>(nil)
                    let path = temporaryPath + ".worker-" + UUID().uuidString
                    defer { try? FileManager.default.removeItem(atPath: path) }
                    try await copyBatchSerial([copy], completedRangeIDs: [], partialDirectory: partialDirectory,
                        temporaryPath: path, audit: local,
                        progress: { reporting.update(copy.id, bytes: $0) },
                        commit: { value in completion.withLock { $0 = value } })
                    guard let completed = completion.withLock({ $0 }) else {
                        throw RepackError.configurationInvalid(detail: "range completed without a checkpoint digest")
                    }
                    return WorkResult(completed: completed, sourceRead: local.sourceBytesRead,
                        outputWritten: local.outputBytesWritten, intentional: local.intentionalCopyBytes,
                        tiles: local.byteCopyTiles, largestScratch: local.largestScratchBytes,
                        largestTransfer: local.largestRemoteTransferBytes, largestHeap: local.largestRemotePayloadHeapBytes,
                        rangeRequests: local.remoteRangeRequests, downloaded: local.remoteBytesDownloaded,
                        rangeRetries: local.remoteRangeRetries, retries: local.remoteRetries)
                }
            }
            while next < min(concurrentTransfers, pending.count) { submit(pending[next]); next += 1 }
            while let result = try await group.next() {
                try Task.checkCancellation()
                // Only this parent writes the checkpoint and shared audit. A
                // failed worker leaves its range uncommitted and safe to resume.
                try commit(result.completed)
                reporting.committed()
                audit.sourceBytesRead += result.sourceRead
                audit.outputBytesWritten += result.outputWritten
                audit.intentionalCopyBytes += result.intentional
                audit.byteCopyTiles += result.tiles
                audit.largestScratchBytes = max(audit.largestScratchBytes, result.largestScratch)
                audit.largestRemoteTransferBytes = max(audit.largestRemoteTransferBytes, result.largestTransfer)
                audit.largestRemotePayloadHeapBytes = max(audit.largestRemotePayloadHeapBytes, result.largestHeap)
                audit.remoteRangeRequests += result.rangeRequests
                audit.remoteBytesDownloaded += result.downloaded
                audit.remoteRangeRetries += result.rangeRetries
                audit.remoteRetries += result.retries
                if next < pending.count { submit(pending[next]); next += 1 }
            }
        }
    }

    private func copyBatchSerial(
        _ copies: [CoalescedRangeCopy],
        completedRangeIDs: Set<String>,
        partialDirectory: String,
        temporaryPath: String,
        audit: RepackAudit,
        progress: @escaping @Sendable (UInt64) -> Void,
        commit: (RemoteCompletedRange) throws -> Void
    ) async throws {
        let scratch = UnsafeMutableRawBufferPointer.allocate(
            byteCount: writeTileBytes,
            alignment: 16_384)
        defer { scratch.deallocate() }
        audit.largestScratchBytes = max(audit.largestScratchBytes, scratch.count)

        var outputFDs: [String: Int32] = [:]
        defer { outputFDs.values.forEach { close($0) } }
        var downloaded: UInt64 = 0

        for copy in copies where !completedRangeIDs.contains(copy.id) {
            try Task.checkCancellation()
            guard let info = files[copy.shardID] else {
                throw RepackError.configurationInvalid(
                    detail: "missing remote info for \(copy.shardID)")
            }
            if try Posix.entryKind(temporaryPath) != .absent {
                try FileManager.default.removeItem(atPath: temporaryPath)
            }
            let base = downloaded
            let temporary = try await remote.downloadRangeToTempFile(
                filename: copy.shardID,
                info: info,
                offset: copy.sourceOffset,
                length: Int(copy.size),
                targetPath: temporaryPath,
                progress: { bytes in progress(base + bytes) },
                audit: audit)

            audit.remoteRangeRequests += 1
            audit.remoteBytesDownloaded += temporary.byteCount
            audit.largestRemoteTransferBytes = max(
                audit.largestRemoteTransferBytes,
                Int(temporary.byteCount))
            downloaded += temporary.byteCount
            progress(downloaded)

            let sourceFD = try Posix.openReadNoFollow(temporary.path)
            var touched = Set<String>()
            do {
                for destination in copy.destinations {
                    let destinationFD: Int32
                    if let existing = outputFDs[destination.destinationPath] {
                        destinationFD = existing
                    } else {
                        destinationFD = try Posix.openExistingRW(
                            destination.destinationPath)
                        outputFDs[destination.destinationPath] = destinationFD
                    }
                    touched.insert(destination.destinationPath)
                    try copyBytes(
                        sourceFD: sourceFD,
                        sourcePath: temporary.path,
                        destinationFD: destinationFD,
                        destinationPath: destination.destinationPath,
                        sourceOffset: destination.sourceOffset - copy.sourceOffset,
                        destinationOffset: destination.destinationOffset,
                        size: destination.size,
                        transform: destination.transform,
                        scratch: scratch,
                        audit: audit)
                }
                close(sourceFD)
            } catch {
                close(sourceFD)
                throw error
            }

            try Task.checkCancellation()
            for path in touched {
                if let descriptor = outputFDs[path] {
                    try Posix.fsync(descriptor, path: path)
                }
            }
            let digest = try Self.destinationDigest(
                copy,
                partialDirectory: partialDirectory,
                scratch: scratch)
            try commit(RemoteCompletedRange(
                id: copy.id,
                destinationDigest: digest,
                sourceBytes: copy.size,
                destinationBytes: copy.destinations.reduce(0) { $0 + $1.destinationSize }))
            progress(downloaded)
            try? FileManager.default.removeItem(atPath: temporary.path)
            try Task.checkCancellation()
        }
    }

    public static func destinationDigest(
        _ copy: CoalescedRangeCopy,
        partialDirectory: String,
        scratch suppliedScratch: UnsafeMutableRawBufferPointer? = nil
    ) throws -> String {
        let scratch = suppliedScratch ?? UnsafeMutableRawBufferPointer.allocate(
            byteCount: WriterCore.tileBytes,
            alignment: 16_384)
        defer {
            if suppliedScratch == nil { scratch.deallocate() }
        }

        var digest = DestinationDigest(copy: copy)
        for destination in copy.destinations {
            digest.append(try RangeCopyPlanner.normalizedRelativePath(
                destination.destinationPath,
                root: partialDirectory))
            digest.append(destination.destinationOffset)
            digest.append(destination.sourceOffset - copy.sourceOffset)
            digest.append(destination.size)
            if destination.transform != .identity {
                digest.append(UInt64(destination.transform.rawValue))
            }

            let descriptor = try Posix.openReadNoFollow(destination.destinationPath)
            defer { close(descriptor) }
            var remaining = destination.destinationSize
            var offset = destination.destinationOffset
            while remaining > 0 {
                let count = min(Int(remaining), scratch.count)
                try Posix.preadAll(
                    fd: descriptor,
                    path: destination.destinationPath,
                    buf: scratch.baseAddress!,
                    count: count,
                    offset: offset)
                digest.append(UnsafeRawBufferPointer(
                    start: scratch.baseAddress,
                    count: count))
                remaining -= UInt64(count)
                offset += UInt64(count)
            }
        }
        return digest.finalize()
    }

    private func copyBytes(
        sourceFD: Int32,
        sourcePath: String,
        destinationFD: Int32,
        destinationPath: String,
        sourceOffset: UInt64,
        destinationOffset: UInt64,
        size: UInt64,
        transform: RangeCopyTransform,
        scratch: UnsafeMutableRawBufferPointer,
        audit: RepackAudit
    ) throws {
        var remaining = size
        var source = sourceOffset
        var destination = destinationOffset
        while remaining > 0 {
            try Task.checkCancellation()
            let alignment = Int(transform.sourceAlignment)
            guard scratch.count >= alignment, remaining.isMultiple(of: transform.sourceAlignment) else {
                throw RepackError.configurationInvalid(detail: "conversion tile is not aligned")
            }
            let count = min(Int(remaining), scratch.count) / alignment * alignment
            try Posix.preadAll(
                fd: sourceFD,
                path: sourcePath,
                buf: scratch.baseAddress!,
                count: count,
                offset: source)
            let outputCount = try WriterCore.convertInPlace(scratch.baseAddress!, byteCount: count, transform: transform)
            try Posix.pwriteAll(
                fd: destinationFD,
                path: destinationPath,
                buf: scratch.baseAddress!,
                count: outputCount,
                offset: destination)
            audit.recordTile(bytes: count)
            audit.recordRead(bytes: count)
            audit.recordWrite(bytes: outputCount)
            remaining -= UInt64(count)
            source += UInt64(count)
            destination += UInt64(outputCount)
        }
    }
}

private struct DestinationDigest {
    private var stream = Sha256Stream()

    init(copy: CoalescedRangeCopy) {
        // Pre-v3 spelling on purpose: this domain is hashed into digests a
        // resumed download compares against. See `RangeCopyPlanner`.
        append("TurboFieldfare.RemoteRangeDestination.v1")
        append(copy.id)
        append(UInt64(copy.destinations.count))
    }

    mutating func append(_ value: UInt64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { stream.update($0) }
    }

    mutating func append(_ value: String) {
        let data = Data(value.utf8)
        append(UInt64(data.count))
        data.withUnsafeBytes { stream.update($0) }
    }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        stream.update(bytes)
    }

    func finalize() -> String {
        stream.finalizeHexString()
    }
}
