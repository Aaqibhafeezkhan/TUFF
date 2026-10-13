import Foundation

public enum StopReason: Sendable, Equatable {
    case eos
    case endOfTurn
    case maxTokens
    case stopString
    /// The caller's `shouldStop` asked the loop to end. Unlike `.stopString` no
    /// text was withheld: everything decoded was reported, and the final sampled
    /// token sits in `uncommittedBoundaryTokenIDs` exactly as it does for
    /// `.maxTokens`.
    case cancelled
    case toolCalls
}

package typealias GeneratorError = TUFFInferenceTypes.GeneratorError
