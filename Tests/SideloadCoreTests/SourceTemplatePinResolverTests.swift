import Foundation
import Testing

@testable import SideloadCore

// Template pins for owner-added sources (design: un-built-in sources, PR1): `asset` with one `{version}`, `tagRule`, an index's
// `downloadPath` with `{versionKey}`, and `requireBuild`. The equivalence tests run the same documents through the built-in
// Apollo and Stremio resolvers and through custom sources loaded from `customSources` entries with those pins; the two must
// give the same ResolvedAsset or the same error code, so the built-ins can later become plain entries. Offline.

private let digestA = String(repeating: "ab", count: 32)

/// What a resolver did with a document, with the app key left out (the two sides name different apps).
private enum Outcome: Equatable {
    case resolved(ResolvedAsset)
    case refused(String)
}

private func outcome(_ source: FetchSource, _ json: Data) -> Outcome {
    do {
        let a = try SourceResolver.resolve(source, json: json)
        return .resolved(
            ResolvedAsset(
                app: "x", version: a.version, fileName: a.fileName, url: a.url,
                upstreamDigest: a.upstreamDigest, size: a.size, build: a.build, minOS: a.minOS))
    } catch {
        return .refused((error as? SideloadError)?.code ?? "other")
    }
}

/// The source `entry` loads to for the custom app `myapp`; the entry must be valid.
private func loaded(_ entry: [String: JSONValue]) throws -> FetchSource {
    let registry = customConfig(sources: [entry]).appRegistry
    #expect(registry.warnings.isEmpty, "\(registry.warnings)")
    return try #require(registry.fetchSources.first { $0.app == "myapp" })
}

private func builtIn(_ app: String) throws -> FetchSource {
    try #require(FetchCatalog.sources.first { $0.app == app })
}

private struct Doc: Sendable, CustomTestStringConvertible {
    let label: String
    let json: Data
    /// Whether the built-in resolver accepts it: keeps the equivalence from passing on refusals alone.
    let accepted: Bool
    var testDescription: String { label }

    init(_ label: String, _ json: Data, accepted: Bool = false) {
        self.label = label
        self.json = json
        self.accepted = accepted
    }
}

// MARK: the migrated shapes

/// The entries design section 1.2 migrates the built-ins to (without `app` and `addedAt`).
private func apolloEntry() -> [String: JSONValue] {
    [
        "app": "myapp", "kind": "githubRelease", "repo": "Apollo-Reborn/Apollo-Reborn",
        "asset": "Apollo-Reborn-{version}-GLASS-NOEXTENSIONS.ipa", "tagRule": "underscoreSuffix",
        "metadataHosts": ["api.github.com"],
        "downloadHosts": [
            "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
        ],
    ]
}

private func stremioEntry(tvos: Bool) -> [String: JSONValue] {
    var entry: [String: JSONValue] = [
        "app": "myapp", "kind": "altstoreIndex",
        "url": .string(
            "https://raw.githubusercontent.com/gorlev/stremio-altstore/main/"
                + (tvos ? "stremio-tvos.json" : "stremio-ios.json")),
        "bundleId": "com.stremio.pal", "requireBuild": true,
        "metadataHosts": ["raw.githubusercontent.com"], "downloadHosts": ["dl.strem.io"],
    ]
    if tvos { entry["downloadPath"] = "/apple/{versionKey}/tvos/stremio_tvOS.ipa" }
    return entry
}

// MARK: documents

private let apolloName = "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa"
private let apolloBase = "https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/"

