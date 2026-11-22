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

/// How a GitHub source's release tag gives the version (design section 8, custom sources). A closed set: a general tag
/// template would match ambiguously, and nothing needs it.
enum TagRule: String, Sendable, Equatable {
    /// The tag without one leading `v`.
    case plain
    /// `v<x>_<ver>`: the version is what follows the underscore.
    case underscoreSuffix
}

/// A GitHub source's `asset`: an exact file name, or a template holding one `{version}` that the release's version
/// fills in. Braces never occur in a plain file name, so the two forms cannot be confused.
enum AssetPin: Equatable, Sendable {
    case exact(String)
    case template(prefix: String, suffix: String)

    static let placeholder = "{version}"

    /// Nil unless `raw` is a valid exact name (`CustomSources.isValidAssetName`) or a valid template: exactly one `{version}`,
    /// no other brace, and the name it gives for the version `0` is a valid exact name.
    init?(_ raw: String) {
        if !raw.contains("{") && !raw.contains("}") {
            guard CustomSources.isValidAssetName(raw) else { return nil }
            self = .exact(raw)
            return
        }
        let pieces = raw.components(separatedBy: Self.placeholder)
        guard pieces.count == 2, !pieces.joined().contains("{"), !pieces.joined().contains("}"),
            CustomSources.isValidAssetName(pieces[0] + "0" + pieces[1])
        else { return nil }
        self = .template(prefix: pieces[0], suffix: pieces[1])
    }

    func name(version: String) -> String {
        switch self {
        case .exact(let name): name
        case .template(let prefix, let suffix): prefix + version + suffix
        }
    }
}

/// One source `fetch` knows how to read (design section 8, sources). Each is a `customSources` entry of the owner's config
/// (the three former built-in ones included, seeded once by `BuiltInSources`), which pins the metadata URL, the asset selection
/// and the host ceiling. `approvedSources` in `config.json` is the owner's switch for each of them and may only narrow the hosts.
struct FetchSource: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// A GitHub repository: the latest release's `.ipa` asset, pinned from the first approved version by bundle ID (or by
        /// `bundleId` when the entry declares it). With `asset` the one asset of exactly that name (or, when it holds one
        /// `{version}`, of that name with the release's version in it); without it the release must have exactly one `.ipa`.
        /// `tagRule` says how the tag gives the version.
        case githubRelease(
            repo: String, asset: String?, tagRule: TagRule = .plain, bundleId: String? = nil)
        /// An AltStore index: the one app with `bundleId`, which every fetched IPA must carry. `downloadPath` pins
        /// the download's exact path (one `{versionKey}` stands for the version key) and `requireBuild` makes the index's
        /// `buildVersion` mandatory, so the version key is always `<ver>b<build>`.
        case altstoreIndex(
            url: String, bundleId: String, downloadPath: String? = nil, requireBuild: Bool = false)

        /// The `kind` a source of this shape has in `customSources` and in `source list`.
        var configKind: String {
            switch self {
            case .githubRelease: "githubRelease"
            case .altstoreIndex: "altstoreIndex"
            }
        }

        /// The asset a GitHub source is pinned to, if any: an exact file name or a template with one `{version}`.
        var pinnedAsset: String? {
            if case .githubRelease(_, let asset, _, _) = self { return asset }
            return nil
        }

        /// The tag rule of a GitHub source when it is not the plain one.
        var tagRule: TagRule? {
            if case .githubRelease(_, _, let rule, _) = self, rule != .plain { return rule }
            return nil
        }

        /// The bundle ID a GitHub source declares for its IPAs, if any.
        var pinnedBundleId: String? {
            if case .githubRelease(_, _, _, let bundleId) = self { return bundleId }
            return nil
        }

        /// The download path template of an index source, if it has one.
        var downloadPath: String? {
            if case .altstoreIndex(_, _, let path, _) = self { return path }
            return nil
        }

        /// An index source that insists on a build number.
        var requiresBuild: Bool {
            if case .altstoreIndex(_, _, _, let required) = self { return required }
            return false
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
        case .githubRelease(let repo, _, _, _):
            URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        case .altstoreIndex(let url, _, _, _):
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
    /// The apps with a source in `config`'s registry: the valid `customSources`.
    static func appNames(_ config: Config) -> [String] {
        config.appRegistry.fetchSources.map(\.app)
    }

    /// The same for a command that has not read the config: none when it cannot be read.
    static func appNames(_ services: Services) -> [String] {
        (try? services.store.load()).map(appNames) ?? []
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
