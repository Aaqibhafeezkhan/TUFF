import Darwin
import Metal

/// Where reading a prompt spends its time, in seconds. GPU spans come from
/// each command buffer's own start and end, so they overlap the CPU spans and
/// each other: expert reads run while earlier tiles compute. Don't add them.
public struct PrefillPhaseTimes: Sendable, Equatable {
    /// Attention, norms and routing; for a dense model, the whole layer.
    public var attentionGPU = 0.0
    public var sharedExpertGPU = 0.0
    public var routedExpertGPU = 0.0
    /// Reducing routed outputs, layer tails, embeddings and the final head.
    public var otherGPU = 0.0
    /// Waiting for routed experts to be read from the SSD.
    public var expertReadWait = 0.0
    /// The CPU waiting for submitted GPU work to finish.
    public var gpuWait = 0.0

    public init() {}

    public static func - (lhs: Self, rhs: Self) -> Self {
        var value = Self()
        value.attentionGPU = lhs.attentionGPU - rhs.attentionGPU
        value.sharedExpertGPU = lhs.sharedExpertGPU - rhs.sharedExpertGPU
        value.routedExpertGPU = lhs.routedExpertGPU - rhs.routedExpertGPU
        value.otherGPU = lhs.otherGPU - rhs.otherGPU
        value.expertReadWait = lhs.expertReadWait - rhs.expertReadWait
        value.gpuWait = lhs.gpuWait - rhs.gpuWait
        return value
    }

    /// The fields as the server reports them in `tuff_timings_seconds`.
    public var timingSeconds: [String: Double] {
        ["prefill_attention_gpu": attentionGPU,
         "prefill_shared_expert_gpu": sharedExpertGPU,
         "prefill_routed_expert_gpu": routedExpertGPU,
         "prefill_other_gpu": otherGPU,
         "prefill_expert_read_wait": expertReadWait,
         "prefill_gpu_wait": gpuWait]
    }
}

/// A runner whose prompt reading is timed by phase. Totals since the runner
/// was created; a caller takes the difference across one prefill.
public protocol PrefillPhaseReporting: AnyObject {
    var prefillPhaseTimes: PrefillPhaseTimes { get }
}

/// Accumulates `PrefillPhaseTimes` while a prompt is read. Every prefill
/// command buffer is waited on once, so it is counted where it is waited on,
/// by the `phase=` in its label.
struct PrefillPhaseClock {
    private(set) var times = PrefillPhaseTimes()
    var active = false

    mutating func waited(_ commandBuffer: MTLCommandBuffer, wallNanos: UInt64) {
        guard active else { return }
        times.gpuWait += Double(wallNanos) / 1e9
        let gpu = max(0, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
        let label = commandBuffer.label ?? ""
        if label.contains("phase=attention") || label.contains("phase=embed_attention") {
            times.attentionGPU += gpu
        } else if label.contains("phase=shared_expert") {
            times.sharedExpertGPU += gpu
        } else if label.contains("phase=routed_tile") {
            times.routedExpertGPU += gpu
        } else {
            times.otherGPU += gpu
        }
    }

    mutating func expertRead(nanos: UInt64) {
        guard active else { return }
        times.expertReadWait += Double(nanos) / 1e9
    }
}
