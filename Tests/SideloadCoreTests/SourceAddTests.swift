import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import sideload

// `source add` and `source remove` (issue #47, PR B): the preview, the confirm value, `--yes`, the refusals and the chain that
// follows. Offline: a temp home and a scripted transport; nothing opens a socket and nothing has run against a real source.

let widgetAPI = "https://api.github.com/repos/acme/widget/releases/latest"
let widgetURL = "https://github.com/acme/widget"
let sourceIndexURL = "https://index.example.org/apps/index.json"

/// Answers metadata GETs from a table the test can change, and counts every request. A download is refused and counted.
final class SourceHTTP: HTTPTransport {
    private let docs: Mutex<[String: Data]>
    private let gets = Mutex<[HTTPRequest]>([])
    private let downloads = Mutex(0)
    private let failure = Mutex<(any Error)?>(nil)
    private let held = Mutex(false)

    init(_ docs: [String: Data] = [:]) { self.docs = Mutex(docs) }

    var getRequests: [HTTPRequest] { gets.withLock { $0 } }
    var downloadCount: Int { downloads.withLock { $0 } }

    func set(_ url: String, _ body: Data) { docs.withLock { $0[url] = body } }
    func fail(with error: (any Error)?) { failure.withLock { $0 = error } }
    /// While held, a GET waits (and ends with the cancellation of its task).
    func hold(_ on: Bool) { held.withLock { $0 = on } }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        gets.withLock { $0.append(request) }
        while held.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        if let error = failure.withLock({ $0 }) { throw error }
        guard let body = docs.withLock({ $0[request.url.absoluteString] }) else {
            return HTTPResponse(status: 404, body: Data())
        }
        return HTTPResponse(status: 200, body: body)
    }

    func download(_ request: DownloadRequest, sink: @Sendable (Data) throws -> Void) async throws
        -> DownloadResponse
    {
        downloads.withLock { $0 += 1 }
        throw HTTPTransportError.disabled
    }
}

/// The release GitHub serves for `acme/widget`: one IPA with a digest and a checksum file.
func widgetRelease(tag: String = "0.3.8", assets: [ReleaseAsset]? = nil) -> Data {
    func url(_ name: String) -> String {
        "https://github.com/acme/widget/releases/download/\(tag)/\(name)"
    }
    return releaseJSON(
        tag: tag,
        assets: assets ?? [
            ReleaseAsset(name: "App.ipa", url: url("App.ipa")),
            ReleaseAsset(name: "App.ipa.sha256", url: url("App.ipa.sha256")),
        ])
}

struct IndexEntry {
    var name = "Widget"
    var bundleId = "io.example.widget"
    var version = "1.2.0"
    var url = "https://cdn.example.org/Widget.ipa"
    var sha256: String? = String(repeating: "cd", count: 32)
    var size = 1000
    var platform: String?
}

func indexJSON(_ apps: [IndexEntry]) -> Data {
    let list: [JSONValue] = apps.map { app in
        var version: [String: JSONValue] = [
            "version": .string(app.version), "downloadURL": .string(app.url),
            "size": .number(Double(app.size)),
        ]
        version["sha256"] = app.sha256.map(JSONValue.string) ?? .null
        var object: [String: JSONValue] = [
            "name": .string(app.name), "bundleIdentifier": .string(app.bundleId),
            "versions": [.object(version)],
        ]
        if let platform = app.platform { object["platform"] = .string(platform) }
        return .object(object)
    }
    return try! JSONEncoder().encode(JSONValue.object(["name": "Index", "apps": .array(list)]))
}

func sourceBaseConfig(prefix: String? = customPrefix, extra: [String: JSONValue] = [:]) -> Config {
    Config(
        devices: iphoneConfig().devices, approvedSources: apolloApproved, bundleIdPrefix: prefix,
        extra: extra)
}

func withSourceHome(
    config: Config = sourceBaseConfig(), http: SourceHTTP,
    _ body: (Paths, Services) async throws -> Void
) async throws {
    try await withTestHome(config: config) { paths, _ in
        try await body(paths, fetchServices(paths, http: http))
    }
}

func source(_ args: [String], _ services: Services) async -> Envelope {
    await run(argv: ["source"] + args, services: services)
}

func configBytes(_ paths: Paths) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: paths.config))
}

func loadConfig(_ paths: Paths) throws -> Config { try ConfigStore(paths: paths).load() }

/// The preview, then the `--yes` command it prints, as the owner would run them.
func addArgs(
    _ url: String, _ extra: [String] = [], confirm: String? = nil
) -> [String] {
    ["add", "--url", url] + extra + (confirm.map { ["--confirm", $0, "--yes"] } ?? [])
}

private func code(_ out: Envelope) -> String? { out.errors.first?.code }

private func hosts(_ value: JSONValue?) -> [String] {
    value?.array?.compactMap(\.string) ?? []
}

// MARK: preview

@Suite("source add: preview")
struct SourceAddPreviewTests {
    @Test("a GitHub repository: one GET, nothing written, no download, no lock")
    func github() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            let out = await source(addArgs(widgetURL), services)
            #expect(out.ok && out.command == "source add", "\(out.errors)")
            #expect(try configBytes(paths) == before, "the config is byte for byte the same")
            #expect(http.getRequests.map(\.url.absoluteString) == [widgetAPI])
            #expect(http.downloadCount == 0)
            expectLockFree(paths)

