import CryptoKit
import Foundation

/// What the owner typed for `source add` (or what the menu's Add source… collected), before anything is read.
struct SourceAddRequest: Sendable, Equatable {
    var url: String
    /// The sideload app ID; derived from the upstream name when nil.
    var app: String?
    /// The upstream bundle ID, which picks one app out of an index.
    var bundle: String?
    var platform: String?
    var name: String?
    /// The file name of the release asset to pin, for a GitHub repository that publishes several IPAs: exact, or with one
    /// `{version}` for a repository whose file names carry the release's version.
    var asset: String?
    /// `underscoreSuffix` for a GitHub repository whose tags are `v<x>_<ver>`.
    var tagRule: String?
    /// The exact path of an index app's download, with one `{versionKey}` for `<ver>b<build>` (or `<ver>`).
    var downloadPath: String?
    /// An index app whose entries must declare a build number.
    var requireBuild: Bool

    init(
        url: String, app: String? = nil, bundle: String? = nil, platform: String? = nil,
        name: String? = nil, asset: String? = nil, tagRule: String? = nil,
        downloadPath: String? = nil, requireBuild: Bool = false
    ) {
        self.url = url
        self.app = app
        self.bundle = bundle
        self.platform = platform
        self.name = name
        self.asset = asset
        self.tagRule = tagRule
        self.downloadPath = downloadPath
        self.requireBuild = requireBuild
    }
}

/// The one metadata document `source add` read from a URL, and what kind of source it says the URL is.
struct SourceProbe: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case github(repo: String)
        case altstore
    }

    let kind: Kind
    /// The URL as the owner gave it, which passed `SourceURL.parseHTTPS`.
    let url: String
    /// The host the one GET went to.
    let metadataHost: String
    let body: Data
}

/// One app a source lists. Every string came from upstream and has been through `printableCut`.
struct SourceCandidate: Sendable, Hashable {
    /// Nil for a GitHub release: its bundle ID is read from the IPA on the first fetch.
    let bundleId: String?
    let name: String
    let version: String
    let size: Int64?
    let hasDigest: Bool

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name), "version": .string(version), "hasDigest": .bool(hasDigest),
        ]
        if let bundleId { o["bundleId"] = .string(bundleId) }
        if let size { o["size"] = .number(Double(size)) }
        return .object(o)
    }
}

/// What `source add` would write, worked out from one metadata GET and the config. `confirm` is what the owner confirms: it
/// covers the trust the source is given (kind, address, upstream bundle ID, the app and the exact hosts) and not the version or
/// digest, so a new release is not a changed source.
struct SourcePlan: Sendable, Hashable {
    /// `githubRelease` or `altstoreIndex`, as spelled in `customSources`.
    let kind: String
    let url: String
    /// `<owner>/<repo>` of a GitHub source.
    let repo: String?
    /// The IPA file name (or `{version}` template) a GitHub source is pinned to; nil when the release must have exactly one IPA.
    let asset: String?
    /// `underscoreSuffix` for a GitHub source whose tags are `v<x>_<ver>`; nil for the plain tag.
    let tagRule: String?
    /// The exact download path of an index source, with its `{versionKey}`; nil when the path is not pinned.
    let downloadPath: String?
    /// An index source that insists on a build number.
    let requireBuild: Bool
    /// The upstream bundle ID of an index app.
    let bundleId: String?
    /// The latest version the source offers now.
    let version: String
    let size: Int64
    let metadataHost: String
    /// Sorted.
    let downloadHosts: [String]
    let appId: String
    let suffix: String
    let platform: String
    let name: String
    /// The app is an existing custom app with no source; nothing is added to `customApps`.
    let attaches: Bool
    let freeBundleId: String
    let confirm: String

    var isGithub: Bool { kind == "githubRelease" }

    var appJSON: JSONValue {
        [
            "id": .string(appId), "suffix": .string(suffix), "platform": .string(platform),
            "name": .string(name), "exists": .bool(attaches),
        ]
    }

    /// The `--name` the command line needs: only a name that is not the default, and only for a new app.
    private var explicitName: String? {
        attaches || name == MenuFormat.capitalised(appId) ? nil : name
    }

