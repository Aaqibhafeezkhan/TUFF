package struct GPTOSSExpertScratchLayout: Sendable, Equatable {
    package static let maximumPrefillQueries = PrefillRuntimeConfig.maxChunkTokens

    package let hiddenSize: Int
    package let intermediateSize: Int
    package let topK: Int
    package let queryCapacity: Int

    package init(hiddenSize: Int, intermediateSize: Int,
         topK: Int = 4, queryCapacity: Int) {
        precondition(hiddenSize > 0 && hiddenSize.isMultiple(of: 32))
        precondition(intermediateSize > 0 && intermediateSize.isMultiple(of: 32))
        precondition(topK > 0)
        self.hiddenSize = hiddenSize
        self.intermediateSize = intermediateSize
        self.topK = topK
        self.queryCapacity = max(1, min(queryCapacity, Self.maximumPrefillQueries))
    }

    package var routeCapacity: Int { queryCapacity * topK }
    package var mlp1Elements: Int { 2 * intermediateSize }
    package var activationElements: Int { intermediateSize }
    package var routePartialElements: Int { routeCapacity * hiddenSize }
    package var privateBytes: Int {
        (mlp1Elements + activationElements) * MemoryLayout<Float16>.stride
            + routePartialElements * MemoryLayout<Float>.stride
    }
    package var sharedBytes: Int {
        routeCapacity * MemoryLayout<Float16>.stride
    }
    package var totalBytes: Int { privateBytes + sharedBytes }
}