            let json = try out.printed().json
            #expect(json["preview"] == true && json["written"] == false)
            #expect(json["kind"] == "githubRelease" && json["url"] == .string(widgetURL))
            #expect(json["repo"] == "acme/widget" && json["metadataHost"] == "api.github.com")
            #expect(
                hosts(json["downloadHosts"]) == [
                    "github.com", "objects.githubusercontent.com",
                    "release-assets.githubusercontent.com",
                ])
            let apps = try #require(json["apps"]?.array)
            #expect(apps.count == 1 && apps[0]["name"] == "App.ipa" && apps[0]["hasDigest"] == true)
            #expect(apps[0]["bundleId"] == nil && json["truncated"] == false)
            #expect(json["version"] == "0.3.8")
            #expect(json["app"]?["id"] == "widget" && json["app"]?["suffix"] == "widget")
            #expect(json["app"]?["platform"] == "ios" && json["app"]?["name"] == "Widget")
            #expect(json["freeBundleId"] == .string(customPrefix + ".free.widget"))
            let confirm = try #require(json["confirm"]?.string)
            #expect(confirm.wholeMatch(of: /[0-9a-f]{16}/) != nil)
            let next = try #require(json["next"]?.string)
            #expect(
                next.contains(
                    "sideload source add --url '\(widgetURL)' --app widget --platform ios --confirm \(confirm) --yes"
                ))
        }
    }

    @Test("an AltStore index: the picked app, the host of its download, nothing written")
    func altstore() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON([IndexEntry()])])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            let out = await source(addArgs(sourceIndexURL), services)
            #expect(out.ok, "\(out.errors)")
            #expect(try configBytes(paths) == before)
            #expect(http.getRequests.count == 1 && http.downloadCount == 0)
            let json = try out.printed().json
            #expect(json["kind"] == "altstoreIndex" && json["metadataHost"] == "index.example.org")
            #expect(hosts(json["downloadHosts"]) == ["cdn.example.org"])
            #expect(json["bundleId"] == "io.example.widget" && json["version"] == "1.2.0")
            let apps = try #require(json["apps"]?.array)
            #expect(apps.count == 1 && apps[0]["bundleId"] == "io.example.widget")
            #expect(apps[0]["size"] == 1000 && apps[0]["hasDigest"] == true)
            #expect(json["app"]?["id"] == "widget")
            let next = try #require(json["next"]?.string)
            #expect(next.contains("--bundle io.example.widget"))
        }
    }

    @Test("a download from github.com also gets GitHub's two object-store hosts")
    func githubDownload() async throws {
        let entry = IndexEntry(url: "https://github.com/acme/widget/releases/download/v1/App.ipa")
        let http = SourceHTTP([sourceIndexURL: indexJSON([entry])])
        try await withSourceHome(http: http) { _, services in
            let out = await source(addArgs(sourceIndexURL), services)
            #expect(
                hosts(out.data["downloadHosts"]) == [
                    "github.com", "objects.githubusercontent.com",
                    "release-assets.githubusercontent.com",
                ], "\(out.errors)")
        }
    }

    @Test("the defaults: ios unless the index says tvos, the id from the name; flags override")
    func defaults() async throws {
        let tv = IndexEntry(name: "My Cool App!", platform: "tvos")
        let http = SourceHTTP([sourceIndexURL: indexJSON([tv])])
        try await withSourceHome(http: http) { _, services in
            let out = await source(addArgs(sourceIndexURL), services)
            #expect(
                out.data["app"]?["id"] == "my-cool-app" && out.data["app"]?["platform"] == "tvos")
            #expect(out.data["app"]?["name"] == "My-cool-app")
            let given = await source(
                addArgs(
                    sourceIndexURL,
                    ["--app", "cool", "--platform", "ios", "--name", "Cool Thing"]), services)
            #expect(given.data["app"]?["id"] == "cool" && given.data["app"]?["platform"] == "ios")
            #expect(given.data["app"]?["name"] == "Cool Thing")
            #expect(given.data["freeBundleId"] == .string(customPrefix + ".free.cool"))
            #expect(given.data["next"]?.string?.contains("--name 'Cool Thing'") == true)
        }
    }

    @Test("every upstream string is cut to printable ASCII")
    func sanitised() async throws {
        let odd = IndexEntry(name: "Wid\u{1B}[31mget \u{202E}é", version: "1.\u{7}2")
        let http = SourceHTTP([sourceIndexURL: indexJSON([odd])])
        try await withSourceHome(http: http) { _, services in
            let out = await source(addArgs(sourceIndexURL, ["--app", "widget"]), services)
            // The version token is not safe, so the resolver refuses; the listing never carried it raw.
            #expect(code(out) == "SOURCE_INVALID", "\(out.errors)")
            let clean = IndexEntry(name: "Wid\u{1B}[31mget \u{202E}é")
            http.set(sourceIndexURL, indexJSON([clean]))
            let ok = await source(addArgs(sourceIndexURL, ["--app", "widget"]), services)
            let name = try #require(ok.data["apps"]?.array?.first?["name"]?.string)
            #expect(name == "Wid[31mget ")
            #expect(name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7f })
        }
    }

    @Test("an index of many apps is SOURCE_AMBIGUOUS and lists them; --bundle picks one")
    func ambiguous() async throws {
        let many = [
            IndexEntry(name: "One", bundleId: "io.example.one"),
            IndexEntry(
                name: "Two", bundleId: "io.example.two", url: "https://cdn.example.org/2.ipa"),
            IndexEntry(
                name: "Three", bundleId: "io.example.three", url: "https://other.example.net/3.ipa"),
        ]
        let http = SourceHTTP([sourceIndexURL: indexJSON(many)])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            let out = await source(addArgs(sourceIndexURL), services)
            #expect(code(out) == "SOURCE_AMBIGUOUS")
            #expect(out.data["apps"]?.array?.count == 3 && out.data["truncated"] == false)
            #expect(try configBytes(paths) == before)

            let picked = await source(
                addArgs(sourceIndexURL, ["--bundle", "io.example.three"]), services)
            #expect(picked.ok, "\(picked.errors)")
            #expect(picked.data["bundleId"] == "io.example.three")
            #expect(picked.data["app"]?["id"] == "three")
            #expect(hosts(picked.data["downloadHosts"]) == ["other.example.net"])
            #expect(picked.data["apps"]?.array?.count == 3, "the listing still shows every app")

            let missing = await source(
                addArgs(sourceIndexURL, ["--bundle", "io.example.zero"]), services)
            #expect(code(missing) == "SOURCE_NOT_FOUND")
        }
    }

    @Test("more than 50 apps: the listing is cut and says so; --bundle still reaches the last one")
    func truncated() async throws {
        let many = (0..<60).map {
            IndexEntry(name: "App \($0)", bundleId: "io.example.app\($0)")
        }
        let http = SourceHTTP([sourceIndexURL: indexJSON(many)])
        try await withSourceHome(http: http) { _, services in
            let out = await source(addArgs(sourceIndexURL), services)
            #expect(code(out) == "SOURCE_AMBIGUOUS")
            #expect(out.data["apps"]?.array?.count == 50 && out.data["truncated"] == true)
            let last = await source(
                addArgs(sourceIndexURL, ["--bundle", "io.example.app59"]), services)
            #expect(
                last.ok && last.data["truncated"] == true && last.data["apps"]?.array?.count == 50)
            #expect(last.data["app"]?["id"] == "app-59")
        }
    }

    @Test("a missing digest is UPSTREAM_DIGEST_MISSING, for an index app and for a release")
    func digest() async throws {
        let http = SourceHTTP([
            sourceIndexURL: indexJSON([IndexEntry(sha256: nil)]),
            widgetAPI: widgetRelease(assets: [
                ReleaseAsset(
                    name: "App.ipa", digest: nil,
                    url: "https://github.com/acme/widget/releases/download/0.3.8/App.ipa")
            ]),
        ])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            #expect(
                code(await source(addArgs(sourceIndexURL), services)) == "UPSTREAM_DIGEST_MISSING")
            #expect(code(await source(addArgs(widgetURL), services)) == "UPSTREAM_DIGEST_MISSING")
            #expect(try configBytes(paths) == before)
            // The listing says which apps lack one.
            let two = [IndexEntry(), IndexEntry(name: "B", bundleId: "io.example.b", sha256: nil)]
            http.set(sourceIndexURL, indexJSON(two))
            let ambiguous = await source(addArgs(sourceIndexURL), services)
            #expect(
                ambiguous.data["apps"]?.array?.compactMap { $0["hasDigest"] } == [true, false])
        }
    }

    @Test(
        "a release with no .ipa is SOURCE_NOT_ALLOWED; several without --asset are SOURCE_AMBIGUOUS"
    )
    func ipaCount() async throws {
        func asset(_ name: String) -> ReleaseAsset {
            ReleaseAsset(
                name: name,
                url: "https://github.com/acme/widget/releases/download/0.3.8/\(name)")
        }
        let none = SourceHTTP([widgetAPI: widgetRelease(assets: [asset("App.zip")])])
        try await withSourceHome(http: none) { _, services in
            #expect(code(await source(addArgs(widgetURL), services)) == "SOURCE_NOT_ALLOWED")
        }
        let two = SourceHTTP([widgetAPI: widgetRelease(assets: [asset("A.ipa"), asset("B.ipa")])])
        try await withSourceHome(http: two) { _, services in
            #expect(code(await source(addArgs(widgetURL), services)) == "SOURCE_AMBIGUOUS")
        }
    }

    @Test(
        "the kind is the document's: anything that is not a GitHub repository or an index is unknown"
    )
    func unknownKind() async throws {
        let http = SourceHTTP([
            "https://example.org/page": Data("<html>hi</html>".utf8),
            "https://example.org/empty.json": indexJSON([]),
            "https://example.org/release.json": widgetRelease(),
            "https://example.org/array.json": Data("[1,2]".utf8),
            "https://github.com/acme/widget/releases": Data("<html></html>".utf8),
            "https://example.org/noid.json": Data(#"{"apps":[{"name":"x"}]}"#.utf8),
        ])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            for url in [
                "https://example.org/page", "https://example.org/empty.json",
                "https://example.org/release.json", "https://example.org/array.json",
                "https://github.com/acme/widget/releases", "https://example.org/noid.json",
            ] {
                let out = await source(addArgs(url), services)
                #expect(code(out) == "SOURCE_KIND_UNKNOWN", "\(url) \(out.errors)")
            }
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("a URL the load rules refuse is refused before any request")
    func urlRules() async throws {
        let http = SourceHTTP([:])
        try await withSourceHome(http: http) { _, services in
            for url in [
                "http://index.example.org/i.json", "https://user:pw@index.example.org/i.json",
                "https://index.example.org:8443/i.json", "https://index.example.org:443/i.json",
                "https://index.example.org/i.json?x=1", "https://index.example.org/i.json#top",
                "https://127.0.0.1/i.json", "https://localhost/i.json",
                "https://*.example.org/i.json", "https://Index.Example.org/i.json",
                "https://index.example.org", "https://index.example.org/a//b.json",
                "https://index.example.org/../i.json", "https://github.com/acme/widget/",
                "ftp://index.example.org/i.json",
            ] {
                let out = await source(addArgs(url), services)
                #expect(code(out) == "SOURCE_NOT_ALLOWED", "\(url) \(out.errors)")
            }
            #expect(http.getRequests.isEmpty, "not one request")
        }
    }

    @Test("oversized metadata, a refused redirect and a failing network are refused")
    func transportFailures() async throws {
        let big = Data(count: URLSessionTransport.maxBodyBytes + 1)
        let http = SourceHTTP([sourceIndexURL: big])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            #expect(code(await source(addArgs(sourceIndexURL), services)) == "DOWNLOAD_TOO_LARGE")
            http.fail(with: HTTPTransportError.redirectRefused)
            #expect(code(await source(addArgs(sourceIndexURL), services)) == "REDIRECT_NOT_ALLOWED")
            http.fail(with: HTTPTransportError.failed)
            #expect(code(await source(addArgs(sourceIndexURL), services)) == "FETCH_NETWORK")
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("invalid --app, --bundle, --platform and --name are refused before any request")
    func arguments() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { _, services in
            for extra in [
                ["--app", "Bad_ID"], ["--app", "UPPER"], ["--platform", "watchos"],
                ["--name", " padded"], ["--name", String(repeating: "n", count: 65)],
                ["--bundle", "nodots"],
            ] {
                let out = await source(addArgs(widgetURL, extra), services)
                #expect(code(out) == "INVALID_ARGUMENT", "\(extra)")
            }
            // A bundle ID picks an app of an index; a release has none.
            let bundle = await source(addArgs(widgetURL, ["--bundle", "io.example.x"]), services)
            #expect(code(bundle) == "INVALID_ARGUMENT")
            #expect(http.getRequests.count == 1, "only the last one got as far as the GET")
        }
    }

    @Test("a missing or invalid bundleIdPrefix is CONFIG_MISSING")
    func prefix() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(config: sourceBaseConfig(prefix: nil), http: http) { _, services in
            #expect(code(await source(addArgs(widgetURL), services)) == "CONFIG_MISSING")
        }
    }

    @Test("--url is required, --confirm and --yes go together, and list takes no option")
    func usage() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            #expect(code(await source(["add"], services)) == "USAGE")
            #expect(code(await source(["add", "--url", widgetURL, "--yes"], services)) == "USAGE")
            #expect(
                code(
                    await source(
                        ["add", "--url", widgetURL, "--confirm", "abcdef0123456789"], services))
                    == "USAGE")
            #expect(
                code(
                    await source(
                        ["add", "--url", widgetURL, "--confirm", "nope", "--yes"], services))
                    == "USAGE")
            #expect(code(await source(["list", "--url", widgetURL], services)) == "USAGE")
            #expect(code(await source(["list", "--yes"], services)) == "USAGE")
            #expect(code(await source(["frobnicate"], services)) == "USAGE")
            #expect(code(await source([], services)) == "USAGE")
            #expect(code(await source(["remove", "--url", widgetURL], services)) == "USAGE")
            #expect(http.getRequests.isEmpty)
            #expect(try configBytes(paths) == before)
        }
    }
}

