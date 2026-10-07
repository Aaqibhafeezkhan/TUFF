import Foundation
import PDFKit

/// A disposable subprocess for untrusted web PDF parsing. This is crash and
/// time isolation, not a security sandbox. It receives only the downloaded
/// bytes and never opens paths, URLs, chats or model data.
public enum AppWebPDFWorker {
    public static let flag = "--tuff-extract-web-pdf"
    public static let maximumCharacters = 64 * 1_024
    public static let maximumOutputBytes = 512 * 1_024

    struct Output: Codable, Sendable {
        let title: String?
        let text: String
    }

    /// Called before app/server initialization. Nonzero exits mean invalid
    /// input (64), unreadable PDF (65), or an I/O failure (74).
    public static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.count > 1, arguments[1] == flag else { return nil }
        guard arguments.count == 2 else { return 64 }
        do {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
                guard data.count + chunk.count <= AppWebPageReader.maximumBytes else { return 64 }
                data.append(chunk)
            }
            guard !data.isEmpty else { return 64 }
            let output = try extract(data)
            let encoded = try JSONEncoder().encode(output)
            guard encoded.count <= maximumOutputBytes else { return 65 }
            try FileHandle.standardOutput.write(contentsOf: encoded)
            return 0
        } catch is AppWebPageError { return 65 }
        catch { return 74 }
    }

    static func extract(_ data: Data) throws -> Output {
        guard data.count <= AppWebPageReader.maximumBytes,
              data.starts(with: Data("%PDF-".utf8)),
              let document = PDFDocument(data: data) else {
            throw AppWebPageError.unsupportedContent("an unreadable PDF")
        }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .map { String($0.prefix(200)) }
        var text = ""
        for index in 0..<min(document.pageCount, AppWebPageReader.maximumPDFPages) {
            guard text.count < maximumCharacters else { break }
            if let content = document.page(at: index)?.string {
                if !text.isEmpty { text += "\n\n" }
                text += content.prefix(max(0, maximumCharacters - text.count))
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppWebPageError.empty }
        return Output(title: title, text: trimmed)
    }

    #if os(macOS)
    static func read(_ response: AppHTTPResponse, timeoutSeconds: Double,
                     executable: URL? = Bundle.main.executableURL) async throws -> AppWebPage {
        guard let executable else { throw AppWebPageError.unsupportedContent("a PDF without a parser helper") }
        let data = try await HTTPDeadline.run(seconds: timeoutSeconds) {
            try await BoundedWebProcess.run(executable: executable, arguments: [flag],
                input: response.body, outputLimit: maximumOutputBytes, bodyLimit: maximumOutputBytes)
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else {
            throw AppWebPageError.unsupportedContent("an unreadable PDF")
        }
        return .init(finalURL: response.finalURL, title: output.title, text: output.text)
    }
    #endif
}
