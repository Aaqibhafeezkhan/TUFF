import Foundation
import Testing
@testable import TUFFAppCore

/// Answers requests for `stub.test` from a table, including redirects, large
/// bodies and stalls, so the transport's limits run against real URLSession
/// behavior without a network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, [String: String], Data, Double)] = [:]
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.test" || request.url?.host == "other.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.path ?? ""
        guard let (status, headers, body, delay) = Self.routes[key] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let respond = { [self] in
            guard !cancelled else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            if (300..<400).contains(status), let location = headers["Location"],
               let target = URL(string: location, relativeTo: request.url) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target.absoluteURL),
                                    redirectResponse: response)
                // When the client refuses the redirect, the 3xx response is
                // the final one, as it is on a real connection.
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() { cancelled = true }
}

@Suite(.serialized) struct HTTPTransportLimitTests {
    private func transport() -> URLSessionHTTPTransport {
        URLSessionHTTPTransport(checksHosts: false, protocolClasses: [StubURLProtocol.self])
    }

    private func request(_ path: String, max: Int = 1_000, timeout: Double = 5) -> AppHTTPRequest {
        AppHTTPRequest(url: URL(string: "https://stub.test\(path)")!,
                       maximumBytes: max, timeoutSeconds: timeout)
    }

    @Test func readsABodyWithinItsLimit() async throws {
        StubURLProtocol.routes["/ok"] = (200, ["Content-Type": "text/plain"], Data("hello".utf8), 0)
        let response = try await transport().perform(request("/ok"))
        #expect(response.statusCode == 200)
        #expect(response.text == "hello")
    }

    @Test func stopsReadingPastTheByteLimit() async throws {
        StubURLProtocol.routes["/big"] = (200, [:], Data(repeating: 65, count: 200_000), 0)
        await #expect(throws: AppHTTPError.oversized(limit: 50_000)) {
            _ = try await transport().perform(request("/big", max: 50_000))
        }
    }

    @Test func followsAFewRedirectsAndRefusesMore() async throws {
        StubURLProtocol.routes["/hop1"] = (302, ["Location": "/hop2"], Data(), 0)
        StubURLProtocol.routes["/hop2"] = (302, ["Location": "/ok2"], Data(), 0)
        StubURLProtocol.routes["/ok2"] = (200, [:], Data("landed".utf8), 0)
        let response = try await transport().perform(request("/hop1"))
        #expect(response.text == "landed")
        #expect(response.finalURL.path == "/ok2")

        for index in 0..<8 {
            StubURLProtocol.routes["/loop\(index)"] = (302, ["Location": "/loop\(index + 1)"], Data(), 0)
        }
        await #expect(throws: AppHTTPError.tooManyRedirects) {
            _ = try await transport().perform(request("/loop0"))
        }
    }

    @Test func refusesARedirectFromHTTPSToHTTP() async throws {
        StubURLProtocol.routes["/downgrade"] = (301, ["Location": "http://stub.test/ok"], Data(), 0)
        await #expect(throws: AppHTTPError.insecureRedirect) {
            _ = try await transport().perform(request("/downgrade"))
        }
    }

    @Test func refusesARedirectToAnotherScheme() async throws {
        StubURLProtocol.routes["/elsewhere"] = (302, ["Location": "ftp://stub.test/file"], Data(), 0)
        await #expect(throws: AppHTTPError.unsupportedScheme) {
            _ = try await transport().perform(request("/elsewhere"))
        }
    }

    @Test func aStalledRequestTimesOut() async throws {
        StubURLProtocol.routes["/slow"] = (200, [:], Data("late".utf8), 3)
        let started = Date()
        await #expect(throws: AppHTTPError.timedOut) {
            _ = try await transport().perform(request("/slow", timeout: 0.3))
        }
        #expect(Date().timeIntervalSince(started) < 2.5)
    }

    @Test func cancellingTheCallerStopsTheRequest() async throws {
        StubURLProtocol.routes["/stall"] = (200, [:], Data("late".utf8), 3)
        let transport = transport()
        let task = Task { try await transport.perform(request("/stall", timeout: 10)) }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 2)
        switch result {
        case .failure(let error as AppHTTPError): #expect(error == .cancelled)
        default: Issue.record("expected cancellation, got \(result)")
        }
    }
}
