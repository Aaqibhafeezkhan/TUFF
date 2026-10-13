import Foundation
import UniformTypeIdentifiers
public struct VisionImageLimits: Sendable, Equatable {
    public let maximumEncodedBytes: Int
    public let maximumSourcePixels: Int
    public let maximumSourceDimension: Int
    /// Decoders the pack is validated against. ImageIO sniffs the real bytes, so
    /// without this a request labelled `image/png` can reach the camera-RAW or
    /// EXR decoder — a far larger surface than the formats actually supported.
    public let allowedTypeIdentifiers: Set<String>
    /// Decoded bytes, not pixels. The pixel cap alone lets a 16-bit image expand
    /// about four times further than an 8-bit one at the same pixel count.
    /// Ceiling on one decoded surface. The 50-million-pixel source contract
    /// needs 200,000,000 bytes for an 8-bit RGBA surface, including an 8,000 by
    /// 6,000 camera image. ImageIO's decoded image and our drawing surface can
    /// overlap, so the M2 acceptance gate measures the resulting transient.
    public let maximumDecodedBytes: Int

    public init(
        maximumEncodedBytes: Int = 64 * 1_024 * 1_024,
        maximumSourcePixels: Int = 50_000_000,
        maximumSourceDimension: Int = 32_768,
        allowedTypeIdentifiers: Set<String> = [
            "public.jpeg", "public.png", "public.heic", "public.heif",
            "public.tiff", "com.compuserve.gif", "public.heics",
        ],
        maximumDecodedBytes: Int = 200_000_000
    ) {
        precondition(
            maximumEncodedBytes > 0 && maximumSourcePixels > 0
                && maximumSourceDimension > 0)
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumSourcePixels = maximumSourcePixels
        self.maximumSourceDimension = maximumSourceDimension
        self.allowedTypeIdentifiers = allowedTypeIdentifiers
        self.maximumDecodedBytes = maximumDecodedBytes
    }

    /// `allowedTypeIdentifiers` as `UTType`s, for the picker and pasteboard
    /// gates that admit an attachment in the first place.
    ///
    /// Those gates used to admit anything conforming to `public.image`, which is
    /// a far wider set than this one: a camera RAW, EXR or WebP was copied at
    /// full size, decoded in-process for its thumbnail beside a loaded model,
    /// and only then refused by `ImageMetadataReader`. Sorted so the picker's
    /// type list is stable between launches.
    public var allowedContentTypes: [UTType] {
        allowedTypeIdentifiers
            .compactMap(UTType.init(_:))
            .sorted { $0.identifier < $1.identifier }
    }
}
