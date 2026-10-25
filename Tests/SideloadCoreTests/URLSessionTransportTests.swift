import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// `URLSessionTransport` against a URLProtocol stub: no socket is ever opened. Each test uses its own host
// name, so the suites run in parallel without sharing stub state.

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, StubProtocol) -> Void

    static let handlers = Mutex<[String: Handler]>([:])
    static let seen = Mutex<[String: [URLRequest]]>([:])

    static func install(host: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func requests(host: String) -> [URLRequest] {
        seen.withLock { $0[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.seen.withLock { $0[host, default: []].append(request) }
        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        handler(request, self)
    }

    func respond(_ status: Int, headers: [String: String] = [:], body: Data = Data()) {
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func request(host: String) -> HTTPRequest {
    HTTPRequest(url: URL(string: "https://\(host)/v1/devices")!, bearer: ASCSecret("stub-token-value"))
}

private let transport = URLSessionTransport(protocolClasses: [StubProtocol.self])

@Suite("URLSession transport")
struct URLSessionTransportTests {
    @Test("sends a GET with the bearer header and returns status, body and Retry-After")
    func getWithBearer() async throws {
        let host = "get.stub.invalid"
        StubProtocol.install(host: host) { _, proto in
            proto.respond(200, headers: ["Retry-After": "7"], body: Data(#"{"data":[]}"#.utf8))
        }
        let response = try await transport.get(request(host: host))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"data":[]}"#)
        #expect(response.retryAfter == 7)
        let seen = StubProtocol.requests(host: host)
        #expect(seen.count == 1)
        #expect(seen.first?.httpMethod == "GET")
        #expect(seen.first?.value(forHTTPHeaderField: "Authorization") == "Bearer stub-token-value")
        #expect(seen.first?.httpBody == nil && seen.first?.httpBodyStream == nil)
    }

    @Test("a redirect to another host is not followed: the 302 comes back and the stub saw one request")
    func redirectRefused() async throws {
        let host = "redirect.stub.invalid"
        let other = "elsewhere.stub.invalid"
        StubProtocol.install(host: other) { _, proto in proto.respond(200) }
        StubProtocol.install(host: host) { req, proto in
            let target = URL(string: "https://\(other)/v1/devices")!
            let redirect = HTTPURLResponse(
                url: req.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            proto.client?.urlProtocol(proto, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            // The delegate declined the redirect: like the real loader, hand the 3xx back as the final response.
            proto.client?.urlProtocol(proto, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            proto.client?.urlProtocolDidFinishLoading(proto)
        }
        let response = try await transport.get(request(host: host))
        #expect(response.status == 302)
        #expect(StubProtocol.requests(host: host).count == 1)
        #expect(StubProtocol.requests(host: other).isEmpty, "the token never reaches the other host")
    }

    @Test("a body over 4 MiB throws bodyTooLarge")
    func bodyTooLarge() async {
        let host = "big-body.stub.invalid"
        StubProtocol.install(host: host) { _, proto in
            proto.respond(200, body: Data(count: URLSessionTransport.maxBodyBytes + 1))
        }
        await #expect(throws: HTTPTransportError.bodyTooLarge) { try await transport.get(request(host: host)) }
    }

    @Test("an oversized Content-Length throws bodyTooLarge before reading")
    func contentLengthTooLarge() async {
        let host = "big-length.stub.invalid"
        StubProtocol.install(host: host) { _, proto in
            proto.respond(200, headers: ["Content-Length": String(URLSessionTransport.maxBodyBytes + 1)], body: Data("x".utf8))
        }
        await #expect(throws: HTTPTransportError.bodyTooLarge) { try await transport.get(request(host: host)) }
    }

    @Test("URLError.cancelled and a cancelled task map to cancelled")
    func cancellation() async {
        let host = "cancelled.stub.invalid"
        StubProtocol.install(host: host) { _, proto in
            proto.client?.urlProtocol(proto, didFailWithError: URLError(.cancelled))
        }
        await #expect(throws: HTTPTransportError.cancelled) { try await transport.get(request(host: host)) }

        let hang = "hang.stub.invalid"
        StubProtocol.install(host: hang) { _, _ in }  // never answers
        let task = Task { try await transport.get(request(host: hang)) }
        while StubProtocol.requests(host: hang).isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: HTTPTransportError.cancelled) { try await task.value }
    }

    @Test("URLError.timedOut maps to timedOut, other failures to failed")
    func errorMapping() async {
        let slow = "timeout.stub.invalid"
        StubProtocol.install(host: slow) { _, proto in
            proto.client?.urlProtocol(proto, didFailWithError: URLError(.timedOut))
        }
        await #expect(throws: HTTPTransportError.timedOut) { try await transport.get(request(host: slow)) }

        let down = "down.stub.invalid"
        StubProtocol.install(host: down) { _, proto in
            proto.client?.urlProtocol(proto, didFailWithError: URLError(.notConnectedToInternet))
        }
        await #expect(throws: HTTPTransportError.failed) { try await transport.get(request(host: down)) }
    }

    // MARK: download (fetch)

    private func download(
        _ host: String, hosts: Set<String>? = nil, maxRedirects: Int = 3, maxBytes: Int64 = 1 << 20,
        sink: @escaping @Sendable (Data) throws -> Void = { _ in }
    ) async throws -> DownloadResponse {
        let request = DownloadRequest(
            url: URL(string: "https://\(host)/file.ipa")!, allowedHosts: hosts ?? [host], maxRedirects: maxRedirects, maxBytes: maxBytes,
            timeout: 60)
        return try await transport.download(request, sink: sink)
    }

    private func redirect(_ proto: StubProtocol, to target: String) {
        let url = URL(string: target)!
        let response = HTTPURLResponse(
            url: proto.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
        proto.client?.urlProtocol(proto, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        // If the delegate declined, hand the 3xx back like the real loader.
        proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
        proto.client?.urlProtocolDidFinishLoading(proto)
    }

    @Test("download streams the body to the sink in order as a plain GET with no Authorization", .timeLimit(.minutes(1)))
    func downloadStreams() async throws {
        let host = "dl.stream.stub.invalid"
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        StubProtocol.install(host: host) { _, proto in proto.respond(200, headers: ["Content-Length": String(body.count)], body: body) }
        let received = Mutex(Data())
        let chunks = Mutex(0)
        let response = try await download(host) { chunk in
            received.withLock { $0.append(chunk) }
            chunks.withLock { $0 += 1 }
        }
        #expect(response.status == 200 && response.byteCount == Int64(body.count))
        #expect(response.finalURL.host == host)
        #expect(received.withLock { $0 } == body)
        #expect(chunks.withLock { $0 } >= 3, "delivered in chunks, not one buffer")
        let seen = try #require(StubProtocol.requests(host: host).first)
        #expect(seen.httpMethod == "GET" && seen.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(seen.httpBody == nil && seen.httpBodyStream == nil)
    }

    @Test("download follows a redirect inside the allowlist and reports the final URL", .timeLimit(.minutes(1)))
    func downloadAllowedRedirect() async throws {
        let first = "redir.from.stub.invalid"
        let second = "redir.to.stub.invalid"
        StubProtocol.install(host: second) { _, proto in proto.respond(200, body: Data("payload".utf8)) }
        StubProtocol.install(host: first) { _, proto in
            proto.client?.urlProtocol(
                proto, wasRedirectedTo: URLRequest(url: URL(string: "https://\(second)/blob")!),
                redirectResponse: HTTPURLResponse(url: proto.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        let received = Mutex(Data())
        let response = try await download(first, hosts: [first, second]) { chunk in received.withLock { $0.append(chunk) } }
        #expect(response.status == 200 && response.finalURL.host == second)
        #expect(received.withLock { String(decoding: $0, as: UTF8.self) } == "payload")
    }

    @Test("download refuses a redirect to a host off the allowlist, to http, and past the limit; the target is never asked", .timeLimit(.minutes(1)))
    func downloadRedirectRefused() async throws {
        let off = "redir.offlist.stub.invalid"
        let target = "redir.target.stub.invalid"
        StubProtocol.install(host: target) { _, proto in proto.respond(200) }
        StubProtocol.install(host: off) { _, proto in redirect(proto, to: "https://\(target)/x") }
        await #expect(throws: HTTPTransportError.redirectRefused) { try await download(off) }
        #expect(StubProtocol.requests(host: target).isEmpty)

        let downgrade = "redir.http.stub.invalid"
        StubProtocol.install(host: downgrade) { _, proto in redirect(proto, to: "http://\(target)/x") }
        await #expect(throws: HTTPTransportError.redirectRefused) { try await download(downgrade, hosts: [downgrade, target]) }

        let limited = "redir.limit.stub.invalid"
        StubProtocol.install(host: limited) { _, proto in redirect(proto, to: "https://\(target)/x") }
        await #expect(throws: HTTPTransportError.redirectRefused) { try await download(limited, hosts: [limited, target], maxRedirects: 0) }
        #expect(StubProtocol.requests(host: target).isEmpty)
    }

    @Test("download: a first URL off the allowlist never leaves the process", .timeLimit(.minutes(1)))
    func downloadFirstURL() async {
        let host = "first.stub.invalid"
        await #expect(throws: HTTPTransportError.failed) { try await download(host, hosts: ["other.stub.invalid"]) }
        #expect(StubProtocol.requests(host: host).isEmpty)
    }

    @Test("download: over the cap is bodyTooLarge, by Content-Length and by counting", .timeLimit(.minutes(1)))
    func downloadCap() async {
        let declared = "cap.declared.stub.invalid"
        StubProtocol.install(host: declared) { _, proto in proto.respond(200, headers: ["Content-Length": "5000"], body: Data("x".utf8)) }
        await #expect(throws: HTTPTransportError.bodyTooLarge) { try await download(declared, maxBytes: 4999) }

        let counted = "cap.counted.stub.invalid"
        StubProtocol.install(host: counted) { _, proto in proto.respond(200, body: Data(count: 101)) }
        await #expect(throws: HTTPTransportError.bodyTooLarge) { try await download(counted, maxBytes: 100) }
    }

    @Test("download: a non-2xx answer returns its status and never calls the sink", .timeLimit(.minutes(1)))
    func downloadStatus() async throws {
        let host = "status.stub.invalid"
        StubProtocol.install(host: host) { _, proto in proto.respond(404, body: Data("nope".utf8)) }
        let calls = Mutex(0)
        let response = try await download(host) { _ in calls.withLock { $0 += 1 } }
        #expect(response.status == 404 && response.byteCount == 0)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("download: a cancelled task is cancelled, not a finished download", .timeLimit(.minutes(1)))
    func downloadCancelled() async {
        let hang = "dl.hang.stub.invalid"
        StubProtocol.install(host: hang) { _, _ in }  // never answers
        let task = Task { try await download(hang) }
        while StubProtocol.requests(host: hang).isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: HTTPTransportError.cancelled) { try await task.value }
    }

    @Test("download: a second response on the same task is refused, not merged")
    func downloadSecondResponse() throws {
        // URLSession itself folds a duplicate response from a URLProtocol into one before the delegate sees it, so
        // the guard is exercised directly.
        var seen = false
        try URLSessionTransport.registerResponse(seen: &seen)
        #expect(seen)
        #expect(throws: HTTPTransportError.failed) { try URLSessionTransport.registerResponse(seen: &seen) }
    }

    @Test("download: a sink error stops the transfer and comes back unchanged; timeouts and cancellation map as for get", .timeLimit(.minutes(1)))
    func downloadErrors() async {
        let host = "sink.stub.invalid"
        StubProtocol.install(host: host) { _, proto in proto.respond(200, body: Data(count: 70_000)) }
        let boom = SideloadError("DOWNLOAD_TOO_LARGE", "sink said stop")
        await #expect(throws: boom) { try await download(host) { _ in throw boom } }

        let slow = "dl.timeout.stub.invalid"
        StubProtocol.install(host: slow) { _, proto in proto.client?.urlProtocol(proto, didFailWithError: URLError(.timedOut)) }
        await #expect(throws: HTTPTransportError.timedOut) { try await download(slow) }

        let down = "dl.down.stub.invalid"
        StubProtocol.install(host: down) { _, proto in proto.client?.urlProtocol(proto, didFailWithError: URLError(.notConnectedToInternet)) }
        await #expect(throws: HTTPTransportError.failed) { try await download(down) }
    }

    // MARK: download flow control (end to end through URLSession)

    /// Answers 200, then delivers `blocks` blocks of `size` bytes (`0x5a`), and finishes unless `hang`.
    private func serve(_ proto: StubProtocol, blocks: Int, size: Int, hang: Bool = false, declared: Int? = nil) {
        let url = proto.request.url!
        var headers: [String: String] = [:]
        if let declared { headers["Content-Length"] = String(declared) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
        let block = Data(repeating: 0x5a, count: size)
        for _ in 0..<blocks { proto.client?.urlProtocol(proto, didLoad: block) }
        if !hang { proto.client?.urlProtocolDidFinishLoading(proto) }
    }

    private func flowTransport(high: Int, low: Int, probe: @escaping @Sendable (Int) -> Void) -> URLSessionTransport {
        URLSessionTransport(protocolClasses: [StubProtocol.self], flowHigh: high, flowLow: low, pendingProbe: probe)
    }

    private func fetchBody(
        _ transport: URLSessionTransport, host: String, maxBytes: Int64, sink: @escaping @Sendable (Data) throws -> Void
    ) async throws -> DownloadResponse {
        let request = DownloadRequest(
            url: URL(string: "https://\(host)/big.ipa")!, allowedHosts: [host], maxRedirects: 0, maxBytes: maxBytes, timeout: 60)
        return try await transport.download(request, sink: sink)
    }

    @Test("download: a slow sink still gets every byte in order, and what waits for it stays bounded", .timeLimit(.minutes(1)))
    func downloadSlowSink() async throws {
        let host = "slow.sink.stub.invalid"
        let (blocks, size) = (400, 16 << 10)  // 6.25 MiB
        StubProtocol.install(host: host) { _, proto in serve(proto, blocks: blocks, size: size) }
        let maxPending = Mutex(0)
        let flow = flowTransport(high: 256 << 10, low: 64 << 10) { value in maxPending.withLock { $0 = value } }
        let received = Mutex(0)
        let response = try await fetchBody(flow, host: host, maxBytes: Int64(blocks * size)) { chunk in
            #expect(chunk.allSatisfy { $0 == 0x5a })
            received.withLock { $0 += chunk.count }
            Thread.sleep(forTimeInterval: 0.0005)
        }
        #expect(response.status == 200 && response.byteCount == Int64(blocks * size))
        #expect(received.withLock { $0 } == blocks * size)
        // The stub delivers from its own thread whatever the task's state, so only the accounting is checked here:
        // the probe saw the flow's high-water mark, and the unit tests above pin the bound with a fake task.
        #expect(maxPending.withLock { $0 } > 0)
    }

    @Test("download: a server that sends more than declared is cut off at the cap by the delegate, before the sink sees it", .timeLimit(.minutes(1)))
    func downloadOversize() async {
        let host = "oversize.stub.invalid"
        StubProtocol.install(host: host) { _, proto in serve(proto, blocks: 40, size: 64 << 10, hang: true) }
        let maxPending = Mutex(0)
        let flow = flowTransport(high: 1 << 20, low: 256 << 10) { value in maxPending.withLock { $0 = value } }
        let seen = Mutex(0)
        await #expect(throws: HTTPTransportError.bodyTooLarge) {
            try await fetchBody(flow, host: host, maxBytes: 100 << 10) { chunk in seen.withLock { $0 += chunk.count } }
        }
        // 40 blocks (2.5 MiB) were offered; the flow queued at most what fits under the cap.
        #expect(maxPending.withLock { $0 } <= 100 << 10)
        #expect(seen.withLock { $0 } <= 100 << 10)
    }

    @Test("download: a declared Content-Length over the cap is refused before any byte is consumed", .timeLimit(.minutes(1)))
    func downloadDeclaredTooLarge() async {
        let host = "declared.big.stub.invalid"
        StubProtocol.install(host: host) { _, proto in serve(proto, blocks: 4, size: 4096, declared: 1 << 30) }
        let flow = flowTransport(high: 1 << 20, low: 256 << 10) { _ in }
        let sunk = Mutex(0)
        await #expect(throws: HTTPTransportError.bodyTooLarge) {
            try await fetchBody(flow, host: host, maxBytes: 1 << 20) { chunk in sunk.withLock { $0 += chunk.count } }
        }
        #expect(sunk.withLock { $0 } == 0, "nothing reached the sink")
    }

    @Test("download: cancelling while the task is suspended ends at once and cleanly", .timeLimit(.minutes(1)))
    func downloadCancelWhileSuspended() async {
        let host = "suspended.cancel.stub.invalid"
        // 512 KiB offered against a 16 KiB high mark, then the connection stays open and silent.
        StubProtocol.install(host: host) { _, proto in serve(proto, blocks: 128, size: 4096, hang: true) }
        let sunk = Mutex(0)
        let flow = flowTransport(high: 16 << 10, low: 4 << 10) { _ in }
        let task = Task {
            try await fetchBody(flow, host: host, maxBytes: 1 << 30) { chunk in
                sunk.withLock { $0 += chunk.count }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        while sunk.withLock({ $0 }) == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: HTTPTransportError.cancelled) { try await task.value }
    }
}
