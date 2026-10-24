import Foundation
import TUFFModelMetadata
import TUFFRuntimeDescriptions

extension MetalKernelGroup {
    /// The groups loading `modelDirectory` will ask for, read from its
    /// manifest without touching the weights. Nil when the manifest can't be
    /// read; the load itself reports why.
    public static func predicted(forModelDirectory modelDirectory: URL, maxContext: Int,
                                 includeVision: Bool) -> Set<MetalKernelGroup>? {
        guard let architecture = try? ManifestReader.resolveArchitecture(directoryURL: modelDirectory),
              let manifest = try? ManifestReader.load(directoryURL: modelDirectory, expecting: architecture)
        else { return nil }
        var groups = required(for: architecture,
            sharedExpertWeightBits: manifest.quant?.sharedExpert.weightBits ?? 8, maxContext: maxContext)
        if includeVision,
           let pack = try? VisionPackLocation.companionURL(forTextModel: modelDirectory),
           FileManager.default.fileExists(atPath: pack.path) {
            groups.insert(.vision)
        }
        return groups
    }
}

extension MetalContext {
    /// Compiles `groups` on another thread, so the shader compiler runs while
    /// the tokenizer and weights load. A runner that needs one of them waits
    /// on the library lock instead of compiling it again. One group at a time,
    /// so a runner isn't held behind the vision group it doesn't need. A
    /// failure is left for that runner to hit and report.
    public func prepareKernelGroupsInBackground(_ groups: Set<MetalKernelGroup>) {
        guard !groups.isSubset(of: compiledKernelGroups) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for group in groups.sorted() { try? prepareKernelGroups([group]) }
        }
    }

    /// Starts the predicted groups for `modelDirectory` compiling.
    public func prewarmKernels(forModelDirectory modelDirectory: URL, maxContext: Int,
                               includeVision: Bool) {
        guard let groups = MetalKernelGroup.predicted(forModelDirectory: modelDirectory,
            maxContext: maxContext, includeVision: includeVision) else { return }
        prepareKernelGroupsInBackground(groups)
    }
}
