import Foundation
import Darwin
import TUFFAppCore
import TUFFModelMetadata
import TUFFModelCatalog

struct Report: Codable {
    let sourceIndexSHA256: String
    let layout: ModelWeightLayoutSummary
    let plans: [String: AppAutomaticMemoryPlan]
}
do {
    guard CommandLine.arguments.count == 2 else {
        throw CocoaError(.fileReadInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "usage: TUFFModelPlan <model.gturbo>"])
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let summary = try ModelWeightLayoutSummary.read(directory: directory)
    guard let model = TUFFModelCatalog.model(manifestModelID: summary.modelID),
          model.architecture.id.rawValue == summary.architectureID else { throw CocoaError(.fileReadCorruptFile) }
    struct Source: Decodable { let sourceSnapshotHash: String? }
    let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    guard source.sourceSnapshotHash == "sha256:" + model.source.sourceIndexSHA256 else { throw CocoaError(.fileReadCorruptFile) }
    let descriptor = AppModelInstallDescriptor(catalog: model)
    var plans: [String: AppAutomaticMemoryPlan] = [:]
    for profile in AppAutomaticMemoryProfile.allCases {
        plans[profile.rawValue] = AppAutomaticMemoryPlanner.plan(for: descriptor,
            on: .current(), profile: profile, layoutSummary: summary)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let report = Report(sourceIndexSHA256: model.source.sourceIndexSHA256, layout: summary, plans: plans)
    FileHandle.standardOutput.write(try encoder.encode(report))
    print("")
} catch {
    FileHandle.standardError.write(Data("model planning failed: \(error)\n".utf8))
    exit(1)
}