private let apolloDocs: [Doc] = {
    let exact = ReleaseAsset(
        name: apolloName, size: 4321, digest: "sha256:" + digestA.uppercased())
    var docs: [Doc] = [
        Doc(
            "exact asset among decoys", releaseJSON(assets: apolloDecoys() + [exact]),
            accepted: true),
        Doc("exact asset first", releaseJSON(assets: [exact] + apolloDecoys()), accepted: true),
        Doc(
            "exact asset last, reversed",
            releaseJSON(assets: Array((apolloDecoys() + [exact]).reversed())), accepted: true),
        Doc(
            "a beta version after the underscore",
            releaseJSON(
                tag: "v2.0_4.1.0-beta2",
                assets: [ReleaseAsset(name: "Apollo-Reborn-4.1.0-beta2-GLASS-NOEXTENSIONS.ipa")]),
            accepted: true),
        Doc(
            "asset carries the x part, not the version",
            releaseJSON(
                tag: "v2.0_4.1.0",
                assets: [ReleaseAsset(name: "Apollo-Reborn-2.0-GLASS-NOEXTENSIONS.ipa")])),
        Doc(
            "two assets with the exact name",
            releaseJSON(assets: [ReleaseAsset(name: apolloName), ReleaseAsset(name: apolloName)])),
        Doc("draft", releaseJSON(assets: [ReleaseAsset(name: apolloName)], draft: true)),
        Doc("pre-release", releaseJSON(assets: [ReleaseAsset(name: apolloName)], prerelease: true)),
        Doc(
            "asset not uploaded",
            releaseJSON(assets: [ReleaseAsset(name: apolloName, state: "starter")])
        ),
        Doc("invalid JSON", Data("not json".utf8)),
        Doc("an object with no tag", Data(#"{"assets":[]}"#.utf8)),
        Doc("a tag and no assets", Data(#"{"tag_name":"v1_2"}"#.utf8)),
        Doc("size 0", releaseJSON(assets: [ReleaseAsset(name: apolloName, size: 0)])),
        Doc(
            "size over the limit",
            releaseJSON(assets: [ReleaseAsset(name: apolloName, size: 3 << 30)])),
    ]
    docs += apolloDecoys().map {
        Doc("decoy alone: \($0.name)", releaseJSON(assets: [$0]))
    }
    for tag in [
        "v1.15.11", "1.15.11_3.9.0", "v1_2_3", "v1.0_../x", "v_3.9.0", "v1.0_", "v1.0_a/b", "x1_2",
    ] {
        docs.append(
            Doc(
                "tag \(tag)",
                releaseJSON(
                    tag: tag,
                    assets: [ReleaseAsset(name: apolloName, url: apolloBase + "\(tag)/x")])))
    }
    let digests: [String?] = [
        nil, "", "sha256:", "sha256:abc", "sha1:" + String(repeating: "ab", count: 32), digestA,
        "sha256:" + String(repeating: "zz", count: 32),
        "sha256:" + String(repeating: "ab", count: 33),
    ]
    for digest in digests {
        docs.append(
            Doc(
                "digest \(digest ?? "nil")",
                releaseJSON(assets: [ReleaseAsset(name: apolloName, digest: digest)])))
    }
    for url in [
        "https://evil.example/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/\(apolloName)",
        "http://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/\(apolloName)",
        "https://github.com/other/repo/releases/download/v1.15.11_3.9.0/\(apolloName)",
        "https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.1/\(apolloName)",
        "https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/\(apolloName)?x=1",
        "https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/x/\(apolloName)",
    ] {
        docs.append(
            Doc("url \(url)", releaseJSON(assets: [ReleaseAsset(name: apolloName, url: url)])))
    }
    return docs
}()

private func indexDoc(_ version: [String: JSONValue], extra: [JSONValue] = []) -> Data {
    let app: JSONValue = [
        "name": "Stremio", "bundleIdentifier": "com.stremio.pal", "versions": [.object(version)],
    ]
    return try! JSONEncoder().encode(JSONValue.object(["apps": .array([app] + extra)]))
}

private func stremioVersion(
    _ patch: (inout [String: JSONValue]) -> Void = { _ in }
) -> [String: JSONValue] {
    var v: [String: JSONValue] = [
        "version": "1.9.6", "buildVersion": "142",
        "downloadURL": "https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "size": 5, "sha256": .string(digestA),
    ]
    patch(&v)
    return v
}

private let stremioDocs: [Doc] = {
    var docs: [Doc] = [
        Doc(
            "tvOS index", stremioIndexJSON(tvos: true, sha256: digestA.uppercased(), size: 777),
            accepted: true),
        Doc("iOS index", stremioIndexJSON(tvos: false), accepted: true),
        Doc(
            "iOS URL on a tvOS-shaped index",
            stremioIndexJSON(tvos: false, downloadURL: "https://dl.strem.io/dir/x.ipa"),
            accepted: true),
        Doc("numeric build", indexDoc(stremioVersion { $0["buildVersion"] = 142 }), accepted: true),
        Doc("no minOSVersion", indexDoc(stremioVersion()), accepted: true),
        Doc("no build", indexDoc(stremioVersion { $0["buildVersion"] = nil })),
        Doc("unsafe build", indexDoc(stremioVersion { $0["buildVersion"] = "../b" })),
        Doc("unsafe version", stremioIndexJSON(tvos: true, version: "../x")),
        Doc("size 0", stremioIndexJSON(tvos: true, size: 0)),
        Doc("size over the limit", stremioIndexJSON(tvos: true, size: 3 << 30)),
        Doc("other bundle", stremioIndexJSON(tvos: true, bundleId: "com.example.other")),
        Doc("no apps", Data(#"{"apps":[]}"#.utf8)),
        Doc(
            "no versions",
            Data(#"{"apps":[{"bundleIdentifier":"com.stremio.pal","versions":[]}]}"#.utf8)),
        Doc("not an index", Data("[]".utf8)),
        Doc(
            "two apps with the bundle ID",
            indexDoc(
                stremioVersion(),
                extra: [
                    [
                        "bundleIdentifier": "com.stremio.pal",
                        "versions": [.object(stremioVersion())],
                    ]
                ])),
    ]
    let minOS = [
        #""15.1""#, "15", "15.0", "17.10", "16.0e0", #""""#, #""fifteen""#, #""1.2.3.4""#,
        #""../1""#, "-1.5", "1e5", "1000.5", "true",
    ]
    for raw in minOS {
        let body =
            #"{"apps":[{"bundleIdentifier":"com.stremio.pal","versions":[{"version":"1.9.6","buildVersion":"142","downloadURL":"https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa","size":5,"sha256":"\#(digestA)","minOSVersion":\#(raw)}]}]}"#
        docs.append(
            Doc(
                "minOS \(raw)", Data(body.utf8),
                accepted: [#""15.1""#, "15", "15.0", "17.10", "16.0e0"].contains(raw)))
    }
    let urls = [
        "http://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://evil.example/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://dl.strem.io.evil.example/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://user@dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://dl.strem.io:8443/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa?x=1",
        "https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa#f",
        "https://dl.strem.io/apple/1.9.6b142/tvos/../stremio_tvOS.ipa",
        "https://dl.strem.io/apple/1.9.6b142/tvos/%2e%2e/stremio_tvOS.ipa",
        "https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.zip",
        "https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.IPA",
        "https://dl.strem.io/apple/1.9.6b142/tvos/Stremio_tvOS.ipa",
        "https://dl.strem.io/apple/1.9.6b141/tvos/stremio_tvOS.ipa",
        "https://dl.strem.io/apple/1.9.6b142/ios/stremio_iOS.ipa",
        "https://dl.strem.io/apple/1.9.6b142/tvos//stremio_tvOS.ipa",
        "https://dl.strem.io/apple/1.9.6/tvos/stremio_tvOS.ipa",
        "https://DL.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa",
        "https://dl.strem.io/dir/", "https://dl.strem.io/x.ipa", "https://cdn.example/x.ipa",
    ]
    for url in urls {
        docs.append(Doc("url \(url)", stremioIndexJSON(tvos: true, downloadURL: url)))
    }
    let digests: [String?] = [
        nil, "", "abc", "zz" + String(repeating: "ab", count: 31), "sha256:" + digestA,
    ]
    for digest in digests {
        docs.append(Doc("digest \(digest ?? "nil")", stremioIndexJSON(tvos: true, sha256: digest)))
    }
    return docs
}()

// MARK: equivalence

@Suite("template pins: the built-in resolvers and the template-pinned custom sources agree")
private struct TemplatePinEquivalenceTests {
    @Test("Apollo: the same asset or the same refusal", arguments: apolloDocs)
    func apollo(doc: Doc) throws {
        let old = outcome(try builtIn("apollo"), doc.json)
        let new = outcome(try loaded(apolloEntry()), doc.json)
        #expect(old == new)
        if doc.accepted { #expect(!isRefused(old), "\(old)") }
    }

    @Test("Stremio iOS: the same asset or the same refusal", arguments: stremioDocs)
    func stremioIOS(doc: Doc) throws {
        let old = outcome(try builtIn("stremio-ios"), doc.json)
        let new = outcome(try loaded(stremioEntry(tvos: false)), doc.json)
        #expect(old == new)
        if doc.accepted { #expect(!isRefused(old), "\(old)") }
    }

    @Test("Stremio tvOS: the same asset or the same refusal", arguments: stremioDocs)
    func stremioTVOS(doc: Doc) throws {
        let old = outcome(try builtIn("stremio-tvos"), doc.json)
        let new = outcome(try loaded(stremioEntry(tvos: true)), doc.json)
        #expect(old == new)
        if doc.accepted && !doc.label.hasPrefix("iOS") {
            #expect(!isRefused(old), "\(old)")
        }
    }

    @Test("the fixtures reach both outcomes, so agreeing is not agreeing on refusals only")
    func fixturesAreNotVacuous() throws {
        let apollo = try builtIn("apollo")
        #expect(apolloDocs.contains { !isRefused(outcome(apollo, $0.json)) })
        #expect(apolloDocs.contains { isRefused(outcome(apollo, $0.json)) })
        let tvos = try builtIn("stremio-tvos")
        #expect(stremioDocs.contains { !isRefused(outcome(tvos, $0.json)) })
        #expect(stremioDocs.contains { isRefused(outcome(tvos, $0.json)) })
        let ios = try builtIn("stremio-ios")
        #expect(stremioDocs.contains { !isRefused(outcome(ios, $0.json)) })
    }

    @Test("Apollo's version key, file name, URL, digest, size and build are what they were")
    func apolloValues() throws {
        let doc = Doc("x", apolloDocs[0].json)
        guard case .resolved(let a) = outcome(try loaded(apolloEntry()), doc.json) else {
            Issue.record("refused")
            return
        }
        #expect(a.version == "3.9.0" && a.fileName == apolloName)
        #expect(a.url.absoluteString == apolloBase + "v1.15.11_3.9.0/" + apolloName)
        #expect(a.upstreamDigest == digestA && a.size == 4321 && a.build == nil)
    }

    @Test("Stremio's version key is <ver>b<build>, on both platforms")
    func stremioKeys() throws {
        for tvos in [true, false] {
            guard
                case .resolved(let a) = outcome(
                    try loaded(stremioEntry(tvos: tvos)), stremioIndexJSON(tvos: tvos))
            else {
                Issue.record("refused")
                return
            }
            #expect(a.version == "1.9.6b142" && a.build == "142")
            #expect(a.fileName == (tvos ? "stremio_tvOS.ipa" : "stremio_iOS.ipa"))
        }
    }
}

private func isRefused(_ outcome: Outcome) -> Bool {
    if case .refused = outcome { return true }
    return false
}

// MARK: the stricter rules the custom resolver has

@Suite("template pins: where the custom resolver is stricter or looser than Apollo's")
struct TemplatePinDifferenceTests {
    @Test("the repository's owner and name compare without regard to case in the download URL")
    func repoCase() throws {
        let url =
            "https://github.com/apollo-reborn/apollo-reborn/releases/download/v1.15.11_3.9.0/\(apolloName)"
        let json = releaseJSON(assets: [ReleaseAsset(name: apolloName, url: url)])
        #expect(isRefused(outcome(try builtIn("apollo"), json)))
        #expect(!isRefused(outcome(try loaded(apolloEntry()), json)))
    }

    @Test("an expanded asset name over 64 characters is refused")
    func longName() throws {
        let version = String(repeating: "9", count: 40)
        let name = "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa"
        let json = releaseJSON(tag: "v1_\(version)", assets: [ReleaseAsset(name: name)])
        #expect(outcome(try loaded(apolloEntry()), json) == .refused("SOURCE_NOT_ALLOWED"))
    }
}

// MARK: template pins on their own

@Suite("template pins: custom GitHub sources")
struct TemplatePinGithubTests {
    private func ipa(_ name: String, tag: String) -> ReleaseAsset {
        ReleaseAsset(
            name: name, url: "https://github.com/acme/widget/releases/download/\(tag)/\(name)")
    }

    private func resolve(_ asset: String?, tagRule: TagRule = .plain, _ json: Data) throws
        -> ResolvedAsset
    {
        try SourceResolver.customGithub(
            app: "myapp", repo: "acme/widget", asset: asset, tagRule: tagRule, json: json)
    }

    @Test("a {version} pin picks the asset of this release, not one of another version")
    func plainTagTemplate() throws {
        let json = releaseJSON(
            tag: "v0.3.8",
            assets: [
                ipa("Widget-0.3.7-iOS.ipa", tag: "v0.3.8"),
                ipa("Widget-0.3.8-iOS.ipa", tag: "v0.3.8"),
                ipa("Widget-0.3.8-tvOS.ipa", tag: "v0.3.8"),
            ])
        let a = try resolve("Widget-{version}-iOS.ipa", json)
        #expect(a.version == "0.3.8" && a.fileName == "Widget-0.3.8-iOS.ipa")
    }

    @Test(
        "the template needs an asset of that name: a release with only another version's is refused"
    )
    func templateMiss() {
        let json = releaseJSON(tag: "v0.3.8", assets: [ipa("Widget-0.3.7-iOS.ipa", tag: "v0.3.8")])
        #expect(
            throws: SideloadError.self,
            performing: { try resolve("Widget-{version}-iOS.ipa", json) })
    }

    @Test("an exact pin and no pin behave as before")
    func existingShapes() throws {
        let json = releaseJSON(
            tag: "v0.3.8", assets: [ipa("A.ipa", tag: "v0.3.8"), ipa("B.ipa", tag: "v0.3.8")])
        #expect(try resolve("B.ipa", json).fileName == "B.ipa")
        #expect(try resolve("B.ipa", json).version == "0.3.8")
        #expect(throws: SideloadError.self, performing: { try resolve(nil, json) })
    }

    @Test("the underscore rule works without an asset pin when the release has one IPA")
    func underscoreWithoutPin() throws {
        let json = releaseJSON(tag: "v1.2_3.4", assets: [ipa("Any-Name.ipa", tag: "v1.2_3.4")])
        let a = try resolve(nil, tagRule: .underscoreSuffix, json)
        #expect(a.version == "3.4" && a.fileName == "Any-Name.ipa")
        #expect(try resolve(nil, json).version == "1.2_3.4", "the plain rule keeps the whole tag")
    }
}

@Suite("template pins: custom index sources")
struct TemplatePinIndexTests {
    private func resolve(
        path: String?, requireBuild: Bool = false, _ version: [String: JSONValue]
    ) throws -> ResolvedAsset {
        try SourceResolver.customAltstore(
            app: "myapp", bundleId: "com.stremio.pal", hosts: ["dl.strem.io"], downloadPath: path,
            requireBuild: requireBuild, json: indexDoc(version))
    }

    @Test("{versionKey} stands for <ver>b<build>, or the bare version when there is no build")
    func versionKey() throws {
        let path = "/apple/{versionKey}/tvos/stremio_tvOS.ipa"
        #expect(try resolve(path: path, stremioVersion()).version == "1.9.6b142")
        let bare = stremioVersion {
            $0["buildVersion"] = nil
            $0["downloadURL"] = "https://dl.strem.io/apple/1.9.6/tvos/stremio_tvOS.ipa"
        }
        #expect(try resolve(path: path, bare).version == "1.9.6")
    }

    @Test(
        "requireBuild turns a missing build into SOURCE_INVALID; without it the version stands alone"
    )
    func requireBuild() throws {
        let noBuild = stremioVersion { $0["buildVersion"] = nil }
        #expect(try resolve(path: nil, noBuild).build == nil)
        #expect(
            throws: SideloadError.self,
            performing: { try resolve(path: nil, requireBuild: true, noBuild) })
    }

    @Test("a path that is not the template with the version key filled in is SOURCE_NOT_ALLOWED")
    func pathMismatch() {
        for url in [
            "https://dl.strem.io/apple/1.9.6b141/tvos/stremio_tvOS.ipa",
            "https://dl.strem.io/apple/1.9.6b142/ios/stremio_tvOS.ipa",
            "https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa/x.ipa",
        ] {
            let version = stremioVersion { $0["downloadURL"] = .string(url) }
            do {
                _ = try resolve(path: "/apple/{versionKey}/tvos/stremio_tvOS.ipa", version)
                Issue.record("accepted \(url)")
            } catch {
                #expect((error as? SideloadError)?.code == "SOURCE_NOT_ALLOWED", "\(url)")
            }
        }
    }

    @Test("a path with no placeholder pins that exact path")
    func fixedPath() throws {
        let version = stremioVersion {
            $0["downloadURL"] = "https://dl.strem.io/stable/Stremio.ipa"
        }
        #expect(try resolve(path: "/stable/Stremio.ipa", version).fileName == "Stremio.ipa")
        #expect(
            throws: SideloadError.self,
            performing: { try resolve(path: "/stable/Other.ipa", version) })
    }
}
