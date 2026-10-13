import Foundation

/// The wording behind the app's memory figure, in one place so the HUD popover,
/// the HUD tooltip and the inspector rows cannot drift apart.
///
/// The figure itself is `phys_footprint`, and it stays that way: measurement on
/// 2026-08-12 showed no per-process counter attributes the GPU-read mapped
/// weights, so a 26B model idles at roughly 160 MB. That reads as a bug unless
/// the exclusion is stated, which is what this copy does.
@MainActor
public enum MemoryFootprintExplanation {
    /// Deliberately "expert slots", never "experts": the 16 pread slot buffers
    /// are inside the footprint, the 12.9 GB routed-expert pool is not.
    private static func chargedLine(bytes: UInt64?) -> String {
        "\(MetricFormat.memory(bytes)) charged to the app \u{2014} the KV cache, "
            + "working buffers, expert slots and staged weights."
    }

    /// Figure-free on purpose, so rows that show a different number (peak, for
    /// instance) can carry the same framing without contradicting themselves.
    public static let exclusionNote =
        "File-backed resident weights and the image tower may be excluded from "
        + "this footprint. It is not total RAM use. Auto's calculated allocation "
        + "includes mapped weights and staging. File cache usage is shown in "
        + "Activity Monitor > Memory > Cached Files."

    /// The tower stays wording, never a live figure: a number here invites
    /// adding it to the charged headline, which would restate the bug this
    /// copy exists to answer. The diagnostics section still carries the
    /// measured "Image tower mapped" row for anyone who wants the bytes.
    public static func text(chargedBytes: UInt64?) -> String {
        [chargedLine(bytes: chargedBytes), exclusionNote].joined(separator: "\n\n")
    }
}
