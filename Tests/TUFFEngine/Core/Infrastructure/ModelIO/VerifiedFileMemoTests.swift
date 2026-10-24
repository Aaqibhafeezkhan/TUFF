import Darwin
import Foundation
import Testing
@testable import TUFFEngine
import TUFFModelMetadata

@Suite struct VerifiedFileMemoTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuff-verified-memo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func verify(_ memo: VerifiedFileMemo, _ file: URL, _ hex: String) throws {
        let fd = open(file.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        try memo.verifyFile(fileDescriptor: fd, named: file.lastPathComponent, expectedHex: hex)
    }

    @Test func recordsAPassAndHashesAgainAfterAWrite() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let memo = VerifiedFileMemo(directory: root.appendingPathComponent("memo"))
        let file = root.appendingPathComponent("weights.bin")
        try Data("weights".utf8).write(to: file)
        let hex = try Sha256Verifier.hashFile(at: file)

        try verify(memo, file, hex)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("memo/\(hex).json").path))

        // Same size, different bytes: the record no longer describes the file.
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("WEIGHTS".utf8))
        try handle.close()
        #expect(throws: ModelError.self) { try verify(memo, file, hex) }
    }

    @Test func aMatchingRecordSkipsTheRead() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let memoDirectory = root.appendingPathComponent("memo")
        let memo = VerifiedFileMemo(directory: memoDirectory)
        let file = root.appendingPathComponent("weights.bin")
        try Data("weights".utf8).write(to: file)

        // A record for a hash the bytes don't have. Passing proves no read.
        let wrong = String(repeating: "a", count: 64)
        let fd = open(file.path, O_RDONLY)
        try #require(fd >= 0)
        let identity = try #require(VerifiedFileMemo.Identity(fileDescriptor: fd))
        close(fd)
        try FileManager.default.createDirectory(at: memoDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(identity).write(to: memoDirectory.appendingPathComponent("\(wrong).json"))
        try verify(memo, file, wrong)

        // Without the memo the same check reads the file and fails.
        #expect(throws: ModelError.self) { try verify(VerifiedFileMemo(directory: nil), file, wrong) }
    }

    @Test func aFailedCheckRecordsNothing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let memoDirectory = root.appendingPathComponent("memo")
        let file = root.appendingPathComponent("weights.bin")
        try Data("weights".utf8).write(to: file)
        let wrong = String(repeating: "b", count: 64)
        #expect(throws: ModelError.self) {
            try verify(VerifiedFileMemo(directory: memoDirectory), file, wrong)
        }
        #expect(!FileManager.default.fileExists(atPath: memoDirectory.appendingPathComponent("\(wrong).json").path))
    }

    @Test func theSwitchTurnsItOff() {
        #expect(VerifiedFileMemo.defaultDirectory(environment: ["TUFF_VERIFIED_FILE_MEMO": "off"]) == nil)
        let scoped = VerifiedFileMemo.defaultDirectory(environment: ["TUFF_APPLICATION_SUPPORT_ROOT": "/tmp/scoped"])
        #expect(scoped?.path == "/tmp/scoped/TUFF/Caches/TUFF/VerifiedFiles")
    }
}
