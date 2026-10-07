#if os(macOS)
import Foundation
import Testing
@testable import TUFFAppCore

@Suite struct AppWebPDFWorkerTests {
    @Test func extractsSyntheticPDFTextAndRejectsNonPDF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tuff-web-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try AppLocalSearchTests.writePDF(url, pages: ["Synthetic public research text.", "A second page."])
        let extracted = try AppWebPDFWorker.extract(Data(contentsOf: url))
        #expect(extracted.text.contains("Synthetic public research text"))
        #expect(extracted.text.contains("A second page"))
        #expect(throws: AppWebPageError.self) {
            _ = try AppWebPDFWorker.extract(Data("not a PDF".utf8))
        }
        #expect(throws: AppWebPageError.self) {
            _ = try AppWebPDFWorker.extract(Data(repeating: 65, count: AppWebPageReader.maximumBytes + 1))
        }
    }

    @Test func PDFPageCountIsBounded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tuff-web-pdf-pages-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try AppLocalSearchTests.writePDF(url, pages: (1...42).map { "SyntheticPageNumber\($0)End" })
        let extracted = try AppWebPDFWorker.extract(Data(contentsOf: url))
        #expect(extracted.text.contains("SyntheticPageNumber40End"))
        #expect(!extracted.text.contains("SyntheticPageNumber41End"))
        #expect(extracted.text.count <= AppWebPDFWorker.maximumCharacters)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TUFF_TEST_PDF_EXECUTABLE"] != nil))
    func packagedWorkerExtractsPDFInAChildProcess() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TUFF_TEST_PDF_EXECUTABLE"])
        #expect(!path.hasPrefix("/Applications/"))
        guard !path.hasPrefix("/Applications/") else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tuff-web-pdf-worker-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try AppLocalSearchTests.writePDF(url, pages: ["Packaged worker synthetic text."])
        let response = AppHTTPResponse(finalURL: URL(string: "https://example.org/sample.pdf")!,
            statusCode: 200, contentType: "application/pdf", body: try Data(contentsOf: url))
        let page = try await AppWebPDFWorker.read(response, timeoutSeconds: 5,
            executable: URL(fileURLWithPath: path))
        #expect(page.text.contains("Packaged worker synthetic text"))
        #expect(page.finalURL == response.finalURL)
    }

    @Test func unrelatedAndExtraWorkerArgumentsDoNotStartParsing() {
        #expect(AppWebPDFWorker.runIfRequested(arguments: ["TUFF", "--help"]) == nil)
        #expect(AppWebPDFWorker.runIfRequested(arguments: ["TUFF", AppWebPDFWorker.flag, "extra"]) == 64)
    }

    @Test func stalledChildProcessIsKilledAtTheDeadline() async {
        let started = ContinuousClock.now
        await #expect(throws: AppHTTPError.timedOut) {
            _ = try await HTTPDeadline.run(seconds: 0.05) {
                try await BoundedWebProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["10"], input: Data(), outputLimit: 1_024, bodyLimit: 1_024)
            }
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test func cancellingWhileTheHelperDoesNotReadInputIsSafe() async {
        await #expect(throws: AppHTTPError.timedOut) {
            _ = try await HTTPDeadline.run(seconds: 0.05) {
                try await BoundedWebProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["10"], input: Data(repeating: 65, count: 2 * 1_024 * 1_024),
                    outputLimit: 1_024, bodyLimit: 1_024)
            }
        }
    }

    @Test func outputFloodIsBounded() async {
        await #expect(throws: AppHTTPError.oversized(limit: 1_024)) {
            _ = try await HTTPDeadline.run(seconds: 2) {
                try await BoundedWebProcess.run(executable: URL(fileURLWithPath: "/usr/bin/yes"),
                    arguments: [], input: Data(), outputLimit: 1_024, bodyLimit: 1_024)
            }
        }
    }

    @Test func cancellationKillsTheChild() async throws {
        let task = Task {
            try await HTTPDeadline.run(seconds: 10) {
                try await BoundedWebProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["10"], input: Data(), outputLimit: 1_024, bodyLimit: 1_024)
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: AppHTTPError.cancelled) { _ = try await task.value }
    }
}
#endif
