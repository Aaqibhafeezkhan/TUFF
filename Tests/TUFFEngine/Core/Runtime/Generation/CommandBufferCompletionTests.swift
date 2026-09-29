import Foundation
import Metal
import Testing

@testable import TUFFEngine

@Suite struct CommandBufferCompletionTests {
    private static func nsError(description: String,
                                userInfo extra: [String: Any] = [:]) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: description]
        info.merge(extra) { current, _ in current }
        return NSError(domain: "MTLCommandBufferErrorDomain", code: 1, userInfo: info)
    }

    @Test func completedBufferWithNoErrorIsNotAFailure() {
        #expect(metalCommandBufferFailureDetail(label: "prefill layer=3",
                                                status: .completed,
                                                error: nil) == nil)
    }

    @Test func errorStatusWithNoErrorObjectIsStillAFailure() throws {
        let detail = try #require(
            metalCommandBufferFailureDetail(label: "prefill layer=3",
                                            status: .error,
                                            error: nil))
        #expect(detail.contains("status=error"))
        #expect(detail.contains("label=prefill layer=3"))
        #expect(detail.contains("error=<none>"))
    }

    @Test(arguments: [
        MTLCommandBufferStatus.notEnqueued,
        .enqueued,
        .committed,
        .scheduled,
    ])
    func nonCompletedStatusIsAFailure(_ status: MTLCommandBufferStatus) throws {
        let detail = try #require(
            metalCommandBufferFailureDetail(label: nil, status: status, error: nil))
        #expect(detail.contains("status=\(metalCommandBufferStatusName(status))"))
    }

    @Test func completedStatusCarryingAnErrorIsAFailure() throws {
        let detail = try #require(
            metalCommandBufferFailureDetail(label: "x",
                                            status: .completed,
                                            error: Self.nsError(description: "boom")))
        #expect(detail.contains("status=completed"))
        #expect(detail.contains("description=boom"))
    }

    @Test func interactivityKillNamesTheLayerAndKeepsTheIOGPUToken() throws {
        let description = "Impacting Interactivity "
            + "(0000000e:kIOGPUCommandBufferCallbackErrorImpactingInteractivity)"
        let detail = try #require(
            metalCommandBufferFailureDetail(
                label: "prefill start=8064 count=128 layer=12 phase=attention",
                status: .error,
                error: Self.nsError(description: description)))
        #expect(detail.contains("kIOGPUCommandBufferCallbackErrorImpactingInteractivity"))
        #expect(detail.contains("domain=MTLCommandBufferErrorDomain"))
        #expect(detail.contains("code=1"))
        #expect(detail.contains("layer=12 phase=attention"))
    }

    @Test func absentAndEmptyLabelsAreDistinguished() throws {
        let absent = try #require(
            metalCommandBufferFailureDetail(label: nil, status: .error,
                                            error: Self.nsError(description: "boom")))
        let empty = try #require(
            metalCommandBufferFailureDetail(label: "", status: .error,
                                            error: Self.nsError(description: "boom")))
        #expect(absent.contains("label=<none>"))
        #expect(empty.contains("label=<empty>"))
    }

    @Test func userInfoKeysAreNamedButValuesAreNotIncluded() throws {
        let detail = try #require(
            metalCommandBufferFailureDetail(
                label: "x",
                status: .error,
                error: Self.nsError(description: "boom",
                                    userInfo: ["TUFFPayload": "do-not-include"])))
        #expect(detail.contains("TUFFPayload"))
        #expect(!detail.contains("do-not-include"))
    }

    @Test func aCompletedRealBufferPassesAndCarriesItsLabel() throws {
        let context = try MetalContext()
        let commandBuffer = try #require(context.queue.makeCommandBuffer())
        commandBuffer.label = "completion-smoke"
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try checkCommandBufferError(commandBuffer)
    }

    @Test func aBufferThatWasNeverCommittedIsReportedAsAFailure() throws {
        let context = try MetalContext()
        let commandBuffer = try #require(context.queue.makeCommandBuffer())
        commandBuffer.label = "never-committed"
        do {
            try checkCommandBufferError(commandBuffer)
            Issue.record("expected a failure for an uncommitted buffer")
        } catch let MetalError.commandBufferFailed(detail) {
            #expect(detail.contains("label=never-committed"))
            #expect(detail.contains("status=notEnqueued"))
        }
    }
}
