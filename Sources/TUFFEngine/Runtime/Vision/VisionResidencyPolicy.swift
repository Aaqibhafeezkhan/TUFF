public typealias VisionResidencyPolicy = TUFFRuntimeDescriptions.VisionResidencyPolicy

public struct VisionExpertResidencyTransition: Sendable, Equatable {
    public let policy: VisionResidencyPolicy
    public let gpuDrainNanoseconds: UInt64
    public let releasedLayerCount: Int
    public let releasedSlotScratchBytes: UInt64
    public let remainingOpenLayerCount: Int
    public let remainingSlotScratchBytes: UInt64
    public let wallNanoseconds: UInt64
}
