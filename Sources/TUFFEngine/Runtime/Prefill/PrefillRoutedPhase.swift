import Foundation

/// Steps of one layer's routed MoE prefill phase, in the order they happen.
/// `RealForwardRunner.routedPhaseObserver` reports them so tests can check
/// the shared-expert schedule and inject a failure at any step.
enum PrefillRoutedPhaseStep: Equatable, Sendable {
    case sharedSubmitted(layer: Int)
    case metadataPrepared(layer: Int)
    case fetchStarting(layer: Int, tile: Int)
    /// The tile's experts are fetched and its binding validated; its argument
    /// buffer and command buffer come next.
    case tileBound(layer: Int, tile: Int)
    case sharedJoined(layer: Int)
    case tileDispatched(layer: Int, tile: Int)
    case tileJoined(layer: Int, tile: Int)
    /// Failure cleanup joined this many buffers that were still submitted.
    case drainedAfterFailure(layer: Int, buffers: Int)
}

/// Joins the GPU work a failed routed phase left submitted.
///
/// Each join waits for its command buffer and then checks its error, so a
/// join that throws has still completed. Cleanup therefore runs every join
/// even after one fails: stopping early would leave a later buffer reading
/// prefill scratch, expert slots or argument buffers that the runner is about
/// to reuse. The caller reports its own original error, not these.
enum PrefillSubmittedWorkDrain {
    @discardableResult
    static func joinAll(_ joins: [() throws -> Void]) -> [Error] {
        var failures: [Error] = []
        for join in joins {
            do {
                try join()
            } catch {
                failures.append(error)
            }
        }
        return failures
    }
}
