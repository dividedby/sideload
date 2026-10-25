import Foundation

/// The four lists `portal` reads. Each is one fixed `GET` path; the `fields[...]` parameter names exactly the
/// attributes the report uses, so names (`name`, `displayName`) and `profileContent` are never requested.
public enum PortalResource: String, CaseIterable, Sendable {
    case certificates
    case bundleIds
    case devices
    case profiles

    /// The positional spelling on the command line.
    public var cliName: String {
        self == .bundleIds ? "bundle-ids" : rawValue
    }

    public init?(cliName: String) {
        guard let match = Self.allCases.first(where: { $0.cliName == cliName }) else { return nil }
        self = match
    }

    var path: String {
        switch self {
        case .certificates: "/v1/certificates"
        case .bundleIds: "/v1/bundleIds"
        case .devices: "/v1/devices"
        case .profiles: "/v1/profiles"
        }
    }

    var fields: String {
        switch self {
        case .certificates: "certificateContent,certificateType,activated,expirationDate,platform"
        case .bundleIds: "identifier,platform,seedId"
        case .devices: "deviceClass,model,platform,status,udid,addedDate"
        case .profiles: "platform,createdDate,profileState,profileType,expirationDate"
        }
    }

    var label: String {
        switch self {
        case .certificates: "certificates"
        case .bundleIds: "App IDs"
        case .devices: "devices"
        case .profiles: "profiles"
        }
    }
}

/// One resource as the API returned it: the opaque portal id and its attributes. Unknown attributes are kept
/// here and ignored by the report.
public struct PortalItem: Sendable, Equatable {
    public let id: String
    public let attributes: [String: JSONValue]

    public init(id: String, attributes: [String: JSONValue] = [:]) {
        self.id = id
        self.attributes = attributes
    }

    func string(_ key: String) -> String? {
        if case .string(let s)? = attributes[key] { return s }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let b)? = attributes[key] { return b }
        return nil
    }
}

public struct PortalListing: Sendable, Equatable {
    public var items: [PortalItem]
    /// The page cap was hit with more pages left.
    public var truncated: Bool
}

/// Lists portal resources over `HTTPTransport`, read-only. Follows `links.next` only to the same host and
/// path, retries only a `GET` that failed with 429, 5xx or a timeout, and stops at its page and time caps.
public struct PortalClient: Sendable {
    static let host = "api.appstoreconnect.apple.com"
    static let allowedPaths: Set<String> = Set(PortalResource.allCases.map(\.path))
    static let pageSize = 200
    static let maxPages = 20
    static let maxRetries = 2
    static let deadline: TimeInterval = 120
    static let maxRetryWait = 10
    static let backoff: [Int] = [1, 3]

    let transport: any HTTPTransport
    let token: ASCSecret
    let clock: any WallClock
    let sleep: @Sendable (Duration) async throws -> Void
    let log: @Sendable (String) -> Void

    public init(
        transport: any HTTPTransport, token: ASCSecret, clock: any WallClock,
        sleep: @escaping @Sendable (Duration) async throws -> Void, log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.token = token
        self.clock = clock
        self.sleep = sleep
        self.log = log
    }