// MARK: --yes

@Suite("source add: --yes")
struct SourceAddYesTests {
    /// The preview's confirm value, then the `--yes` run.
    private func add(
        _ url: String, _ extra: [String] = [], services: Services
    ) async throws -> (preview: Envelope, yes: Envelope) {
        let preview = await source(addArgs(url, extra), services)
        let confirm = try #require(preview.data["confirm"]?.string, "\(preview.errors)")
        let yes = await source(addArgs(url, extra, confirm: confirm), services)
        return (preview, yes)
    }

    @Test("a GitHub source writes exactly the app, the source and the approval; nothing is fetched")
    func github() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { paths, services in
            let before = try loadConfig(paths)
            let (_, yes) = try await add(widgetURL, services: services)
            #expect(yes.ok && yes.command == "source add", "\(yes.errors)")
            #expect(yes.data["added"] == true)
            #expect(
                yes.data["wrote"]
                    == ["customApps": true, "customSources": true, "approvedSources": true])
            #expect(http.downloadCount == 0 && http.getRequests.count == 2)
            expectLockFree(paths)

            var expected = before
            expected.extra["customApps"] = [["id": "widget", "platform": "ios"]]
            expected.extra["customSources"] = [
                [
                    "app": "widget", "kind": "githubRelease", "repo": "acme/widget",
                    "metadataHosts": ["api.github.com"],
                    "downloadHosts": [
                        "github.com", "objects.githubusercontent.com",
                        "release-assets.githubusercontent.com",
                    ], "addedAt": .string(ISO8601DateFormatter().string(from: testNow)),
                ]
            ]
            expected.approvedSources = before.approvedSources + [["app": "widget"]]
            #expect(try loadConfig(paths) == expected)

