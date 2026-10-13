import Foundation
import Testing
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
}
