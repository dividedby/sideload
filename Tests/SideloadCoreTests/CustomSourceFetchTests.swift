import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// `fetch` and `updates` over a custom source (issue #47, PR A): the two resolvers, the host rules, the bundle-ID pin and the
// update cache. The transport is a script; the IPAs are the synthetic ones from SampleIPAs. Nothing here has run against a real
// source.

private let ghAPI = "https://api.github.com/repos/acme/widget/releases/latest"
private let indexURL = "https://index.example.org/apps/index.json"
private let evil = URL(string: "https://evil.example.org/App.ipa")!

private func assetURL(_ name: String, tag: String = "0.3.8") -> String {
    "https://github.com/acme/widget/releases/download/\(tag)/\(name)"
}

/// A release of the shape GitHub serves: the IPA with its digest, and a checksum file that is not an IPA.
private func widgetAssets(
    _ ipa: Data, tag: String = "0.3.8", size: Int? = nil, digest: String? = nil
)
    -> [ReleaseAsset]
{
    [
        ReleaseAsset(
            name: "App.ipa", size: size ?? ipa.count,
            digest: "sha256:" + (digest ?? sha256Hex(ipa)), url: assetURL("App.ipa", tag: tag)),
        ReleaseAsset(
            name: "App.ipa.sha256", size: 80,
            digest: "sha256:" + String(repeating: "ef", count: 32),
            url: assetURL("App.ipa.sha256", tag: tag)),
    ]
}

private func widgetRelease(
    _ ipa: Data, tag: String = "0.3.8", assets: [ReleaseAsset]? = nil, draft: Bool = false,
    prerelease: Bool = false
) -> Data {
    releaseJSON(
        tag: tag, assets: assets ?? widgetAssets(ipa, tag: tag), draft: draft,
        prerelease: prerelease)
}

private func resolveGithub(_ json: Data) throws -> ResolvedAsset {
    try SourceResolver.github(app: "myapp", repo: "acme/widget", json: json)
}

private func code(_ body: () throws -> Any) -> String? {
    do {
        _ = try body()
        return nil
    } catch {
        return (error as? SideloadError)?.code ?? "\(error)"
    }
}

@Suite("custom sources: GitHub resolver")
struct CustomGithubResolverTests {
    private let blob = Data("ipa".utf8)

    @Test(
        "the release shape GitHub serves: tag 0.3.8, one .ipa asset with a digest, a checksum file ignored"
    )
    func happy() throws {
        let asset = try resolveGithub(widgetRelease(blob))
        #expect(asset.app == "myapp" && asset.version == "0.3.8" && asset.fileName == "App.ipa")
        #expect(asset.url.absoluteString == assetURL("App.ipa"))
        #expect(asset.upstreamDigest == sha256Hex(blob) && asset.size == 3)
        #expect(asset.build == nil && asset.minOS == nil)
    }

    @Test("a leading v is dropped from the tag; the asset URL still carries the whole tag")
    func vTag() throws {
        let asset = try resolveGithub(widgetRelease(blob, tag: "v1.2.3"))
        #expect(asset.version == "1.2.3")
        #expect(asset.url.absoluteString == assetURL("App.ipa", tag: "v1.2.3"))
    }

    @Test("a draft or pre-release is skipped", arguments: [(true, false), (false, true)])
    func draft(draft: Bool, prerelease: Bool) {
        let json = widgetRelease(blob, draft: draft, prerelease: prerelease)
        #expect(code { try resolveGithub(json) } == "SOURCE_NOT_ALLOWED")
    }