    /// The `source add` command that writes exactly this plan, with every choice spelled out.
    var command: String {
        var parts = [
            "sideload source add --url \(SourceAdd.shellQuote(url))", "--app \(appId)",
        ]
        if let bundleId { parts.append("--bundle \(bundleId)") }
        if let asset { parts.append("--asset \(SourceAdd.shellQuote(asset))") }
        if let tagRule { parts.append("--tag-rule \(tagRule)") }
        if requireBuild { parts.append("--require-build") }
        if let downloadPath {
            parts.append("--download-path \(SourceAdd.shellQuote(downloadPath))")
        }
        parts.append("--platform \(platform)")
        if let explicitName { parts.append("--name \(SourceAdd.shellQuote(explicitName))") }
        parts.append("--confirm \(confirm) --yes")
        return parts.joined(separator: " ")
    }
}

/// `source add`'s reading of a source and its writes (design section 8, custom sources). The command and the menu's Add
/// source… both call `probe`, `preview` and `commit`, so the checks are written once. Reading is one bounded GET through
/// `Services.http`; only `write` changes `config.json`, and nothing here downloads an IPA.
enum SourceAdd {
    /// The most apps a preview lists.
    static let maxListed = 50
    static let command = "source add"
    /// The code of a source that is not what the owner reviewed (`--yes` and the menu's click both end with it).
    static let changedCode = "SOURCE_CHANGED"

    // MARK: arguments

    /// A malformed `--app`, `--bundle`, `--platform`, `--name`, `--asset`, `--tag-rule` or `--download-path`, before anything is
    /// read.
    static func validate(_ request: SourceAddRequest) throws {
        if let app = request.app, !AppRegistry.isValidName(app) {
            throw invalidArgument(
                "--app is not 1 to 31 of a-z, 0-9 and -, starting with a letter or digit.")
        }
        if let bundle = request.bundle, !CustomSources.isValidBundleId(bundle) {
            throw invalidArgument("--bundle is not a reverse-DNS bundle ID.")
        }
        if let asset = request.asset, !CustomSources.isValidAssetPin(asset) {
            throw invalidArgument(
                "--asset is not a plain .ipa file name (letters, digits, `.`, `_` and `-`, at most 64 characters, ending in .ipa or .IPA in any case; the name itself is matched exactly), nor such a name with one {version}."
            )
        }
        if let rule = request.tagRule, rule != TagRule.underscoreSuffix.rawValue {
            throw invalidArgument("--tag-rule is not underscoreSuffix.")
        }
        if let path = request.downloadPath, !CustomSources.isValidDownloadPath(path) {
            throw invalidArgument(
                "--download-path is not a plain /-separated path ending in .ipa with at most one {versionKey} (at most 200 characters)."
            )
        }
        if let platform = request.platform, !AppRegistry.platforms.contains(platform) {
            throw invalidArgument("--platform is not ios or tvos.")
        }
        if let name = request.name, !AppRegistry.isValidDisplayName(name) {
            throw invalidArgument(
                "--name is not 1 to \(AppRegistry.maxDisplayName) printable characters with no outer spaces."
            )
        }
    }

