import Foundation
import Synchronization

/// One bounded, read-only request. There is no method and no body: every request is a GET. The bearer token
/// (`portal` only; `fetch` sends none) is held as a secret and only ever becomes the `Authorization` header.
public struct HTTPRequest: Sendable {
    public let url: URL
    public let bearer: ASCSecret?

    public init(url: URL, bearer: ASCSecret? = nil) {
        self.url = url
        self.bearer = bearer
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    /// `Retry-After` in whole seconds, when the server sent one.
    public let retryAfter: Int?

    public init(status: Int, body: Data, retryAfter: Int? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Why a request produced no response. The client maps these to `ASC_NETWORK` (`cancelled` to `CANCELLED`); only `timedOut` is retried.
public enum HTTPTransportError: Error, Sendable, Equatable {
    case timedOut
    case failed
    case bodyTooLarge
    /// The task was cancelled while the request was in flight.
    case cancelled
    /// The default transport: no command reaches the network unless the live set wires a real one.
    case disabled
    /// A download redirect went to a URL that is not https on an allowed host, or past the redirect limit.
    case redirectRefused
}

/// A streamed, bounded download for `fetch` (design section 8, "Network client"). Every hop, the first URL
/// included, must be https on a host in `allowedHosts`; at most `maxRedirects` redirects are followed.
public struct DownloadRequest: Sendable {
    public let url: URL
    public let allowedHosts: Set<String>
    public let maxRedirects: Int
    /// The body may not exceed this many bytes (checked against `Content-Length` and while streaming).
    public let maxBytes: Int64
    /// Wall-clock limit for the whole transfer, in seconds.
    public let timeout: TimeInterval

    public init(
        url: URL, allowedHosts: Set<String>, maxRedirects: Int = FetchLimits.maxRedirects,
        maxBytes: Int64, timeout: TimeInterval
    ) {
        self.url = url
        self.allowedHosts = allowedHosts
        self.maxRedirects = maxRedirects
        self.maxBytes = maxBytes
        self.timeout = timeout
    }
}

public struct DownloadResponse: Sendable, Equatable {
    public let status: Int
    /// Where the body actually came from, after any redirects.
    public let finalURL: URL
    public let byteCount: Int64

    public init(status: Int, finalURL: URL, byteCount: Int64) {
        self.status = status
        self.finalURL = finalURL
        self.byteCount = byteCount
    }
}

public protocol HTTPTransport: Sendable {
    func get(_ request: HTTPRequest) async throws -> HTTPResponse
    /// Streams a 2xx body to `sink` in chunks (never called for another status). An error thrown by `sink`
    /// stops the transfer and is rethrown unchanged.
    func download(_ request: DownloadRequest, sink: @Sendable (Data) throws -> Void) async throws
        -> DownloadResponse
}

extension HTTPTransport {
    /// Transports that predate `fetch` (test fakes for `portal`) have no download.
    public func download(_ request: DownloadRequest, sink: @Sendable (Data) throws -> Void)
        async throws -> DownloadResponse
    {
        throw HTTPTransportError.disabled
    }
}

/// The `Services` default. Throws on every request, so a test (or a command that forgot to wire a transport)
/// can never hit the network.
public struct DisabledTransport: HTTPTransport {
    public init() {}

    public func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw HTTPTransportError.disabled
    }
}

/// The real client (design section 8): an ephemeral `URLSession` (no cookies, no cache, no credential
/// storage), 20 s per request, 30 s overall (both measure the network, not how soon our own task gets a thread),
/// redirects refused (the bearer token never follows one), response bodies capped at 4 MiB.
public struct URLSessionTransport: HTTPTransport {
    static let defaultRequestTimeout: TimeInterval = 20
    static let defaultResourceTimeout: TimeInterval = 30
    static let maxBodyBytes = 4 << 20

    /// `URLProtocol` classes put in front of the real loader; tests inject a stub so no socket is opened.
    let protocolClasses: [AnyClass]
    /// Backpressure thresholds for `download` (see `DownloadFlow`): suspend above `flowHigh` unconsumed bytes,
    /// resume at `flowLow` or less.
    let flowHigh: Int
    let flowLow: Int
    /// Tests only: told the most unconsumed bytes a download ever held, when it ends.
    let pendingProbe: (@Sendable (Int) -> Void)?
    /// `get`'s limits; tests shorten them to see the timers fire.
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval

    public init() {
        protocolClasses = []
        flowHigh = Self.defaultFlowHigh
        flowLow = Self.defaultFlowLow
        pendingProbe = nil
        requestTimeout = Self.defaultRequestTimeout
        resourceTimeout = Self.defaultResourceTimeout
    }

    init(
        protocolClasses: [AnyClass], flowHigh: Int = URLSessionTransport.defaultFlowHigh,
        flowLow: Int = URLSessionTransport.defaultFlowLow,
        pendingProbe: (@Sendable (Int) -> Void)? = nil,
        requestTimeout: TimeInterval = URLSessionTransport.defaultRequestTimeout,
        resourceTimeout: TimeInterval = URLSessionTransport.defaultResourceTimeout
    ) {
        self.protocolClasses = protocolClasses
        self.flowHigh = flowHigh
        self.flowLow = flowLow
        self.pendingProbe = pendingProbe
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    /// Collects a GET's body on URLSession's own queue and hands over the finished response. `session.bytes(for:)` is
    /// not used: it delivers only as its reader asks, so the request's timers keep running on an answer already here
    /// until the reader gets a thread, and a busy process reads a finished response as `timedOut`.
    private final class GetDelegate: NSObject, URLSessionDataDelegate, Sendable {
        private let body = Mutex(Data())
        private let results: AsyncThrowingStream<HTTPResponse, any Error>.Continuation

        init(results: AsyncThrowingStream<HTTPResponse, any Error>.Continuation) {
            self.results = results
        }

        /// Completes a redirect with `nil`, so the task ends with the 3xx response instead of following it.
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            if response.expectedContentLength > Int64(URLSessionTransport.maxBodyBytes) {
                results.finish(throwing: HTTPTransportError.bodyTooLarge)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
        {
            let fits = body.withLock { body -> Bool in
                guard body.count + data.count <= URLSessionTransport.maxBodyBytes else {
                    return false
                }
                body.append(data)
                return true
            }
            if !fits {
                results.finish(throwing: HTTPTransportError.bodyTooLarge)
                dataTask.cancel()
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
        ) {
            if let error {
                results.finish(throwing: error)
            } else if let http = task.response as? HTTPURLResponse {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
                results.yield(
                    HTTPResponse(
                        status: http.statusCode, body: body.withLock { $0 }, retryAfter: retryAfter)
                )
                results.finish()
            } else {
                results.finish(throwing: HTTPTransportError.failed)
            }
        }
    }

    public func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        let (results, continuation) = AsyncThrowingStream.makeStream(
            of: HTTPResponse.self, throwing: (any Error).self)
        let session = URLSession(
            configuration: config, delegate: GetDelegate(results: continuation), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        request.bearer?.reveal {
            urlRequest.setValue("Bearer " + $0, forHTTPHeaderField: "Authorization")
        }

        let task = session.dataTask(with: urlRequest)
        // Leaving the wait for any reason (answered, failed, cancelled task) stops the transfer.
        continuation.onTermination = { _ in task.cancel() }
        task.resume()

        do {
            for try await response in results { return response }
            // A cancelled task ends the stream quietly; the delegate never finishes it without a result or an error.
            throw HTTPTransportError.cancelled
        } catch let error as HTTPTransportError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw HTTPTransportError.timedOut
        } catch is CancellationError {
            throw HTTPTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw HTTPTransportError.cancelled
        } catch {
            throw HTTPTransportError.failed
        }
    }

    static let downloadIdleTimeout: TimeInterval = 30
    static let downloadChunkBytes = 64 << 10
    static let defaultFlowHigh = 4 << 20
    static let defaultFlowLow = 1 << 20

    private enum DownloadEvent: Sendable {
        case response(status: Int, url: URL?)
        case data(Data)
    }

    /// Feeds a data task's events into a stream, in order, through a `DownloadFlow` that caps the total and bounds
    /// what is waiting for the consumer. Follows a redirect only while the hop count, the scheme and the host stay
    /// inside the request's limits; otherwise it declines (the 3xx comes back as the final response) and
    /// remembers that it did.
    private final class DownloadDelegate: NSObject, URLSessionDataDelegate, Sendable {
        private struct State {
            var hops = 0
            var refused = false
        }

        private let state = Mutex(State())
        private let allowedHosts: Set<String>
        private let maxRedirects: Int
        private let events: AsyncThrowingStream<DownloadEvent, any Error>.Continuation
        let flow: DownloadFlow

        init(
            allowedHosts: Set<String>, maxRedirects: Int, flow: DownloadFlow,
            events: AsyncThrowingStream<DownloadEvent, any Error>.Continuation
        ) {
            self.allowedHosts = allowedHosts
            self.maxRedirects = maxRedirects
            self.flow = flow
            self.events = events
        }

        var refused: Bool { state.withLock { $0.refused } }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            let follow = state.withLock { s -> Bool in
                s.hops += 1
                guard s.hops <= maxRedirects, let url = request.url,
                    DownloadPolicy.permits(url, hosts: allowedHosts)
                else {
                    s.refused = true
                    return false
                }
                return true
            }
            completionHandler(follow ? request : nil)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                events.finish(throwing: HTTPTransportError.failed)
                completionHandler(.cancel)
                return
            }
            if (200..<300).contains(http.statusCode), http.expectedContentLength > flow.maxBytes {
                events.finish(throwing: HTTPTransportError.bodyTooLarge)
                completionHandler(.cancel)
                return
            }
            events.yield(.response(status: http.statusCode, url: http.url))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
        {
            // A non-2xx body is not wanted; the consumer stops at the status. Count it all the same.
            let outcome = flow.received(data.count) { events.yield(.data(data)) }
            // The flow has already cancelled the task; this callback ran first, so this error is the one reported.
            if outcome == .exceeded { events.finish(throwing: HTTPTransportError.bodyTooLarge) }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
        ) {
            events.finish(throwing: error)
        }
    }

    public func download(_ request: DownloadRequest, sink: @Sendable (Data) throws -> Void)
        async throws -> DownloadResponse
    {
        guard DownloadPolicy.permits(request.url, hosts: request.allowedHosts) else {
            throw HTTPTransportError.failed
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = Self.downloadIdleTimeout
        config.timeoutIntervalForResource = request.timeout
        config.waitsForConnectivity = false
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        // Unbounded here is safe: the flow keeps what is waiting in it under `flowHigh` (plus a small overshoot).
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: DownloadEvent.self, throwing: (any Error).self)
        let maxBytes = min(request.maxBytes, FetchLimits.maxIPABytes)
        let flow = DownloadFlow(maxBytes: maxBytes, high: flowHigh, low: flowLow)
        let delegate = DownloadDelegate(
            allowedHosts: request.allowedHosts, maxRedirects: request.maxRedirects, flow: flow,
            events: continuation)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer {
            flow.close()
            session.invalidateAndCancel()
            pendingProbe?(flow.maxPending)
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: urlRequest)
        flow.attach(
            DownloadFlow.Controls(
                suspend: { task.suspend() }, resume: { task.resume() }, cancel: { task.cancel() }))
        // Leaving the loop for any reason (done, error, cancelled task) stops the transfer; cancelling a suspended
        // task is what ends it, so a consumer that goes away can never be left waiting for a resume.
        continuation.onTermination = { _ in
            flow.close()
            task.cancel()
        }
        task.resume()

        do {
            var head: (status: Int, url: URL)?
            var sawResponse = false
            var total: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(Self.downloadChunkBytes)
            for try await event in events {
                switch event {
                case .response(let status, let url):
                    try Self.registerResponse(seen: &sawResponse)
                    if delegate.refused { throw HTTPTransportError.redirectRefused }
                    let finalURL = url ?? request.url
                    guard (200..<300).contains(status) else {
                        return DownloadResponse(status: status, finalURL: finalURL, byteCount: 0)
                    }
                    head = (status, finalURL)
                case .data(let data):
                    defer { flow.consumed(data.count) }
                    total += Int64(data.count)
                    if total > maxBytes { throw HTTPTransportError.bodyTooLarge }
                    try Self.forward(data, through: &buffer, to: sink)
                }
            }
            // A cancelled task ends the stream quietly; that is not a finished download.
            if Task.isCancelled { throw HTTPTransportError.cancelled }
            if delegate.refused { throw HTTPTransportError.redirectRefused }
            guard let head else { throw HTTPTransportError.failed }
            if !buffer.isEmpty { try sink(buffer) }
            return DownloadResponse(status: head.status, finalURL: head.url, byteCount: total)
        } catch let error as HTTPTransportError {
            throw error
        } catch let error as SideloadError {
            throw error  // from the sink
        } catch let error as URLError where error.code == .timedOut {
            throw HTTPTransportError.timedOut
        } catch is CancellationError {
            throw HTTPTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw HTTPTransportError.cancelled
        } catch {
            throw HTTPTransportError.failed
        }
    }

    /// One response per task. A second one is a protocol violation: it fails the download (`FETCH_NETWORK` in
    /// fetch) rather than mix two bodies or let a later status overwrite the first.
    static func registerResponse(seen: inout Bool) throws {
        if seen { throw HTTPTransportError.failed }
        seen = true
    }

    /// Hands `data` to `sink` in `downloadChunkBytes` pieces without copying whole blocks: full pieces are slices of
    /// `data` itself, and only a tail shorter than a piece is held in `buffer` for the next block.
    static func forward(
        _ data: Data, through buffer: inout Data, to sink: @Sendable (Data) throws -> Void
    ) throws {
        let piece = downloadChunkBytes
        var offset = data.startIndex
        while offset < data.endIndex {
            if buffer.isEmpty, data.endIndex - offset >= piece {
                try sink(data[offset..<offset + piece])
                offset += piece
            } else {
                let take = min(piece - buffer.count, data.endIndex - offset)
                buffer.append(data[offset..<offset + take])
                offset += take
                if buffer.count == piece {
                    try sink(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
    }
}
