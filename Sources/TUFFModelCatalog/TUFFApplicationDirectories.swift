import Foundation

/// A scoped data root for local builds, tests and portable installs. It names
/// the Application Support parent; TUFF keeps its own TUFF/ subtree inside it.
public enum TUFFApplicationDirectories {
    /// Preferences use a separate domain for each explicit local data root.
    /// The stable namespace hash is only an identifier, not a security digest.
    public static func preferencesSuiteName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard let path = environment["TUFF_APPLICATION_SUPPORT_ROOT"], path.hasPrefix("/"),
              !path.contains("\0") else { return "TUFF" }
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "TUFF.local.\(String(hash, radix: 16))"
    }
    public static func applicationSupportURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let path = environment["TUFF_APPLICATION_SUPPORT_ROOT"], path.hasPrefix("/"),
           !path.contains("\0") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
