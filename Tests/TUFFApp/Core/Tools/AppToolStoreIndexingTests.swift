import Foundation
import Testing
@testable import TUFFAppCore

@Suite(.serialized) @MainActor
struct AppToolStoreIndexingTests {
    @Test func restartingIndexingKeepsTheNewRunVisibleAndRemovingFoldersStopsIt() async throws {
        let box = try AppLocalSearchTests.sandbox()
        defer { box.cleanUp() }
        try box.write("notes.txt", "The lighthouse needs fresh paint.")
        let store = AppToolStore.inMemory(indexURL: box.root.deletingLastPathComponent()
            .appendingPathComponent("store.sqlite"))
        store.inferenceActivity.set(true)
        defer { store.stopIndexing(); store.inferenceActivity.set(false) }
        store.addFolders([box.root])
        try await waitUntil { store.isIndexing }
        store.reindex()
        try await waitUntil { store.isIndexing }
        // The cancelled run exits while its replacement is paused. Its final
        // callback must not hide the replacement's Stop Indexing control.
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.isIndexing)
        store.removeAllFolders()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!store.isIndexing)
        #expect(store.folders.isEmpty)
        #expect(store.folderStatus.isEmpty)
        // Adding the same folder immediately after clearing it must wait for
        // deletion, then repopulate the index rather than losing fresh rows.
        store.inferenceActivity.set(false)
        store.addFolders([box.root])
        let folderID = try #require(store.folders.first?.id)
        try await waitUntil { store.folderStatus[folderID]?.indexedFiles == 1 && !store.isIndexing }
        let results = try await store.makeToolbox(provider: .duckDuckGo).searchFiles("lighthouse", 3)
        #expect(results.count == 1)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Indexing did not start")
    }
}
