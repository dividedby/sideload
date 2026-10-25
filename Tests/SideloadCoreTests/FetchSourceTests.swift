import Foundation
import Testing

@testable import SideloadCore

private let apolloSource = FetchCatalog.sources.first { $0.app == "apollo" }!
private let digestA = String(repeating: "ab", count: 32)

private func resolveApollo(_ json: Data) throws -> ResolvedAsset { try SourceResolver.resolve(apolloSource, json: json) }

private func failure(_ body: () throws -> Any) -> String? {
    do {
        _ = try body()
        return nil
    } catch {
        return (error as? SideloadError)?.code ?? "other"
    }
}

@Suite("fetch: Apollo Reborn selection")
struct ApolloSelectionTests {
    @Test("picks the exact GLASS-NOEXTENSIONS asset and no look-alike, whatever the order")
    func exactName() throws {
        let exact = ReleaseAsset(name: "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa", size: 4321, digest: "sha256:" + digestA.uppercased())
        for assets in [apolloDecoys() + [exact], [exact] + apolloDecoys(), Array((apolloDecoys() + [exact]).reversed())] {
            let asset = try resolveApollo(releaseJSON(assets: assets))
            #expect(asset.app == "apollo")
            #expect(asset.version == "3.9.0")
            #expect(asset.fileName == "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa")
            #expect(asset.url.absoluteString == "https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa")
            #expect(asset.upstreamDigest == digestA, "lowercased hex, prefix dropped")
            #expect(asset.size == 4321)
            #expect(asset.build == nil && asset.minOS == nil, "Apollo declares neither a build nor a minimum OS")
        }
    }

    @Test("each decoy alone is refused", arguments: apolloDecoys().map(\.name))
    func decoyAlone(name: String) {
        let json = releaseJSON(assets: apolloDecoys().filter { $0.name == name })
        #expect(failure { try resolveApollo(json) } == "SOURCE_NOT_ALLOWED")
    }

    @Test("the version comes from the tag suffix after the underscore")
    func versionFromTag() throws {
        let json = releaseJSON(
            tag: "v2.0_4.1.0-beta2", assets: [ReleaseAsset(name: "Apollo-Reborn-4.1.0-beta2-GLASS-NOEXTENSIONS.ipa")])
        #expect(try resolveApollo(json).version == "4.1.0-beta2")
        // The asset must carry that version, not the x part.
        let wrong = releaseJSON(tag: "v2.0_4.1.0", assets: [ReleaseAsset(name: "Apollo-Reborn-2.0-GLASS-NOEXTENSIONS.ipa")])
        #expect(failure { try resolveApollo(wrong) } == "SOURCE_NOT_ALLOWED")
    }

    @Test("a tag that is not v<x>_<ver> is refused", arguments: ["v1.15.11", "1.15.11_3.9.0", "v1_2_3", "v1.0_../x", "v_3.9.0", "v1.0_", "v1.0_a/b"])
    func badTags(tag: String) {
        let json = releaseJSON(tag: tag, assets: [ReleaseAsset(name: "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa", url: "https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/\(tag)/x")])
        #expect(failure { try resolveApollo(json) } == "SOURCE_NOT_ALLOWED")
    }

    @Test("a missing or malformed digest is a hard failure", arguments: [
        nil, "", "sha256:", "sha256:abc", "sha1:" + String(repeating: "ab", count: 32), String(repeating: "ab", count: 32),
        "sha256:" + String(repeating: "zz", count: 32), "sha256:" + String(repeating: "ab", count: 33),
    ] as [String?])
    func badDigest(digest: String?) {
        let json = releaseJSON(assets: [ReleaseAsset(name: "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa", digest: digest)])
        #expect(failure { try resolveApollo(json) } == "UPSTREAM_DIGEST_MISSING")
    }

