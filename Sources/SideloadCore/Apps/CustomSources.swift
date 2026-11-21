import Foundation

/// The grammar every host and URL in `customSources` must satisfy (design section 8, custom sources). Strict on purpose: a
/// value that is not exactly this shape is refused, never normalised.
enum SourceURL {
    /// The most hosts one list (`metadataHosts`, `downloadHosts`) may name.
    static let maxHosts = 4

    /// Lowercase letters, digits and hyphens in labels of 1 to 63 characters, at least two labels, none starting with `xn--`.
    /// Not an IP literal (the last label of an IPv4 address is a number, an IPv6 one has `:`), not `localhost` or under it, no
    /// trailing dot, no `*`.
    static func isValidHost(_ host: String) -> Bool {
        guard host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard label.wholeMatch(of: /[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?/) != nil,
                !label.hasPrefix("xn--")
            else { return false }
        }
        let tld = labels[labels.count - 1]
        return !tld.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } && tld != "localhost"
    }

    /// Printable ASCII only, 0x21 to 0x7e: no space, control or non-ASCII character anywhere in the raw text.
    static func isPrintableASCII(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }

    struct Parsed: Equatable {
        let url: String
        let host: String
    }

    /// An index URL: `https://<host>/<path>` with a valid host, no credentials, no port (not even `:443`), no query, no
    /// fragment, no backslash, and a path of plain segments (none empty, `.` or `..`).
    static func parseHTTPS(_ raw: String) -> Result<Parsed, AppRegistry.Reason> {
        guard isPrintableASCII(raw) else {
            return .failure("its url has characters outside printable ASCII")
        }
        guard raw.hasPrefix("https://") else { return .failure("its url is not https") }
        guard !raw.contains("?") else { return .failure("its url has a query") }
        guard !raw.contains("#") else { return .failure("its url has a fragment") }
        guard !raw.contains("\\") else { return .failure("its url has a backslash") }
        let rest = raw.dropFirst("https://".count)
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = String(rest[..<slash])
        guard !authority.contains("@") else {
            return .failure("its url has a user name or password")
        }
        guard !authority.contains(":") else { return .failure("its url names a port") }
        guard isValidHost(authority) else { return .failure("its url host is not allowed") }
        let segments = rest[slash...].dropFirst().split(
            separator: "/", omittingEmptySubsequences: false)
        guard rest[slash...].hasPrefix("/"),
            !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return .failure("its url path is not plain segments") }
        guard URL(string: raw) != nil,
            URLComponents(string: raw)?.host == authority
        else { return .failure("its url does not parse") }
        return .success(Parsed(url: raw, host: authority))
    }
}

