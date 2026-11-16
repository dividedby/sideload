import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// `customSources` in config.json (issue #47, PR A): strict load validation, the registry attach, the one approval gate and
// `source list`. Offline: a temp home and fakes; nothing opens a socket.

let customPrefix = "io.github.dividedby"
private let githubHosts: JSONValue = [
    "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
]

/// A GitHub source entry for the custom app `myapp`.
let githubEntry: [String: JSONValue] = [
    "app": "myapp", "kind": "githubRelease", "repo": "acme/widget",
    "metadataHosts": ["api.github.com"], "downloadHosts": githubHosts,
    "addedAt": "2026-11-15T12:00:00Z",
]

/// An AltStore source entry for `myapp`.
let altstoreEntry: [String: JSONValue] = [
    "app": "myapp", "kind": "altstoreIndex", "url": "https://index.example.org/apps/index.json",
    "bundleId": "io.example.apollo", "metadataHosts": ["index.example.org"],
    "downloadHosts": ["cdn.example.org"], "addedAt": "2026-11-15T12:00:00Z",
]

/// A config with the custom app `myapp`, the given `customSources` and the owner's approval of apollo and `approved`.
func customConfig(
    sources: [[String: JSONValue]], approved: [JSONValue] = [["app": "myapp"]],
    devices: [String: SavedDevice] = iphoneConfig().devices
) -> Config {
    Config(
        devices: devices, approvedSources: apolloApproved + approved, bundleIdPrefix: customPrefix,
        extra: [
            "customApps": [["id": "myapp", "platform": "ios"]],
            "customSources": .array(sources.map(JSONValue.object)),
        ])
}

private func codes(_ registry: AppRegistry) -> [String] {
    registry.warnings.compactMap { $0["code"]?.string }
}

private func messages(_ registry: AppRegistry) -> [String] {
    registry.warnings.compactMap { $0["message"]?.string }
}

private typealias Edit = @Sendable (inout [String: JSONValue]) -> Void

private struct Bad: Sendable, CustomTestStringConvertible {
    let name: String
    let github: Bool
    let edit: Edit
    var testDescription: String { name }

    init(_ name: String, github: Bool = false, _ edit: @escaping Edit) {
        self.name = name
        self.github = github
        self.edit = edit
    }

    /// An AltStore entry whose index URL (and so its metadata host) is `url`.
    static func url(_ name: String, _ url: String, host: String) -> Bad {
        Bad(name) {
            $0["url"] = .string(url)
            $0["metadataHosts"] = .array([.string(host)])
        }
    }

    static func downloads(_ name: String, github: Bool = false, _ hosts: [JSONValue]) -> Bad {
        Bad(name, github: github) { $0["downloadHosts"] = .array(hosts) }
    }
}

private let manyHosts: [JSONValue] = (1...5).map { .string("cdn\($0).example.org") }