    /// https, the API host, no credentials or odd port in the URL, and one of the four list paths (the one
    /// named by `path` when given). The token is never sent anywhere else.
    static func isAllowed(_ url: URL, path: String? = nil) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        guard parts.scheme == "https", parts.host == host, parts.user == nil, parts.password == nil,
            parts.port == nil || parts.port == 443, parts.fragment == nil
        else { return false }
        if let path { return parts.path == path }
        return allowedPaths.contains(parts.path)
    }

    static func firstURL(_ resource: PortalResource) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = resource.path
        parts.queryItems = [
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "fields[\(resource.rawValue)]", value: resource.fields),
        ]
        return parts.url!
    }

    public func list(_ resource: PortalResource) async throws -> PortalListing {
        let limit = clock.now().addingTimeInterval(Self.deadline)
        var url = Self.firstURL(resource)
        var items: [PortalItem] = []
        var page = 0
        while true {
            page += 1
            log("portal: GET \(resource.path) page \(page)")
            let response = try await fetch(url, resource, limit: limit)
            let parsed = try Self.parse(response.body, resource)
            items += parsed.items
            guard let next = parsed.next else { return PortalListing(items: items, truncated: false) }
            guard Self.isAllowed(next, path: resource.path) else { throw Self.invalidResponse(resource) }
            if page >= Self.maxPages { return PortalListing(items: items, truncated: true) }
            url = next
        }
    }

    private func fetch(_ url: URL, _ resource: PortalResource, limit: Date) async throws -> HTTPResponse {
        guard Self.isAllowed(url, path: resource.path) else { throw Self.invalidResponse(resource) }
        var retries = 0
        while true {
            if Task.isCancelled { throw Self.cancelled(resource) }
            if clock.now() >= limit { throw Self.network(resource, "ran out of time") }
            do {
                let response = try await transport.get(HTTPRequest(url: url, bearer: token))
                if (200..<300).contains(response.status) { return response }
                guard response.status == 429 || (500..<600).contains(response.status), retries < Self.maxRetries
                else { throw Self.status(response, resource) }
                try await pause(Self.wait(retries, retryAfter: response.retryAfter), resource)
            } catch let error as SideloadError {
                throw error
            } catch {
                if error is CancellationError || (error as? HTTPTransportError) == .cancelled {
                    throw Self.cancelled(resource)
                }
                guard (error as? HTTPTransportError) == .timedOut, retries < Self.maxRetries else {
                    throw Self.network(resource, (error as? HTTPTransportError) == .timedOut ? "timed out" : nil)
                }
                try await pause(Self.wait(retries, retryAfter: nil), resource)
            }
            retries += 1
        }
    }

    /// A cancelled run stops retrying at once.
    private func pause(_ duration: Duration, _ resource: PortalResource) async throws {
        do {
            try await sleep(duration)
        } catch {
            throw Self.cancelled(resource)
        }
    }

    static func cancelled(_ resource: PortalResource) -> SideloadError {
        SideloadError(
            "CANCELLED", "Cancelled while listing \(resource.label).", fix: "Retry the command.")
    }

    static func wait(_ retry: Int, retryAfter: Int?) -> Duration {
        if let retryAfter, retryAfter >= 0 { return .seconds(min(retryAfter, maxRetryWait)) }
        return .seconds(backoff[min(retry, backoff.count - 1)])
    }

    // MARK: Response handling

    struct Page {
        var items: [PortalItem]
        var next: URL?
    }

    static func parse(_ body: Data, _ resource: PortalResource) throws -> Page {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body), case .object(let root) = json,
            case .array(let rows)? = root["data"]
        else { throw invalidResponse(resource) }
        var items: [PortalItem] = []
        for row in rows {
            guard case .object(let fields) = row, case .string(let id)? = fields["id"] else {
                throw invalidResponse(resource)
            }
            var attributes: [String: JSONValue] = [:]
            if case .object(let a)? = fields["attributes"] { attributes = a }
            items.append(PortalItem(id: id, attributes: attributes))
        }
        var next: URL?
        if case .object(let links)? = root["links"], let raw = links["next"], raw != .null {
            guard case .string(let text) = raw, let url = URL(string: text) else { throw invalidResponse(resource) }
            next = url
        }
        return Page(items: items, next: next)
    }

    /// Apple's error `code` (for example `NOT_AUTHORIZED`) when it has the expected shape; never the free text.
    static func appleCode(_ body: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body), case .object(let root) = json,
            case .array(let errors)? = root["errors"], case .object(let first)? = errors.first,
            case .string(let code)? = first["code"], code.count <= 64,
            code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }), !code.isEmpty
        else { return nil }
        return code
    }

    static func status(_ response: HTTPResponse, _ resource: PortalResource) -> SideloadError {
        let data: [String: JSONValue] = appleCode(response.body).map { ["appleCode": .string($0)] } ?? [:]
        switch response.status {
        case 401:
            return SideloadError(
                "ASC_UNAUTHORIZED", "App Store Connect rejected the API token for \(resource.label) (HTTP 401).",
                fix: "Check that the key is not revoked, that keyId and issuerId in key.json are right, and this Mac's clock.",
                data: data)
        case 403:
            let fix =
                resource == .certificates
                ? "Switch the key to Admin in App Store Connect > Users and Access > Integrations (an owner action), then retry."
                : "Check the key's role and access in App Store Connect > Users and Access > Integrations."
            return SideloadError(
                "ASC_FORBIDDEN", "The API key may not list \(resource.label) (HTTP 403).", fix: fix, data: data)
        case 429:
            return SideloadError(
                "ASC_RATE_LIMITED", "App Store Connect is rate limiting this key (listing \(resource.label)).",
                fix: "Wait a few minutes and retry.", data: data)
        default:
            return SideloadError(
                "ASC_HTTP_ERROR", "App Store Connect answered HTTP \(response.status) for \(resource.label).",
                fix: "Retry later; if it persists, check Apple's system status.", data: data)
        }
    }

    static func network(_ resource: PortalResource, _ reason: String?) -> SideloadError {
        SideloadError(
            "ASC_NETWORK", "Could not reach App Store Connect for \(resource.label)\(reason.map { " (\($0))" } ?? "").",
            fix: "Check the network connection and retry.")
    }

    static func invalidResponse(_ resource: PortalResource) -> SideloadError {
        SideloadError(
            "ASC_RESPONSE_INVALID", "App Store Connect sent a response sideload cannot use for \(resource.label).",
            fix: "Retry; if it persists the API may have changed, so report it.")
    }
}
