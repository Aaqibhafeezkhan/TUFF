#if os(macOS)
import Darwin
import Foundation

/// Public-web transport with checked DNS answers pinned at connection time.
/// System curl preserves hostname certificate verification and SNI with
/// --resolve. No shell, curl settings, proxy, credentials, cookies or automatic
/// redirects are used. Every redirect is a fresh checked, pinned request.
struct PinnedHTTPTransport: AppHTTPTransport {
    typealias Resolver = @Sendable (String) async throws -> [String]
    typealias Exchange = @Sendable (AppHTTPRequest, String, Double) async throws -> Data
    let resolve: Resolver
    let exchange: Exchange
    static let maximumHeaderBytes = 64 * 1_024

    init(resolve: @escaping Resolver = Self.resolveHost,
         exchange: @escaping Exchange = Self.curlExchange) {
        self.resolve = resolve
        self.exchange = exchange
    }

    func perform(_ request: AppHTTPRequest) async throws -> AppHTTPResponse {
        guard request.maximumBytes > 0, request.timeoutSeconds.isFinite,
              request.timeoutSeconds > 0 else { throw AppHTTPError.timedOut }
        let deadline = ContinuousClock.now + .seconds(request.timeoutSeconds)
        return try await HTTPDeadline.run(seconds: request.timeoutSeconds) {
            var current = request
            for redirects in 0...URLSessionHTTPTransport.maximumRedirects {
                try Task.checkCancellation()
                try Self.validateURL(current.url)
                let host = current.url.host!.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let addresses = try await resolve(host)
                guard !addresses.isEmpty,
                      addresses.allSatisfy({ AppNetworkPolicy.IPAddress($0)?.isPublic == true }) else {
                    throw AppHTTPError.privateAddress(host)
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                let seconds = Double(remaining.components.seconds)
                    + Double(remaining.components.attoseconds) / 1e18
                guard seconds > 0 else { throw AppHTTPError.timedOut }
                let raw = try await exchange(current, addresses[0], seconds)
                let parsed = try Self.parse(raw, request: current)
                guard [301, 302, 303, 307, 308].contains(parsed.response.statusCode),
                      let location = parsed.headers["location"] else { return parsed.response }
                guard redirects < URLSessionHTTPTransport.maximumRedirects else {
                    throw AppHTTPError.tooManyRedirects
                }
                guard let destination = URL(string: location, relativeTo: current.url)?.absoluteURL else {
                    throw AppHTTPError.network("The page returned an invalid redirect address.")
                }
                try Self.validateURL(destination)
                if current.url.scheme?.lowercased() == "https", destination.scheme?.lowercased() == "http" {
                    throw AppHTTPError.insecureRedirect
                }
                if Self.origin(current.url) != Self.origin(destination) {
                    // Provider credentials and POST bodies never cross origins.
                    // Page reads carry only non-secret Accept/User-Agent values.
                    if current.body != nil || current.headers.keys.contains(where: {
                        !["accept", "user-agent"].contains($0.lowercased())
                    }) {
                        throw AppHTTPError.network("A credential-bearing request redirected to another site.")
                    }
                }
                if parsed.response.statusCode == 303
                    || ([301, 302].contains(parsed.response.statusCode) && current.method == "POST") {
                    current.method = "GET"
                    current.body = nil
                    current.headers = current.headers.filter { $0.key.lowercased() != "content-type" }
                }
                current.url = destination
            }
            throw AppHTTPError.tooManyRedirects
        }
    }

    static func validateURL(_ url: URL) throws {
        try URLSessionHTTPTransport.checkScheme(url)
        guard let host = url.host, AppNetworkPolicy.isPublicHost(host) else {
            throw AppHTTPError.privateAddress(url.host ?? "unknown host")
        }
        guard url.user == nil, url.password == nil,
              url.port == nil || (1...65_535).contains(url.port!) else {
            throw AppHTTPError.network("Web addresses cannot contain credentials or an invalid port.")
        }
    }

    static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))"
    }

    static func resolveHost(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
                    continuation.resume(throwing: AppHTTPError.network("The host could not be resolved."))
                    return
                }
                defer { freeaddrinfo(list) }
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                var addresses: [String] = []
                while let entry = cursor {
                    guard let address = AppNetworkPolicy.IPAddress(sockaddr: entry.pointee.ai_addr),
                          address.isPublic else {
                        continuation.resume(throwing: AppHTTPError.privateAddress(host))
                        return
                    }
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen,
                                      &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                        continuation.resume(throwing: AppHTTPError.network("The host returned an invalid address."))
                        return
                    }
                    addresses.append(String(cString: buffer))
                    cursor = entry.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }

    static func parse(_ data: Data, request: AppHTTPRequest)
        throws -> (response: AppHTTPResponse, headers: [String: String]) {
        var remaining = data
        var headerBytes = 0
        while true {
            guard let end = remaining.range(of: Data("\r\n\r\n".utf8)) else {
                throw AppHTTPError.network("The page returned an invalid HTTP response.")
            }
            headerBytes += end.upperBound
            guard headerBytes <= maximumHeaderBytes,
                  let header = String(data: remaining[..<end.lowerBound], encoding: .isoLatin1) else {
                throw AppHTTPError.network("The page's response headers were too large.")
            }
            let lines = header.components(separatedBy: "\r\n")
            let status = lines[0].split(separator: " ")
            guard status.count >= 2, status[0].hasPrefix("HTTP/"),
                  let code = Int(status[1]), (100...599).contains(code) else {
                throw AppHTTPError.network("The page returned an invalid HTTP status.")
            }
            remaining = remaining.subdata(in: end.upperBound..<remaining.count)
            if (100..<200).contains(code), code != 101 { continue }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if headers[key] != nil, key == "location" {
                    throw AppHTTPError.network("The page returned ambiguous redirect addresses.")
                }
                headers[key] = value
            }
            guard remaining.count <= request.maximumBytes else {
                throw AppHTTPError.oversized(limit: request.maximumBytes)
            }
            return (.init(finalURL: request.url, statusCode: code,
                          contentType: headers["content-type"], body: remaining), headers)
        }
    }

    static func curlExchange(_ request: AppHTTPRequest, address: String, seconds: Double) async throws -> Data {
        let configuration = try curlConfiguration(request, address: address, seconds: seconds)
        return try await BoundedWebProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-q", "--config", "-", "--silent", "--show-error", "--globoff",
                        "--include", "--http1.1", "--proto", "=http,https",
                        "--proxy", "", "--noproxy", "*", "--max-redirs", "0"],
            input: configuration,
            outputLimit: request.maximumBytes + maximumHeaderBytes,
            bodyLimit: request.maximumBytes)
    }

    static func curlConfiguration(_ request: AppHTTPRequest, address: String, seconds: Double) throws -> Data {
        guard ["GET", "POST", "HEAD"].contains(request.method),
              request.headers.allSatisfy({ key, value in
                  !key.contains(where: { $0 == ":" || $0.isNewline || $0 == "\0" })
                      && !value.contains(where: { $0.isNewline || $0 == "\0" })
              }) else { throw AppHTTPError.network("Invalid HTTP request headers or method.") }
        let host = request.url.host!.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = request.url.port ?? (request.url.scheme?.lowercased() == "https" ? 443 : 80)
        let pinned = address.contains(":") ? "[\(address)]" : address
        // Secrets stay in the stdin config, never the process argument list.
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r") + "\""
        }
        var config = ["url = \(quoted(request.url.absoluteString))",
                      "request = \(quoted(request.method))",
                      "max-time = \(seconds)", "connect-timeout = \(seconds)",
                      "max-filesize = \(request.maximumBytes)",
                      "user-agent = \(quoted(URLSessionHTTPTransport.userAgent))"]
        // Numeric URL hosts are already pinned. curl's --resolve grammar
        // treats colons as separators, so do not give it an IPv6 host literal.
        if AppNetworkPolicy.IPAddress(host) == nil {
            config.append("resolve = \(quoted("\(host):\(port):\(pinned)"))")
        }
        for (key, value) in request.headers { config.append("header = \(quoted("\(key): \(value)"))") }
        if let body = request.body {
            // Current callers send UTF-8 JSON or URL-encoded form text.
            // Keep all body text in the pipe too. data-raw treats a leading
            // @ literally, so it can never turn body content into a file read.
            guard let text = String(data: body, encoding: .utf8), !text.contains("\0") else {
                throw AppHTTPError.network("The web request body must be UTF-8 text without null bytes.")
            }
            config.append("data-raw = \(quoted(text))")
        }
        return Data((config.joined(separator: "\n") + "\n").utf8)
    }
}