private let refusals: [Bad] = [
    // shape
    Bad("an unknown key (github)", github: true) { $0["extra"] = "x" },
    Bad("an unknown key (altstore)") { $0["tvos"] = true },
    Bad("a url on a github entry", github: true) { $0["url"] = "https://index.example.org/a.json" },
    Bad("a repo on an altstore entry") { $0["repo"] = "acme/widget" },
    Bad("an unknown kind") { $0["kind"] = "ftp" },
    Bad("a missing kind") { $0["kind"] = nil },
    Bad("a bad addedAt") { $0["addedAt"] = "yesterday" },
    Bad("a built-in app") { $0["app"] = "apollo" },
    Bad("an app that is not in customApps") { $0["app"] = "other" },
    Bad("an app that is not a string") { $0["app"] = 7 },
    // URL
    .url("http", "http://index.example.org/a.json", host: "index.example.org"),
    .url("a user name", "https://user@index.example.org/a.json", host: "index.example.org"),
    .url("credentials", "https://user:pw@index.example.org/a.json", host: "index.example.org"),
    .url("a port", "https://index.example.org:8443/a.json", host: "index.example.org"),
    .url(
        "the default port spelled out", "https://index.example.org:443/a.json",
        host: "index.example.org"),
    .url("a query", "https://index.example.org/a.json?x=1", host: "index.example.org"),
    .url("a fragment", "https://index.example.org/a.json#top", host: "index.example.org"),
    .url("a non-ASCII path", "https://index.example.org/\u{e4}.json", host: "index.example.org"),
    .url("a space", "https://index.example.org/a b.json", host: "index.example.org"),
    .url("a backslash", "https://index.example.org/a\\b.json", host: "index.example.org"),
    .url("a dot-dot path", "https://index.example.org/../a.json", host: "index.example.org"),
    .url("no path", "https://index.example.org", host: "index.example.org"),
    .url("an xn-- host", "https://xn--exmple-cua.org/a.json", host: "xn--exmple-cua.org"),
    .url("an IPv4 host", "https://192.0.2.1/a.json", host: "192.0.2.1"),
    .url("an IPv6 host", "https://[::1]/a.json", host: "[::1]"),
    .url("a trailing dot", "https://index.example.org./a.json", host: "index.example.org."),
    .url("localhost", "https://localhost/a.json", host: "localhost"),
    .url("a host under localhost", "https://index.localhost/a.json", host: "index.localhost"),
    .url("an upper-case host", "https://Index.example.org/a.json", host: "Index.example.org"),
    Bad("a missing url") { $0["url"] = nil },
    Bad("a bundle ID that is not reverse-DNS") { $0["bundleId"] = "nodots" },
    Bad("a metadata host that is not the url's host") {
        $0["metadataHosts"] = ["other.example.org"]
    },
    // hosts
    .downloads("a wildcard host", ["*.example.org"]),
    .downloads("a single-label host", ["cdn"]),
    .downloads("an xn-- download host", ["xn--exmple-cua.org"]),
    .downloads("an IP literal download host", ["192.0.2.1"]),
    .downloads("a trailing-dot download host", ["cdn.example.org."]),
    .downloads("localhost as a download host", ["localhost"]),
    .downloads("an upper-case download host", ["CDN.example.org"]),
    .downloads("a host with a port", ["cdn.example.org:443"]),
    .downloads("a host that is not a string", [1]),
    .downloads("more than 4 hosts", manyHosts),
    .downloads("no download host", []),
    .downloads("a host listed twice", ["cdn.example.org", "cdn.example.org"]),
    // GitHub
    .downloads(
        "a GitHub download host outside the set", github: true, ["github.com", "evil.example.org"]),
    .downloads("more than 4 GitHub hosts", github: true, manyHosts),
    Bad("a GitHub metadata host that is not api.github.com", github: true) {
        $0["metadataHosts"] = ["evil.example.org"]
    },
    Bad("a repo with no owner", github: true) { $0["repo"] = "widget" },
    Bad("a repo with a dot-dot", github: true) { $0["repo"] = "acme/wid..get" },
    Bad("a repo that is a single dot", github: true) { $0["repo"] = "acme/." },
    Bad("a repo with a third part", github: true) { $0["repo"] = "acme/widget/x" },
    Bad("a repo with a space", github: true) { $0["repo"] = "acme/wid get" },
    Bad("an owner of 40 characters", github: true) {
        $0["repo"] = .string(String(repeating: "a", count: 40) + "/widget")
    },
    Bad("a repository of 101 characters", github: true) {
        $0["repo"] = .string("acme/" + String(repeating: "a", count: 101))
    },
]