            // The registry the other commands load sees a valid, approved source and no warning.
            let registry = try loadConfig(paths).appRegistry
            #expect(registry.warnings.isEmpty && registry.app("widget")?.fetch != nil)
            let listed = await source(["list"], services)
            let entry = try #require(
                listed.data["sources"]?.array?.first { $0["app"] == "widget" })
            #expect(entry["approved"] == true && entry["builtIn"] == false)
        }
    }

    @Test("an index source writes its url, bundle ID and the host of the download")
    func altstore() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON([IndexEntry(platform: "tvos")])])
        try await withSourceHome(http: http) { paths, services in
            let (_, yes) = try await add(sourceIndexURL, services: services)
            #expect(yes.ok, "\(yes.errors)")
            let config = try loadConfig(paths)
            let entry = try #require(config.extra["customSources"]?.array?.first)
            #expect(entry["kind"] == "altstoreIndex" && entry["url"] == .string(sourceIndexURL))
            #expect(entry["bundleId"] == "io.example.widget")
            #expect(entry["metadataHosts"] == ["index.example.org"])
            #expect(entry["downloadHosts"] == ["cdn.example.org"])
            #expect(config.extra["customApps"] == [["id": "widget", "platform": "tvos"]])
            #expect(config.approvedSources.last == ["app": "widget"])
            #expect(config.appRegistry.app("widget")?.devicePlatform == "tvos")
        }
    }

    @Test("a new version is not a changed source; changed hosts, bundle or app are")
    func changed() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON([IndexEntry()])])
        try await withSourceHome(http: http) { paths, services in
            let preview = await source(addArgs(sourceIndexURL, ["--app", "widget"]), services)
            let confirm = try #require(preview.data["confirm"]?.string)
            let args = addArgs(sourceIndexURL, ["--app", "widget"], confirm: confirm)
            let before = try configBytes(paths)

            for changed in [
                IndexEntry(url: "https://evil.example.net/Widget.ipa"),
                IndexEntry(bundleId: "io.example.other"),
            ] {
                http.set(sourceIndexURL, indexJSON([changed]))
                let out = await source(args, services)
                #expect(code(out) == "SOURCE_CHANGED", "\(out.errors)")
                #expect(try configBytes(paths) == before)
                expectLockFree(paths)
            }
            // The GitHub hosts of a download that moved to github.com are a change too.
            http.set(
                sourceIndexURL,
                indexJSON([
                    IndexEntry(url: "https://github.com/acme/widget/releases/download/v1/W.ipa")
                ]))
            #expect(code(await source(args, services)) == "SOURCE_CHANGED")

            // Only the version, the size, the digest and the name moved: the same source.
            http.set(
                sourceIndexURL,
                indexJSON([
                    IndexEntry(
                        name: "Renamed", version: "2.0.0",
                        sha256: String(repeating: "ab", count: 32),
                        size: 4000)
                ]))
            let same = await source(args, services)
            #expect(same.ok, "\(same.errors)")
            #expect(try loadConfig(paths).appRegistry.app("widget") != nil)
        }
    }

    @Test("without --app the id follows the upstream name, so a changed name is SOURCE_CHANGED")
    func derivedIDChanges() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON([IndexEntry()])])
        try await withSourceHome(http: http) { _, services in
            let preview = await source(addArgs(sourceIndexURL), services)
            let confirm = try #require(preview.data["confirm"]?.string)
            http.set(sourceIndexURL, indexJSON([IndexEntry(name: "Other")]))
            #expect(
                code(await source(addArgs(sourceIndexURL, confirm: confirm), services))
                    == "SOURCE_CHANGED")
        }
    }

    @Test("a wrong confirm value is SOURCE_CHANGED and writes nothing")
    func wrongConfirm() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            let out = await source(
                addArgs(widgetURL, confirm: "0123456789abcdef"), services)
            #expect(code(out) == "SOURCE_CHANGED")
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("--yes without --confirm is USAGE and makes no request")
    func needsConfirm() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            let out = await source(["add", "--url", widgetURL, "--yes"], services)
            #expect(code(out) == "USAGE" && http.getRequests.isEmpty)
            #expect(try configBytes(paths) == before)
        }
    }

    @Test(
        "a busy lock is OPERATION_IN_PROGRESS, after the GET; nothing is written; a preview needs no lock"
    )
    func busy() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { paths, services in
            let preview = await source(addArgs(widgetURL), services)
            let confirm = try #require(preview.data["confirm"]?.string)
            let before = try configBytes(paths)
            let held = try OperationLock.acquire(paths: paths)
            defer { held.release() }
            let again = await source(addArgs(widgetURL), services)
            #expect(again.ok, "a preview takes no lock")
            let requests = http.getRequests.count
            let out = await source(addArgs(widgetURL, confirm: confirm), services)
            #expect(code(out) == "OPERATION_IN_PROGRESS")
            #expect(http.getRequests.count == requests + 1, "the GET came before the lock")
            #expect(try configBytes(paths) == before)
        }
    }

    // MARK: the app

    @Test(
        "APP_EXISTS: a built-in ID, a built-in suffix, another custom app's suffix, an ignored entry"
    )
    func appExists() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        let extra: [String: JSONValue] = [
            "customApps": [
                ["id": "other", "suffix": "taken", "platform": "ios"],
                ["id": "broken", "bogus": 1],
            ]
        ]
        try await withSourceHome(config: sourceBaseConfig(extra: extra), http: http) {
            paths, services in
            let before = try configBytes(paths)
            for app in ["apollo", "stremio-ios", "filler", "stremio", "taken", "broken"] {
                let preview = await source(addArgs(widgetURL, ["--app", app]), services)
                #expect(code(preview) == "APP_EXISTS", "\(app) \(preview.errors)")
            }
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("APP_EXISTS when the app appeared after the preview")
    func appearedMeanwhile() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { paths, services in
            let preview = await source(addArgs(widgetURL), services)
            let confirm = try #require(preview.data["confirm"]?.string)
            try await ConfigStore(paths: paths).update {
                $0.extra["customApps"] = [["id": "newer", "suffix": "widget", "platform": "ios"]]
            }
            let before = try configBytes(paths)
            let out = await source(addArgs(widgetURL, confirm: confirm), services)
            #expect(code(out) == "APP_EXISTS")
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("SOURCE_EXISTS: the custom app already has a source, or an entry the loader ignored")
    func sourceExists() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        let extra: [String: JSONValue] = [
            "customApps": [
                ["id": "widget", "platform": "ios"], ["id": "myapp", "platform": "ios"],
            ],
            "customSources": [
                ["app": "widget", "kind": "githubRelease", "repo": "acme/other"],
                .object(githubEntry),
            ],
        ]
        try await withSourceHome(config: sourceBaseConfig(extra: extra), http: http) {
            paths, services in
            let before = try configBytes(paths)
            // `widget` has an entry that does not load; `myapp` has a good one.
            #expect(code(await source(addArgs(widgetURL), services)) == "SOURCE_EXISTS")
            #expect(
                code(await source(addArgs(widgetURL, ["--app", "myapp"]), services))
                    == "SOURCE_EXISTS")
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("a custom app with no source can be given one; a different platform is refused")
    func attach() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        let extra: [String: JSONValue] = [
            "customApps": [["id": "widget", "platform": "ios", "name": "My Widget"]]
        ]
        try await withSourceHome(config: sourceBaseConfig(extra: extra), http: http) {
            paths, services in
            let before = try loadConfig(paths)
            let mismatch = await source(addArgs(widgetURL, ["--platform", "tvos"]), services)
            #expect(code(mismatch) == "APP_EXISTS")
            let rename = await source(addArgs(widgetURL, ["--name", "Else"]), services)
            #expect(code(rename) == "INVALID_ARGUMENT")

            let preview = await source(addArgs(widgetURL), services)
            #expect(preview.data["app"]?["exists"] == true)
            #expect(preview.data["app"]?["name"] == "My Widget")
            let confirm = try #require(preview.data["confirm"]?.string)
            let out = await source(addArgs(widgetURL, confirm: confirm), services)
            #expect(out.ok, "\(out.errors)")
            #expect(
                out.data["wrote"]
                    == ["customApps": false, "customSources": true, "approvedSources": true])
            let after = try loadConfig(paths)
            #expect(after.extra["customApps"] == before.extra["customApps"])
            #expect(after.appRegistry.app("widget")?.fetch != nil)
            #expect(after.appRegistry.app("widget")?.displayName == "My Widget")
        }
    }

    @Test(
        "attach versus new is part of the confirm: it changing before --yes is SOURCE_CHANGED, both ways"
    )
    func attachRace() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        let existing: [String: JSONValue] = ["customApps": [["id": "widget", "platform": "ios"]]]
        // Previewed as an existing app, whose entry then goes.
        try await withSourceHome(config: sourceBaseConfig(extra: existing), http: http) {
            paths, services in
            let preview = await source(addArgs(widgetURL), services)
            #expect(preview.data["app"]?["exists"] == true)
            let confirm = try #require(preview.data["confirm"]?.string)
            try await ConfigStore(paths: paths).update { $0.extra["customApps"] = nil }
            let before = try configBytes(paths)
            let out = await source(addArgs(widgetURL, confirm: confirm), services)
            #expect(code(out) == "SOURCE_CHANGED", "\(out.errors)")
            #expect(try configBytes(paths) == before)
        }
        // Previewed as a new app, which then appears with no source.
        try await withSourceHome(http: http) { paths, services in
            let preview = await source(addArgs(widgetURL), services)
            #expect(preview.data["app"]?["exists"] == false)
            let confirm = try #require(preview.data["confirm"]?.string)
            try await ConfigStore(paths: paths).update {
                $0.extra["customApps"] = [["id": "widget", "platform": "ios"]]
            }
            let before = try configBytes(paths)
            #expect(
                code(await source(addArgs(widgetURL, confirm: confirm), services))
                    == "SOURCE_CHANGED")
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("the write itself refuses an app that is not the one confirmed, and changes nothing")
    func writeGuard() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { _, services in
            let probe = try await SourceAdd.probe(services, url: widgetURL)
            let plain = sourceBaseConfig()
            let existing = sourceBaseConfig(extra: [
                "customApps": [["id": "widget", "platform": "ios"]]
            ])
            let request = SourceAddRequest(url: widgetURL)
            let attaching = try SourceAdd.preview(probe, request: request, config: existing).plan
            let creating = try SourceAdd.preview(probe, request: request, config: plain).plan
            #expect(attaching.attaches && !creating.attaches)
            #expect(attaching.confirm != creating.confirm)

            var gone = plain
            #expect(throws: SideloadError.self) {
                try SourceAdd.write(attaching, into: &gone, now: testNow)
            }
            #expect(gone == plain)
            var appeared = existing
            do {
                _ = try SourceAdd.write(creating, into: &appeared, now: testNow)
                Issue.record("expected a refusal")
            } catch {
                #expect((error as? SideloadError)?.code == "SOURCE_CHANGED")
            }
            #expect(appeared == existing)

            // The matching pairs write.
            var ok = existing
            #expect(try SourceAdd.write(attaching, into: &ok, now: testNow).customApps == false)
            var fresh = plain
            #expect(try SourceAdd.write(creating, into: &fresh, now: testNow).customApps == true)
        }
    }

    @Test("an approval the owner already has (with hosts) is kept, not duplicated")
    func approvalKept() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        var config = sourceBaseConfig()
        config.approvedSources.append(["app": "widget", "hosts": ["github.com"]])
        try await withSourceHome(config: config, http: http) { paths, services in
            let (_, yes) = try await add(widgetURL, services: services)
            #expect(yes.ok && yes.data["wrote"]?["approvedSources"] == false)
            let approvals = try loadConfig(paths).approvedSources.filter { $0["app"] == "widget" }
            #expect(approvals == [["app": "widget", "hosts": ["github.com"]]])
        }
    }

    @Test("a config whose customSources is not an array is CONFIG_INVALID, and stays as it was")
    func notAnArray() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        let config = sourceBaseConfig(extra: ["customSources": "oops"])
        try await withSourceHome(config: config, http: http) { paths, services in
            let before = try configBytes(paths)
            #expect(code(await source(addArgs(widgetURL), services)) == "CONFIG_INVALID")
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("derived IDs are lowercase labels, or nothing")
    func derive() {
        #expect(SourceAdd.deriveID("Widget") == "widget")
        #expect(SourceAdd.deriveID("My Cool App!") == "my-cool-app")
        #expect(SourceAdd.deriveID("--x--") == "x")
        #expect(SourceAdd.deriveID("Éclair") == "clair")
        #expect(SourceAdd.deriveID("日本語") == nil)
        #expect(SourceAdd.deriveID(String(repeating: "a", count: 40))?.count == 31)
        #expect(SourceAdd.deriveID("") == nil)
    }
}