    @Test("zero or several .ipa assets are SOURCE_NOT_ALLOWED")
    func ipaCount() {
        let none = [ReleaseAsset(name: "App.zip", url: assetURL("App.zip"))]
        #expect(
            code { try resolveGithub(widgetRelease(blob, assets: none)) } == "SOURCE_NOT_ALLOWED")
        let two = widgetAssets(blob) + [ReleaseAsset(name: "Other.ipa", url: assetURL("Other.ipa"))]
        #expect(
            code { try resolveGithub(widgetRelease(blob, assets: two)) } == "SOURCE_NOT_ALLOWED")
        let upper =
            widgetAssets(blob) + [ReleaseAsset(name: "Other.IPA", url: assetURL("Other.IPA"))]
        #expect(
            code { try resolveGithub(widgetRelease(blob, assets: upper)) } == "SOURCE_NOT_ALLOWED")
    }

    @Test(
        "a missing or malformed digest is UPSTREAM_DIGEST_MISSING",
        arguments: [nil, "", "sha256:xyz", "abcd"])
    func digest(digest: String?) {
        var assets = widgetAssets(blob)
        assets[0].digest = digest
        #expect(
            code { try resolveGithub(widgetRelease(blob, assets: assets)) }
                == "UPSTREAM_DIGEST_MISSING")
    }

    @Test(
        "a tag that is not a plain version is refused",
        arguments: ["", "v", "../x", "a/b", "1.0 beta", "v..1", "-1"])
    func badTag(tag: String) {
        #expect(code { try resolveGithub(widgetRelease(blob, tag: tag)) } != nil)
    }

    @Test("the asset URL must be exactly the repository's release asset")
    func urls() {
        let wrong = [
            "https://evil.example.org/acme/widget/releases/download/0.3.8/App.ipa",
            "https://github.com/acme/other/releases/download/0.3.8/App.ipa",
            "https://github.com/acme/widget/releases/download/0.3.9/App.ipa",
            "https://github.com/acme/widget/releases/download/0.3.8/App.ipa?x=1",
            "http://github.com/acme/widget/releases/download/0.3.8/App.ipa",
        ]
        for url in wrong {
            var assets = widgetAssets(blob)
            assets[0].url = url
            #expect(
                code { try resolveGithub(widgetRelease(blob, assets: assets)) }
                    == "SOURCE_NOT_ALLOWED", "\(url)")
        }
    }

    @Test("owner and repo compare without regard to case; the rest of the URL stays exact")
    func repoCase() throws {
        // The config says Acme/WIDGET; the API serves the canonical acme/widget.
        let asset = try SourceResolver.github(
            app: "myapp", repo: "Acme/WIDGET", json: widgetRelease(blob))
        #expect(asset.url.absoluteString == assetURL("App.ipa"))
        // And the other way round.
        var upper = widgetAssets(blob)
        upper[0].url = "https://github.com/ACME/Widget/releases/download/0.3.8/App.ipa"
        #expect(
            try SourceResolver.github(
                app: "myapp", repo: "acme/widget", json: widgetRelease(blob, assets: upper)
            ).version == "0.3.8")
        // A different repository still refuses, and so does a changed case anywhere else.
        for url in [
            "https://github.com/acme/widget2/releases/download/0.3.8/App.ipa",
            "https://github.com/other/widget/releases/download/0.3.8/App.ipa",
            "https://GitHub.com/acme/widget/releases/download/0.3.8/App.ipa",
            "https://github.com/acme/widget/Releases/download/0.3.8/App.ipa",
            "https://github.com/acme/widget/releases/download/0.3.8/app.ipa",
            "https://github.com/acme/widget/releases/download/0.3.8/App.ipa/x",
            "https://github.com/acme/widget/extra/releases/download/0.3.8/App.ipa",
        ] {
            var assets = widgetAssets(blob)
            assets[0].url = url
            #expect(
                code {
                    try SourceResolver.github(
                        app: "myapp", repo: "Acme/WIDGET", json: widgetRelease(blob, assets: assets)
                    )
                } == "SOURCE_NOT_ALLOWED", "\(url)")
        }
    }

    @Test("an unusable size or an asset that is not fully uploaded is refused")
    func sizes() {
        var assets = widgetAssets(blob)
        assets[0].size = 0
        #expect(code { try resolveGithub(widgetRelease(blob, assets: assets)) } == "SOURCE_INVALID")
        assets[0].size = Int(FetchLimits.maxIPABytes) + 1
        #expect(
            code { try resolveGithub(widgetRelease(blob, assets: assets)) } == "DOWNLOAD_TOO_LARGE")
        assets = widgetAssets(blob)
        assets[0].state = "starter"
        #expect(
            code { try resolveGithub(widgetRelease(blob, assets: assets)) } == "SOURCE_NOT_ALLOWED")
        #expect(code { try resolveGithub(Data("nope".utf8)) } == "SOURCE_INVALID")
    }

    @Test("an asset name with a path or a space is refused")
    func names() {
        var assets = widgetAssets(blob)
        assets[0].name = "My App.ipa"
        assets[0].url = assetURL("My App.ipa")
        #expect(
            code { try resolveGithub(widgetRelease(blob, assets: assets)) } == "SOURCE_NOT_ALLOWED")
    }
}