    @Test("two assets with the exact name, a draft, a half-uploaded asset and a foreign URL are refused")
    func otherRefusals() {
        let name = "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa"
        #expect(failure { try resolveApollo(releaseJSON(assets: [ReleaseAsset(name: name), ReleaseAsset(name: name)])) } == "SOURCE_NOT_ALLOWED")
        #expect(failure { try resolveApollo(releaseJSON(assets: [ReleaseAsset(name: name)], draft: true)) } == "SOURCE_NOT_ALLOWED")
        #expect(failure { try resolveApollo(releaseJSON(assets: [ReleaseAsset(name: name)], prerelease: true)) } == "SOURCE_NOT_ALLOWED")
        #expect(failure { try resolveApollo(releaseJSON(assets: [ReleaseAsset(name: name, state: "starter")])) } == "SOURCE_NOT_ALLOWED")
        for url in [
            "https://evil.example/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/\(name)",
            "http://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/\(name)",
            "https://github.com/other/repo/releases/download/v1.15.11_3.9.0/\(name)",
        ] {
            #expect(failure { try resolveApollo(releaseJSON(assets: [ReleaseAsset(name: name, url: url)])) } == "SOURCE_NOT_ALLOWED", "\(url)")
        }
    }

    @Test("invalid JSON and a missing size are SOURCE_INVALID; an oversized declared file is DOWNLOAD_TOO_LARGE")
    func shape() {
        let name = "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa"
        #expect(failure { try resolveApollo(Data("not json".utf8)) } == "SOURCE_INVALID")
        #expect(failure { try resolveApollo(releaseJSON(assets: [ReleaseAsset(name: name, size: 0)])) } == "SOURCE_INVALID")
        #expect(failure { try resolveApollo(releaseJSON(assets: [ReleaseAsset(name: name, size: 3 << 30)])) } == "DOWNLOAD_TOO_LARGE")
    }
}

@Suite("fetch: Stremio indexes")
struct StremioIndexTests {
    private func resolve(tvos: Bool, _ json: Data) throws -> ResolvedAsset {
        try SourceResolver.resolve(FetchCatalog.sources.first { $0.app == (tvos ? "stremio-tvos" : "stremio-ios") }!, json: json)
    }

    @Test("tvOS: first version, exact CDN path, digest and size")
    func tvos() throws {
        let asset = try resolve(tvos: true, stremioIndexJSON(tvos: true, sha256: digestA.uppercased(), size: 777))
        #expect(asset.app == "stremio-tvos")
        #expect(asset.version == "1.9.6b142")
        #expect(asset.fileName == "stremio_tvOS.ipa")
        #expect(asset.url.absoluteString == "https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa")
        #expect(asset.upstreamDigest == digestA)
        #expect(asset.size == 777)
        #expect(asset.build == "142" && asset.minOS == "15.0", "the index's buildVersion and minOSVersion")
    }

    @Test("iOS: same bundle ID as tvOS, its own app key, host pinned")
    func ios() throws {
        let asset = try resolve(tvos: false, stremioIndexJSON(tvos: false))
        #expect(asset.app == "stremio-ios")
        #expect(asset.version == "1.9.6b142")
        #expect(asset.fileName == "stremio_iOS.ipa")
        #expect(asset.url.host == "dl.strem.io")
        #expect(asset.minOS == "14.0" && asset.build == "142")
        #expect(FetchCatalog.sources.map(\.app) == ["apollo", "stremio-ios", "stremio-tvos"])
        #expect(FetchCatalog.stremioBundleId == "com.stremio.pal")
    }

