import Foundation

/// Where saved prompt-prefix snapshots live. The engine writes them; the app
/// only needs the folder so deleting a model can take its snapshots with it.
public enum TUFFPrefixSnapshotLocation {
    /// `Caches/TUFF/PrefixSnapshots/<model>`, holding one folder per build.
    /// A scoped data root keeps the cache inside it, as local builds expect.
    public static func modelDirectory(modelID: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment,
                                      fileManager: FileManager = .default) -> URL? {
        let component = safeComponent(modelID)
        // "." and ".." survive the character filter; either would name a
        // parent folder that holds every model's snapshots.
        guard !component.isEmpty, component != ".", component != ".." else { return nil }
        let caches: URL
        if let scoped = environment["TUFF_APPLICATION_SUPPORT_ROOT"],
           scoped.hasPrefix("/"), !scoped.contains("\0") {
            caches = URL(fileURLWithPath: scoped, isDirectory: true).standardizedFileURL
                .appendingPathComponent("TUFF/Caches", isDirectory: true)
        } else if let normal = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            caches = normal
        } else { return nil }
        return caches.appendingPathComponent(
            "TUFF/PrefixSnapshots/\(component)", isDirectory: true)
    }

    /// Letters, digits, `-` and `.` pass through; anything else becomes `_`.
    public static func safeComponent(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
    }
}