/// The owner's `customSources` in `config.json` (design section 8): a data-driven source for one `customApps` entry. Each
/// entry is checked on its own, strictly and fail-closed; one that is not exactly the shape below is left out with a
/// `CUSTOM_SOURCE_IGNORED` warning, and never stops a built-in source or another valid entry.
///
///     {"app", "kind": "githubRelease", "repo": "<owner>/<repo>", "asset"?: "<file>.ipa",
///      "metadataHosts": ["api.github.com"], "downloadHosts": [...], "addedAt"?}
///     {"app", "kind": "altstoreIndex", "url", "bundleId", "metadataHosts": [<url host>], "downloadHosts": [...],
///      "addedAt"?}
enum CustomSources {
    static let warningCode = "CUSTOM_SOURCE_IGNORED"
    static let githubMetadataHost = "api.github.com"
    /// The hosts GitHub serves a release asset from: the first request and its redirects.
    static let githubDownloadHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]
    private static let commonKeys: Set<String> = [
        "app", "kind", "metadataHosts", "downloadHosts", "addedAt",
    ]
    private static let githubKeys = commonKeys.union(["repo", "asset"])
    private static let altstoreKeys = commonKeys.union(["url", "bundleId"])
    private static let maxAddedAt = 40

    struct Outcome {
        var fetches: [String: AppDefinition.Fetch] = [:]
        var warnings: [JSONValue] = []
    }

    /// One entry that passed every check: the app it names and the source it gives that app.
    private struct Entry {
        let app: String
        let fetch: AppDefinition.Fetch
    }

    /// The valid sources by app, and one warning for every entry left out. `customApps` is the registry's valid custom apps:
    /// a source may only name one of those.
    static func load(_ raw: JSONValue?, customApps: [AppDefinition]) -> Outcome {
        guard let raw else { return Outcome() }
        guard case .array(let entries) = raw else {
            return Outcome(warnings: [
                warning("customSources is not an array, so every custom source is ignored.")
            ])
        }
        let checked = entries.map { (name: appName($0), result: check($0, customApps: customApps)) }
        let counts = Dictionary(grouping: checked.compactMap(\.name), by: { $0 }).mapValues(\.count)
        var out = Outcome()
        for (index, item) in checked.enumerated() {
            if let name = item.name, counts[name, default: 0] > 1 {
                out.warnings.append(
                    ignoredWarning(
                        index, "another customSources entry names the same app", app: name)
                )
                continue
            }
            switch item.result {
            case .success(let entry): out.fetches[entry.app] = entry.fetch
            case .failure(let reason):
                out.warnings.append(ignoredWarning(index, reason.text, app: item.name))
            }
        }
        return out
    }

    /// The `CUSTOM_SOURCE_IGNORED` warnings of `registry`, for one `app` or all. The one place that picks them out.
    static func ignoredWarnings(in registry: AppRegistry, app: String? = nil) -> [JSONValue] {
        registry.warnings.filter {
            guard case .object(let o) = $0, o["code"] == .string(warningCode) else { return false }
            return app == nil || o["app"] == app.map(JSONValue.string)
        }
    }

    /// The entry's `app` when it is a string, however the rest of the entry fares (duplicates count by it).
    private static func appName(_ entry: JSONValue) -> String? {
        guard case .object(let fields) = entry, case .string(let name)? = fields["app"] else {
            return nil
        }
        return name
    }

    /// The checks every kind shares, then the one sub-parser of its kind.
    private static func check(_ entry: JSONValue, customApps: [AppDefinition]) -> Result<
        Entry, AppRegistry.Reason
    > {
        guard case .object(let fields) = entry else { return .failure("it is not an object") }
        guard case .string(let kind)? = fields["kind"] else {
            return .failure("its kind is missing or not a string")
        }
        let allowed: Set<String>
        switch kind {
        case "githubRelease": allowed = githubKeys
        case "altstoreIndex": allowed = altstoreKeys
        default: return .failure("its kind is not githubRelease or altstoreIndex")
        }
        if let extra = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
            return .failure("it has the unknown field \(printableCut(extra, to: 32))")
        }
        guard case .string(let app)? = fields["app"] else {
            return .failure("its app is missing or not a string")
        }
        guard AppRegistry.isValidName(app) else { return .failure("its app is not a valid app ID") }
        if AppRegistry.builtIns.contains(where: { $0.id == app }) {
            return .failure("\(app) is a built-in app")
        }
        guard customApps.contains(where: { $0.id == app }) else {
            return .failure("\(app) is not a valid entry of customApps")
        }
        if let added = fields["addedAt"] {
            guard case .string(let text) = added, text.count <= maxAddedAt,
                SourceURL.isPrintableASCII(text), isTimestamp(text)
            else { return .failure("its addedAt is not an ISO 8601 timestamp") }
        }
        let metadata: [String]
        let downloads: [String]
        switch hosts(fields["metadataHosts"], key: "metadataHosts") {
        case .success(let list): metadata = list
        case .failure(let reason): return .failure(reason)
        }
        switch hosts(fields["downloadHosts"], key: "downloadHosts") {
        case .success(let list): downloads = list
        case .failure(let reason): return .failure(reason)
        }
        let fetch: Result<AppDefinition.Fetch, AppRegistry.Reason>
        if kind == "githubRelease" {
            fetch = githubFetch(fields, metadata: metadata, downloads: downloads)
        } else {
            fetch = altstoreFetch(fields, metadata: metadata, downloads: downloads)
        }
        return fetch.map { Entry(app: app, fetch: $0) }
    }

    private static func githubFetch(
        _ fields: [String: JSONValue], metadata: [String], downloads: [String]
    ) -> Result<AppDefinition.Fetch, AppRegistry.Reason> {
        guard case .string(let repo)? = fields["repo"], isValidRepo(repo) else {
            return .failure("its repo is not <owner>/<repo> of plain GitHub names")
        }
        var asset: String?
        if let declared = fields["asset"] {
            guard case .string(let name) = declared, isValidAssetName(name) else {
                return .failure(
                    "its asset is not a plain file name ending in .ipa or .IPA (the name itself is matched exactly)"
                )
            }
            asset = name
        }
        guard metadata == [githubMetadataHost] else {
            return .failure("its metadataHosts is not exactly [\"\(githubMetadataHost)\"]")
        }
        guard Set(downloads).isSubset(of: githubDownloadHosts) else {
            return .failure("a downloadHosts entry is not a GitHub release host")
        }
        return .success(
            AppDefinition.Fetch(
                kind: .customGithubRelease(repo: repo, asset: asset), metadataHosts: Set(metadata),
                downloadHosts: Set(downloads)))
    }

    private static func altstoreFetch(
        _ fields: [String: JSONValue], metadata: [String], downloads: [String]
    ) -> Result<AppDefinition.Fetch, AppRegistry.Reason> {
        guard case .string(let raw)? = fields["url"] else {
            return .failure("its url is missing or not a string")
        }
        let url: SourceURL.Parsed
        switch SourceURL.parseHTTPS(raw) {
        case .success(let value): url = value
        case .failure(let reason): return .failure(reason)
        }
        guard case .string(let bundleId)? = fields["bundleId"], isValidBundleId(bundleId) else {
            return .failure("its bundleId is not a reverse-DNS bundle ID")
        }
        guard metadata == [url.host] else {
            return .failure("its metadataHosts is not exactly the url's host")
        }
        return .success(
            AppDefinition.Fetch(
                kind: .customAltstoreIndex(url: url.url, bundleId: bundleId),
                metadataHosts: Set(metadata), downloadHosts: Set(downloads)))
    }

    /// 1 to 4 distinct valid hosts.
    private static func hosts(_ value: JSONValue?, key: String)
        -> Result<
            [String], AppRegistry.Reason
        >
    {
        guard case .array(let items)? = value else { return .failure("its \(key) is not an array") }
        guard !items.isEmpty else { return .failure("its \(key) is empty") }
        guard items.count <= SourceURL.maxHosts else {
            return .failure("its \(key) has more than \(SourceURL.maxHosts) hosts")
        }
        var list: [String] = []
        for item in items {
            guard case .string(let host) = item, SourceURL.isValidHost(host) else {
                return .failure("a \(key) entry is not an allowed host name")
            }
            guard !list.contains(host) else { return .failure("its \(key) lists a host twice") }
            list.append(host)
        }
        return .success(list)
    }

    /// `<owner>/<repo>`: an owner of up to 39 letters, digits and hyphens, a repository of up to 100 of those plus `.` and `_`,
    /// never `..` and never made only of dots.
    static func isValidRepo(_ repo: String) -> Bool {
        guard repo.wholeMatch(of: /[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}/) != nil,
            !repo.contains("..")
        else { return false }
        return repo.split(separator: "/")[1].contains { $0 != "." }
    }

    /// A pinned release asset: a plain file name that ends in `.ipa` (any case, as the unpinned rule reads it) and passes the resolver's safe token (so no path
    /// character, and at most 64 characters, the same ceiling a resolved asset's name has). The name is matched case-sensitively and in
    /// full; there are no globs and no version placeholder.
    static func isValidAssetName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".ipa") && SourceResolver.isSafeToken(name)
    }

    static func isValidBundleId(_ text: String) -> Bool {
        text.utf8.count <= 155
            && text.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) != nil
    }

    private static func isTimestamp(_ text: String) -> Bool {
        if ISO8601DateFormatter().date(from: text) != nil { return true }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) != nil
    }

    private static func ignoredWarning(_ index: Int, _ reason: String, app: String?) -> JSONValue {
        var w = warning("customSources entry \(index) is ignored: \(reason).")
        if case .object(var o) = w {
            o["index"] = .number(Double(index))
            if let app, AppRegistry.isValidName(app) { o["app"] = .string(app) }
            w = .object(o)
        }
        return w
    }

    private static func warning(_ message: String) -> JSONValue {
        CanaryCommand.warning(
            warningCode, message,
            "Fix or remove the entry in customSources in $SIDELOAD_HOME/config.json. Built-in sources are not affected."
        )
    }
}
