import Foundation
import Synchronization
import Testing
import TUFFModelCatalog
import TUFFRepackCore

@testable import TUFFAppCore

/// Deleting an installed model removes only that model's folder, and only
/// when nothing is downloading into it.
@Suite @MainActor struct ModelDeletionTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuff-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder that is not a complete install must not be deletable, so a
    /// stray click or a partial download can never remove files the user
    /// still needs.
    @Test func anUninstalledModelCannotBeDeleted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockModelInstallerClient()
        let coordinator = ModelInstallCoordinator(
            descriptor: .default,
            directoryURL: directory.appendingPathComponent("missing.gturbo"),
            client: client)

        #expect(!coordinator.isInstalled)
        #expect(!coordinator.canDeleteInstalled)
        try await coordinator.deleteInstalled()
        #expect(!client.removeInstalledCalled)
    }

    /// The real client removes the folder and nothing beside it.
    @Test func removeInstalledModelDeletesOnlyThatFolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.gturbo", isDirectory: true)
        let neighbour = root.appendingPathComponent("other.gturbo", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: model.appendingPathComponent("weights.bin"))

        try await RepackModelInstallerClient().removeInstalledModel(outputDirectory: model)

        #expect(!FileManager.default.fileExists(atPath: model.path))
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
    }

    /// A delete interrupted after the move leaves a hidden folder. The next
    /// delete of that model clears it, and a neighbour whose name merely
    /// starts the same way is left alone.
    @Test func removeInstalledModelClearsAnEarlierInterruptedDelete() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.gturbo", isDirectory: true)
        let stale = root.appendingPathComponent(".model.gturbo.deleting-earlier", isDirectory: true)
        let lookalike = root.appendingPathComponent(".model.gturbo2.deleting-other", isDirectory: true)
        for directory in [model, stale, lookalike] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try await RepackModelInstallerClient().removeInstalledModel(outputDirectory: model)

        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!left.contains("model.gturbo"))
        #expect(!left.contains { $0.hasPrefix(".model.gturbo.deleting-") })
        #expect(left.contains(".model.gturbo2.deleting-other"))
    }

    /// A symlink where the model belongs is refused, and whatever it points
    /// at survives.
    @Test func removeInstalledModelNeverFollowsASymlink() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("file"))
        let link = root.appendingPathComponent("model.gturbo")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        await #expect(throws: (any Error).self) {
            try await RepackModelInstallerClient().removeInstalledModel(outputDirectory: link)
        }
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("file").path))
    }

    /// Snapshots go with their model; other models' snapshots stay.
    @Test func prefixSnapshotsAreRemovedForThatModelOnly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["TUFF_APPLICATION_SUPPORT_ROOT": root.path]
        let mine = try #require(TUFFPrefixSnapshotLocation.modelDirectory(
            modelID: "gemma4-26b-a4b", environment: environment))
        let other = try #require(TUFFPrefixSnapshotLocation.modelDirectory(
            modelID: "qwen36-35b-a3b", environment: environment))
        for directory in [mine, other] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("9.0.3"), withIntermediateDirectories: true)
        }

        AppModelDeletionCleanup.removePrefixSnapshots(modelID: "gemma4-26b-a4b", environment: environment)

        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(mine.path.hasPrefix(root.path))
    }

    /// An identifier that would name the shared parent folder has no
    /// snapshot folder, so it can never take every model's snapshots.
    @Test func snapshotLocationRejectsParentNames() {
        for name in ["", ".", ".."] {
            #expect(TUFFPrefixSnapshotLocation.modelDirectory(modelID: name) == nil)
        }
    }

    /// Only a Background API holding this model is asked to unload, and a
    /// refusal (it is answering a request) keeps the model.
    @Test func releaseAsksOnlyTheServerHoldingTheModel() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TUFFResidencyRegistry(directory: root)
        let server = try registry.acquire(TUFFResidencyRecord(
            owner: .backgroundServer, modelID: "qwen36", estimatedBytes: 1, controlPort: 18_090))
        defer { server.release() }
        let asked = Mutex<[Int]>([])
        func residency(answer: Bool) -> AppResidencyCoordinator {
            AppResidencyCoordinator(registry: registry, budgetBytes: 1 << 40) { port in
                asked.withLock { $0.append(port) }
                return answer
            }
        }

        #expect(await AppModelDeletionCleanup.release("gemma4", from: residency(answer: false)))
        #expect(asked.withLock { $0 }.isEmpty)
        #expect(!(await AppModelDeletionCleanup.release("qwen36", from: residency(answer: false))))
        #expect(await AppModelDeletionCleanup.release("qwen36", from: residency(answer: true)))
        #expect(asked.withLock { $0 } == [18_090, 18_090])
    }

    /// When the Background API will not let go, nothing is deleted and the
    /// person is told why. When it does, the folder goes and cleanup runs.
    @Test func deleteWaitsForTheBackgroundAPI() async throws {
        for serverReleases in [false, true] {
            let qwenDirectory = try makeCompleteModelInstall("delete", stampedAs: .qwen36)
            defer { try? FileManager.default.removeItem(at: qwenDirectory) }
            let qwenClient = MockModelInstallerClient(descriptor: .qwen36)
            let qwen = ModelInstallCoordinator(
                descriptor: .qwen36, directoryURL: qwenDirectory, client: qwenClient)
            let cleaned = Mutex<[String]>([])
            let gemmaRoot = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: gemmaRoot) }
            let model = makeAppModel(
                modelDirectory: gemmaRoot.appendingPathComponent("gemma.gturbo"),
                installer: MockModelInstallerClient(descriptor: .default),
                otherInstalls: [qwen],
                deletionCleanup: AppModelDeletionCleanup(
                    releaseFromBackgroundAPI: { _ in serverReleases },
                    afterDeletion: { descriptor in cleaned.withLock { $0.append(descriptor.id) } }))
            #expect(model.canDeleteInstalledModel(qwen))

            model.deleteInstalledModel(qwen)
            #expect(!model.canDeleteInstalledModel(qwen))
            let deadline = ContinuousClock.now + .seconds(5)
            while !model.deletingModelIDs.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(model.deletingModelIDs.isEmpty)
            #expect(qwenClient.removeInstalledCalled == serverReleases)
            #expect(cleaned.withLock { $0 } == (serverReleases ? [qwen.id] : []))
            #expect((model.error != nil) == !serverReleases)
        }
    }
}
