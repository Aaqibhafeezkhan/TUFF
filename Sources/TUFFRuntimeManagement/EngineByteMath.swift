import Foundation

enum EngineByteMath {
    static func sum(_ values: [UInt64]) throws -> UInt64 {
        try values.reduce(0) { total, bytes in
            let result = total.addingReportingOverflow(bytes)
            guard !result.overflow else { throw InferenceEngineManifestError.invalidManifest }
            return result.partialValue
        }
    }
}