@Suite("custom sources: AltStore resolver")
struct CustomAltstoreResolverTests {
    private func resolve(_ json: Data, hosts: Set<String> = ["cdn.example.org"]) throws
        -> ResolvedAsset
    {
        try SourceResolver.altstore(
            app: "myapp", bundleId: "io.example.apollo", hosts: hosts, json: json)
    }

    private func index(url: String, bundleId: String = "io.example.apollo") -> Data {
        stremioIndexJSON(
            tvos: false, downloadURL: url, sha256: String(repeating: "cd", count: 32),
            bundleId: bundleId)
    }

    @Test("the Stremio index shape, with no tvOS path pin, on a listed download host")
    func happy() throws {
        let asset = try resolve(index(url: "https://cdn.example.org/any/path/App.ipa"))
        #expect(asset.version == "1.9.6b142" && asset.build == "142" && asset.minOS == "14.0")
        #expect(asset.fileName == "App.ipa" && asset.url.host == "cdn.example.org")
        #expect(asset.size == 2000 && asset.upstreamDigest == String(repeating: "cd", count: 32))
    }

    @Test("a download host off the list, a lookalike or an unsafe URL is refused")
    func hosts() {
        for url in [
            "https://dl.strem.io/App.ipa", "https://cdn.example.org.evil.example/App.ipa",
            "http://cdn.example.org/App.ipa", "https://cdn.example.org:8443/App.ipa",
            "https://u@cdn.example.org/App.ipa", "https://cdn.example.org/App.ipa?x=1",
            "https://cdn.example.org/a/../App.ipa", "https://cdn.example.org/App.zip",
        ] {
            #expect(code { try resolve(index(url: url)) } == "SOURCE_NOT_ALLOWED", "\(url)")
        }
        #expect(
            code {
                try resolve(
                    index(url: "https://cdn.example.org/App.ipa"), hosts: ["other.example.org"])
            }
                == "SOURCE_NOT_ALLOWED")
    }

    /// The index with `buildVersion` removed from the app's first version.
    private func withoutBuild(_ json: Data) throws -> Data {
        var root = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        var apps = try #require(root["apps"] as? [[String: Any]])
        var versions = try #require(apps[0]["versions"] as? [[String: Any]])
        versions[0].removeValue(forKey: "buildVersion")
        apps[0]["versions"] = versions
        root["apps"] = apps
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test("buildVersion is optional: used when present, else the version stands alone")
    func optionalBuild() throws {
        let json = index(url: "https://cdn.example.org/App.ipa")
        #expect(try resolve(json).version == "1.9.6b142")
        let bare = try resolve(try withoutBuild(json))
        #expect(bare.version == "1.9.6" && bare.build == nil && bare.fileName == "App.ipa")
        #expect(
            VersionOrder.parse(bare.version) == VersionOrder.Parsed(parts: [1, 9, 6], build: nil))
        // A build that is there but unusable is still refused.
        let odd = String(decoding: json, as: UTF8.self).replacingOccurrences(
            of: "\"142\"", with: "\"1 2\"")
        #expect(code { try resolve(Data(odd.utf8)) } == "SOURCE_INVALID")
    }

    @Test("the migrated Stremio entry still requires the build")
    func stremioStillNeedsBuild() throws {
        let json = try withoutBuild(stremioIndexJSON(tvos: false))
        let source = try #require(FetchCatalog.sources.first { $0.app == "stremio-ios" })
        #expect(code { try SourceResolver.resolve(source, json: json) } == "SOURCE_INVALID")
    }

    @Test("an index without the pinned bundle ID is refused")
    func bundle() {
        let json = index(url: "https://cdn.example.org/App.ipa", bundleId: "io.example.other")
        #expect(code { try resolve(json) } == "SOURCE_NOT_ALLOWED")
    }
}

