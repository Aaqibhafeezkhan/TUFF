import Darwin
import Foundation
import IOKit

/// The hardware a result was measured on. Deliberately coarse: enough to
/// group comparable Macs, nothing that identifies one.
public struct AppBenchmarkMachine: Codable, Equatable, Sendable {
    /// "Apple M2", "Apple M4 Pro" and so on.
    public var chip: String
    /// Apple's model identifier, such as "Mac14,2". Shared by every Mac of
    /// that model, so it is not identifying.
    public var modelIdentifier: String
    public var memoryBytes: UInt64
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var gpuCores: Int?
    public var macOSVersion: String

    // `macOSVersion` is spelled so the snake_case strategies round-trip it
    // as `mac_os_version`.
    private enum CodingKeys: String, CodingKey {
        case chip, modelIdentifier, memoryBytes, performanceCores, efficiencyCores, gpuCores
        case macOSVersion = "macOsVersion"
    }

    public init(chip: String, modelIdentifier: String, memoryBytes: UInt64,
                performanceCores: Int?, efficiencyCores: Int?, gpuCores: Int?,
                macOSVersion: String) {
        self.chip = chip
        self.modelIdentifier = modelIdentifier
        self.memoryBytes = memoryBytes
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.gpuCores = gpuCores
        self.macOSVersion = macOSVersion
    }

    public static func current() -> AppBenchmarkMachine {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return AppBenchmarkMachine(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            modelIdentifier: sysctlString("hw.model") ?? "unknown",
            memoryBytes: sysctlInteger("hw.memsize").map(UInt64.init)
                ?? ProcessInfo.processInfo.physicalMemory,
            performanceCores: sysctlInteger("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInteger("hw.perflevel1.physicalcpu"),
            gpuCores: gpuCoreCount(),
            macOSVersion: macOS)
    }

    /// Memory as people say it: "16 GB".
    public var memoryDescription: String {
        "\(memoryBytes / (1 << 30)) GB"
    }

    /// "Apple M2, 16 GB", without the redundant "Apple".
    public var shortDescription: String {
        let name = chip.hasPrefix("Apple ") ? String(chip.dropFirst(6)) : chip
        return "\(name), \(memoryDescription)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                           as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    private static func sysctlInteger(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// The GPU core count the Apple GPU driver publishes in the I/O registry.
    private static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return value.intValue
    }
}
