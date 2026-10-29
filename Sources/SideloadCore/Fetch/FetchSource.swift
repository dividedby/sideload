import Foundation

/// The limits `fetch` and its transport share, so no two places can disagree about them.
public enum FetchLimits {
    /// The largest IPA anything accepts: what a source may declare, what the download may stream, what `inspect`
    /// opens.
    public static let maxIPABytes: Int64 = 2 << 30
    /// Redirect hops a download may follow.
    public static let maxRedirects = 3
}

/// The URL rule every `fetch` request obeys, the first one and each redirect hop: https, no credentials, the
/// default port, and a host in the source's allowlist.
enum DownloadPolicy {
    static func permits(_ url: URL, hosts: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), hosts.contains(host) else { return false }
        guard url.user == nil, url.password == nil else { return false }
        return url.port == nil || url.port == 443
    }
}

/// One source `fetch` knows how to read (design section 8, approved sources). The catalog is code: it pins the
/// metadata URL, the asset selection and the host ceiling. `approvedSources` in `config.json` is the owner's
/// switch for each of them and may only narrow the hosts.
struct FetchSource: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// GitHub releases API; the asset is chosen by exact name.
        case githubRelease(repo: String)
        /// A gorlev AltStore-style index; `tvos` pins the exact CDN path shape (design section 8).
        case altstoreIndex(url: String, tvos: Bool)

        var isThirdParty: Bool {
            if case .altstoreIndex = self { true } else { false }
        }
    }

    let app: String
    let kind: Kind
    /// Hosts the metadata request may use.
    let metadataHosts: Set<String>
    /// Hosts the IPA download and every redirect hop may use. A redirect anywhere else is refused.
    let downloadHosts: Set<String>

    var metadataURL: URL {
        switch kind {
        case .githubRelease(let repo): URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        case .altstoreIndex(let url, _): URL(string: url)!
        }
    }

    func narrowed(to hosts: Set<String>) -> FetchSource {
        FetchSource(app: app, kind: kind, metadataHosts: metadataHosts.intersection(hosts), downloadHosts: downloadHosts.intersection(hosts))
    }
}

enum FetchCatalog {
    static let apolloRepo = "Apollo-Reborn/Apollo-Reborn"
    static let stremioIndexBase = "https://raw.githubusercontent.com/gorlev/stremio-altstore/main/"
    static let stremioBundleId = "com.stremio.pal"
    static let stremioHost = "dl.strem.io"

    /// Release assets are served by github.com, which redirects to its object store; GitHub has used both
    /// `objects.githubusercontent.com` and `release-assets.githubusercontent.com` for that.
    static let sources: [FetchSource] = [
        FetchSource(
            app: "apollo", kind: .githubRelease(repo: apolloRepo), metadataHosts: ["api.github.com"],
            downloadHosts: ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]),
        FetchSource(
            app: "stremio-ios", kind: .altstoreIndex(url: stremioIndexBase + "stremio-ios.json", tvos: false),
            metadataHosts: ["raw.githubusercontent.com"], downloadHosts: [stremioHost]),
        FetchSource(
            app: "stremio-tvos", kind: .altstoreIndex(url: stremioIndexBase + "stremio-tvos.json", tvos: true),
            metadataHosts: ["raw.githubusercontent.com"], downloadHosts: [stremioHost]),
    ]

    static var appNames: [String] { sources.map(\.app) }

    /// The catalog entry for `app`, if the owner approved it in `config.approvedSources`. An entry is an object
    /// `{"app": "<key>"}`; an optional `"hosts": [...]` narrows the allowlist (it can never add a host).
    static func approved(app: String, config: Config) throws -> FetchSource {
        guard let source = sources.first(where: { $0.app == app }) else {
            throw SideloadError(
                "SOURCE_NOT_ALLOWED", "\"\(printableCut(app))\" is not a source fetch knows.",
                fix: "Use one of: \(appNames.joined(separator: ", ")).")
        }
        let entries = config.approvedSources.compactMap { value -> [String: JSONValue]? in
            guard case .object(let o) = value, case .string(let name)? = o["app"], name == app else { return nil }
            return o
        }
        guard let entry = entries.first else {
            throw SideloadError(
                "SOURCE_NOT_ALLOWED", "\(app) is not in approvedSources in config.json.",
                fix: "The owner approves a source by adding {\"app\": \"\(app)\"} to approvedSources in $SIDELOAD_HOME/config.json.")
        }
        guard case .array(let listed)? = entry["hosts"] else { return source }
        let hosts = Set(listed.compactMap { value -> String? in
            if case .string(let h) = value { return h.lowercased() }
            return nil
        })
        return source.narrowed(to: hosts)
    }
}

/// Text from outside (an app key typed on the command line) cut to a printable length.
func printableCut(_ text: String, to limit: Int = 64) -> String {
    let printable = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7f }
    return String(String.UnicodeScalarView(printable.prefix(limit)))
}
