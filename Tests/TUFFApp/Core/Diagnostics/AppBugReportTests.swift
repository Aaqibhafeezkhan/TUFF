import Foundation
import Testing
import TUFFModelCatalog
@testable import TUFFAppCore

@Suite struct AppBugReportTests {
    @Test func summaryContainsOnlyWhitelistedDiagnostics() {
        let report = AppBugReport(system: .init(macOS: "26.6.2", macModel: "Mac14,2", chip: "Apple M2", memoryBytes: 16 << 30),
            model: TUFFModelCatalog.default, contextTokens: 4096, temperature: 0.2,
            topK: 64, topP: 0.95, runtime: .init(), diagnostics: nil)
        #expect(report.summary.contains("TUFF 7.0.0"))
        #expect(report.summary.contains("Mac14,2"))
        #expect(!report.summary.contains("/Users/"))
        #expect(!report.summary.contains("file://"))
        let privateURL = report.issueURL(includeDiagnostics: false)
        #expect(!privateURL.absoluteString.contains("diagnostics="))
        let selectedURL = report.issueURL(includeDiagnostics: true)
        #expect(URLComponents(url: selectedURL, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "diagnostics" }?.value == report.summary)
    }
    @Test func unexpectedSystemStringsCannotLeakPathsOrExtraFields() {
        let report = AppBugReport(system: .init(macOS: "file:///private/a", macModel: "/Users/rex/private", chip: "M2\ncredential=secret", memoryBytes: 1),
            model: TUFFModelCatalog.default, contextTokens: 4096, temperature: 0,
            topK: 0, topP: 1, runtime: .init(), diagnostics: nil)
        #expect(!report.summary.contains("/private"))
        #expect(!report.summary.contains("/Users"))
        #expect(!report.summary.contains("secret"))
        #expect(report.summary.components(separatedBy: "Redacted").count == 4)
    }
}
