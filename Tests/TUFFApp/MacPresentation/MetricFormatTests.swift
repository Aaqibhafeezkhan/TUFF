import Testing
@testable import TUFFMacPresentation

@MainActor
@Suite struct MetricFormatTests {
    @Test func memoryClampsUnsignedCountsBeyondSignedRange() {
        #expect(MetricFormat.memory(UInt64.max) == MetricFormat.memory(UInt64(Int64.max)))
        #expect(MetricFormat.memory(UInt64.max).contains("-") == false)
    }
}
