import Foundation

public enum VisionPackError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidTextModelPath(String)
    case packNotFound(String)
    case invalidMetadata(String)
    case incompatibleTextArtifact
    case invalidReceipt(String)
    case invalidDirectoryEntries(String)
    case fileSizeMismatch(file: String, expected: UInt64, actual: UInt64)
    case regionExceedsDevice(name: String, bytes: UInt64, maximum: UInt64)

    public var description: String {
        switch self {
        case let .invalidTextModelPath(path):
            "text model path is not a .gturbo directory: \(path)"
        case let .packNotFound(path):
            "no vision companion pack at \(path)"
        case let .invalidMetadata(detail):
            "vision companion metadata is invalid: \(detail)"
        case .incompatibleTextArtifact:
            "vision companion does not match the loaded text artifact"
        case let .invalidReceipt(detail):
            "vision companion receipt is invalid: \(detail)"
        case let .invalidDirectoryEntries(difference):
            "vision companion directory does not match the v1 contract: \(difference)"
        case let .fileSizeMismatch(file, expected, actual):
            "\(file) size \(actual) does not match manifest size \(expected)"
        case let .regionExceedsDevice(name, bytes, maximum):
            "vision tensor \(name) region \(bytes) exceeds Metal maximum \(maximum)"
        }
    }
}

public enum VisionPackLocation {
    public static func companionURL(forTextModel textModelURL: URL) throws -> URL {
        let standardized = textModelURL.standardizedFileURL
        let name = standardized.lastPathComponent
        guard name.hasSuffix(".gturbo"), name.count > ".gturbo".count else {
            throw VisionPackError.invalidTextModelPath(standardized.path)
        }
        let stem = name.dropLast(".gturbo".count)
        return standardized.deletingLastPathComponent()
            .appendingPathComponent("\(stem).vision.gturbo", isDirectory: true)
    }
}