/// A deadline that does not await an uncooperative DNS resolver after timing
/// out. The losing operation is cancelled, including its child curl process.
private final class HTTPDeadlineState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var work: Task<Void, Never>?
    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let result = lock.withLock { () -> Result<Value, any Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func setWork(_ work: Task<Void, Never>) {
        let finished = lock.withLock { self.work = work; return result != nil }
        if finished { work.cancel() }
    }
    func finish(_ result: Result<Value, any Error>) {
        let pair = lock.withLock { () -> (CheckedContinuation<Value, any Error>?, Task<Void, Never>?)? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil; work = nil }
            return (continuation, work)
        }
        pair?.0?.resume(with: result)
        pair?.1?.cancel()
    }
}

enum HTTPDeadline {
    static func run<Value: Sendable>(seconds: Double,
                                     operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let state = HTTPDeadlineState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let work = Task {
                    do { state.finish(.success(try await operation())) }
                    catch is CancellationError { state.finish(.failure(AppHTTPError.cancelled)) }
                    catch { state.finish(.failure(error)) }
                }
                state.setWork(work)
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    state.finish(.failure(AppHTTPError.timedOut))
                }
            }
        } onCancel: { state.finish(.failure(AppHTTPError.cancelled)) }
    }
}

private final class WebProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    func launch(_ process: Process) throws {
        try lock.withLock {
            guard !stopped else { throw AppHTTPError.cancelled }
            self.process = process
            try process.run()
        }
    }
    func stop() {
        lock.withLock {
            stopped = true
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

enum BoundedWebProcess {
    static func run(executable: URL, arguments: [String], input: Data,
                    outputLimit: Int, bodyLimit: Int) async throws -> Data {
        let control = WebProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try runSynchronously(executable: executable, arguments: arguments,
                                     inputData: input, outputLimit: outputLimit,
                                     bodyLimit: bodyLimit, control: control)
            }.value
        } onCancel: { control.stop() }
    }

    private static func runSynchronously(executable: URL, arguments: [String], inputData: Data,
                                         outputLimit: Int, bodyLimit: Int,
                                         control: WebProcessControl) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Ignore proxy and credential-related environment settings.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        // A helper can exit or be killed while input is still being written.
        // Suppress SIGPIPE for this descriptor so that becomes an I/O error,
        // never a signal terminating the app itself.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw AppHTTPError.network("The helper input pipe could not be prepared.")
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let stdout = WebProcessOutput(limit: outputLimit, control: control)
        let stderr = WebProcessOutput(limit: 16 * 1_024, control: control)
        let drains = DispatchGroup()
        try control.launch(process)
        for (handle, collector) in [(output.fileHandleForReading, stdout),
                                     (errors.fileHandleForReading, stderr)] {
            drains.enter()
            DispatchQueue.global().async {
                defer { drains.leave(); try? handle.close() }
                do {
                    while let bytes = try handle.read(upToCount: 16_384), !bytes.isEmpty {
                        collector.append(bytes)
                    }
                } catch { control.stop() }
            }
        }
        do { try input.fileHandleForWriting.write(contentsOf: inputData) }
        catch { control.stop() }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        drains.wait()
        try Task.checkCancellation()
        if stdout.exceeded { throw AppHTTPError.oversized(limit: bodyLimit) }
        switch process.terminationStatus {
        case 0: return stdout.data
        case 28: throw AppHTTPError.timedOut
        case 63: throw AppHTTPError.oversized(limit: bodyLimit)
        default: throw AppHTTPError.network("The web connection failed (code \(process.terminationStatus)).")
        }
    }
}

private final class WebProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var oversized = false
    private let limit: Int
    private let control: WebProcessControl
    init(limit: Int, control: WebProcessControl) { self.limit = limit; self.control = control }
    var data: Data { lock.withLock { bytes } }
    var exceeded: Bool { lock.withLock { oversized } }
    func append(_ chunk: Data) {
        let exceeded = lock.withLock {
            guard !oversized else { return true }
            if bytes.count + chunk.count > limit { oversized = true; return true }
            bytes.append(chunk)
            return false
        }
        if exceeded { control.stop() }
    }
}
#endif
