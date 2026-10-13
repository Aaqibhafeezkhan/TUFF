import Foundation
import Metal
import Testing
import TUFFValidationSupport
@testable import TUFFEngine

/// Optional, read-only numerical diagnostic for the installed Ornith 397B pack.
@Suite struct InstalledNumericalProbeTests {
    @Test func installedSingleTokenRemainsFinite() async throws {
        guard let path = ProcessInfo.processInfo.environment["TUFF_NUMERICAL_PROBE_MODEL"] else { return }
        let context = try MetalContext()
        let model = try Model.load(directoryURL: URL(fileURLWithPath: path), device: context.device,
            streamingMode: .pread(slotCount: 10), denseResidency: .bounded(residentLayers: []),
            integrityPolicy: .sizeCheckTrustedReceipt)
        try #require(model.config.variant == .ornith15_397B)
        let runner = try RealForwardRunner(model: model, context: context, maxContext: 64,
            runtimeConfiguration: RuntimeConfiguration(expertCacheSlots: 10, prefillEnabled: false,
                prefillChunkTokens: 32, forceLogitsHead: true))
        let logits = try #require(context.device.makeBuffer(length: model.config.vocabSize * 2,
            options: .storageModeShared))
        var firstBad: Int?
        runner.debugLayerSink = { layer in
            let values = Fp16Buffer.read(runner.debugResidual, count: model.config.hiddenSize)
            let finite = values.filter { $0.isFinite }
            print("PROBE layer \(layer): finite \(finite.count)/\(values.count), max \(finite.map { abs($0) }.max() ?? 0)")
            if finite.count != values.count && firstBad == nil { firstBad = layer }

        }
        try await runner.produce(token: 198, position: 0, into: logits)
        let values = Fp16Buffer.read(logits, count: model.config.vocabSize)
        print("PROBE logits finite \(values.filter { $0.isFinite }.count)/\(values.count)")
        #expect(firstBad == nil)
        #expect(values.allSatisfy { $0.isFinite })
    }
}