// MARK: source remove

@Suite("source remove")
struct SourceRemoveTests {
    private func config(approved: [JSONValue] = [["app": "myapp"]]) -> Config {
        customConfig(sources: [githubEntry], approved: approved)
    }

    @Test("the preview lists what stays and changes nothing")
    func preview() async throws {
        let http = SourceHTTP()
        try await withSourceHome(config: config(), http: http) { paths, services in
            let before = try configBytes(paths)
            let out = await source(["remove", "--app", "myapp"], services)
            #expect(out.ok && out.command == "source remove", "\(out.errors)")
            #expect(out.data["preview"] == true && out.data["written"] == false)
            #expect(
                out.data["customSourcesEntries"] == 1 && out.data["approvedSourcesEntries"] == 1)
            #expect(out.data["source"] == "acme/widget" && out.data["kind"] == "githubRelease")
            #expect(out.data["stays"]?["customApp"] == true)
            #expect(
                out.data["stays"]?["manifestEntries"] == 0 && out.data["stays"]?["installs"] == 0)
            #expect(out.data["next"]?.string?.contains("source remove --app myapp --yes") == true)
            #expect(try configBytes(paths) == before)
            #expect(http.getRequests.isEmpty)
        }
    }

    @Test("--yes removes only that app's source and approval; the custom app and the rest stay")
    func yes() async throws {
        let other: [String: JSONValue] = githubEntry.merging(["app": "second"]) { $1 }
        var base = customConfig(
            sources: [githubEntry, other], approved: [["app": "myapp"], ["app": "second"]])
        base.extra["customApps"] = [
            ["id": "myapp", "platform": "ios"], ["id": "second", "platform": "ios"],
        ]
        try await withSourceHome(config: base, http: SourceHTTP()) { paths, services in
            let before = try loadConfig(paths)
            var manifest = Manifest()
            manifest.entries = [
                ManifestEntry(
                    app: "myapp", version: "1", file: "myapp/1/A.ipa", urlHost: "github.com",
                    sha256: "aa", upstreamDigest: "aa", size: 1, fetchedAt: testNow, approved: true,
                    approvedAt: testNow, build: nil, declaredSize: 1, minOS: nil, inspectMinOS: nil)
            ]
            try ManifestStore(paths: paths).save(manifest)

            let out = await source(["remove", "--app", "myapp", "--yes"], services)
            #expect(out.ok && out.data["removed"] == true, "\(out.errors)")
            #expect(out.data["wrote"] == ["customSources": 1, "approvedSources": 1])
            #expect(out.data["stays"]?["manifestEntries"] == 1)
            expectLockFree(paths)

            var expected = before
            expected.extra["customSources"] = [.object(other)]
            expected.approvedSources = before.approvedSources.filter { $0["app"] != "myapp" }
            #expect(try loadConfig(paths) == expected)
            let registry = try loadConfig(paths).appRegistry
            #expect(registry.app("myapp") != nil && registry.app("myapp")?.fetch == nil)
            #expect(try ManifestStore(paths: paths).load().entries.count == 1)

            // The last one takes the key with it.
            let last = await source(["remove", "--app", "second", "--yes"], services)
            #expect(last.ok)
            #expect(try loadConfig(paths).extra["customSources"] == nil)
            #expect(await source(["list"], services).ok)
        }
    }

    @Test("a built-in app is SOURCE_BUILT_IN, an unknown one SOURCE_NOT_FOUND")
    func refusals() async throws {
        try await withSourceHome(config: config(), http: SourceHTTP()) { paths, services in
            let before = try configBytes(paths)
            for app in ["apollo", "stremio-ios", "filler"] {
                #expect(
                    code(await source(["remove", "--app", app, "--yes"], services))
                        == "SOURCE_BUILT_IN")
            }
            for app in ["nothere", "Bad ID"] {
                #expect(
                    code(await source(["remove", "--app", app, "--yes"], services))
                        == "SOURCE_NOT_FOUND")
            }
            #expect(code(await source(["remove"], services)) == "USAGE")
            #expect(
                code(await source(["remove", "--app", "myapp", "--confirm", "x"], services))
                    == "USAGE")
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("a busy lock is OPERATION_IN_PROGRESS and nothing is removed")
    func busy() async throws {
        try await withSourceHome(config: config(), http: SourceHTTP()) { paths, services in
            let before = try configBytes(paths)
            let held = try OperationLock.acquire(paths: paths)
            defer { held.release() }
            #expect(
                code(await source(["remove", "--app", "myapp", "--yes"], services))
                    == "OPERATION_IN_PROGRESS")
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("an entry the loader ignored can still be removed")
    func ignored() async throws {
        let broken: [String: JSONValue] = ["app": "myapp", "kind": "nonsense"]
        try await withSourceHome(
            config: customConfig(sources: [broken], approved: []), http: SourceHTTP()
        ) { paths, services in
            let out = await source(["remove", "--app", "myapp", "--yes"], services)
            #expect(out.ok && out.data["wrote"]?["approvedSources"] == 0, "\(out.errors)")
            let after = try loadConfig(paths)
            #expect(after.extra["customSources"] == nil)
        }
    }
}

