import Foundation
import TUFFEngine

/// Backend subspans. Rendering includes template evaluation and tokenization;
/// cache lookup includes any continuation bridge encoding. Parent spans in
/// ServerRequestTimings contain these values and must not be summed with them.
struct ServerInferencePhaseTimings: Sendable {
    private(set) var seconds: [String: Double]

    init(_ seconds: [String: Double] = [:]) { self.seconds = seconds }

    mutating func record(_ phase: String, since start: UInt64,
                         through end: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        seconds[phase, default: 0] += Double(end >= start ? end - start : 0) / 1e9
    }

    mutating func recordCachePlan(_ statistics: ConversationStateStore.Statistics) {
        seconds["cache_lookup_and_bridge"] = statistics.lastLookupSeconds ?? 0
        seconds["cache_capture"] = statistics.lastCaptureSeconds ?? 0
        seconds["cache_restore"] = statistics.lastRestoreSeconds ?? 0
    }
}