@Suite("custom sources: load validation")
struct CustomSourceValidationTests {
    @Test(
        "a bad entry is left out with CUSTOM_SOURCE_IGNORED; built-ins and the custom app stay",
        arguments: refusals)
    fileprivate func refused(_ bad: Bad) throws {
        var entry = bad.github ? githubEntry : altstoreEntry
        bad.edit(&entry)
        let config = customConfig(sources: [entry])
        let registry = config.appRegistry
        #expect(codes(registry) == ["CUSTOM_SOURCE_IGNORED"], "\(messages(registry))")
        #expect(registry.app("myapp") != nil && registry.app("myapp")?.fetch == nil)
        #expect(registry.fetchSources.map(\.app) == ["apollo", "stremio-ios", "stremio-tvos"])
        #expect(registry.app("apollo")?.fetch == AppDefinition.apollo.fetch)
        let source = try FetchCatalog.approved(app: "apollo", config: config)
        #expect(source.kind == AppDefinition.apollo.fetch?.kind)
        #expect(throws: SideloadError.self) {
            try FetchCatalog.approved(app: "myapp", config: config)
        }
    }

    @Test("the warning says which entry, and never echoes the bad value")
    func warningText() throws {
        var entry = altstoreEntry
        entry["url"] = "https://user:s3cret@index.example.org/a.json"
        let warning = try #require(customConfig(sources: [entry]).appRegistry.warnings.first)
        #expect(warning["index"] == 0 && warning["app"] == "myapp")
        let text = try #require(warning["message"]?.string) + (warning["fix"]?.string ?? "")
        #expect(
            text.hasPrefix("customSources entry 0 is ignored: its url has a user name or password"))
        #expect(!text.contains("s3cret"))
        #expect(warning["fix"]?.string?.contains("customSources") == true)
    }

    @Test("the valid shapes attach to the custom app, with exactly their hosts")
    func valid() throws {
        let github = customConfig(sources: [githubEntry]).appRegistry
        #expect(github.warnings.isEmpty)
        let ghFetch = try #require(github.app("myapp")?.fetch)
        #expect(ghFetch.kind == .customGithubRelease(repo: "acme/widget"))
        #expect(ghFetch.metadataHosts == ["api.github.com"])
        #expect(
            ghFetch.downloadHosts == [
                "github.com", "objects.githubusercontent.com",
                "release-assets.githubusercontent.com",
            ])
        #expect(ghFetch.kind.isThirdParty && ghFetch.kind.isCustom)

        let alt = customConfig(sources: [altstoreEntry]).appRegistry
        #expect(alt.warnings.isEmpty)
        let altFetch = try #require(alt.app("myapp")?.fetch)
        #expect(
            altFetch.kind
                == .customAltstoreIndex(
                    url: "https://index.example.org/apps/index.json", bundleId: "io.example.apollo")
        )
        #expect(altFetch.metadataHosts == ["index.example.org"])
        #expect(altFetch.downloadHosts == ["cdn.example.org"])
        #expect(altFetch.kind.isThirdParty)
        #expect(!(AppDefinition.apollo.fetch?.kind.isCustom ?? true))
        // Exactly 4 hosts and an addedAt with fractional seconds are fine.
        var four = altstoreEntry
        four["downloadHosts"] = .array(Array(manyHosts.prefix(4)))
        four["addedAt"] = "2026-11-15T12:00:00.250Z"
        #expect(customConfig(sources: [four]).appRegistry.warnings.isEmpty)
        // addedAt is optional.
        var plain = githubEntry
        plain["addedAt"] = nil
        #expect(customConfig(sources: [plain]).appRegistry.warnings.isEmpty)
    }

    @Test("two entries for one app are both left out, whether or not the other is valid")
    func duplicates() {
        var other = githubEntry
        other["repo"] = "acme/other"
        let both = customConfig(sources: [githubEntry, other]).appRegistry
        #expect(codes(both) == ["CUSTOM_SOURCE_IGNORED", "CUSTOM_SOURCE_IGNORED"])
        #expect(both.app("myapp")?.fetch == nil)
        #expect(messages(both).allSatisfy { $0.contains("names the same app") })

        var broken = altstoreEntry
        broken["url"] = "http://index.example.org/a.json"
        let mixed = customConfig(sources: [githubEntry, broken]).appRegistry
        #expect(codes(mixed).count == 2 && mixed.app("myapp")?.fetch == nil)
    }

    @Test("one bad entry never stops another valid one")
    func independent() throws {
        var config = customConfig(sources: [])
        var good = altstoreEntry
        good["app"] = "second"
        var bad = githubEntry
        bad["repo"] = "nope"
        config.extra["customApps"] = [
            ["id": "myapp", "platform": "ios"], ["id": "second", "platform": "ios"],
        ]
        config.extra["customSources"] = .array([.object(bad), .object(good)])
        let registry = config.appRegistry
        #expect(codes(registry) == ["CUSTOM_SOURCE_IGNORED"])
        #expect(registry.app("myapp")?.fetch == nil && registry.app("second")?.fetch != nil)
    }

    @Test("a customSources that is not an array is one warning; no customApps ignores every entry")
    func notArray() {
        var config = customConfig(sources: [])
        config.extra["customSources"] = ["not": "an array"]
        let registry = config.appRegistry
        #expect(
            messages(registry) == [
                "customSources is not an array, so every custom source is ignored."
            ])
        #expect(registry.fetchSources.map(\.app) == ["apollo", "stremio-ios", "stremio-tvos"])

        var bare = customConfig(sources: [githubEntry])
        bare.extra["customApps"] = nil
        #expect(codes(bare.appRegistry) == ["CUSTOM_SOURCE_IGNORED"])
        #expect(bare.appRegistry.fetchSources.count == 3)
    }

    @Test("an entry that is not an object is ignored")
    func notObject() {
        var config = customConfig(sources: [])
        config.extra["customSources"] = ["text", 3]
        #expect(codes(config.appRegistry) == ["CUSTOM_SOURCE_IGNORED", "CUSTOM_SOURCE_IGNORED"])
    }

    @Test("customSources stays in config.json as written, for older builds to keep and ignore")
    func keptInExtra() throws {
        let config = customConfig(sources: [githubEntry, altstoreEntry])
        let reparsed = try Config.parse(try config.encoded())
        #expect(reparsed.extra["customSources"] == config.extra["customSources"])
        #expect(reparsed.appRegistry.warnings.count == 2)
    }

    @Test("the approval gate is unchanged: a valid source needs its approvedSources entry")
    func approvalStillRequired() throws {
        let unapproved = customConfig(sources: [githubEntry], approved: [])
        #expect(unapproved.appRegistry.warnings.isEmpty)
        #expect(throws: SideloadError.self) {
            try FetchCatalog.approved(app: "myapp", config: unapproved)
        }
        #expect(!FetchCatalog.approvedSources(unapproved).contains { $0.app == "myapp" })

        let approved = customConfig(sources: [githubEntry])
        let source = try FetchCatalog.approved(app: "myapp", config: approved)
        #expect(source.kind == .customGithubRelease(repo: "acme/widget"))
        #expect(FetchCatalog.approvedSources(approved).map(\.app).contains("myapp"))
    }

    @Test("approvedSources hosts only narrow a custom source, and cannot add a host")
    func narrowing() throws {
        let narrowed = customConfig(
            sources: [altstoreEntry],
            approved: [["app": "myapp", "hosts": ["index.example.org", "evil.example.org"]]])
        let source = try FetchCatalog.approved(app: "myapp", config: narrowed)
        #expect(source.metadataHosts == ["index.example.org"] && source.downloadHosts.isEmpty)
    }

    @Test("an unknown app that has an ignored entry points at status in the error")
    func ignoredHint() {
        var entry = githubEntry
        entry["repo"] = "nope"
        var config = customConfig(sources: [entry])
        config.extra["customApps"] = [["id": "myapp", "platform": "ios"]]
        #expect(throws: SideloadError.self) {
            try FetchCatalog.approved(app: "myapp", config: config)
        }
        do {
            _ = try FetchCatalog.approved(app: "myapp", config: config)
        } catch let error as SideloadError {
            #expect(error.fix?.contains("was ignored") == true)
        } catch {}
    }
}