// MARK: fetch

private func withCustom(
    sources: [[String: JSONValue]], approved: [JSONValue] = [["app": "myapp"]],
    _ body: (Paths, Config) async throws -> Void
) async throws {
    let config = customConfig(sources: sources, approved: approved)
    try await withTestHome(config: config) { paths, _ in try await body(paths, config) }
}

private func fetch(
    _ paths: Paths, _ http: any HTTPTransport, approve version: String? = nil, app: String = "myapp"
) async -> Envelope {
    await FetchCommand.run(
        fetchServices(paths, http: http, runner: RecordingRunner()),
        FetchOptions(app: app, approve: version != nil, version: version),
        registry: ScratchRegistry())
}

private func githubTransport(
    _ ipa: Data, tag: String = "0.3.8", body: Data? = nil, metadata: Data? = nil,
    delivery: (@Sendable (DownloadRequest) throws -> Delivery)? = nil
) -> FakeFetchTransport {
    FakeFetchTransport(
        metadata: [ghAPI: metadata ?? widgetRelease(ipa, tag: tag)],
        download: delivery ?? { _ in Delivery(body ?? ipa) })
}

private func altstoreTransport(
    _ ipa: Data, bundleId: String = "io.example.apollo",
    url: String = "https://cdn.example.org/App.ipa",
    delivery: (@Sendable (DownloadRequest) throws -> Delivery)? = nil
) -> FakeFetchTransport {
    let json = stremioIndexJSON(
        tvos: false, downloadURL: url, sha256: sha256Hex(ipa), size: ipa.count, bundleId: bundleId)
    return FakeFetchTransport(
        metadata: [indexURL: json], download: delivery ?? { _ in Delivery(ipa) })
}

private func nothingKept(_ paths: Paths, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(
        partFiles(paths).isEmpty && scratchFolders(paths).isEmpty, sourceLocation: sourceLocation)
    #expect(listing(paths.downloads).isEmpty, sourceLocation: sourceLocation)
    #expect(try ManifestStore(paths: paths).load().entries.isEmpty, sourceLocation: sourceLocation)
    expectLockFree(paths, sourceLocation: sourceLocation)
}

@Suite("custom sources: fetch")
struct CustomFetchTests {
    @Test("GitHub: fetch, the owner's approve, then the manifest holds what sign reads")
    func githubChain() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(sources: [githubEntry]) { paths, _ in
            let http = githubTransport(ipa)
            let fetched = await fetch(paths, http)
            #expect(fetched.ok, "\(fetched.errors)")
            let json = try fetched.printed().json
            #expect(json["app"] == "myapp" && json["version"] == "0.3.8")
            #expect(json["downloaded"] == true && json["approved"] == false)
            #expect(json["file"] == "myapp/0.3.8/App.ipa" && json["urlHost"] == "github.com")
            #expect(json["upstreamDigest"] == .string(sha256Hex(ipa)))
            #expect(json["inspect"]?["bundleId"] == "io.example.apollo")
            #expect(http.getRequests.map(\.url.absoluteString) == [ghAPI])
            #expect(http.downloadRequests.map(\.url.absoluteString) == [assetURL("App.ipa")])
            #expect(
                Set(http.downloadRequests[0].allowedHosts) == [
                    "github.com", "objects.githubusercontent.com",
                    "release-assets.githubusercontent.com",
                ])

            let before = try ManifestStore(paths: paths).load()
            #expect(before.entry(app: "myapp", version: "0.3.8")?.approved == false)
            #expect(before.entry(app: "myapp", version: "0.3.8")?.bundleId == "io.example.apollo")

