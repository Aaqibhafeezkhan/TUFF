import Foundation

/// Whether ordinary MoE prefill lets the shared expert run on the GPU while
/// the routed phase builds its metadata and fetches its first expert tile.
///
/// Off unless `TUFF_SHARED_EXPERT_OVERLAP=on` when the runner is created, and
/// only for Gemma 4 26B-A4B and Qwen3.8 Flash Next. Speculative verification
/// always keeps the serialized schedule. The switch exists so the same binary
/// can be measured with both schedules; it is not an app setting.
public struct SharedExpertOverlapPolicy: Sendable, Equatable {
    public static let environmentKey = "TUFF_SHARED_EXPERT_OVERLAP"
    static let qualifiedVariants: Set<ModelVariant> = [.gemma4_26B_A4B, .qwen38FlashNext]

    public let enabled: Bool

    public static let disabled = SharedExpertOverlapPolicy(enabled: false)

    /// Tests use this to exercise the schedule on toy architectures.
    init(enabled: Bool) {
        self.enabled = enabled
    }

    public init(environment: [String: String], variant: ModelVariant) {
        self.enabled = environment[Self.environmentKey] == "on"
            && Self.qualifiedVariants.contains(variant)
    }

    /// The value a run reports in its resolved settings.
    public static func resolvedSetting(environment: [String: String],
                                       variant: ModelVariant) -> String {
        guard environment[environmentKey] == "on" else { return "off" }
        return qualifiedVariants.contains(variant) ? "on" : "off (model not qualified)"
    }

    func admits(speculativeVerification: Bool) -> Bool {
        enabled && !speculativeVerification
    }
}