// MARK: source list

private func invokeSource(_ argv: [String], config: Config) async throws -> (
    Envelope, FakeFetchTransport, [String: Data]
) {
    try await withTestHome(config: config) { paths, _ in
        let http = FakeFetchTransport(metadata: [:])
        let services = fetchServices(paths, http: http)
        let before = snapshot(paths.home)
        let out = await run(argv: argv, services: services)
        #expect(snapshot(paths.home) == before, "source list writes nothing")
        return (out, http, before)
    }
}

/// Every file under `root` with its bytes.
private func snapshot(_ root: String) -> [String: Data] {
    var out: [String: Data] = [:]
    let walker = FileManager.default.enumerator(atPath: root)
    while let relative = walker?.nextObject() as? String {
        let path = root + "/" + relative
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            out[relative] = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        } else {
            out[relative] = Data()
        }
    }
    return out
}

@Suite("custom sources: source list")
struct SourceListTests {
    @Test(
        "lists the built-ins and a custom source with their hosts and approval, with no network and no write"
    )
    func list() async throws {
        let config = customConfig(sources: [githubEntry])
        let (out, http, _) = try await invokeSource(["source", "list"], config: config)
        #expect(out.ok && out.command == "source list", "\(out.errors)")
        #expect(http.callCount == 0, "no request of any kind")
        let sources = try #require(out.data["sources"]?.array)
        #expect(
            sources.compactMap { $0["app"]?.string } == [
                "apollo", "myapp", "stremio-ios", "stremio-tvos",
            ])
        let apollo = try #require(sources.first { $0["app"] == "apollo" })
        #expect(apollo["builtIn"] == true && apollo["kind"] == "githubRelease")
        #expect(apollo["approved"] == true)
        #expect(
            apollo["url"]
                == "https://api.github.com/repos/Apollo-Reborn/Apollo-Reborn/releases/latest")
        #expect(apollo["metadataHosts"] == ["api.github.com"])
        let custom = try #require(sources.first { $0["app"] == "myapp" })
        #expect(custom["builtIn"] == false && custom["kind"] == "githubRelease")
        #expect(custom["approved"] == true)
        #expect(custom["url"] == "https://api.github.com/repos/acme/widget/releases/latest")
        #expect(
            custom["downloadHosts"] == [
                "github.com", "objects.githubusercontent.com",
                "release-assets.githubusercontent.com",
            ])
        let stremio = try #require(sources.first { $0["app"] == "stremio-ios" })
        #expect(stremio["approved"] == false && stremio["downloadHosts"] == ["dl.strem.io"])
        #expect(out.data["warnings"] == [])
    }

    @Test(
        "an AltStore source shows its index URL; an unapproved one says so; an ignored one is a warning"
    )
    func listVariants() async throws {
        var broken = githubEntry
        broken["app"] = "other"
        var config = customConfig(sources: [altstoreEntry, broken], approved: [])
        config.extra["customApps"] = [
            ["id": "myapp", "platform": "ios"], ["id": "other", "platform": "ios"],
        ]
        let (out, http, _) = try await invokeSource(["source", "list"], config: config)
        #expect(http.callCount == 0)
        let sources = try #require(out.data["sources"]?.array)
        let custom = try #require(sources.first { $0["app"] == "myapp" })
        #expect(custom["kind"] == "altstoreIndex" && custom["approved"] == false)
        #expect(custom["url"] == "https://index.example.org/apps/index.json")
        #expect(custom["metadataHosts"] == ["index.example.org"])
        let other = try #require(sources.first { $0["app"] == "other" })
        #expect(other["kind"] == "githubRelease" && other["approved"] == false)
    }

    @Test("a source that was left out is not listed and is a warning")
    func listIgnored() async throws {
        var broken = githubEntry
        broken["repo"] = "nope"
        let (out, _, _) = try await invokeSource(
            ["source", "list"], config: customConfig(sources: [broken]))
        let apps = out.data["sources"]?.array?.compactMap { $0["app"]?.string } ?? []
        #expect(!apps.contains("myapp"))
        #expect(out.data["warnings"]?.array?.first?["code"] == "CUSTOM_SOURCE_IGNORED")
    }

    @Test("narrowed hosts show as the approved source uses them")
    func listNarrowed() async throws {
        let config = customConfig(
            sources: [altstoreEntry], approved: [["app": "myapp", "hosts": ["index.example.org"]]])
        let (out, _, _) = try await invokeSource(["source", "list"], config: config)
        let custom = try #require(out.data["sources"]?.array?.first { $0["app"] == "myapp" })
        #expect(custom["downloadHosts"] == [] && custom["approved"] == true)
    }

    @Test("it takes no option; add and remove are not built yet; help lists it")
    func usage() async throws {
        let config = customConfig(sources: [])
        let (yes, _, _) = try await invokeSource(["source", "list", "--yes"], config: config)
        #expect(yes.firstCode == "USAGE")
        let (bare, _, _) = try await invokeSource(["source"], config: config)
        #expect(bare.firstCode == "USAGE")
        let (add, http, _) = try await invokeSource(
            ["source", "add", "--url", "https://x.example.org/a", "--yes"], config: config)
        #expect(add.firstCode == "NOT_IMPLEMENTED" && http.callCount == 0)
        let (remove, _, _) = try await invokeSource(
            ["source", "remove", "--app", "myapp"], config: config)
        #expect(remove.firstCode == "NOT_IMPLEMENTED")
        let (help, _, _) = try await invokeSource(["help"], config: config)
        #expect(help.data["usage"]?.array?.contains("source list") == true)
        #expect(help.data["built"]?.array?.contains("source") == true)
    }
}