    @Test("a missing minOSVersion is nil; a malformed one is SOURCE_INVALID", arguments: ["", "fifteen", "15.0; rm", "1.2.3.4", "../1"])
    func minOS(bad: String) throws {
        let json = Data(
            #"{"apps":[{"bundleIdentifier":"com.stremio.pal","versions":[{"version":"1.9.6","buildVersion":"142","downloadURL":"https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa","size":5,"sha256":"\#(digestA)","minOSVersion":"\#(bad)"}]}]}"#.utf8)
        #expect(failure { try resolve(tvos: true, json) } == "SOURCE_INVALID")
        let absent = Data(
            #"{"apps":[{"bundleIdentifier":"com.stremio.pal","versions":[{"version":"1.9.6","buildVersion":"142","downloadURL":"https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa","size":5,"sha256":"\#(digestA)"}]}]}"#.utf8)
        #expect(try resolve(tvos: true, absent).minOS == nil)
    }

    @Test("minOSVersion as a string, an integer or a float is formatted without an artefact; missing is nil", arguments: [
        (#""15.1""#, "15.1"), (#""15.0""#, "15.0"), ("15", "15"), ("15.0", "15"), ("15.1", "15.1"), ("14.5", "14.5"),
        ("17.10", "17.1"), ("16.0e0", "16"),
    ])
    func minOSForms(raw: String, expected: String) throws {
        let json = Data(
            #"{"apps":[{"bundleIdentifier":"com.stremio.pal","versions":[{"version":"1.9.6","buildVersion":"142","downloadURL":"https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa","size":5,"sha256":"\#(digestA)","minOSVersion":\#(raw)}]}]}"#.utf8)
        #expect(try resolve(tvos: true, json).minOS == expected)
    }

    @Test("a float minOSVersion that is not a version number is still refused", arguments: ["-1.5", "1e5", "1000.5", "true"])
    func minOSBadNumber(raw: String) {
        let json = Data(
            #"{"apps":[{"bundleIdentifier":"com.stremio.pal","versions":[{"version":"1.9.6","buildVersion":"142","downloadURL":"https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa","size":5,"sha256":"\#(digestA)","minOSVersion":\#(raw)}]}]}"#.utf8)
        #expect(failure { try resolve(tvos: true, json) } == "SOURCE_INVALID")
    }

    @Test("a numeric buildVersion is accepted")
    func numericBuild() throws {
        let json = Data(
            #"{"apps":[{"bundleIdentifier":"com.stremio.pal","versions":[{"version":"1.9.6","buildVersion":142,"downloadURL":"https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa","size":5,"sha256":"\#(digestA)"}]}]}"#.utf8)
        #expect(try resolve(tvos: true, json).version == "1.9.6b142")
    }

    @Test("a download URL off https://dl.strem.io is refused", arguments: [
        "http://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://evil.example/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://dl.strem.io.evil.example/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://user@dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://dl.strem.io:8443/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa?x=1",
        "https://dl.strem.io/apple/1.9.6b142/tvos/../stremio_tvOS.ipa",
        "https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.zip",
        "https://dl.strem.io/apple/1.9.6b141/tvos/stremio_tvOS.ipa",
        "https://dl.strem.io/apple/1.9.6b142/ios/stremio_iOS.ipa",
    ])
    func badURL(url: String) {
        #expect(failure { try resolve(tvos: true, stremioIndexJSON(tvos: true, downloadURL: url)) } == "SOURCE_NOT_ALLOWED", "\(url)")
    }

    @Test("iOS refuses a foreign host or scheme the same way")
    func badIOSURL() {
        for url in ["http://dl.strem.io/x.ipa", "https://cdn.example/x.ipa", "https://dl.strem.io/dir/"] {
            #expect(failure { try resolve(tvos: false, stremioIndexJSON(tvos: false, downloadURL: url)) } == "SOURCE_NOT_ALLOWED", "\(url)")
        }
    }

    @Test("a missing or malformed sha256 is UPSTREAM_DIGEST_MISSING", arguments: [nil, "", "abc", "zz" + String(repeating: "ab", count: 31)] as [String?])
    func badDigest(digest: String?) {
        #expect(failure { try resolve(tvos: true, stremioIndexJSON(tvos: true, sha256: digest)) } == "UPSTREAM_DIGEST_MISSING")
    }

    @Test("no app, two apps or no versions for the bundle ID is refused; a bad size is not accepted")
    func shape() {
        #expect(failure { try resolve(tvos: true, stremioIndexJSON(tvos: true, bundleId: "com.example.other")) } == "SOURCE_NOT_ALLOWED")
        #expect(failure { try resolve(tvos: true, Data(#"{"apps":[]}"#.utf8)) } == "SOURCE_NOT_ALLOWED")
        #expect(failure { try resolve(tvos: true, Data(#"{"apps":[{"bundleIdentifier":"com.stremio.pal","versions":[]}]}"#.utf8)) } == "SOURCE_INVALID")
        #expect(failure { try resolve(tvos: true, Data("[]".utf8)) } == "SOURCE_INVALID")
        #expect(failure { try resolve(tvos: true, stremioIndexJSON(tvos: true, size: 0)) } == "SOURCE_INVALID")
        #expect(failure { try resolve(tvos: true, stremioIndexJSON(tvos: true, size: 3 << 30)) } == "DOWNLOAD_TOO_LARGE")
        #expect(failure { try resolve(tvos: true, stremioIndexJSON(tvos: true, version: "../x")) } == "SOURCE_INVALID")
    }
}

@Suite("fetch: host allowlist and approved sources")
struct AllowlistTests {
    @Test("the size cap and the redirect limit each have one definition")
    func singleSourceLimits() {
        #expect(FetchLimits.maxIPABytes == 2 << 30 && FetchLimits.maxRedirects == 3)
        #expect(InspectLimits().maxFileBytes == UInt64(FetchLimits.maxIPABytes), "inspect opens what fetch may download")
        let request = DownloadRequest(url: URL(string: "https://dl.strem.io/a.ipa")!, allowedHosts: ["dl.strem.io"], maxBytes: 1, timeout: 1)
        #expect(request.maxRedirects == FetchLimits.maxRedirects)
    }

    @Test("https, an allowed host, the default port and no credentials")
    func policy() {
        let hosts: Set<String> = ["dl.strem.io"]
        func ok(_ s: String) -> Bool { DownloadPolicy.permits(URL(string: s)!, hosts: hosts) }
        #expect(ok("https://dl.strem.io/a.ipa"))
        #expect(ok("https://DL.STREM.IO:443/a.ipa"))
        #expect(!ok("http://dl.strem.io/a.ipa"))
        #expect(!ok("https://evil.example/a.ipa"))
        #expect(!ok("https://x.dl.strem.io/a.ipa"))
        #expect(!ok("https://dl.strem.io:8443/a.ipa"))
        #expect(!ok("https://u:p@dl.strem.io/a.ipa"))
        #expect(!ok("ftp://dl.strem.io/a.ipa"))
        #expect(!ok("file:///etc/passwd"))
    }

    @Test("the catalog's hosts are exactly the approved ones")
    func catalogHosts() {
        let all = FetchCatalog.sources.reduce(into: Set<String>()) { $0.formUnion($1.metadataHosts.union($1.downloadHosts)) }
        #expect(all == [
            "api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
            "raw.githubusercontent.com", "dl.strem.io",
        ])
        // Stremio's CDN may not redirect anywhere else yet (design section 17, question 2).
        #expect(FetchCatalog.sources.filter { $0.app.hasPrefix("stremio") }.allSatisfy { $0.downloadHosts == ["dl.strem.io"] })
    }

    @Test("a source is usable only when the owner listed it in approvedSources")
    func approval() throws {
        #expect(failure { try FetchCatalog.approved(app: "apollo", config: Config()) } == "SOURCE_NOT_ALLOWED")
        #expect(failure { try FetchCatalog.approved(app: "feather", config: Config(approvedSources: [["app": "feather"]])) } == "SOURCE_NOT_ALLOWED")
        #expect(failure { try FetchCatalog.approved(app: "apollo", config: Config(approvedSources: [["app": "stremio-ios"], "junk", ["kind": "x"]])) } == "SOURCE_NOT_ALLOWED")
        let source = try FetchCatalog.approved(app: "apollo", config: Config(approvedSources: [["app": "apollo"]]))
        #expect(source == apolloSource)
    }

    @Test("a hosts list in the entry can narrow the allowlist and never widen it")
    func narrowing() throws {
        let narrowed = try FetchCatalog.approved(
            app: "apollo", config: Config(approvedSources: [["app": "apollo", "hosts": ["api.github.com", "github.com", "evil.example"]]]))
        #expect(narrowed.metadataHosts == ["api.github.com"])
        #expect(narrowed.downloadHosts == ["github.com"])
    }
}
