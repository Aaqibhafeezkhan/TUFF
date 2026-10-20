package enum GeneratorError: Error, CustomStringConvertible, Equatable {
    case contextOverflow(prompt: Int, maxNew: Int, maxContext: Int)
    case invalidGenerationConfig(String)
    case invalidContinuation(String)
    case invalidModelOutput
    case emptyPrompt

    public var description: String {
        switch self {
        case .contextOverflow(let prompt, let maxNew, let maxContext):
            return "context overflow: prompt \(prompt) + maxNew \(maxNew) exceeds maxContext \(maxContext)"
        case .invalidGenerationConfig(let reason):
            return reason
        case .invalidContinuation(let reason):
            return reason
        case .invalidModelOutput:
            return "Model computation failed to produce a valid next token. Reload the model and try again."
        case .emptyPrompt:
            return "empty prompt"
        }
    }
}