    private static func invalidArgument(_ message: String) -> SideloadError {
        SideloadError("INVALID_ARGUMENT", message, fix: "Run `sideload help`.")
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: probe

    /// Checks the URL with the rules `customSources` is loaded by, then makes the one metadata GET: a GitHub repository is its
    /// latest release on the API, any other URL has to answer with an AltStore index.
    static func probe(_ services: Services, url raw: String) async throws -> SourceProbe {
        let parsed: SourceURL.Parsed
        switch SourceURL.parseHTTPS(raw) {
        case .success(let value): parsed = value
        case .failure(let reason):
            throw SideloadError(
                "SOURCE_NOT_ALLOWED", "The source URL is refused: \(reason.text).",
                fix:
                    "Use https://github.com/<owner>/<repo> or the https address of an AltStore index, with no credentials, port, query or fragment."
            )
        }
        let source: FetchSource
        let kind: SourceProbe.Kind
        if let repo = githubRepo(parsed) {
            kind = .github(repo: repo)
            source = FetchSource(
                app: "source", kind: .customGithubRelease(repo: repo, asset: nil),
                metadataHosts: [CustomSources.githubMetadataHost],
                downloadHosts: CustomSources.githubDownloadHosts)
        } else {
            kind = .altstore
            source = FetchSource(
                app: "source", kind: .customAltstoreIndex(url: parsed.url, bundleId: ""),
                metadataHosts: [parsed.host], downloadHosts: [])
        }
        let body = try await SourceMetadata.fetch(services, source, command: command)
        let host = source.metadataURL.host ?? parsed.host
        let probe = SourceProbe(kind: kind, url: parsed.url, metadataHost: host, body: body)
        if case .altstore = kind, try indexApps(body).isEmpty {
            throw unknownKind
        }
        return probe
    }

    private static var unknownKind: SideloadError {
        SideloadError(
            "SOURCE_KIND_UNKNOWN",
            "The address did not answer with an AltStore index that lists an app, and it is not a GitHub repository.",
            fix:
                "Only https://github.com/<owner>/<repo> and AltStore-format indexes ({\"apps\": [...]}) can be added."
        )
    }

    /// `https://github.com/<owner>/<repo>` and nothing else: exactly two path segments of plain GitHub names.
    private static func githubRepo(_ parsed: SourceURL.Parsed) -> String? {
        guard parsed.host == "github.com" else { return nil }
        let path = String(parsed.url.dropFirst("https://github.com/".count))
        guard path.split(separator: "/", omittingEmptySubsequences: false).count == 2,
            CustomSources.isValidRepo(path)
        else { return nil }
        return path
    }

    // MARK: reading the document

    private struct IndexApp {
        let bundleId: String
        let name: String
        let tvos: Bool
        let latest: SourceResolver.Index.Version
    }

    /// The apps of an AltStore index that can be pinned: a valid bundle ID and at least one version. Throws
    /// `SOURCE_KIND_UNKNOWN` when the document is not an index at all.
    private static func indexApps(_ body: Data) throws -> [IndexApp] {
        guard let index = try? JSONDecoder().decode(SourceResolver.Index.self, from: body),
            let apps = index.apps
        else { throw unknownKind }
        return apps.compactMap { app in
            guard let bundleId = app.bundleIdentifier, CustomSources.isValidBundleId(bundleId),
                let latest = app.versions?.first
            else { return nil }
            let name = printableCut(app.name?.text ?? "")
            let platform = app.platform?.text?.lowercased()
            return IndexApp(
                bundleId: bundleId, name: name.isEmpty ? printableCut(bundleId) : name,
                tvos: platform == "tvos" || platform == "appletvos", latest: latest)
        }
    }

    private static func candidate(_ app: IndexApp) -> SourceCandidate {
        SourceCandidate(
            bundleId: app.bundleId, name: app.name,
            version: printableCut(app.latest.version?.text ?? "?"), size: app.latest.size,
            hasDigest: (try? SourceResolver.parseDigest(app.latest.sha256, prefixed: false)) != nil)
    }

    /// The apps of an index, at most `maxListed`, and whether more were left out. A GitHub release is its one asset: the pinned
    /// one, or the only `.ipa`. A release with several IPAs and no pin lists them all (`preview` refuses it as
    /// `SOURCE_AMBIGUOUS`; the menu asks which).
    static func listing(_ probe: SourceProbe, asset: String? = nil, tagRule: TagRule = .plain)
        throws
        -> (
            apps: [SourceCandidate], truncated: Bool
        )
    {
        switch probe.kind {
        case .github(let repo):
            if asset == nil {
                let release = SourceResolver.githubIpas(json: probe.body)
                if release.ipas.count > 1 {
                    let candidates = release.ipas.prefix(maxListed).map {
                        SourceCandidate(
                            bundleId: nil, name: printableCut($0.name), version: release.version,
                            size: $0.size, hasDigest: $0.hasDigest)
                    }
                    return (candidates, release.ipas.count > maxListed)
                }
            }
            let resolved = try SourceResolver.customGithub(
                app: "source", repo: repo, asset: asset, tagRule: tagRule, json: probe.body)
            return ([githubCandidate(resolved, repo: repo)], false)
        case .altstore:
            let all = try indexApps(probe.body)
            return (all.prefix(maxListed).map(candidate), all.count > maxListed)
        }
    }

    private static func githubCandidate(_ asset: ResolvedAsset, repo: String) -> SourceCandidate {
        SourceCandidate(
            bundleId: nil, name: printableCut(asset.fileName), version: asset.version,
            size: asset.size, hasDigest: true)
    }

    // MARK: plan

    struct Preview: Sendable {
        let plan: SourcePlan
        let apps: [SourceCandidate]
        let truncated: Bool
    }

    /// Everything the preview shows and `--yes` writes: the picked app and version from the document, the hosts, the app's
    /// identity and the confirm value. Pure given the probe and the config. Throws `SOURCE_AMBIGUOUS` for an index of several
    /// apps without `request.bundle`.
    static func preview(_ probe: SourceProbe, request: SourceAddRequest, config: Config) throws
        -> Preview
    {
        try validate(request)
        let tagRule = request.tagRule.flatMap(TagRule.init(rawValue:)) ?? .plain
        let listed = try listing(probe, asset: request.asset, tagRule: tagRule)
        let kind: String
        let repo: String?
        let bundleId: String?
        let asset: ResolvedAsset
        let downloadHosts: [String]
        let nameSource: String
        var detectedPlatform: String?
        switch probe.kind {
        case .github(let named):
            if request.bundle != nil {
                throw invalidArgument(
                    "--bundle picks an app out of an index, not a GitHub release.")
            }
            if request.downloadPath != nil || request.requireBuild {
                throw invalidArgument(
                    "--download-path and --require-build describe an app of an index, not a GitHub release."
                )
            }
            kind = "githubRelease"
            repo = named
            bundleId = nil
            if request.asset == nil, listed.apps.count > 1 {
                throw githubAmbiguous(listed)
            }
            asset = try SourceResolver.customGithub(
                app: "source", repo: named, asset: request.asset, tagRule: tagRule,
                json: probe.body)
            // Only a pin is read for a default platform: an unpinned single IPA keeps today's plan and confirm value.
            if let pinned = request.asset, pinned.lowercased().contains("tvos") {
                detectedPlatform = "tvos"
            }
            downloadHosts = CustomSources.githubDownloadHosts.sorted()
            nameSource = String(named.split(separator: "/")[1])
        case .altstore:
            if request.asset != nil {
                throw invalidArgument(
                    "--asset picks a release asset of a GitHub repository, not an app of an index; use --bundle."
                )
            }
            if request.tagRule != nil {
                throw invalidArgument(
                    "--tag-rule reads a GitHub release's tag, not an index.")
            }
            kind = "altstoreIndex"
            repo = nil
            let app = try pick(probe, bundle: request.bundle, listed: listed)
            bundleId = app.bundleId
            downloadHosts = try hosts(of: app)
            asset = try SourceResolver.customAltstore(
                app: "source", bundleId: app.bundleId, hosts: Set(downloadHosts),
                downloadPath: request.downloadPath, requireBuild: request.requireBuild,
                json: probe.body)
            nameSource = app.name
            if app.tvos { detectedPlatform = "tvos" }
        }

        let id: String
        if let given = request.app {
            id = given
        } else if let derived = deriveID(nameSource) {
            id = derived
        } else {
            throw invalidArgument("An app ID could not be derived from the source's name.")
        }
        guard let prefix = config.bundleIdPrefix, CanaryCommand.isValidPrefix(prefix) else {
            throw SideloadError(
                "CONFIG_MISSING", "bundleIdPrefix is missing or invalid in config.json.",
                fix: "Add \"bundleIdPrefix\": \"com.yourname\" to $SIDELOAD_HOME/config.json.")
        }
        let target = try resolveApp(
            config, id: id, platform: request.platform, detected: detectedPlatform,
            name: request.name)
        let free = prefix + ".free." + target.suffix
        let metadataHost = probe.metadataHost
        let confirm = confirmValue(
            kind: kind, url: probe.url, repo: repo, asset: request.asset,
            tagRule: tagRule == .plain ? nil : tagRule.rawValue,
            downloadPath: request.downloadPath, requireBuild: request.requireBuild,
            bundleId: bundleId, app: target, metadataHosts: [metadataHost],
            downloadHosts: downloadHosts)
        let plan = SourcePlan(
            kind: kind, url: probe.url, repo: repo, asset: request.asset,
            tagRule: tagRule == .plain ? nil : tagRule.rawValue,
            downloadPath: request.downloadPath, requireBuild: request.requireBuild,
            bundleId: bundleId, version: asset.version,
            size: asset.size, metadataHost: metadataHost, downloadHosts: downloadHosts,
            appId: target.id, suffix: target.suffix, platform: target.platform, name: target.name,
            attaches: target.attaches, freeBundleId: free, confirm: confirm)
        return Preview(plan: plan, apps: listed.apps, truncated: listed.truncated)
    }

    /// A release with several `.ipa` assets and no `--asset`: there is no add-all and no guessing, so the names are listed.
    private static func githubAmbiguous(_ listed: (apps: [SourceCandidate], truncated: Bool))
        -> SideloadError
    {
        let names = listed.apps.prefix(10).map(\.name).joined(separator: ", ")
        return SideloadError(
            "SOURCE_AMBIGUOUS",
            "The release has \(listed.apps.count)\(listed.truncated ? " or more" : "") .ipa assets; there is no add-all.",
            fix:
                "Re-run with --asset <file name>, one of those in `candidates` (\(names)\(listed.apps.count > 10 ? ", ..." : "")).",
            data: [
                "candidates": .array(listed.apps.map(\.json)), "truncated": .bool(listed.truncated),
            ])
    }

    /// The index app the request names, or the only one.
    private static func pick(
        _ probe: SourceProbe, bundle: String?, listed: (apps: [SourceCandidate], truncated: Bool)
    ) throws -> IndexApp {
        let apps = try indexApps(probe.body)
        if let bundle {
            guard let found = apps.first(where: { $0.bundleId == bundle }) else {
                throw SideloadError(
                    "SOURCE_NOT_FOUND", "The index lists no app with that bundle ID.",
                    fix: "Pick one of the bundle IDs in `apps`.",
                    data: listData(listed))
            }
            return found
        }
        guard apps.count == 1, let only = apps.first else {
            throw SideloadError(
                "SOURCE_AMBIGUOUS", "The index lists \(apps.count) apps; there is no add-all.",
                fix: "Re-run with --bundle <bundle ID>, one of those in `apps`.",
                data: listData(listed))
        }
        return only
    }

    private static func listData(_ listed: (apps: [SourceCandidate], truncated: Bool)) -> [String:
        JSONValue]
    {
        ["apps": .array(listed.apps.map(\.json)), "truncated": .bool(listed.truncated)]
    }

    /// The host of the app's latest download, plus GitHub's two object-store hosts when that host is `github.com`.
    private static func hosts(of app: IndexApp) throws -> [String] {
        guard let link = app.latest.downloadURL, let host = URLComponents(string: link)?.host,
            SourceURL.isValidHost(host)
        else {
            throw SideloadError(
                "SOURCE_NOT_ALLOWED", "The latest download URL is not on a valid host name.",
                fix: "Nothing was added.")
        }
        var hosts: Set<String> = [host]
        if host == "github.com" {
            hosts.formUnion(CustomSources.githubDownloadHosts)
        }
        return hosts.sorted()
    }

    /// A lowercase DNS-style label from an upstream name; nil when nothing usable is left.
    static func deriveID(_ text: String) -> String? {
        var id = ""
        for scalar in text.lowercased().unicodeScalars {
            let plain =
                (scalar.value >= 0x61 && scalar.value <= 0x7a)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
            if plain {
                id.unicodeScalars.append(scalar)
            } else if !id.isEmpty, !id.hasSuffix("-") {
                id.append("-")
            }
        }
        id = String(id.prefix(31))
        while id.hasSuffix("-") { id.removeLast() }
        return AppRegistry.isValidName(id) ? id : nil
    }

    // MARK: the app

    struct AppTarget {
        let id: String
        let suffix: String
        let platform: String
        let name: String
        /// An existing custom app with no source.
        let attaches: Bool
    }

    /// The `customApps` / `customSources` entries as written in the file, or `CONFIG_INVALID` when the key is not an array.
    static func entries(_ config: Config, _ key: String) throws -> [JSONValue] {
        switch config.extra[key] {
        case nil: return []
        case .array(let list)?: return list
        default:
            throw SideloadError(
                "CONFIG_INVALID", "config.json \(key) is not an array.",
                fix: "Fix or remove \(key) in $SIDELOAD_HOME/config.json.")
        }
    }

    static func field(_ entry: JSONValue, _ key: String) -> String? {
        guard case .object(let fields) = entry, case .string(let text)? = fields[key] else {
            return nil
        }
        return text
    }

    /// Whether `id` can be added as a new app, or is an existing custom app that can be given this source. Written to be
    /// checked again under the lock against the config as it is then.
    static func resolveApp(
        _ config: Config, id: String, platform: String?, detected: String?, name: String?
    ) throws -> AppTarget {
        if AppRegistry.builtIns.contains(where: { $0.id == id }) {
            throw appExists("\(id) is a built-in app.")
        }
        let customSources = try entries(config, "customSources")
        let customApps = try entries(config, "customApps")
        if customSources.contains(where: { field($0, "app") == id }) {
            throw SideloadError(
                "SOURCE_EXISTS", "\(id) already has a customSources entry.",
                fix: "Remove it first: `sideload source remove --app \(id)`.")
        }
        let registry = config.appRegistry
        if let app = registry.app(id), !app.builtIn {
            guard platform == nil || platform == app.devicePlatform else {
                throw appExists(
                    "\(id) is an existing custom app for \(app.devicePlatform); --platform \(platform ?? "") does not match."
                )
            }
            guard name == nil else {
                throw invalidArgument("--name cannot rename the existing app \(id).")
            }
            return AppTarget(
                id: id, suffix: app.suffix, platform: app.devicePlatform, name: app.displayName,
                attaches: true)
        }
        // An entry the registry left out still holds its ID and suffix: a new app must not collide with it.
        if customApps.contains(where: { field($0, "id") == id }) {
            throw appExists("customApps already has an entry for \(id) that is not valid.")
        }
        if let taken = AppRegistry.builtIns.first(where: { $0.suffix == id }) {
            throw appExists("the suffix \(id) belongs to the built-in app \(taken.id).")
        }
        if customApps.contains(where: { (field($0, "suffix") ?? field($0, "id")) == id })
            || registry.apps.contains(where: { $0.suffix == id })
        {
            throw appExists("another custom app has the suffix \(id).")
        }
        return AppTarget(
            id: id, suffix: id, platform: platform ?? detected ?? "ios",
            name: name ?? MenuFormat.capitalised(id), attaches: false)
    }

    private static func appExists(_ message: String) -> SideloadError {
        SideloadError(
            "APP_EXISTS", "Cannot add the app: \(message)",
            fix: "Pass another --app ID, or run `sideload source list` and `sideload status`.")
    }

    // MARK: confirm

    /// The first 16 hex characters of SHA-256 over the sorted-key JSON of what the owner trusts. Version and digest are left
    /// out on purpose: a new release is not a change of trust.
    static func confirmValue(
        kind: String, url: String, repo: String?, asset: String? = nil, tagRule: String? = nil,
        downloadPath: String? = nil, requireBuild: Bool = false, bundleId: String?,
        app: AppTarget, metadataHosts: [String], downloadHosts: [String]
    ) -> String {
        // `attaches` is part of what is confirmed: giving an existing app a source and creating a new app are different writes.
        var fields: [String: JSONValue] = [
            "kind": .string(kind), "id": .string(app.id), "suffix": .string(app.suffix),
            "attaches": .bool(app.attaches),
            "platform": .string(app.platform),
            "metadataHosts": .array(metadataHosts.sorted().map(JSONValue.string)),
            "downloadHosts": .array(downloadHosts.sorted().map(JSONValue.string)),
        ]
        if let repo { fields["repo"] = .string(repo) } else { fields["url"] = .string(url) }
        if let bundleId { fields["bundleId"] = .string(bundleId) }
        // Which IPA is trusted is part of the trust; an unpinned source leaves the key out, so its value is what it always was.
        if let asset { fields["asset"] = .string(asset) }
        // The same for the three template-pin fields: a source without them hashes as it did before they existed.
        if let tagRule { fields["tagRule"] = .string(tagRule) }
        if let downloadPath { fields["downloadPath"] = .string(downloadPath) }
        if requireBuild { fields["requireBuild"] = .bool(true) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSONValue.object(fields))) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: write

    struct Written: Sendable, Equatable {
        var customApps: Bool
        var customSources: Bool
        var approvedSources: Bool
    }

    /// The three entries `--yes` adds, in one edit of the config. It checks the app and the source again against the config
    /// as it is now, and refuses (writing nothing) unless the result loads as a valid source for the app.
    static func write(_ plan: SourcePlan, into config: inout Config, now: Date) throws -> Written {
        let target = try resolveApp(
            config, id: plan.appId, platform: plan.platform, detected: nil, name: nil)
        // The app must be what the owner confirmed: an existing app given a source, or a new one. A customApps entry that came or
        // went since the preview would otherwise write something nobody reviewed.
        guard target.attaches == plan.attaches, target.suffix == plan.suffix else {
            throw SideloadError(
                changedCode,
                "The app changed since the preview: \(plan.attaches ? "the existing app is gone" : "an app with this ID now exists").",
                fix:
                    "Nothing was written. Run `sideload source add --url <url>` again and review it."
            )
        }
        var written = Written(customApps: false, customSources: true, approvedSources: false)
        var apps = try entries(config, "customApps")
        if !target.attaches {
            var entry: [String: JSONValue] = [
                "id": .string(plan.appId), "platform": .string(plan.platform),
            ]
            if plan.name != MenuFormat.capitalised(plan.appId) {
                entry["name"] = .string(plan.name)
            }
            apps.append(.object(entry))
            config.extra["customApps"] = .array(apps)
            written.customApps = true
        }
        var source: [String: JSONValue] = [
            "app": .string(plan.appId), "kind": .string(plan.kind),
            "metadataHosts": [.string(plan.metadataHost)],
            "downloadHosts": .array(plan.downloadHosts.map(JSONValue.string)),
            "addedAt": .string(ISO8601DateFormatter().string(from: now)),
        ]
        if let repo = plan.repo { source["repo"] = .string(repo) }
        if let asset = plan.asset { source["asset"] = .string(asset) }
        if let tagRule = plan.tagRule { source["tagRule"] = .string(tagRule) }
        if let bundleId = plan.bundleId {
            source["url"] = .string(plan.url)
            source["bundleId"] = .string(bundleId)
        }
        if let downloadPath = plan.downloadPath { source["downloadPath"] = .string(downloadPath) }
        if plan.requireBuild { source["requireBuild"] = .bool(true) }
        var sources = try entries(config, "customSources")
        sources.append(.object(source))
        config.extra["customSources"] = .array(sources)
        let approved = config.approvedSources.contains {
            guard case .object(let o) = $0 else { return false }
            return o["app"] == .string(plan.appId)
        }
        if !approved {
            config.approvedSources.append(["app": .string(plan.appId)])
            written.approvedSources = true
        }
        // The same loader `fetch` uses must accept what was written, or nothing is.
        guard config.appRegistry.app(plan.appId)?.fetch != nil else {
            throw SideloadError(
                "SOURCE_NOT_ALLOWED", "The entry would not load as a valid source.",
                fix: "Nothing was written.")
        }
        return written
    }

    // MARK: output

    static func previewJSON(_ preview: Preview) -> [String: JSONValue] {
        let plan = preview.plan
        var out: [String: JSONValue] = [
            "preview": true, "written": false, "kind": .string(plan.kind), "url": .string(plan.url),
            "metadataHost": .string(plan.metadataHost),
            "downloadHosts": .array(plan.downloadHosts.map(JSONValue.string)),
            "apps": .array(preview.apps.map(\.json)), "truncated": .bool(preview.truncated),
            "version": .string(plan.version), "app": plan.appJSON,
            "freeBundleId": .string(plan.freeBundleId), "confirm": .string(plan.confirm),
            "next": .string(
                "Nothing was written. The owner adds this source with: \(plan.command)"),
        ]
        if let repo = plan.repo { out["repo"] = .string(repo) }
        if let asset = plan.asset { out["asset"] = .string(asset) }
        if let tagRule = plan.tagRule { out["tagRule"] = .string(tagRule) }
        if let bundleId = plan.bundleId { out["bundleId"] = .string(bundleId) }
        if let downloadPath = plan.downloadPath { out["downloadPath"] = .string(downloadPath) }
        if plan.requireBuild { out["requireBuild"] = true }
        return out
    }
}
