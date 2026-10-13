import Foundation
import ImageIO
import UniformTypeIdentifiers

public typealias VisionImageLimits = TUFFRuntimeDescriptions.VisionImageLimits

public struct VisionImageMetadata: Sendable, Equatable {
    public let encodedBytes: Int
    public let encodedWidth: Int
    public let encodedHeight: Int
    public let orientedWidth: Int
    public let orientedHeight: Int
    public let orientation: Int
    public let bitsPerComponent: Int?
    public let colorModel: String?
    public let typeIdentifier: String?
}

public struct ImageMetadataReader: Sendable {
    public let limits: VisionImageLimits

    public init(limits: VisionImageLimits = VisionImageLimits()) {
        self.limits = limits
    }

    /// `verifyStreamCompleteness` walks a JPEG's whole entropy-coded scan to
    /// prove the file is not truncated — a read of every encoded byte. A
    /// caller that only needs dimensions (admission token counting) can skip
    /// it: a truncated file still fails at encode time, where the walk runs.
    package func read(
        opened: OpenedVisionImage,
        verifyStreamCompleteness: Bool = true
    ) throws -> VisionImageMetadata {
        let source = opened.source
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount == 1 else {
            throw VisionImageError.unsupportedFrameCount(frameCount)
        }
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let sourceType = UTType(typeIdentifier),
              sourceType.conforms(to: .image) else {
            throw VisionImageError.invalidMetadata("unsupported image type")
        }
        // Checked against the sniffed type, not the caller's label: a data URL
        // announcing image/png can carry anything ImageIO recognises.
        guard limits.allowedTypeIdentifiers.contains(typeIdentifier) else {
            throw VisionImageError.invalidMetadata(
                "unsupported image type \(typeIdentifier)")
        }
        // A truncated JPEG decodes to gray filler rather than failing, so the
        // stream has to be checked structurally; see `hasCompleteJPEGStream`.
        if verifyStreamCompleteness, sourceType.conforms(to: .jpeg),
           !opened.hasCompleteJPEGStream() {
            throw VisionImageError.invalidMetadata(
                "JPEG scan is not terminated: the file is truncated")
        }
        // PNG fails the same way and used to pass: the undecoded remainder
        // reads as black and the answer describes a black square.
        if verifyStreamCompleteness, sourceType.conforms(to: .png),
           !opened.hasCompletePNGStream() {
            throw VisionImageError.invalidMetadata(
                "PNG has no IEND chunk: the file is truncated")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else {
            throw VisionImageError.invalidMetadata("missing frame properties")
        }
        let dictionary = properties as NSDictionary
        guard let width = (dictionary[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (dictionary[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw VisionImageError.invalidMetadata("missing positive pixel dimensions")
        }
        guard width <= limits.maximumSourceDimension,
              height <= limits.maximumSourceDimension else {
            throw VisionImageError.sideTooLarge(
                width: width, height: height, sideLimit: limits.maximumSourceDimension)
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= limits.maximumSourcePixels else {
            throw VisionImageError.dimensionsTooLarge(
                width: width, height: height, pixelLimit: limits.maximumSourcePixels)
        }
        let depth = (dictionary[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        // Four channels is the decode target; source depth drives how much
        // ImageIO materialises before the thumbnail conversion.
        let (depthBytes, depthOverflow) = pixels.multipliedReportingOverflow(
            by: max(1, depth / 8) * 4)
        // One ceiling, because every format is now decoded at native size:
        // the reduction belongs to our own filter, so ImageIO no longer gets to
        // subsample JPEG or HEIF. The split that gave those formats 320 MB
        // rested on a shortcut this path deliberately gave up, and the cost is
        // two full surfaces live at once — the decoded CGImage and the one we
        // draw into — so the bound has to cover both.
        guard !depthOverflow, depthBytes <= limits.maximumDecodedBytes else {
            throw VisionImageError.decodedBytesTooLarge(
                width: width, height: height, byteLimit: limits.maximumDecodedBytes)
        }
        let orientation = (dictionary[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else {
            throw VisionImageError.invalidMetadata("unsupported EXIF orientation \(orientation)")
        }
        let bitsPerComponent = (dictionary[kCGImagePropertyDepth] as? NSNumber)?.intValue
        let colorModel = dictionary[kCGImagePropertyColorModel] as? String
        // The bounded ImageIO thumbnail decode converts source depth and color space
        // into the preprocessor's RGBA8 sRGB context.
        let swapsAxes = (5...8).contains(orientation)
        return VisionImageMetadata(
            encodedBytes: opened.encodedBytes,
            encodedWidth: width,
            encodedHeight: height,
            orientedWidth: swapsAxes ? height : width,
            orientedHeight: swapsAxes ? width : height,
            orientation: orientation,
            bitsPerComponent: bitsPerComponent,
            colorModel: colorModel,
            typeIdentifier: typeIdentifier)
    }
}
