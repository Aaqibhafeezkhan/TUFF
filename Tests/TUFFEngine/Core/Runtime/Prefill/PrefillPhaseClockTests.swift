import Metal
import Testing
@testable import TUFFEngine

/// Prompt reading timed by phase: each command buffer is counted once, where
/// it is waited on, under the phase its label names.
@Suite struct PrefillPhaseClockTests {
    func finished(_ label: String) throws -> MTLCommandBuffer {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let commandBuffer = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        commandBuffer.label = label
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer
    }

    @Test func labelsDecideThePhaseAndOnlyActivePrefillCounts() throws {
        var clock = PrefillPhaseClock()
        clock.waited(try finished("prefill layer=0 phase=attention"), wallNanos: 1_000_000)
        #expect(clock.times == PrefillPhaseTimes())

        clock.active = true
        clock.waited(try finished("prefill layer=0 phase=attention"), wallNanos: 2_000_000)
        clock.waited(try finished("prefill layer=0 phase=shared_expert"), wallNanos: 0)
        clock.waited(try finished("prefill layer=0 phase=routed_tile"), wallNanos: 0)
        clock.waited(try finished("prefill phase=final_head"), wallNanos: 0)
        clock.expertRead(nanos: 3_000_000)
        #expect(clock.times.gpuWait == 0.002)
        #expect(clock.times.expertReadWait == 0.003)
        #expect(clock.times.attentionGPU >= 0)
        let keys = Set(clock.times.timingSeconds.keys)
        #expect(keys == ["prefill_attention_gpu", "prefill_shared_expert_gpu",
                         "prefill_routed_expert_gpu", "prefill_other_gpu",
                         "prefill_expert_read_wait", "prefill_gpu_wait"])
    }
}
