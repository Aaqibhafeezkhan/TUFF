import AppKit
import Foundation
import Testing
import TUFFInferenceTypes
import TUFFModelCatalog
import TUFFRuntimeDescriptions
@testable import TUFFAppCore

/// Image prompts run under chunked prefill, which needs 16 expert slots. Auto
/// used to settle on 8 after a run paged, and an image then failed partway
/// through its prompt with "prefill routed tile depth 1 with 8 experts/tile
/// needs 16 slots, has 8".
@Suite(.serialized) struct AppImageExpertCacheTests {
    private var device: TUFFDeviceCapabilities {
        .init(unifiedMemoryBytes: 16 << 30, macOSMajorVersion: 26, appleSiliconGeneration: 2)
    }

    /// What happened with Ornith 1.5 122B on a 16 GB M2: the first plan paged,
    /// so Auto chose 8 slots for text. An image workload keeps 16.
    @Test func anImageWorkloadKeepsEnoughSlotsAfterPaging() throws {
        let descriptor = AppModelInstallDescriptor(catalog: TUFFModelCatalog.ornith15_122B)
        let summary = try #require(AppAutomaticMemoryPlanner.predictedLayout(for: descriptor))
        let first = try #require(AppAutomaticMemoryPlanner.plan(for: descriptor, on: device,
            profile: .speed, layoutSummary: summary, observations: [], workloadKey: "fixture",
            contextTokens: 4_096))
        #expect(first.expertCacheSlots >= 16)
        let paged = InferencePlanObservation(candidateID: try #require(first.candidateID), workloadKey: "fixture",
            decodeTokens: 92, decodeSeconds: 56, timeToFirstTokenSeconds: 31,
            swapGrowthBytes: 4_873_977_856)
        let text = try #require(AppAutomaticMemoryPlanner.plan(for: descriptor, on: device,
            profile: .speed, layoutSummary: summary, observations: [paged], workloadKey: "fixture",
            contextTokens: 4_096))
        #expect(text.expertCacheSlots < 16, "the fixture no longer reproduces the fallback")
        let image = try #require(AppAutomaticMemoryPlanner.plan(for: descriptor, on: device,
            profile: .speed, layoutSummary: summary, observations: [paged], workloadKey: "fixture",
            contextTokens: 4_096, imageInput: true))
        #expect(image.expertCacheSlots >= RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill)
    }

    private func withVisionEnabled<T>(_ body: () throws -> T) rethrows -> T {
        let previous = ProcessInfo.processInfo.environment["TUFF_VISION_RUNTIME"]
        setenv("TUFF_VISION_RUNTIME", "1", 1)
        defer {
            if let previous { setenv("TUFF_VISION_RUNTIME", previous, 1) } else { unsetenv("TUFF_VISION_RUNTIME") }
        }
        return try body()
    }

    private func writePNG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    /// A manual Slots setting is the user's: an image turn below 16 stops with
    /// a message that says what to change, before anything is sent.
    @MainActor
    @Test func aManualSmallCacheRefusesTheImageTurnUpFront() async throws {
        let directory = try makeVisionReadyModelInstall("image-slots")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-slots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: root)
        }
        // A scripted answer, so a run that wrongly went ahead would show up
        // as a finished turn rather than reach a real engine.
        let model = makeAppModel(modelDirectory: directory,
            client: ScriptedInferenceClient([ToolLoopFixtures.answer("Red.")]),
            attachmentStore: AppImageAttachmentStore(directoryURL: root.appendingPathComponent("staged")))
        #expect(model.selectedDescriptor.usesExpertCache)
        model.automaticMemory = false
        model.runtimeOptions.expertCacheSlots = 8
        model.runtimeOptions.prefillEnabled = false
        #expect(!model.imageTurnNeedsLargerExpertCache, "a text turn needs no change")

        let png = root.appendingPathComponent("red.png")
        try writePNG(to: png)
        withVisionEnabled { model.addImages([png]) }
        let deadline = Date().addingTimeInterval(5)
        while model.isAddingImages, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try #require(model.imageAttachments.count == 1)
        #expect(model.imageTurnNeedsLargerExpertCache)

        model.loadState = .ready(modelDirectory: directory, loadSeconds: 1)
        model.promptText = "What colour is this?"
        #expect(model.canRun)
        model.run()
        #expect(!model.isRunning)
        #expect(model.conversation.isEmpty)
        #expect(model.error.map { "\($0)" }?.contains("Raise Slots to 16") == true)

        model.runtimeOptions.expertCacheSlots = 16
        #expect(!model.imageTurnNeedsLargerExpertCache)
    }
}
