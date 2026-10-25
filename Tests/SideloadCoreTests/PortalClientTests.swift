import Foundation
import Testing

@testable import SideloadCore

private let bearer = ASCSecret("test-bearer-value")

private func client(
    _ transport: FakeHTTPTransport, clock: any WallClock = FixedClock(testNow), sleeps: SleepLog = SleepLog(),
    log: LogLines = LogLines()
) -> PortalClient {
    PortalClient(transport: transport, token: bearer, clock: clock, sleep: sleeps.sleep, log: log.log)
}

private func failure(_ block: () async throws -> PortalListing) async -> SideloadError? {
    do {
        _ = try await block()
        return nil
    } catch {
        return error as? SideloadError
    }
}

private let next = "https://api.appstoreconnect.apple.com/v1/devices?cursor=AQ&limit=200"

@Suite("portal client")
struct PortalClientTests {
    @Test("the first request is a bounded GET of the list with only the fields the report uses")
    func firstRequest() async throws {
        for resource in PortalResource.allCases {
            let transport = FakeHTTPTransport { _ in okPage([]) }
            _ = try await client(transport).list(resource)
            let request = try #require(transport.requests.first)
            let parts = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
            #expect(parts.scheme == "https" && parts.host == "api.appstoreconnect.apple.com")
            #expect(parts.path == resource.path)
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query["limit"] == "200")
            let fields = try #require(query["fields[\(resource.rawValue)]"])
            for banned in ["name", "displayName", "profileContent", "serialNumber"] {
                #expect(!fields.split(separator: ",").contains(Substring(banned)), "\(resource) must not request \(banned)")
            }
            #expect(query.count == 2)
            #expect(request.bearer?.reveal { $0 } == "test-bearer-value")
        }
    }

    @Test("follows links.next and concatenates the pages")
    func paging() async throws {
        let transport = FakeHTTPTransport { request in
            if request.url.query?.contains("cursor=AQ") == true { return okPage([resource("devices", "2", [:])]) }
            return okPage([resource("devices", "1", [:])], next: next)
        }
        let log = LogLines()
        let listing = try await client(transport, log: log).list(.devices)
        #expect(listing.items.map(\.id) == ["1", "2"])
        #expect(!listing.truncated)
        #expect(transport.requests.count == 2)
        #expect(log.all == ["portal: GET /v1/devices page 1", "portal: GET /v1/devices page 2"])
    }

    @Test("a next link that leaves the API host or list is refused and the token goes nowhere else", arguments: [
        "https://evil.example/v1/devices?cursor=AQ",
        "http://api.appstoreconnect.apple.com/v1/devices?cursor=AQ",
        "https://api.appstoreconnect.apple.com/v1/profiles?cursor=AQ",
        "https://api.appstoreconnect.apple.com/v1/devices/123?cursor=AQ",
        "https://api.appstoreconnect.apple.com@evil.example/v1/devices",
        "https://user:pw@api.appstoreconnect.apple.com/v1/devices",
        "https://api.appstoreconnect.apple.com:8443/v1/devices",
        "https://api.appstoreconnect.apple.com.evil.example/v1/devices",
        "//evil.example/v1/devices", "/v1/devices?cursor=AQ", "not a url",
    ])
    func offHostNext(link: String) async {
        let transport = FakeHTTPTransport { _ in okPage([], next: link) }
        let error = await failure { try await client(transport).list(.devices) }
        #expect(error?.code == "ASC_RESPONSE_INVALID")
        #expect(transport.requests.count == 1)
    }

    @Test("a malformed next link is ASC_RESPONSE_INVALID")
    func malformedNext() async {
        let transport = FakeHTTPTransport { _ in
            jsonResponse(["data": [], "links": ["next": 7]])
        }
        #expect(await failure { try await client(transport).list(.devices) }?.code == "ASC_RESPONSE_INVALID")
    }

    @Test("stops at 20 pages and reports the list as truncated")
    func pageCap() async throws {
        let transport = FakeHTTPTransport { _ in okPage([resource("devices", "x", [:])], next: next) }
        let listing = try await client(transport).list(.devices)
        #expect(listing.truncated)
        #expect(listing.items.count == 20)
        #expect(transport.requests.count == 20)
    }

    @Test("retries 429 and 5xx twice with 1 s then 3 s, then succeeds")
    func retryBackoff() async throws {
        let sleeps = SleepLog()
        let transport = FakeHTTPTransport(results: [
            .success(errorResponse(500)), .success(errorResponse(429)), .success(okPage([resource("devices", "1", [:])])),
        ])
        let listing = try await client(transport, sleeps: sleeps).list(.devices)
        #expect(listing.items.count == 1)
        #expect(sleeps.durations == [.seconds(1), .seconds(3)])
        #expect(transport.requests.count == 3)
    }

    @Test("gives up after two retries with the status's error code", arguments: [
        (500, "ASC_HTTP_ERROR"), (503, "ASC_HTTP_ERROR"), (429, "ASC_RATE_LIMITED"),
    ])
    func retryExhausted(status: Int, code: String) async {
        let transport = FakeHTTPTransport { _ in errorResponse(status) }
        let error = await failure { try await client(transport).list(.devices) }
        #expect(error?.code == code)
        #expect(transport.requests.count == 3)
    }

    @Test("Retry-After is honoured and capped at 10 s")
    func retryAfter() async throws {
        let sleeps = SleepLog()
        let transport = FakeHTTPTransport(results: [
            .success(jsonResponse(["errors": []], status: 429, retryAfter: 2)),
            .success(jsonResponse(["errors": []], status: 429, retryAfter: 600)),
            .success(okPage([])),
        ])
        _ = try await client(transport, sleeps: sleeps).list(.devices)
        #expect(sleeps.durations == [.seconds(2), .seconds(10)])
    }

    @Test("a timeout is retried, other transport failures are not")
    func transportFailures() async throws {
        let sleeps = SleepLog()
        let timeoutThenOk = FakeHTTPTransport(results: [.failure(.timedOut), .success(okPage([]))])
        _ = try await client(timeoutThenOk, sleeps: sleeps).list(.devices)
        #expect(sleeps.durations == [.seconds(1)])

        let alwaysTimeout = FakeHTTPTransport(results: [.failure(.timedOut)])
        #expect(await failure { try await client(alwaysTimeout).list(.devices) }?.code == "ASC_NETWORK")
        #expect(alwaysTimeout.requests.count == 3)

        for kind in [HTTPTransportError.failed, .bodyTooLarge, .disabled] {
            let transport = FakeHTTPTransport(results: [.failure(kind)])
            #expect(await failure { try await client(transport).list(.devices) }?.code == "ASC_NETWORK")
            #expect(transport.requests.count == 1, "\(kind) is not retried")
        }
    }

    @Test("4xx other than 429 is not retried and maps to its code", arguments: [
        (401, "ASC_UNAUTHORIZED"), (403, "ASC_FORBIDDEN"), (404, "ASC_HTTP_ERROR"), (400, "ASC_HTTP_ERROR"),
        (302, "ASC_HTTP_ERROR"),
    ])
    func clientErrors(status: Int, code: String) async {
        let transport = FakeHTTPTransport { _ in errorResponse(status) }
        let error = await failure { try await client(transport).list(.devices) }
        #expect(error?.code == code)
        #expect(error?.fix?.isEmpty == false)
        #expect(transport.requests.count == 1)
    }

    @Test("a 403 on certificates tells the owner to switch the key to Admin")
    func forbiddenCertificates() async {
        let transport = FakeHTTPTransport { _ in errorResponse(403, code: "FORBIDDEN_ERROR") }
        let error = await failure { try await client(transport).list(.certificates) }
        #expect(error?.code == "ASC_FORBIDDEN")
        #expect(error?.fix?.contains("Admin") == true)
        #expect(error?.data["appleCode"] == "FORBIDDEN_ERROR")
        let other = await failure { try await client(transport).list(.devices) }
        #expect(other?.fix?.contains("Admin") == false)
    }

    @Test("only a well-shaped Apple error code is kept, never the title or detail text")
    func appleCode() async {
        let transport = FakeHTTPTransport { _ in errorResponse(500, code: "has spaces and text", detail: Canary.detail) }
        let error = await failure { try await client(transport).list(.devices) }
        #expect(error?.data["appleCode"] == nil)
        let text = String(describing: error)
        #expect(!text.contains(Canary.detail) && !text.contains("title text"))

        let longCode = String(repeating: "A", count: 65)
        #expect(PortalClient.appleCode(errorResponse(500, code: longCode).body) == nil)
        #expect(PortalClient.appleCode(errorResponse(500, code: "STATE.ERROR_1").body) == "STATE.ERROR_1")
    }

    @Test("unusable bodies are ASC_RESPONSE_INVALID", arguments: [
        "not json", "[]", #"{"data":"x"}"#, #"{"meta":{}}"#, #"{"data":[{"attributes":{}}]}"#, #"{"data":[7]}"#, "",
    ])
    func invalidBodies(body: String) async {
        let transport = FakeHTTPTransport { _ in textResponse(body) }
        #expect(await failure { try await client(transport).list(.devices) }?.code == "ASC_RESPONSE_INVALID")
    }

    @Test("tolerates unknown and missing attributes")
    func tolerant() async throws {
        let transport = FakeHTTPTransport { _ in
            okPage([
                ["type": "devices", "id": "1", "attributes": ["future": [1, 2], "udid": "x"], "relationships": [:]],
                ["type": "devices", "id": "2"],
            ])
        }
        let listing = try await client(transport).list(.devices)
        #expect(listing.items.map(\.id) == ["1", "2"])
        #expect(listing.items[1].attributes.isEmpty)
    }

    @Test("a cancelled wait stops retrying at once and is CANCELLED")
    func cancelledWait() async {
        let transport = FakeHTTPTransport { _ in errorResponse(500) }
        let cancelling = PortalClient(
            transport: transport, token: bearer, clock: FixedClock(testNow), sleep: { _ in throw CancellationError() },
            log: { _ in })
        let error = await failure { try await cancelling.list(.devices) }
        #expect(error?.code == "CANCELLED")
        #expect(transport.requests.count == 1, "no further attempt after the cancelled wait")

        let timeouts = FakeHTTPTransport(results: [.failure(.timedOut)])
        let onTimeout = PortalClient(
            transport: timeouts, token: bearer, clock: FixedClock(testNow), sleep: { _ in throw CancellationError() },
            log: { _ in })
        #expect(await failure { try await onTimeout.list(.devices) }?.code == "CANCELLED")
        #expect(timeouts.requests.count == 1)
    }

    @Test("cancellation during a request is CANCELLED, not a network failure", arguments: [0, 1])
    func cancelledInFlight(kind: Int) async {
        let transport = FakeHTTPTransport { _ in
            throw kind == 0 ? CancellationError() as any Error : HTTPTransportError.cancelled
        }
        let error = await failure { try await client(transport).list(.devices) }
        #expect(error?.code == "CANCELLED")
        #expect(transport.requests.count == 1, "no retry")
    }

    @Test("a cancelled task makes no request, and the live sleep rethrows cancellation")
    func cancelledTask() async throws {
        let transport = FakeHTTPTransport { _ in okPage([]) }
        let task = Task { () -> SideloadError? in
            while !Task.isCancelled { await Task.yield() }
            return await failure { try await client(transport).list(.devices) }
        }
        task.cancel()
        #expect(await task.value?.code == "CANCELLED")
        #expect(transport.requests.isEmpty)

        let services = Services(
            runner: FakeRunner(), fs: FakeFileSystem.free(gb: 1), clock: FixedClock(testNow), keychain: FakeKeychain(),
            home: Paths(home: "/nonexistent"))
        let sleeper = Task { try await services.sleep(.seconds(60)) }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
    }

    @Test("the 120 s deadline ends a slow listing as ASC_NETWORK")
    func deadline() async {
        let clock = StepClock()
        let transport = FakeHTTPTransport { _ in errorResponse(500) }
        let slow = PortalClient(
            transport: transport, token: bearer, clock: clock, sleep: { _ in clock.advance(200) }, log: { _ in })
        let error = await failure { try await slow.list(.devices) }
        #expect(error?.code == "ASC_NETWORK")
        #expect(transport.requests.count == 1)
    }

    @Test("the default Services transport refuses every request, so tests cannot reach the network")
    func defaultTransportThrows() async throws {
        let services = Services(
            runner: FakeRunner(), fs: FakeFileSystem.free(gb: 1), clock: FixedClock(testNow), keychain: FakeKeychain(),
            home: Paths(home: "/nonexistent"))
        let request = HTTPRequest(url: PortalClient.firstURL(.devices), bearer: bearer)
        await #expect(throws: HTTPTransportError.disabled) { try await services.http.get(request) }
        let error = await failure {
            try await PortalClient(transport: services.http, token: bearer, clock: services.clock, sleep: { _ in }).list(.devices)
        }
        #expect(error?.code == "ASC_NETWORK")
    }

    @Test("only the four list paths are allowed")
    func allowedPaths() {
        let ok = URL(string: "https://api.appstoreconnect.apple.com/v1/certificates")!
        #expect(PortalClient.isAllowed(ok))
        #expect(!PortalClient.isAllowed(URL(string: "https://api.appstoreconnect.apple.com/v1/apps")!))
        #expect(!PortalClient.isAllowed(URL(string: "https://api.appstoreconnect.apple.com/v1/certificates/ABC")!))
        #expect(!PortalClient.isAllowed(URL(string: "https://api.appstoreconnect.apple.com/v1/certificates#frag")!))
        #expect(!PortalClient.isAllowed(ok, path: "/v1/devices"))
    }

    @Test("cli names map to resources")
    func cliNames() {
        #expect(PortalResource(cliName: "bundle-ids") == .bundleIds)
        #expect(PortalResource(cliName: "bundleIds") == nil)
        #expect(PortalResource(cliName: "certificates") == .certificates)
        #expect(PortalResource.allCases.map(\.cliName) == ["certificates", "bundle-ids", "devices", "profiles"])
    }
}
