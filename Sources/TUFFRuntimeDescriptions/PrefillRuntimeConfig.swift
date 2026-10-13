public enum PrefillKVStorageMode: String, Sendable, Equatable {
    case fp16
}

public enum PrefillExecutedMode: String, Sendable, Equatable {
    case off
    case chunked
    case unsupported
}

public enum PrefillChunkCompleteness: String, Sendable, Equatable {
    case complete
    case unsupported
}

public struct PrefillExecutionDiagnostics: Sendable, Equatable {
    public let requestedMode: PrefillRuntimeConfig.Mode
    public let executedMode: PrefillExecutedMode
    public let kvStorageMode: PrefillKVStorageMode?
    public let chunkCompleteness: PrefillChunkCompleteness
    public let unsupportedReason: String?

    public init(config: PrefillRuntimeConfig,
                executedMode: PrefillExecutedMode,
                kvStorageMode: PrefillKVStorageMode? = nil,
                chunkCompleteness: PrefillChunkCompleteness? = nil,
                unsupportedReason: String? = nil) {
        self.requestedMode = config.mode
        self.executedMode = executedMode
        self.kvStorageMode = kvStorageMode
        self.chunkCompleteness = chunkCompleteness
            ?? (executedMode == .unsupported ? .unsupported : .complete)
        self.unsupportedReason = unsupportedReason
    }

    public static func unsupported(config: PrefillRuntimeConfig,
                                   kvStorageMode: PrefillKVStorageMode? = nil,
                                   reason: String) -> PrefillExecutionDiagnostics {
        PrefillExecutionDiagnostics(config: config,
                                    executedMode: .unsupported,
                                    kvStorageMode: kvStorageMode,
                                    chunkCompleteness: .unsupported,
                                    unsupportedReason: reason)
    }
}

public struct PrefillRuntimeConfig: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        case off
        case chunked
    }

    /// Chunked prefill loops chunks outside layers, so each chunk streams that
    /// layer's experts again and read volume tracks chunk count and nothing
    /// else. On an 11,612-token prompt that meant 578 GB read from a 12 GB pool
    /// with no cache hits at all.
    ///
    /// Larger chunks divide that traffic. On a 16 GB M2, Qwen 3.6 (19.5 GB, so
    /// its experts cannot stay in the page cache) prefilled 6,996 tokens in
    /// 190 s at 256 and 86 s at 2,048, with identical output; Gemma 4 26B,
    /// whose experts do fit, went from 193 s to 187 s. The cost is memory that
    /// scales with the chunk: prefill scratch, and the FP16 ring on
    /// sliding-window layers, which holds the window plus one chunk. Runners
    /// size both from the chunk size they are configured with, never from this
    /// ceiling, so a model run at 256 pays exactly what it did before.
    public static let maxChunkTokens = 2_048

    /// The chunk size ring and scratch memory is never sized below. Every size
    /// up to it produces the geometry TUFF shipped before larger chunks existed.
    public static let baselineChunkTokens = 256

    /// Chunk sizes a caller may select.
    public static let allowedChunkTokens = [32, 64, 128, 256, 512, 1_024, 2_048]

    /// The largest selectable chunk no greater than `requested`.
    ///
    /// Capping at `maxChunkTokens` is not enough on its own: a bare cap lets a
    /// caller ask for a size `--prefill-chunk-tokens` rejects. Snapping to the
    /// same list keeps the two doors agreeing on what is legal.
    public static func supportedChunkTokens(_ requested: Int) -> Int {
        let capped = max(1, min(requested, maxChunkTokens))
        return allowedChunkTokens.last { $0 <= capped } ?? capped
    }

    /// The smallest allowed chunk that covers `promptTokens`, capped.
    ///
    /// One chunk means each layer's experts are read once for the whole
    /// prefill, which is the floor, so this asks for the smallest size that
    /// reaches it and never more than the prompt needs.
    public static func autoChunkTokens(
        promptTokens: Int,
        cap: Int = maxChunkTokens
    ) -> Int {
        let ceiling = min(cap, maxChunkTokens)
        for candidate in allowedChunkTokens where candidate >= promptTokens {
            return min(candidate, ceiling)
        }
        return ceiling
    }

    public let mode: Mode
    public let chunkTokens: Int

    private init(mode: Mode, chunkTokens: Int) {
        self.mode = mode
        self.chunkTokens = chunkTokens
    }

    public var enabled: Bool { mode == .chunked }

    public static var off: PrefillRuntimeConfig {
        PrefillRuntimeConfig(mode: .off, chunkTokens: 128)
    }

    public static var defaultChunked: PrefillRuntimeConfig {
        production(chunkTokens: 128)
    }

    /// This config at a different chunk size, all other settings intact. The
    /// multimodal path runs each work item at the size it was planned at.
    public func replacingChunkTokens(_ tokens: Int) -> PrefillRuntimeConfig {
        PrefillRuntimeConfig(mode: mode, chunkTokens: max(1, tokens))
    }

    /// Whether the chunked path an image prompt needs is switched on. This tree
    /// has no per-stage toggles, so the mode is the whole requirement.
    ///
    /// This is deliberately not "the image turn will succeed": a chunked config
    /// is still held to its prompt-token budget afterwards.
    public var servesImagePrompt: Bool { mode == .chunked }

    /// The config an image prompt can run under, or nil when it already runs.
    ///
    /// Image spans are only served by the chunked multimodal path, so anything
    /// short of it threw after the model was loaded and every image had been
    /// encoded on the GPU. Prefill mode is a performance choice; whether images
    /// work at all is not, so an image turn is coerced rather than refused.
    /// Callers report the coercion.
    public func coercedForImagePrompt() -> PrefillRuntimeConfig? {
        servesImagePrompt ? nil : .defaultChunked
    }

    public static func production(chunkTokens: Int) -> PrefillRuntimeConfig {
        precondition(RuntimeConfiguration.allowedPrefillChunkTokens.contains(chunkTokens),
                     "unsupported prefill chunk size")
        return PrefillRuntimeConfig(mode: .chunked, chunkTokens: chunkTokens)
    }
}
