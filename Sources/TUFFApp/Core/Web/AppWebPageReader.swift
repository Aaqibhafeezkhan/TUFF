import Foundation
import PDFKit
import Security

public struct AppWebPage: Equatable, Sendable {
    public let finalURL: URL
    public let title: String?
    public let text: String
}

public enum AppWebPageError: Error, Equatable, Sendable, CustomStringConvertible {
    case transport(AppHTTPError)
    case http(Int)
    case unsupportedContent(String)
    case empty

    public var description: String {
        switch self {
        case .transport(let error): error.description
        case .http(let status): "The page returned HTTP \(status)."
        case .unsupportedContent(let type):
            "The address is \(type), not a web page, text or PDF TUFF can read."
        case .empty: "The page has no readable text."
        }
    }
}

/// Reads one web page's text. Kept apart from local file access: it only
/// ever fetches http and https addresses through the bounded transport.
public struct AppWebPageReader: Sendable {
    public static let maximumBytes = 2 * 1_024 * 1_024
    public static let maximumPDFPages = 40
    private let transport: any AppHTTPTransport
    private let timeoutSeconds: Double

    public init(transport: any AppHTTPTransport, timeoutSeconds: Double = 15) {
        self.transport = transport
        self.timeoutSeconds = timeoutSeconds
    }

    public func read(_ url: URL) async throws -> AppWebPage {
        let response: AppHTTPResponse
        do {
            response = try await transport.perform(AppHTTPRequest(
                url: url,
                headers: ["Accept": "text/html,application/xhtml+xml,text/plain;q=0.9,application/pdf;q=0.8"],
                maximumBytes: Self.maximumBytes, timeoutSeconds: timeoutSeconds))
        } catch let error as AppHTTPError {
            throw AppWebPageError.transport(error)
        }
        if Self.contentType(response) == "application/pdf" {
            guard (200..<300).contains(response.statusCode) else {
                throw AppWebPageError.http(response.statusCode)
            }
            #if os(macOS)
            return try await AppWebPDFWorker.read(response, timeoutSeconds: timeoutSeconds)
            #else
            throw AppWebPageError.unsupportedContent("a PDF without a parser helper")
            #endif
        }
        try Task.checkCancellation()
        return try Self.page(from: response)
    }

    private static func contentType(_ response: AppHTTPResponse) -> String {
        (response.contentType?.split(separator: ";").first)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/html"
    }

    static func page(from response: AppHTTPResponse) throws -> AppWebPage {
        guard (200..<300).contains(response.statusCode) else {
            throw AppWebPageError.http(response.statusCode)
        }
        let type = contentType(response)
        let title: String?
        let text: String
        switch type {
        case "text/html", "application/xhtml+xml", "":
            let extracted = AppHTMLDocumentText.extract(response.text)
            title = extracted.title
            text = extracted.text
        case "text/plain", "text/markdown":
            title = nil
            text = response.text
        case "application/pdf":
            // Network PDF parsing must run through the disposable worker.
            // Keep the synchronous fixture parser fail-closed for this type.
            throw AppWebPageError.unsupportedContent("a PDF requiring the parser helper")
        default:
            throw AppWebPageError.unsupportedContent(type)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppWebPageError.empty }
        return AppWebPage(finalURL: response.finalURL, title: title, text: trimmed)
    }
}

/// Where provider API keys live. Production uses the login Keychain; tests
/// use memory, so no test reads or writes a real key.
public protocol AppSearchKeyStore: Sendable {
    func key(for provider: AppSearchProviderKind) -> String?
    func setKey(_ key: String, for provider: AppSearchProviderKind) throws
    func removeKey(for provider: AppSearchProviderKind) throws
}

public enum AppSearchKeyStoreError: Error, Equatable, CustomStringConvertible {
    case keychain(OSStatus)
    public var description: String {
        switch self {
        case .keychain(let status):
            "The Keychain refused the change (\(status))."
        }
    }
}

/// Generic-password items in the login Keychain, one per provider, readable
/// only on this Mac and never synchronized. Keys stay in this process: they
/// are not sent to the decode service, written to chats or settings, or
/// included in diagnostics and logs.
public struct KeychainSearchKeyStore: AppSearchKeyStore {
    public static let service = "com.rexmhall09.TUFF.search-provider-key"
    private let service: String

    public init(service: String = KeychainSearchKeyStore.service) {
        self.service = service
    }

    private func query(_ provider: AppSearchProviderKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }

    public func key(for provider: AppSearchProviderKind) -> String? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    public func setKey(_ key: String, for provider: AppSearchProviderKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try removeKey(for: provider) }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(query(provider) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AppSearchKeyStoreError.keychain(update) }
        var item = query(provider)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "TUFF \(provider.displayName) API key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppSearchKeyStoreError.keychain(status) }
    }

    public func removeKey(for provider: AppSearchProviderKind) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppSearchKeyStoreError.keychain(status)
        }
    }
}

public final class InMemorySearchKeyStore: AppSearchKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [AppSearchProviderKind: String] = [:]
    public init(_ keys: [AppSearchProviderKind: String] = [:]) { self.keys = keys }
    public func key(for provider: AppSearchProviderKind) -> String? { lock.withLock { keys[provider] } }
    public func setKey(_ key: String, for provider: AppSearchProviderKind) throws {
        lock.withLock { keys[provider] = key.isEmpty ? nil : key }
    }
    public func removeKey(for provider: AppSearchProviderKind) throws {
        lock.withLock { keys[provider] = nil }
    }
}
