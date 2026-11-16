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
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
            hosts.contains(host)
        else { return false }
        guard url.user == nil, url.password == nil else { return false }
        return url.port == nil || url.port == 443
    }
}

/// One source `fetch` knows how to read (design section 8, approved sources). Each comes from an app in `AppRegistry`,
/// which pins the metadata URL, the asset selection and the host ceiling. `approvedSources` in `config.json` is the owner's
/// switch for each of them and may only narrow the hosts.
struct FetchSource: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// GitHub releases API; the asset is chosen by exact name.
        case githubRelease(repo: String)
        /// A gorlev AltStore-style index: the one app with `bundleId`, downloaded from `host`; `tvos` pins the exact CDN
        /// path shape (design section 8).
        case altstoreIndex(url: String, bundleId: String, host: String, tvos: Bool)
        /// An owner-added GitHub repository (`customSources`, design section 8): the latest release with exactly one `.ipa`
        /// asset, pinned from the first approved version by bundle ID.
        case customGithubRelease(repo: String)
        /// An owner-added AltStore index: the one app with `bundleId`, which every fetched IPA must carry.
        case customAltstoreIndex(url: String, bundleId: String)

        var isThirdParty: Bool {
            switch self {
            case .githubRelease: false
            case .altstoreIndex, .customGithubRelease, .customAltstoreIndex: true
            }
        }

        /// The `kind` a source of this shape has in `customSources` and in `source list`.
        var configKind: String {
            switch self {
            case .githubRelease, .customGithubRelease: "githubRelease"
            case .altstoreIndex, .customAltstoreIndex: "altstoreIndex"
            }
        }

        /// Added by the owner in `customSources` rather than defined in code.
        var isCustom: Bool {
            switch self {
            case .customGithubRelease, .customAltstoreIndex: true
            case .githubRelease, .altstoreIndex: false
            }
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
        case .githubRelease(let repo), .customGithubRelease(let repo):
            URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        case .altstoreIndex(let url, _, _, _), .customAltstoreIndex(let url, _):
            URL(string: url)!
        }
    }

    func narrowed(to hosts: Set<String>) -> FetchSource {
        FetchSource(
            app: app, kind: kind, metadataHosts: metadataHosts.intersection(hosts),
            downloadHosts: downloadHosts.intersection(hosts))
    }
}

/// The fetch sources of the apps in `AppRegistry`, and the owner's `approvedSources` switch over them.
enum FetchCatalog {
    /// The built-in apps' sources, in app-ID order.
    static var sources: [FetchSource] { AppRegistry.builtIn.fetchSources }

    static var appNames: [String] { sources.map(\.app) }

    /// The apps with a source in `config`'s registry: the built-ins' and the valid `customSources`.
    static func appNames(_ config: Config) -> [String] {
        config.appRegistry.fetchSources.map(\.app)
    }

    /// The same for a command that has not read the config: the built-ins' when it cannot be read.
    static func appNames(_ services: Services) -> [String] {
        (try? services.store.load()).map(appNames) ?? appNames
    }

    /// The source of `app` in the config's registry, if the owner approved it in `config.approvedSources`. An entry is an
    /// object `{"app": "<key>"}`; an optional `"hosts": [...]` narrows the allowlist (it can never add a host).
    static func approved(app: String, config: Config) throws -> FetchSource {
        let sources = config.appRegistry.fetchSources
        guard let source = sources.first(where: { $0.app == app }) else {
            let ignored = !CustomSources.ignoredWarnings(in: config.appRegistry, app: app).isEmpty
            throw SideloadError(
                "SOURCE_NOT_ALLOWED", "\"\(printableCut(app))\" is not a source fetch knows.",
                fix: "Use one of: \(sources.map(\.app).joined(separator: ", "))."
                    + (ignored
                        ? " Its customSources entry in config.json was ignored; `sideload status` says why."
                        : ""))
        }
        let entries = config.approvedSources.compactMap { value -> [String: JSONValue]? in
            guard case .object(let o) = value, case .string(let name)? = o["app"], name == app
            else { return nil }
            return o
        }
        guard let entry = entries.first else {
            throw SideloadError(
                "SOURCE_NOT_ALLOWED", "\(app) is not in approvedSources in config.json.",
                fix:
                    "The owner approves a source by adding {\"app\": \"\(app)\"} to approvedSources in $SIDELOAD_HOME/config.json."
            )
        }
        guard case .array(let listed)? = entry["hosts"] else { return source }
        let hosts = Set(
            listed.compactMap { value -> String? in
                if case .string(let h) = value { return h.lowercased() }
                return nil
            })
        return source.narrowed(to: hosts)
    }

    /// Every source `approved(app:config:)` accepts, in app-ID order.
    static func approvedSources(_ config: Config) -> [FetchSource] {
        config.appRegistry.fetchSources.compactMap { try? approved(app: $0.app, config: config) }
    }
}

/// Text from outside (an app key typed on the command line) cut to a printable length.
func printableCut(_ text: String, to limit: Int = 64) -> String {
    let printable = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7f }
    return String(String.UnicodeScalarView(printable.prefix(limit)))
}
