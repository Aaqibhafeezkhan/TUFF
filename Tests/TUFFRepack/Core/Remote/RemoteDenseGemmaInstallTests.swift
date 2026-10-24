import Foundation
import TUFFModelMetadata
import Testing
@testable import TUFFRepackCore

extension RemotePayloadCopyTests {
    @Test func denseGemmaRemoteInstallOmitsExpertArtifactsAndVerifies() async throws {
        let snapshotDir = tmpDirForRemote("e4b-snap")
        let output = tmpPathForRemote("e4b-output")
        defer { cleanUpRemote([snapshotDir, output]) }
        let snapshot = try SyntheticSnapshot.buildDenseGemmaE4B(at: snapshotDir)

        resetFakeHF()
        FakeHFURLProtocol.files = try remoteFiles(
            snapshotDir: snapshotDir,
            snap: snapshot,
            includeRequiredTokenizer: true,
            includeOptionalTokenizer: true)
        let result = try await RemoteStreamingRepacker(options: remoteOptions(
            outputDir: output,
            session: fakeHFSession())).run()

        #expect(result.plan.arch.feedForwardKind == .dense)
        #expect(result.plan.layers.isEmpty)
        #expect(FileManager.default.fileExists(atPath:
            (output as NSString).appendingPathComponent("model_weights.bin")))
        #expect(!FileManager.default.fileExists(atPath:
            (output as NSString).appendingPathComponent("packed_experts")))
        let manifestData = try Data(contentsOf: URL(fileURLWithPath:
            (output as NSString).appendingPathComponent("manifest.json")))
        let manifest = try JSONSerialization.jsonObject(with: manifestData)
            as! [String: Any]
        let flags = manifest["flags"] as! [String: Bool]
        #expect(manifest["versionMinor"] as? Int == 1)
        #expect(flags["denseFFN"] == true)

        let verification = try VerifiedInstallTool.run(
            options: VerifyInstallOptions(inputGTurbo: output))
        #expect(verification.unexpectedEntries.isEmpty)
        #expect(verification.bytesVerified > 0)
    }

    /// The install records each file it hashed, so the engine's first load
    /// of the model finds the same file unchanged and doesn't hash it again.
    @Test func installRecordsTheFilesItHashed() async throws {
        let snapshotDir = tmpDirForRemote("memo-snap")
        let output = tmpPathForRemote("memo-output")
        let memoDirectory = URL(fileURLWithPath: tmpDirForRemote("memo-records"))
        defer { cleanUpRemote([snapshotDir, output, memoDirectory.path]) }
        let snapshot = try SyntheticSnapshot.buildDenseGemmaE4B(at: snapshotDir)
        resetFakeHF()
        FakeHFURLProtocol.files = try remoteFiles(snapshotDir: snapshotDir, snap: snapshot,
            includeRequiredTokenizer: true, includeOptionalTokenizer: true)
        _ = try await RemoteStreamingRepacker(options: remoteOptions(outputDir: output,
            session: fakeHFSession(), verifiedFileMemo: VerifiedFileMemo(directory: memoDirectory))).run()

        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:
            (output as NSString).appendingPathComponent("manifest.json")))) as! [String: Any]
        let files = try #require(manifest["files"] as? [String: [String: Any]])
        let weights = try #require(files["model_weights.bin"]?["sha256"] as? String)
        for (path, entry) in files {
            let sha = try #require(entry["sha256"] as? String)
            let record = memoDirectory.appendingPathComponent("\(sha.lowercased()).json")
            let recorded = try JSONDecoder().decode(VerifiedFileMemo.Identity.self, from: Data(contentsOf: record))
            let fd = open((output as NSString).appendingPathComponent(path), O_RDONLY)
            try #require(fd >= 0)
            defer { close(fd) }
            #expect(VerifiedFileMemo.Identity(fileDescriptor: fd) == recorded, "\(path) changed after it was recorded")
        }
        #expect(files.keys.contains("model_weights.bin") && !weights.isEmpty)
    }
}