            let approved = await fetch(paths, http, approve: "0.3.8")
            #expect(approved.ok, "\(approved.errors)")
            let manifest = try ManifestStore(paths: paths).load()
            let entry = try #require(manifest.entry(app: "myapp", version: "0.3.8"))
            #expect(entry.approved && entry.approvedAt != nil && entry.sha256 == sha256Hex(ipa))
            #expect(
                try Data(
                    contentsOf: URL(fileURLWithPath: ManifestStore(paths: paths).path(of: entry)))
                    == ipa)
        }
    }

    @Test(
        "a valid source without its approvedSources entry is not fetchable, and nothing is requested"
    )
    func needsApproval() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(sources: [githubEntry], approved: []) { paths, _ in
            let http = githubTransport(ipa)
            let out = await fetch(paths, http)
            #expect(out.firstCode == "SOURCE_NOT_ALLOWED" && http.callCount == 0)
            try nothingKept(paths)
        }
    }

    @Test(
        "hosts in approvedSources narrow a custom source: a narrower list than the metadata host is refused"
    )
    func narrowedAway() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(
            sources: [githubEntry], approved: [["app": "myapp", "hosts": ["github.com"]]]
        ) { paths, _ in
            let http = githubTransport(ipa)
            let out = await fetch(paths, http)
            #expect(out.firstCode == "SOURCE_NOT_ALLOWED" && http.callCount == 0)
        }
    }

    @Test("a redirect to a host off the list is refused and nothing is kept")
    func redirectOffList() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(sources: [githubEntry]) { paths, _ in
            let http = githubTransport(ipa) { _ in Delivery(ipa, finalURL: evil) }
            let out = await fetch(paths, http)
            #expect(out.firstCode == "REDIRECT_NOT_ALLOWED")
            try nothingKept(paths)
        }
    }

    @Test("a download from a host off the list is never requested (AltStore)")
    func hostOffList() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(sources: [altstoreEntry]) { paths, _ in
            let http = altstoreTransport(ipa, url: "https://dl.strem.io/App.ipa")
            let out = await fetch(paths, http)
            #expect(out.firstCode == "SOURCE_NOT_ALLOWED")
            #expect(http.downloadRequests.isEmpty)
            try nothingKept(paths)
        }
    }

    @Test("SIZE_MISMATCH still applies: a body shorter than the declared size is deleted")
    func sizeMismatch() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(sources: [githubEntry]) { paths, _ in
            let metadata = widgetRelease(ipa, assets: widgetAssets(ipa, size: ipa.count + 10))
            let out = await fetch(paths, githubTransport(ipa, metadata: metadata))
            #expect(out.firstCode == "SIZE_MISMATCH")
            try nothingKept(paths)
        }
    }

    @Test("a body that does not match the digest is deleted")
    func digestMismatch() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(sources: [githubEntry]) { paths, _ in
            var other = ipa
            other[other.startIndex] ^= 0xff
            let out = await fetch(paths, githubTransport(ipa, body: other))
            #expect(out.firstCode == "DIGEST_MISMATCH")
            try nothingKept(paths)
        }
    }

    @Test("metadata over 4 MiB is refused by fetch before it is parsed")
    func oversizedMetadata() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(sources: [githubEntry]) { paths, _ in
            let big = Data(count: URLSessionTransport.maxBodyBytes + 1)
            let http = githubTransport(ipa, metadata: big)
            let out = await fetch(paths, http)
            #expect(out.firstCode == "DOWNLOAD_TOO_LARGE" && http.downloadRequests.isEmpty)
            try nothingKept(paths)
        }
    }

    @Test("GitHub: a missing digest is refused before any download")
    func missingDigest() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(sources: [githubEntry]) { paths, _ in
            var assets = widgetAssets(ipa)
            assets[0].digest = nil
            let http = githubTransport(ipa, metadata: widgetRelease(ipa, assets: assets))
            let out = await fetch(paths, http)
            #expect(out.firstCode == "UPSTREAM_DIGEST_MISSING" && http.downloadRequests.isEmpty)
        }
    }

    // MARK: bundle-ID pin

    @Test("AltStore: the happy path records the pinned bundle ID and goes through approve")
    func altstoreChain() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withCustom(sources: [altstoreEntry]) { paths, _ in
            let http = altstoreTransport(ipa)
            let out = await fetch(paths, http)
            #expect(out.ok, "\(out.errors)")
            #expect(try out.printed().json["version"] == "1.9.6b142")
            #expect(http.getRequests.map(\.url.absoluteString) == [indexURL])
            #expect(await fetch(paths, http, approve: "1.9.6b142").ok)
            let entry = try #require(try ManifestStore(paths: paths).load().entries.first)
            #expect(entry.approved && entry.bundleId == "io.example.apollo")
        }
    }

    @Test(
        "AltStore: an IPA whose bundle ID is not the stored one is BUNDLE_ID_MISMATCH and the file is deleted"
    )
    func altstoreMismatch() async throws {
        let ipa = try await SampleIPAs.shared.data("withExtension")  // com.stremio.pal
        try await withCustom(sources: [altstoreEntry]) { paths, _ in
            let out = await fetch(paths, altstoreTransport(ipa))
            #expect(out.firstCode == "BUNDLE_ID_MISMATCH")
            #expect(out.errors.first?.message.contains("com.stremio.pal") == true)
            try nothingKept(paths)
        }
    }

    @Test(
        "GitHub: nothing is pinned until a version is approved, then a different bundle ID is refused"
    )
    func githubPin() async throws {
        let apollo = try await SampleIPAs.shared.data("plain")  // io.example.apollo
        let stremio = try await SampleIPAs.shared.data("withExtension")  // com.stremio.pal
        try await withCustom(sources: [githubEntry]) { paths, _ in
            // First fetch, not approved yet: no pin, so the second (different app) is recorded too.
            #expect(await fetch(paths, githubTransport(apollo, tag: "0.3.8")).ok)
            let second = await fetch(paths, githubTransport(stremio, tag: "0.3.9"))
            #expect(second.ok, "\(second.errors)")
            // The owner approves the first: that is the pin.
            #expect(await fetch(paths, githubTransport(apollo, tag: "0.3.8"), approve: "0.3.8").ok)
            // The other version can no longer be approved ...
            let blocked = await fetch(
                paths, githubTransport(stremio, tag: "0.3.9"), approve: "0.3.9")
            #expect(blocked.firstCode == "BUNDLE_ID_MISMATCH")
            // ... and the refused file and its unapproved entry are gone, as a refused download leaves nothing.
            let afterApprove = try ManifestStore(paths: paths).load()
            #expect(afterApprove.entry(app: "myapp", version: "0.3.9") == nil)
            #expect(afterApprove.entry(app: "myapp", version: "0.3.8")?.approved == true)
            #expect(!FileManager.default.fileExists(atPath: paths.downloads + "/myapp/0.3.9"))
            #expect(
                FileManager.default.fileExists(atPath: paths.downloads + "/myapp/0.3.8/App.ipa"))
            expectLockFree(paths)
            // ... and a later upload with the other bundle ID is refused and deleted.
            let later = await fetch(paths, githubTransport(stremio, tag: "0.4.0"))
            #expect(later.firstCode == "BUNDLE_ID_MISMATCH")
            let manifest = try ManifestStore(paths: paths).load()
            #expect(manifest.entry(app: "myapp", version: "0.4.0") == nil)
            #expect(!FileManager.default.fileExists(atPath: paths.downloads + "/myapp/0.4.0"))
            #expect(partFiles(paths).isEmpty && scratchFolders(paths).isEmpty)
            // The same app at a newer version is fine.
            #expect(await fetch(paths, githubTransport(apollo, tag: "0.4.1")).ok)
        }
    }

    @Test(
        "GitHub: an earliest approved version with no recorded bundle ID refuses, the pin never moves on"
    )
    func githubLegacyPin() async throws {
        let apollo = try await SampleIPAs.shared.data("plain")
        let stremio = try await SampleIPAs.shared.data("withExtension")
        try await withCustom(sources: [githubEntry]) { paths, _ in
            let store = ManifestStore(paths: paths)
            #expect(await fetch(paths, githubTransport(apollo, tag: "0.3.8")).ok)
            #expect(await fetch(paths, githubTransport(apollo, tag: "0.3.8"), approve: "0.3.8").ok)
            // A later version, fetched and waiting for the owner.
            #expect(await fetch(paths, githubTransport(apollo, tag: "0.5.0")).ok)
            // The first approval is as an older build left it: no bundle ID recorded.
            var manifest = try store.load()
            var legacy = try #require(manifest.entry(app: "myapp", version: "0.3.8"))
            legacy.bundleId = nil
            manifest.upsert(legacy)
            try store.save(manifest)

            // Approving the waiting version is refused and it is deleted ...
            let approve = await fetch(
                paths, githubTransport(apollo, tag: "0.5.0"), approve: "0.5.0")
            #expect(approve.firstCode == "BUNDLE_ID_MISMATCH")
            #expect(approve.errors.first?.message.contains("no recorded bundle ID") == true)
            #expect(try store.load().entry(app: "myapp", version: "0.5.0") == nil)
            #expect(!FileManager.default.fileExists(atPath: paths.downloads + "/myapp/0.5.0"))
            // ... and so is any new fetch, of another app or of the same one: there is no pin to check against.
            for (ipa, tag) in [(stremio, "0.6.0"), (apollo, "0.6.1")] {
                let out = await fetch(paths, githubTransport(ipa, tag: tag))
                #expect(out.firstCode == "BUNDLE_ID_MISMATCH", "\(tag)")
                #expect(out.errors.first?.fix?.contains("manifest.json") == true)
                #expect(try store.load().entry(app: "myapp", version: tag) == nil)
                #expect(!FileManager.default.fileExists(atPath: paths.downloads + "/myapp/" + tag))
            }
            #expect(partFiles(paths).isEmpty && scratchFolders(paths).isEmpty)
            expectLockFree(paths)
        }
    }
}

