import Foundation

/// The one GET of a source's metadata (the GitHub release, the Stremio index), shared by `fetch` and `updates`: the URL is
/// pinned by the catalog, the host must still be on the source's (possibly narrowed) metadata allowlist, no redirect is
/// followed and no token is sent.
enum SourceMetadata {
    /// The body of a 200 answer; anything else is a `SideloadError`.
    static func fetch(_ services: Services, _ source: FetchSource) async throws -> Data {
        let response = try await get(services, source)
        guard response.status == 200 else { throw httpError(response.status) }
        return response.body
    }

    /// The raw answer, for a caller that reads the status and `Retry-After` itself. The request is still checked first.
    static func get(_ services: Services, _ source: FetchSource, command: String = "fetch") async throws -> HTTPResponse {
        let url = source.metadataURL
        guard DownloadPolicy.permits(url, hosts: source.metadataHosts) else {
            throw SideloadError(
                "SOURCE_NOT_ALLOWED", "The metadata URL for \(source.app) is not on an allowed host.",
                fix: "Allowed hosts: \(source.metadataHosts.sorted().joined(separator: ", ")).")
        }
        do {
            return try await services.http.get(HTTPRequest(url: url))
        } catch {
            throw map(error, command: command)
        }
    }

    static func httpError(_ status: Int, retryAfter: Int? = nil) -> SideloadError {
        var data: [String: JSONValue] = ["status": .number(Double(status))]
        if let retryAfter { data["retryAfter"] = .number(Double(retryAfter)) }
        return SideloadError(
            "FETCH_HTTP_ERROR", "The metadata request answered HTTP \(status) (redirects are not followed).",
            fix: "Retry later.", data: data)
    }

    static var redirectRefused: SideloadError {
        SideloadError(
            "REDIRECT_NOT_ALLOWED", "The download was redirected to a URL that is not https on this source's allowed hosts.",
            fix: "Nothing was kept. If the CDN moved, the owner reviews the new host before it is added to the catalog.")
    }

    /// A transport failure as the error `fetch` reports; `command` names the command in the cancelled message.
    static func map(_ error: any Error, command: String = "fetch") -> SideloadError {
        if let known = error as? SideloadError { return known }
        if error is CancellationError { return SideloadError("CANCELLED", "\(command) was cancelled.", fix: "Re-run the command.") }
        switch error as? HTTPTransportError {
        case .redirectRefused: return redirectRefused
        case .bodyTooLarge:
            return SideloadError("DOWNLOAD_TOO_LARGE", "The download is larger than the size the source declared.", fix: "Nothing was kept.")
        case .timedOut: return SideloadError("FETCH_TIMEOUT", "The request timed out.", fix: "Retry later.")
        case .cancelled: return SideloadError("CANCELLED", "\(command) was cancelled.", fix: "Re-run the command.")
        case .disabled: return SideloadError("FETCH_NETWORK", "Network access is disabled in this build.", fix: "Use the live sideload binary.")
        case .failed, nil: return SideloadError("FETCH_NETWORK", "The request failed.", fix: "Check the network and retry.")
        }
    }
}
