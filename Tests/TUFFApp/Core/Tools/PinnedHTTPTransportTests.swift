#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import TUFFAppCore

@Suite struct PinnedHTTPTransportTests {
    private let request = AppHTTPRequest(url: URL(string: "https://example.org/start")!,
                                          maximumBytes: 1_000, timeoutSeconds: 1)
    private func raw(_ status: Int = 200, headers: String = "", body: String = "ok") -> Data {
        Data("HTTP/1.1 \(status) Test\r\n\(headers)\r\n\(body)".utf8)
    }

    @Test func connectsOnlyToAnAddressFromTheCheckedSet() async throws {
        let observed = Mutex<[String]>([])
        let transport = PinnedHTTPTransport(resolve: { _ in ["93.184.216.34"] },
            exchange: { _, address, _ in
                observed.withLock { $0.append(address) }
                return raw()
            })
        #expect(try await transport.perform(request).text == "ok")
        #expect(observed.withLock { $0 } == ["93.184.216.34"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TUFF_TEST_LIVE_WEB"] == "1"))
    func liveHTTPSUsesTheProductionPinnedTransport() async throws {
        let response = try await URLSessionHTTPTransport().perform(AppHTTPRequest(
            url: URL(string: "https://example.com/?literal=[1-2]{a,b}")!,
            maximumBytes: 64 * 1_024, timeoutSeconds: 15))
        #expect(response.statusCode == 200)
        #expect(response.text.contains("Example Domain"))
        // URL glob expansion would concatenate two or more HTTP responses.
        #expect(!response.text.contains("HTTP/1.1"))
    }

    @Test func requestBodiesStayInThePipeAndFilePrefixesAreLiteral() throws {
        var post = request
        post.method = "POST"
        post.body = Data("@/private/file\n\"quoted\"\\value".utf8)
        let configuration = String(decoding: try PinnedHTTPTransport.curlConfiguration(
            post, address: "93.184.216.34", seconds: 1), as: UTF8.self)
        #expect(configuration.contains(#"data-raw = "@/private/file\n\"quoted\"\\value""#))
        #expect(!configuration.contains("data-binary"))
        post.body = Data([0xff, 0xfe])
        #expect(throws: AppHTTPError.self) {
            _ = try PinnedHTTPTransport.curlConfiguration(post, address: "93.184.216.34", seconds: 1)
        }
        post.body = Data([0])
        #expect(throws: AppHTTPError.self) {
            _ = try PinnedHTTPTransport.curlConfiguration(post, address: "93.184.216.34", seconds: 1)
        }
    }

    @Test func mixedPrivateAndPublicDNSAnswersAreRefused() async {
        let calls = Mutex(0)
        let transport = PinnedHTTPTransport(resolve: { _ in ["93.184.216.34", "127.0.0.1"] },
            exchange: { _, _, _ in calls.withLock { $0 += 1 }; return raw() })
        await #expect(throws: AppHTTPError.privateAddress("example.org")) {
            _ = try await transport.perform(request)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func rechecksEveryRedirectAndRefusesPrivateDestinations() async {
        let calls = Mutex(0)
        let transport = PinnedHTTPTransport(resolve: { _ in ["93.184.216.34"] },
            exchange: { _, _, _ in
                calls.withLock { $0 += 1 }
                return raw(302, headers: "Location: http://127.0.0.1/secret\r\n", body: "")
            })
        await #expect(throws: AppHTTPError.privateAddress("127.0.0.1")) {
            _ = try await transport.perform(request)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func providerCredentialsCannotFollowCrossOriginRedirects() async {
        var keyed = request
        keyed.headers = ["X-Subscription-Token": "test-secret"]
        let calls = Mutex(0)
        let transport = PinnedHTTPTransport(resolve: { _ in ["93.184.216.34"] },
            exchange: { _, _, _ in
                calls.withLock { $0 += 1 }
                return raw(307, headers: "Location: https://other.example/collect\r\n", body: "")
            })
        await #expect(throws: AppHTTPError.self) { _ = try await transport.perform(keyed) }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func dnsIsIncludedInTheAbsoluteDeadline() async {
        var quick = request
        quick.timeoutSeconds = 0.05
        let transport = PinnedHTTPTransport(resolve: { _ in
            // An intentionally uncooperative operation, like getaddrinfo.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    continuation.resume(returning: ["93.184.216.34"])
                }
            }
        }, exchange: { _, _, _ in raw() })
        let started = ContinuousClock.now
        await #expect(throws: AppHTTPError.timedOut) { _ = try await transport.perform(quick) }
        #expect(started.duration(to: .now) < .milliseconds(300))
    }

    @Test func cancellingDuringDNSDoesNotWaitForResolution() async throws {
        let transport = PinnedHTTPTransport(resolve: { _ in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    continuation.resume(returning: ["93.184.216.34"])
                }
            }
        }, exchange: { _, _, _ in raw() })
        let task = Task { try await transport.perform(request) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: AppHTTPError.cancelled) { _ = try await task.value }
    }

    @Test func ambiguousRedirectsAndMalformedHeadersAreRefused() {
        #expect(throws: AppHTTPError.self) {
            _ = try PinnedHTTPTransport.parse(raw(302, headers: "Location: /a\r\nLocation: /b\r\n"), request: request)
        }
        #expect(throws: AppHTTPError.self) {
            _ = try PinnedHTTPTransport.parse(Data("garbage".utf8), request: request)
        }
    }

    @Test func handlesInformationalHeadersAndEnforcesTheBodyLimit() throws {
        let data = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8) + raw(headers: "Content-Type: text/plain\r\n")
        #expect(try PinnedHTTPTransport.parse(data, request: request).response.text == "ok")
        #expect(throws: AppHTTPError.oversized(limit: 1_000)) {
            _ = try PinnedHTTPTransport.parse(raw(body: String(repeating: "a", count: 1_001)), request: request)
        }
    }
}
#endif
