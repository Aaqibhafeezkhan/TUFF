import Foundation

public enum PrefillError: Error, CustomStringConvertible, Equatable {
    public static let chunkedRequiresChunkedRunnerReason =
        "chunked prefill requires a ChunkedPrefillRunner-backed runtime"

    case chunkedUnsupported(String)
    case chunkedRunnerDirty(String)
    case prefillCursorMismatch(String)
    case unsupportedPrefillSeed(String)

    public var description: String {
        switch self {
        case .chunkedUnsupported(let reason),
             .chunkedRunnerDirty(let reason),
             .prefillCursorMismatch(let reason),
             .unsupportedPrefillSeed(let reason):
            return reason
        }
    }
}

struct PrefillChunkCommitState: Sendable, Equatable {
    private(set) var isDirty = false
    private(set) var inFlightStartPosition: Int?
    private(set) var inFlightTokenCount: Int?

    var inFlightEndPosition: Int? {
        guard let start = inFlightStartPosition,
              let count = inFlightTokenCount else { return nil }
        return start + count
    }

    init() {}

    mutating func markDirty(startPosition: Int, tokenCount: Int) {
        precondition(startPosition >= 0, "prefill dirty startPosition must be non-negative")
        precondition(tokenCount > 0, "prefill dirty tokenCount must be positive")
        isDirty = true
        inFlightStartPosition = startPosition
        inFlightTokenCount = tokenCount
    }

    mutating func markCommitted() {
        isDirty = false
        inFlightStartPosition = nil
        inFlightTokenCount = nil
    }

    mutating func reset() {
        markCommitted()
    }

    func requireClean(operation: String) throws {
        guard !isDirty else {
            let range: String
            if let start = inFlightStartPosition, let end = inFlightEndPosition {
                range = " for in-flight chunk [\(start), \(end))"
            } else {
                range = ""
            }
            throw PrefillError.chunkedRunnerDirty(
                "\(operation) rejected because a previous chunked prefill wrote KV rows\(range) but did not commit; call reset() before reusing the runner")
        }
    }
}

struct PrefillChunkSpan: Sendable, Equatable {
    let tokenOffset: Int
    let tokenCount: Int
    let startPosition: Int
    let completedCount: Int

    init(tokenOffset: Int,
                tokenCount: Int,
                startPosition: Int,
                completedCount: Int) {
        self.tokenOffset = tokenOffset
        self.tokenCount = tokenCount
        self.startPosition = startPosition
        self.completedCount = completedCount
    }

}

/// One item of a multimodal prefill turn: either a run of text small enough to
/// fit the chunk scratch, or exactly one image span, which executes whole.
struct PrefillWorkItem: Sendable, Equatable {
    let range: Range<Int>
    let imageIndex: Int?

    init(range: Range<Int>, imageIndex: Int?) {
        self.range = range
        self.imageIndex = imageIndex
    }

    var isImage: Bool { imageIndex != nil }
}

enum PrefillChunkPlanner {
    /// Splits a multimodal prompt into the items a turn executes, in order.
    ///
    /// Text is cut at the same clamp the scratch layout applies, so the split
    /// and the buffer it runs against can never disagree; image spans pass
    /// through whole, because an image's features are one indivisible block.
    /// `imageRanges` must be sorted, non-overlapping, and inside `tokenCount`.
    static func multimodalWork(tokenCount: Int,
                               imageRanges: [Range<Int>],
                               chunkTokens: Int) -> [PrefillWorkItem] {
        precondition(tokenCount >= 0, "prefill tokenCount must be non-negative")
        let chunk = max(1, min(chunkTokens, PrefillRuntimeConfig.maxChunkTokens))
        var work: [PrefillWorkItem] = []

        func appendText(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            var offset = range.lowerBound
            while offset < range.upperBound {
                let end = min(range.upperBound, offset + chunk)
                work.append(PrefillWorkItem(range: offset..<end, imageIndex: nil))
                offset = end
            }
        }

        var cursor = 0
        for (index, imageRange) in imageRanges.enumerated() {
            appendText(cursor..<imageRange.lowerBound)
            work.append(PrefillWorkItem(range: imageRange, imageIndex: index))
            cursor = imageRange.upperBound
        }
        appendText(cursor..<tokenCount)
        return work
    }

    static func spans(tokenCount: Int,
                             startPosition: Int,
                             config: PrefillRuntimeConfig) -> [PrefillChunkSpan] {
        spans(tokenCount: tokenCount,
              startPosition: startPosition,
              chunkTokens: config.chunkTokens)
    }

    static func spans(tokenCount: Int,
                             startPosition: Int,
                             chunkTokens: Int) -> [PrefillChunkSpan] {
        precondition(tokenCount >= 0, "prefill tokenCount must be non-negative")
        precondition(startPosition >= 0, "prefill startPosition must be non-negative")
        let chunk = max(1, min(chunkTokens, PrefillRuntimeConfig.maxChunkTokens))
        guard tokenCount > 0 else { return [] }

        var spans: [PrefillChunkSpan] = []
        spans.reserveCapacity((tokenCount + chunk - 1) / chunk)
        var offset = 0
        while offset < tokenCount {
            let count = min(chunk, tokenCount - offset)
            let completed = offset + count
            spans.append(PrefillChunkSpan(tokenOffset: offset,
                                          tokenCount: count,
                                          startPosition: startPosition + offset,
                                          completedCount: completed))
            offset = completed
        }
        return spans
    }
}

@_exported import TUFFRuntimeDescriptions
public typealias PrefillKVStorageMode = TUFFRuntimeDescriptions.PrefillKVStorageMode
public typealias PrefillExecutedMode = TUFFRuntimeDescriptions.PrefillExecutedMode
public typealias PrefillChunkCompleteness = TUFFRuntimeDescriptions.PrefillChunkCompleteness
public typealias PrefillExecutionDiagnostics = TUFFRuntimeDescriptions.PrefillExecutionDiagnostics
public typealias PrefillRuntimeConfig = TUFFRuntimeDescriptions.PrefillRuntimeConfig