// MARK: the chain

@Suite("source add: the chain after it")
struct SourceAddChainTests {
    @Test(
        "source add --yes, then fetch, approve and sign work against fakes; source remove leaves sign working"
    )
    func chain() async throws {
        let ipa = try await SignIPAs.shared.data(.apollo)
        let free = try freeKeychainCert()
        let freeDER = try certDER(TestCerts.free)
        try await withSignWorld(app: .apollo, manifest: .none, profile: .noRecord) { w in
            let digest = "sha256:" + sha256Hex(ipa)
            let release = widgetRelease(
                assets: [
                    ReleaseAsset(
                        name: "App.ipa", size: ipa.count, digest: digest,
                        url: "https://github.com/acme/widget/releases/download/0.3.8/App.ipa")
                ])
            let http = FakeFetchTransport(
                metadata: [widgetAPI: release], download: { _ in Delivery(ipa) })
            let services = fetchServices(w.paths, http: http, runner: RecordingRunner())

            let preview = await run(
                argv: ["source"] + addArgs(widgetURL, ["--app", "myapp"]), services: services)
            let confirm = try #require(preview.data["confirm"]?.string, "\(preview.errors)")
            let added = await run(
                argv: ["source"] + addArgs(widgetURL, ["--app", "myapp"], confirm: confirm),
                services: services)
            #expect(added.ok, "\(added.errors)")
            #expect(http.downloadRequests.isEmpty, "source add fetched nothing")

            let options = { (version: String?) in
                FetchOptions(app: "myapp", approve: version != nil, version: version)
            }
            let fetched = await FetchCommand.run(
                services, options(nil), registry: ScratchRegistry())
            #expect(fetched.ok, "\(fetched.errors)")
            let approved = await FetchCommand.run(
                services, options("0.3.8"), registry: ScratchRegistry())
            #expect(approved.ok, "\(approved.errors)")

            let bundleId = carrierPrefix + ".free.myapp"
            let udid = savedUdid("1")
            let xml = try profileXML(
                uuid: signProfileUUID, team: Team.free,
                applicationIdentifier: Team.free + "." + bundleId,
                getTaskAllow: true, devices: [udid], certs: [freeDER], platform: ["iOS"],
                created: daysFromNow(-2), expires: daysFromNow(5))
            let dir = "\(w.paths.freeProfiles)/myapp/iphone"
            try makeDirectories(dir, mode: 0o700)
            try Data(xml.utf8).write(
                to: URL(fileURLWithPath: "\(dir)/\(signProfileUUID).mobileprovision"))
            try await LedgerStore(paths: w.paths).update { ledger in
                ledger.freeProfiles = [
                    LedgerFreeProfile(
                        id: "iphone/myapp", device: "iphone", deviceTail: Redactor.tail4(udid),
                        app: "myapp", bundleId: bundleId, profileUuid: signProfileUUID,
                        created: daysFromNow(-2), expires: daysFromNow(5),
                        certFp8: LedgerSync.fp8(free.reference),
                        file: "profiles/free/myapp/iphone/\(signProfileUUID).mobileprovision")
                ]
            }
            let signed = await w.run(app: "myapp", device: "iphone")
            #expect(signed.ok, "\(signed.errors)")
            #expect(signed.data["bundleId"] == .string(bundleId))

            // Removing the source stops fetch, and leaves sign working over what was fetched.
            let removed = await run(
                argv: ["source", "remove", "--app", "myapp", "--yes"], services: services)
            #expect(removed.ok, "\(removed.errors)")
            let refetch = await FetchCommand.run(
                services, options(nil), registry: ScratchRegistry())
            #expect(refetch.errors.first?.code == "SOURCE_NOT_ALLOWED")
            let again = await w.run(app: "myapp", device: "iphone")
            #expect(again.ok, "\(again.errors)")
        }
    }
}
