import Darwin
import Foundation
import Testing

@testable import TUFFEngine

/// The AGX driver reads its interactivity-watchdog variable once, at the first
/// device creation in a process, so every production device must be created
/// through `MetalContext`.
@Suite(.serialized) struct MetalDeviceCreationTests {
    private static let key = MetalContext.interactivityWatchdogVariable

    private static func read() -> String? {
        getenv(key).map { String(cString: $0) }
    }

    private static func withCleanEnvironment(_ body: () throws -> Void) rethrows {
        let saved = read()
        unsetenv(key)
        defer {
            if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
        }
        try body()
    }

    @Test func creatingADeviceSetsTheWatchdogRelaxation() throws {
        try Self.withCleanEnvironment {
            _ = try MetalContext()
            #expect(Self.read() == "1")
        }
    }

    @Test func anOperatorOverrideIsNotReplaced() throws {
        try Self.withCleanEnvironment {
            setenv(Self.key, "0", 1)
            _ = try MetalContext()
            #expect(Self.read() == "0")
        }
    }

    /// The bundled `tuff`, TUFFCLI and TUFFServer live in
    /// `Contents/Resources/bin`, where `Bundle.main` is `bin` itself. Without
    /// the parent directory they fell through to SwiftPM's accessor and trapped
    /// on every Mac without a build tree.
    @Test func bundledToolsLookOneDirectoryAboveBin() {
        let resources = URL(fileURLWithPath: "/Applications/TUFF.app/Contents/Resources")
        let tool = resources.appendingPathComponent("bin/TUFFCLI")
        let directories = MetalContext.packagedResourceDirectories(
            mainResourceURL: resources.appendingPathComponent("bin"),
            executableURL: tool)
        #expect(directories.map(\.standardizedFileURL.path) == [
            resources.appendingPathComponent("bin").path,
            resources.path,
        ])

        let app = URL(fileURLWithPath: "/Applications/TUFF.app/Contents/MacOS/TUFF")
        #expect(MetalContext.packagedResourceDirectories(
            mainResourceURL: resources, executableURL: app) == [resources])
    }

    @Test func onlyMetalContextCreatesTheSystemDevice() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Infrastructure
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // TUFFEngine
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        try #require(FileManager.default.fileExists(atPath: sources.path))
        let sanctioned = "TUFFEngine/Infrastructure/Metal/MetalContext.swift"
        let prefix = sources.standardizedFileURL.path + "/"

        var offenders: [String] = []
        let walker = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            guard relative != sanctioned else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() where line.contains("MTLCreateSystemDefaultDevice(") {
                offenders.append("\(relative):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty,
                "device creation bypasses MetalContext: \(offenders.joined(separator: ", "))")
    }
}
