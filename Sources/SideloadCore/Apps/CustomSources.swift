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
/// `CUSTOM_SOURCE_IGNORED` warning, and never stops another valid entry.
///
///     {"app", "kind": "githubRelease", "repo": "<owner>/<repo>", "asset"?: "<file>.ipa" or a template with one {version},
///      "tagRule"?: "underscoreSuffix", "bundleId"?: the pin every fetched IPA must carry, "metadataHosts": ["api.github.com"], "downloadHosts": [...], "addedAt"?}
///     {"app", "kind": "altstoreIndex", "url", "bundleId", "downloadPath"?: "/<plain path>/{versionKey}/<file>.ipa",
///      "requireBuild"?: true, "metadataHosts": [<url host>], "downloadHosts": [...], "addedAt"?}
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
    private static let githubKeys = commonKeys.union(["repo", "asset", "tagRule", "bundleId"])
    private static let altstoreKeys = commonKeys.union([
        "url", "bundleId", "downloadPath", "requireBuild",
    ])
    private static let maxAddedAt = 40
    private static let maxDownloadPath = 200

    struct Outcome {
        var fetches: [String: AppDefinition.Fetch] = [:]
        var warnings: [JSONValue] = []
    }

    /// One entry that passed every check: the app it names and the source it gives that app.
    private struct Entry {
        let app: String
        let fetch: AppDefinition.Fetch
    }

    /// The valid sources by app, and one warning for every entry left out. `apps` is the apps a source may name: the registry's
    /// valid custom apps and the built-in apps that `sign` signs (the filler has no IPA).
    static func load(_ raw: JSONValue?, apps: [AppDefinition]) -> Outcome {
        guard let raw else { return Outcome() }
        guard case .array(let entries) = raw else {
            return Outcome(warnings: [
                warning("customSources is not an array, so every custom source is ignored.")
            ])
        }
        let checked = entries.map { (name: appName($0), result: check($0, apps: apps)) }
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
    private static func check(_ entry: JSONValue, apps: [AppDefinition]) -> Result<
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
        if AppRegistry.builtIns.contains(where: { $0.id == app && $0.signedByProvision }) {
            return .failure("\(app) has no IPA, so it takes no source")
        }
        guard apps.contains(where: { $0.id == app }) else {
            return .failure("\(app) is not a built-in app or a valid entry of customApps")
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
            guard case .string(let name) = declared, isValidAssetPin(name) else {
                return .failure(
                    "its asset is not a plain file name ending in .ipa or .IPA (the name itself is matched exactly), or such a name with one {version}"
                )
            }
            asset = name
        }
        var tagRule = TagRule.plain
        if let declared = fields["tagRule"] {
            guard case .string(let name) = declared, name == TagRule.underscoreSuffix.rawValue
            else { return .failure("its tagRule is not \"underscoreSuffix\"") }
            tagRule = .underscoreSuffix
        }
        var bundleId: String?
        if let declared = fields["bundleId"] {
            guard case .string(let text) = declared, isValidBundleId(text) else {
                return .failure("its bundleId is not a reverse-DNS bundle ID")
            }
            bundleId = text
        }
        guard metadata == [githubMetadataHost] else {
            return .failure("its metadataHosts is not exactly [\"\(githubMetadataHost)\"]")
        }
        guard Set(downloads).isSubset(of: githubDownloadHosts) else {
            return .failure("a downloadHosts entry is not a GitHub release host")
        }
        return .success(
            AppDefinition.Fetch(
                kind: .githubRelease(
                    repo: repo, asset: asset, tagRule: tagRule, bundleId: bundleId),
                metadataHosts: Set(metadata),
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
        var downloadPath: String?
        if let declared = fields["downloadPath"] {
            guard case .string(let path) = declared, isValidDownloadPath(path) else {
                return .failure(
                    "its downloadPath is not a plain /-separated path ending in .ipa with at most one {versionKey}"
                )
            }
            downloadPath = path
        }
        var requireBuild = false
        if let declared = fields["requireBuild"] {
            guard case .bool(true) = declared else {
                return .failure("its requireBuild is not true")
            }
            requireBuild = true
        }
        guard metadata == [url.host] else {
            return .failure("its metadataHosts is not exactly the url's host")
        }
        return .success(
            AppDefinition.Fetch(
                kind: .altstoreIndex(
                    url: url.url, bundleId: bundleId, downloadPath: downloadPath,
                    requireBuild: requireBuild),
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
    /// full; there are no globs (a template with `{version}` is `isValidAssetPin`).
    static func isValidAssetName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".ipa") && SourceResolver.isSafeToken(name)
    }

    /// A `githubRelease` `asset`: an exact name (`isValidAssetName`) or a template with one `{version}` that gives a valid name.
    static func isValidAssetPin(_ raw: String) -> Bool {
        AssetPin(raw) != nil
    }

    /// An index source's `downloadPath`: printable ASCII from `/`, plain segments (none empty, `.` or `..`), the last ending in
    /// `.ipa`, at most one `{versionKey}` and no other brace, no `%`, and at most 200 characters. The file name (with the
    /// placeholder replaced by `0`) must be a safe token, as the resolver reads a resolved file name.
    static func isValidDownloadPath(_ path: String) -> Bool {
        let pieces = path.components(separatedBy: SourceResolver.versionKeyPlaceholder)
        guard path.utf8.count <= maxDownloadPath, SourceURL.isPrintableASCII(path),
            path.hasPrefix("/"), pieces.count <= 2,
            !pieces.joined().contains("{"), !pieces.joined().contains("}"),
            !path.contains("?"), !path.contains("#"), !path.contains("%"), !path.contains("\\")
        else { return false }
        let expanded = pieces.joined(separator: "0")
        let segments = expanded.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard let last = segments.last.map(String.init) else { return false }
        return !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && last.hasSuffix(".ipa") && SourceResolver.isSafeToken(last)
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
            "Fix or remove the entry in customSources in $SIDELOAD_HOME/config.json. Other sources are not affected."
        )
    }
}