// MARK: updates

@Suite("custom sources: updates")
struct CustomUpdatesTests {
    private func world(
        _ sources: [[String: JSONValue]], installed version: String?,
        _ body: (Services, Paths, FakeFetchTransport) async throws -> Void,
        http: FakeFetchTransport
    ) async throws {
        let config = customConfig(sources: sources)
        try await withTestHome(config: config) { paths, _ in
            let myapp = try #require(config.appRegistry.app("myapp"))
            var record = installRecord(myapp)
            record.version = version ?? "0.3.0"
            try await LedgerStore(paths: paths).update { $0.installs = [record] }
            try await body(fetchServices(paths, http: http), paths, http)
        }
    }

    @Test(
        "updates lists a custom source, and its cache entry survives a reload so the cadence holds")
    func cadenceHolds() async throws {
        let ipa = Data("ipa".utf8)
        let http = FakeFetchTransport(metadata: [ghAPI: widgetRelease(ipa)])
        try await world(
            [githubEntry], installed: "0.3.0",
            { services, paths, http in
                let first = await UpdatesCommand.run(services, UpdatesOptions())
                #expect(first.ok, "\(first.errors)")
                let mine = try #require(
                    first.data["sources"]?.array?.first { $0["app"] == "myapp" })
                #expect(mine["status"] == "ok" && mine["fromCache"] == false)
                #expect(mine["upstream"]?["version"] == "0.3.8")
                #expect(first.data["installs"]?.array?.first?["state"] == "newer")
                #expect(http.getRequests.map(\.url.absoluteString) == [ghAPI])
                #expect(http.downloadRequests.isEmpty)

                // The cache file keeps the custom entry when it is read again with the config's registry ...
                let config = try ConfigStore(paths: paths).load()
                let kept = try UpdateCacheStore(paths: paths).load(
                    now: testNow, apps: FetchCatalog.appNames(config))
                #expect(kept.cache.apps["myapp"]?.version == "0.3.8" && !kept.repaired)

                // ... so a second run inside the 6 h window asks nothing.
                var later = services
                later.clock = FixedClock(testNow.addingTimeInterval(3600))
                let second = await UpdatesCommand.run(later, UpdatesOptions())
                let again = try #require(
                    second.data["sources"]?.array?.first { $0["app"] == "myapp" })
                #expect(again["fromCache"] == true && again["upstream"]?["version"] == "0.3.8")
                #expect(http.getRequests.count == 1, "no second GET inside the cadence")
            }, http: http)
    }

    @Test(
        "an AltStore custom source is checked the same way; its bad metadata is a per-source error")
    func altstore() async throws {
        let ipa = Data("ipa".utf8)
        let json = stremioIndexJSON(
            tvos: false, downloadURL: "https://cdn.example.org/App.ipa", sha256: sha256Hex(ipa),
            size: ipa.count, bundleId: "io.example.apollo")
        try await world(
            [altstoreEntry], installed: "1.9.5b100",
            { services, _, http in
                let out = await UpdatesCommand.run(services, UpdatesOptions(app: "myapp"))
                #expect(out.ok, "\(out.errors)")
                #expect(out.data["sources"]?.array?.first?["upstream"]?["version"] == "1.9.6b142")
                #expect(http.getRequests.map(\.url.absoluteString) == [indexURL])
            }, http: FakeFetchTransport(metadata: [indexURL: json]))

        let off = stremioIndexJSON(
            tvos: false, downloadURL: "https://dl.strem.io/App.ipa", sha256: sha256Hex(ipa),
            size: ipa.count, bundleId: "io.example.apollo")
        try await world(
            [altstoreEntry], installed: "1.9.5b100",
            { services, _, _ in
                let out = await UpdatesCommand.run(services, UpdatesOptions(app: "myapp"))
                #expect(out.firstCode == "SOURCE_NOT_ALLOWED")
            }, http: FakeFetchTransport(metadata: [indexURL: off]))
    }

    @Test("metadata over 4 MiB is a per-source error")
    func oversized() async throws {
        let http = FakeFetchTransport(metadata: [
            ghAPI: Data(count: URLSessionTransport.maxBodyBytes + 1)
        ])
        try await world(
            [githubEntry], installed: "0.3.0",
            { services, _, _ in
                let out = await UpdatesCommand.run(services, UpdatesOptions(app: "myapp"))
                #expect(out.firstCode == "DOWNLOAD_TOO_LARGE")
            }, http: http)
    }

    @Test("an ignored entry is a warning on updates and the built-ins are still checked")
    func ignoredWarns() async throws {
        var broken = githubEntry
        broken["repo"] = "nope"
        let http = FakeFetchTransport(metadata: [:])
        try await world(
            [broken], installed: "0.3.0",
            { services, _, _ in
                let out = await UpdatesCommand.run(services, UpdatesOptions())
                let codes = out.data["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
                #expect(codes == ["CUSTOM_SOURCE_IGNORED"])
                #expect(out.data["sources"]?.array?.contains { $0["app"] == "apollo" } == true)
            }, http: http)
    }
}

