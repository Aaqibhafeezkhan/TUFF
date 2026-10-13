import Foundation
import TUFFInferenceTypes
import TUFFModelMetadata

public extension RemoteStreamingRepackResult {
    /// Exact destination layout counts from bounded source metadata, before a
    /// weight download. Zero hashes mean an uninstalled source plan, not verified
    /// output bytes. Installed packs replace this with their actual hashes.
    var weightLayoutSummary: ModelWeightLayoutSummary {
        let supportsStaging = plan.arch.family != .gptOss
        var fixed: UInt64 = 0
        var layers = Array(repeating: UInt64(0), count: plan.arch.numLayers)
        var staging = layers
        let page: UInt64 = 16_384
        for entry in plan.resident.entries {
            let present = [(entry.fileOffset, entry.sizeBytes), (entry.scaleOffset, entry.scaleSize),
                           (entry.biasOffset, entry.biasSize)].filter { $0.1 > 0 }
            guard let start = present.map(\.0).min(), let end = present.map({ $0.0 + $0.1 }).max() else { continue }
            let bytes = end - start
            let mapped = (bytes + start % page + page - 1) / page * page
            let prefix = "language_model.model.layers."
            let layer = entry.name.hasPrefix(prefix)
                ? Int(entry.name.dropFirst(prefix.count).split(separator: ".").first ?? "") : nil
            if supportsStaging, let layer, layers.indices.contains(layer) {
                layers[layer] += mapped
                staging[layer] = (staging[layer] + 255) / 256 * 256 + bytes
            } else { fixed += mapped }
        }
        let experts: [InferenceWeightLayout.ExpertLayer] = plan.layers.filter { $0.expertsPerLayer > 0 }.map {
            .init(bytesPerExpert: $0.expertStride, expertCount: $0.expertsPerLayer,
                  minimumSlots: plan.arch.topKExperts)
        }
        var rows: [InferenceWeightLayout.RowAccessTable] = []
        if let table = plan.ngramTable {
            rows.append(.init(bytesPerRow: UInt64(table.rowWidth / 2 + table.rowWidth / table.groupSize * 4),
                rowCount: Int(table.rowCount), maximumRowsPerToken: plan.arch.ngramHeads))
        }
        let layout = InferenceWeightLayout(fixedResidentBytes: fixed,
            denseGroupBytes: supportsStaging ? layers : [], expertLayers: experts, rowAccessTables: rows)
        return ModelWeightLayoutSummary(schemaVersion: 1, modelID: plan.matchedModelID ?? "unknown/snapshot",
            architectureID: plan.arch.variant.rawValue, manifestSHA256: String(repeating: "0", count: 64),
            weightsSHA256: String(repeating: "0", count: 64), layout: layout,
            packedResidentPayloadBytes: plan.resident.residentSize, minimumDenseStagingBytes: staging.max() ?? 0)
    }
}
