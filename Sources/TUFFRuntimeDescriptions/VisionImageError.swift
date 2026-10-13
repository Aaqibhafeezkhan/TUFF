import Foundation
public enum VisionImageError: Error, CustomStringConvertible {
    case invalidSource(String)
    case invalidMetadata(String)
    case unsupportedFrameCount(Int)
    case sourceTooLarge(bytes: Int, limit: Int)
    case dimensionsTooLarge(width: Int, height: Int, pixelLimit: Int)
    case sideTooLarge(width: Int, height: Int, sideLimit: Int)
    case decodedBytesTooLarge(width: Int, height: Int, byteLimit: Int)
    case decodeFailed
    case allocationFailed

    public var description: String {
        switch self {
        case .invalidSource(let detail): "invalid image source: \(detail)"
        case .invalidMetadata(let detail): "invalid image metadata: \(detail)"
        case .unsupportedFrameCount(let count): "image must contain one frame, found \(count)"
        case .sourceTooLarge(let bytes, let limit):
            "encoded image has \(bytes) bytes, limit is \(limit)"
        case .dimensionsTooLarge(let width, let height, let limit):
            "image dimensions \(width)x\(height) exceed the \(limit)-pixel limit"
        case .sideTooLarge(let width, let height, let limit):
            "image dimensions \(width)x\(height) exceed the \(limit)-pixel per-side limit"
        case .decodedBytesTooLarge(let width, let height, let limit):
            "image \(width)x\(height) would decode to more than \(limit) bytes"
        case .decodeFailed: "ImageIO could not decode the image"
        case .allocationFailed: "image preprocessing buffer allocation failed"
        }
    }
}