// MARK: the sign chain

@Suite("custom sources: sign chain")
struct CustomSourceSignTests {
    @Test(
        "a custom GitHub source goes fetch, approve, then the existing sign, which signs it like a built-in"
    )
    func fetchApproveSign() async throws {
        let ipa = try await SignIPAs.shared.data(.apollo)
        let free = try freeKeychainCert()
        let freeDER = try certDER(TestCerts.free)
        try await withSignWorld(
            app: .apollo, manifest: .none, profile: .noRecord,
            config: { config in
                config.extra["customApps"] = [["id": "myapp", "platform": "ios"]]
                config.extra["customSources"] = .array([.object(githubEntry)])
                config.approvedSources = [["app": "myapp"]]
            }
        ) { w in
            let http = githubTransport(ipa)
            let services = fetchServices(w.paths, http: http, runner: RecordingRunner())
            let options = { (version: String?) in
                FetchOptions(app: "myapp", approve: version != nil, version: version)
            }
            let fetched = await FetchCommand.run(
                services, options(nil), registry: ScratchRegistry())
            #expect(fetched.ok, "\(fetched.errors)")
            let approved = await FetchCommand.run(
                services, options("0.3.8"), registry: ScratchRegistry())
            #expect(approved.ok, "\(approved.errors)")

            // What `provision` would have left for the custom app: its profile and the ledger record.
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

            let out = await w.run(app: "myapp", device: "iphone")
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["app"] == "myapp" && out.data["version"] == "0.3.8")
            #expect(out.data["bundleId"] == .string(bundleId))
            #expect(out.data["signed"] == "builds/signed/myapp/iphone/Apollo.app")
            #expect(try w.ledger().freeSigned.map(\.app) == ["myapp"])
        }
    }
}
