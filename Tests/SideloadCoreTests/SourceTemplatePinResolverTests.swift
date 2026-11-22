import Foundation
import Testing

@testable import SideloadCore

// Template pins for owner-added sources (design: un-built-in sources, PR1): `asset` with one `{version}`, `tagRule`, an index's
// `downloadPath` with `{versionKey}`, and `requireBuild`. The fixtures are the documents the built-in Apollo and Stremio
// resolvers were checked with (PR1 ran them through both and required the same ResolvedAsset or error code); they now run
// through the migrated `customSources` entries. Offline.

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

/// The source the one-time migration gives `app` (the former built-in source).
private func builtIn(_ app: String) throws -> FetchSource {
    try #require(FetchCatalog.sources.first { $0.app == app })
}

private struct Doc: Sendable, CustomTestStringConvertible {
    let label: String
    let json: Data
    var testDescription: String { label }

    init(_ label: String, _ json: Data) {
        self.label = label
        self.json = json
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
            "exact asset among decoys", releaseJSON(assets: apolloDecoys() + [exact])),
        Doc("exact asset first", releaseJSON(assets: [exact] + apolloDecoys())),
        Doc(
            "exact asset last, reversed",
            releaseJSON(assets: Array((apolloDecoys() + [exact]).reversed()))),
        Doc(
            "a beta version after the underscore",
            releaseJSON(
                tag: "v2.0_4.1.0-beta2",
                assets: [ReleaseAsset(name: "Apollo-Reborn-4.1.0-beta2-GLASS-NOEXTENSIONS.ipa")])),
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
            "tvOS index", stremioIndexJSON(tvos: true, sha256: digestA.uppercased(), size: 777)),
        Doc("iOS index", stremioIndexJSON(tvos: false)),
        Doc(
            "iOS URL on a tvOS-shaped index",
            stremioIndexJSON(tvos: false, downloadURL: "https://dl.strem.io/dir/x.ipa")),
        Doc("numeric build", indexDoc(stremioVersion { $0["buildVersion"] = 142 })),
        Doc("no minOSVersion", indexDoc(stremioVersion())),
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
            Doc("minOS \(raw)", Data(body.utf8)))
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

/// One outcome as a line of `recordedOutcomes`: `r|version|file|url|digest|size|build|minOS` or `e|CODE`.
private func encodeOutcome(_ o: Outcome) -> String {
    switch o {
    case .refused(let code): return "e|\(code)"
    case .resolved(let a):
        return [
            "r", a.version, a.fileName, a.url.absoluteString, a.upstreamDigest, "\(a.size)",
            a.build ?? "-", a.minOS ?? "-",
        ].joined(separator: "|")
    }
}

/// What the built-in Apollo and Stremio resolvers answered at fc6df80 for `apolloDocs` and `stremioDocs` (`ios` and `tvos`).
private let recordedOutcomes = """
    apollo|0|exact asset among decoys|r|3.9.0|Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|abababababababababababababababababababababababababababababababab|4321|-|-
    apollo|1|exact asset first|r|3.9.0|Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|abababababababababababababababababababababababababababababababab|4321|-|-
    apollo|2|exact asset last, reversed|r|3.9.0|Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|abababababababababababababababababababababababababababababababab|4321|-|-
    apollo|3|a beta version after the underscore|r|4.1.0-beta2|Apollo-Reborn-4.1.0-beta2-GLASS-NOEXTENSIONS.ipa|https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v2.0_4.1.0-beta2/Apollo-Reborn-4.1.0-beta2-GLASS-NOEXTENSIONS.ipa|abababababababababababababababababababababababababababababababab|1000|-|-
    apollo|4|asset carries the x part, not the version|e|SOURCE_NOT_ALLOWED
    apollo|5|two assets with the exact name|e|SOURCE_NOT_ALLOWED
    apollo|6|draft|e|SOURCE_NOT_ALLOWED
    apollo|7|pre-release|e|SOURCE_NOT_ALLOWED
    apollo|8|asset not uploaded|e|SOURCE_NOT_ALLOWED
    apollo|9|invalid JSON|e|SOURCE_INVALID
    apollo|10|an object with no tag|e|SOURCE_INVALID
    apollo|11|a tag and no assets|e|SOURCE_NOT_ALLOWED
    apollo|12|size 0|e|SOURCE_INVALID
    apollo|13|size over the limit|e|DOWNLOAD_TOO_LARGE
    apollo|14|decoy alone: Apollo-Reborn-3.9.0-dSYMs.zip|e|SOURCE_NOT_ALLOWED
    apollo|15|decoy alone: Apollo-Reborn-3.9.0-NOEXTENSIONS.ipa|e|SOURCE_NOT_ALLOWED
    apollo|16|decoy alone: Apollo-Reborn-3.9.0-GLASSICONS-NOEXTENSIONS.ipa|e|SOURCE_NOT_ALLOWED
    apollo|17|decoy alone: Apollo-Reborn-3.9.0-GLASS.ipa|e|SOURCE_NOT_ALLOWED
    apollo|18|decoy alone: apollo-reborn_3.9.0_iphoneos-arm.deb|e|SOURCE_NOT_ALLOWED
    apollo|19|decoy alone: Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa.sig|e|SOURCE_NOT_ALLOWED
    apollo|20|decoy alone: apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|e|SOURCE_NOT_ALLOWED
    apollo|21|tag v1.15.11|e|SOURCE_NOT_ALLOWED
    apollo|22|tag 1.15.11_3.9.0|e|SOURCE_NOT_ALLOWED
    apollo|23|tag v1_2_3|e|SOURCE_NOT_ALLOWED
    apollo|24|tag v1.0_../x|e|SOURCE_NOT_ALLOWED
    apollo|25|tag v_3.9.0|e|SOURCE_NOT_ALLOWED
    apollo|26|tag v1.0_|e|SOURCE_NOT_ALLOWED
    apollo|27|tag v1.0_a/b|e|SOURCE_NOT_ALLOWED
    apollo|28|tag x1_2|e|SOURCE_NOT_ALLOWED
    apollo|29|digest nil|e|UPSTREAM_DIGEST_MISSING
    apollo|30|digest |e|UPSTREAM_DIGEST_MISSING
    apollo|31|digest sha256:|e|UPSTREAM_DIGEST_MISSING
    apollo|32|digest sha256:abc|e|UPSTREAM_DIGEST_MISSING
    apollo|33|digest sha1:abababababababababababababababababababababababababababababababab|e|UPSTREAM_DIGEST_MISSING
    apollo|34|digest abababababababababababababababababababababababababababababababab|e|UPSTREAM_DIGEST_MISSING
    apollo|35|digest sha256:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz|e|UPSTREAM_DIGEST_MISSING
    apollo|36|digest sha256:ababababababababababababababababababababababababababababababababab|e|UPSTREAM_DIGEST_MISSING
    apollo|37|url https://evil.example/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|e|SOURCE_NOT_ALLOWED
    apollo|38|url http://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|e|SOURCE_NOT_ALLOWED
    apollo|39|url https://github.com/other/repo/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|e|SOURCE_NOT_ALLOWED
    apollo|40|url https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.1/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|e|SOURCE_NOT_ALLOWED
    apollo|41|url https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa?x=1|e|SOURCE_NOT_ALLOWED
    apollo|42|url https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/x/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa|e|SOURCE_NOT_ALLOWED
    ios|0|tvOS index|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|777|142|15.0
    ios|1|iOS index|r|1.9.6b142|stremio_iOS.ipa|https://dl.strem.io/apple/1.9.6b142/ios/stremio_iOS.ipa|cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd|2000|142|14.0
    ios|2|iOS URL on a tvOS-shaped index|r|1.9.6b142|x.ipa|https://dl.strem.io/dir/x.ipa|cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd|2000|142|14.0
    ios|3|numeric build|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|-
    ios|4|no minOSVersion|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|-
    ios|5|no build|e|SOURCE_INVALID
    ios|6|unsafe build|e|SOURCE_INVALID
    ios|7|unsafe version|e|SOURCE_INVALID
    ios|8|size 0|e|SOURCE_INVALID
    ios|9|size over the limit|e|DOWNLOAD_TOO_LARGE
    ios|10|other bundle|e|SOURCE_NOT_ALLOWED
    ios|11|no apps|e|SOURCE_NOT_ALLOWED
    ios|12|no versions|e|SOURCE_INVALID
    ios|13|not an index|e|SOURCE_INVALID
    ios|14|two apps with the bundle ID|e|SOURCE_NOT_ALLOWED
    ios|15|minOS "15.1"|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|15.1
    ios|16|minOS 15|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|15
    ios|17|minOS 15.0|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|15
    ios|18|minOS 17.10|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|17.1
    ios|19|minOS 16.0e0|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|16
    ios|20|minOS ""|e|SOURCE_INVALID
    ios|21|minOS "fifteen"|e|SOURCE_INVALID
    ios|22|minOS "1.2.3.4"|e|SOURCE_INVALID
    ios|23|minOS "../1"|e|SOURCE_INVALID
    ios|24|minOS -1.5|e|SOURCE_INVALID
    ios|25|minOS 1e5|e|SOURCE_INVALID
    ios|26|minOS 1000.5|e|SOURCE_INVALID
    ios|27|minOS true|e|SOURCE_INVALID
    ios|28|url http://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    ios|29|url https://evil.example/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    ios|30|url https://dl.strem.io.evil.example/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    ios|31|url https://user@dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    ios|32|url https://dl.strem.io:8443/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    ios|33|url https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa?x=1|e|SOURCE_NOT_ALLOWED
    ios|34|url https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa#f|e|SOURCE_NOT_ALLOWED
    ios|35|url https://dl.strem.io/apple/1.9.6b142/tvos/../stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    ios|36|url https://dl.strem.io/apple/1.9.6b142/tvos/%2e%2e/stremio_tvOS.ipa|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/%2e%2e/stremio_tvOS.ipa|cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd|2000|142|15.0
    ios|37|url https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.zip|e|SOURCE_NOT_ALLOWED
    ios|38|url https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.IPA|e|SOURCE_NOT_ALLOWED
    ios|39|url https://dl.strem.io/apple/1.9.6b142/tvos/Stremio_tvOS.ipa|r|1.9.6b142|Stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/Stremio_tvOS.ipa|cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd|2000|142|15.0
    ios|40|url https://dl.strem.io/apple/1.9.6b141/tvos/stremio_tvOS.ipa|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b141/tvos/stremio_tvOS.ipa|cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd|2000|142|15.0
    ios|41|url https://dl.strem.io/apple/1.9.6b142/ios/stremio_iOS.ipa|r|1.9.6b142|stremio_iOS.ipa|https://dl.strem.io/apple/1.9.6b142/ios/stremio_iOS.ipa|cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd|2000|142|15.0
    ios|42|url https://dl.strem.io/apple/1.9.6b142/tvos//stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    ios|43|url https://dl.strem.io/apple/1.9.6/tvos/stremio_tvOS.ipa|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6/tvos/stremio_tvOS.ipa|cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd|2000|142|15.0
    ios|44|url https://DL.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    ios|45|url https://dl.strem.io/dir/|e|SOURCE_NOT_ALLOWED
    ios|46|url https://dl.strem.io/x.ipa|r|1.9.6b142|x.ipa|https://dl.strem.io/x.ipa|cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd|2000|142|15.0
    ios|47|url https://cdn.example/x.ipa|e|SOURCE_NOT_ALLOWED
    ios|48|digest nil|e|UPSTREAM_DIGEST_MISSING
    ios|49|digest |e|UPSTREAM_DIGEST_MISSING
    ios|50|digest abc|e|UPSTREAM_DIGEST_MISSING
    ios|51|digest zzababababababababababababababababababababababababababababababab|e|UPSTREAM_DIGEST_MISSING
    ios|52|digest sha256:abababababababababababababababababababababababababababababababab|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|2000|142|15.0
    tvos|0|tvOS index|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|777|142|15.0
    tvos|1|iOS index|e|SOURCE_NOT_ALLOWED
    tvos|2|iOS URL on a tvOS-shaped index|e|SOURCE_NOT_ALLOWED
    tvos|3|numeric build|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|-
    tvos|4|no minOSVersion|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|-
    tvos|5|no build|e|SOURCE_INVALID
    tvos|6|unsafe build|e|SOURCE_INVALID
    tvos|7|unsafe version|e|SOURCE_INVALID
    tvos|8|size 0|e|SOURCE_INVALID
    tvos|9|size over the limit|e|DOWNLOAD_TOO_LARGE
    tvos|10|other bundle|e|SOURCE_NOT_ALLOWED
    tvos|11|no apps|e|SOURCE_NOT_ALLOWED
    tvos|12|no versions|e|SOURCE_INVALID
    tvos|13|not an index|e|SOURCE_INVALID
    tvos|14|two apps with the bundle ID|e|SOURCE_NOT_ALLOWED
    tvos|15|minOS "15.1"|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|15.1
    tvos|16|minOS 15|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|15
    tvos|17|minOS 15.0|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|15
    tvos|18|minOS 17.10|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|17.1
    tvos|19|minOS 16.0e0|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|5|142|16
    tvos|20|minOS ""|e|SOURCE_INVALID
    tvos|21|minOS "fifteen"|e|SOURCE_INVALID
    tvos|22|minOS "1.2.3.4"|e|SOURCE_INVALID
    tvos|23|minOS "../1"|e|SOURCE_INVALID
    tvos|24|minOS -1.5|e|SOURCE_INVALID
    tvos|25|minOS 1e5|e|SOURCE_INVALID
    tvos|26|minOS 1000.5|e|SOURCE_INVALID
    tvos|27|minOS true|e|SOURCE_INVALID
    tvos|28|url http://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|29|url https://evil.example/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|30|url https://dl.strem.io.evil.example/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|31|url https://user@dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|32|url https://dl.strem.io:8443/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|33|url https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa?x=1|e|SOURCE_NOT_ALLOWED
    tvos|34|url https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa#f|e|SOURCE_NOT_ALLOWED
    tvos|35|url https://dl.strem.io/apple/1.9.6b142/tvos/../stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|36|url https://dl.strem.io/apple/1.9.6b142/tvos/%2e%2e/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|37|url https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.zip|e|SOURCE_NOT_ALLOWED
    tvos|38|url https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.IPA|e|SOURCE_NOT_ALLOWED
    tvos|39|url https://dl.strem.io/apple/1.9.6b142/tvos/Stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|40|url https://dl.strem.io/apple/1.9.6b141/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|41|url https://dl.strem.io/apple/1.9.6b142/ios/stremio_iOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|42|url https://dl.strem.io/apple/1.9.6b142/tvos//stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|43|url https://dl.strem.io/apple/1.9.6/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|44|url https://DL.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|e|SOURCE_NOT_ALLOWED
    tvos|45|url https://dl.strem.io/dir/|e|SOURCE_NOT_ALLOWED
    tvos|46|url https://dl.strem.io/x.ipa|e|SOURCE_NOT_ALLOWED
    tvos|47|url https://cdn.example/x.ipa|e|SOURCE_NOT_ALLOWED
    tvos|48|digest nil|e|UPSTREAM_DIGEST_MISSING
    tvos|49|digest |e|UPSTREAM_DIGEST_MISSING
    tvos|50|digest abc|e|UPSTREAM_DIGEST_MISSING
    tvos|51|digest zzababababababababababababababababababababababababababababababab|e|UPSTREAM_DIGEST_MISSING
    tvos|52|digest sha256:abababababababababababababababababababababababababababababababab|r|1.9.6b142|stremio_tvOS.ipa|https://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa|abababababababababababababababababababababababababababababababab|2000|142|15.0
    """

// MARK: the migrated entries on the fixtures

@Suite(
    "template pins: the migrated Apollo and Stremio entries resolve the fixtures as the built-in sources did"
)
private struct MigratedEntryFixtureTests {
    /// Every fixture, on every source: exactly what the code-defined resolvers answered at fc6df80 (`recordedOutcomes`,
    /// `app|index|label|outcome`, recorded by running PR1's equivalence fixtures on that commit), all ResolvedAsset fields or
    /// the error code. The label is checked too, so a reordered fixture cannot match another's outcome.
    private func check(_ key: String, _ app: String, _ docs: [Doc]) throws {
        let recorded = recordedOutcomes.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix(key + "|") }
            .map {
                $0.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(
                    String.init)
            }
        #expect(recorded.count == docs.count)
        let source = try builtIn(app)
        for (index, doc) in docs.enumerated() where index < recorded.count {
            #expect(recorded[index][1] == "\(index)" && recorded[index][2] == doc.label)
            #expect(
                encodeOutcome(outcome(source, doc.json)) == recorded[index][3],
                "\(key) \(index) \(doc.label)")
        }
    }

    @Test("Apollo: every fixture gives the recorded asset or error")
    func apollo() throws { try check("apollo", "apollo", apolloDocs) }

    @Test("Stremio iOS: every fixture gives the recorded asset or error")
    func stremioIOS() throws { try check("ios", "stremio-ios", stremioDocs) }

    @Test("Stremio tvOS: every fixture gives the recorded asset or error")
    func stremioTVOS() throws { try check("tvos", "stremio-tvos", stremioDocs) }

    @Test("the fixtures reach both outcomes, so the checks above are not one-sided")
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

    @Test("the migrated entries are the shapes of design section 1.2 for a custom app")
    func migratedEntriesMatchTheShapes() throws {
        #expect(
            try builtIn("apollo").kind.withBundleId(nil)
                == (try loaded(apolloEntry())).kind)
        #expect(try builtIn("stremio-ios").kind == (try loaded(stremioEntry(tvos: false))).kind)
        #expect(try builtIn("stremio-tvos").kind == (try loaded(stremioEntry(tvos: true))).kind)
    }

    @Test("Apollo's version key, file name, URL, digest, size and build are what they were")
    func apolloValues() throws {
        let doc = Doc("x", apolloDocs[0].json)
        guard case .resolved(let a) = outcome(try builtIn("apollo"), doc.json) else {
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
            let source = try builtIn(tvos ? "stremio-tvos" : "stremio-ios")
            guard case .resolved(let a) = outcome(source, stremioIndexJSON(tvos: tvos)) else {
                Issue.record("refused")
                return
            }
            #expect(a.version == "1.9.6b142" && a.build == "142")
            #expect(a.fileName == (tvos ? "stremio_tvOS.ipa" : "stremio_iOS.ipa"))
        }
    }
}

extension FetchSource.Kind {
    /// The same GitHub source without its bundle ID pin (the shapes in this file's helper have none).
    fileprivate func withBundleId(_ id: String?) -> FetchSource.Kind {
        guard case .githubRelease(let repo, let asset, let rule, _) = self else { return self }
        return .githubRelease(repo: repo, asset: asset, tagRule: rule, bundleId: id)
    }
}

private func isRefused(_ outcome: Outcome) -> Bool {
    if case .refused = outcome { return true }
    return false
}

// MARK: the differences from the old built-in resolvers

@Suite("template pins: where the resolver is stricter or looser than the old Apollo source was")
struct TemplatePinDifferenceTests {
    // Intentional difference 1 (owner decision 2026-11-21): fc6df80's Apollo resolver compared the whole download URL exactly, so
    // it refused a differently cased owner or repository; the migrated entry accepts that one difference and nothing else.
    @Test("the repository's owner and name compare without regard to case in the download URL")
    func repoCase() throws {
        let url =
            "https://github.com/apollo-reborn/apollo-reborn/releases/download/v1.15.11_3.9.0/\(apolloName)"
        let json = releaseJSON(assets: [ReleaseAsset(name: apolloName, url: url)])
        #expect(!isRefused(outcome(try builtIn("apollo"), json)))
        #expect(!isRefused(outcome(try loaded(apolloEntry()), json)))
        // Another repository, another tag and another file name are still refused.
        for other in [
            "https://github.com/evil/apollo-reborn/releases/download/v1.15.11_3.9.0/\(apolloName)",
            "https://github.com/apollo-reborn/apollo-reborn/releases/download/v9_3.9.0/\(apolloName)",
        ] {
            let doc = releaseJSON(assets: [ReleaseAsset(name: apolloName, url: other)])
            #expect(isRefused(outcome(try builtIn("apollo"), doc)), "\(other)")
        }
    }

    // Intentional difference 2: fc6df80's resolver had no cap on the expanded name; the template's result must be a safe token
    // (at most 64 characters), so a version over 27 characters is refused.
    @Test("an expanded asset name over 64 characters is refused")
    func longName() throws {
        let version = String(repeating: "9", count: 40)
        let name = "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa"
        let json = releaseJSON(tag: "v1_\(version)", assets: [ReleaseAsset(name: name)])
        #expect(outcome(try loaded(apolloEntry()), json) == .refused("SOURCE_NOT_ALLOWED"))
        #expect(outcome(try builtIn("apollo"), json) == .refused("SOURCE_NOT_ALLOWED"))
        let fits = String(repeating: "9", count: 27)
        let ok = "Apollo-Reborn-\(fits)-GLASS-NOEXTENSIONS.ipa"
        let accepted = releaseJSON(tag: "v1_\(fits)", assets: [ReleaseAsset(name: ok)])
        #expect(!isRefused(outcome(try builtIn("apollo"), accepted)))
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
        try SourceResolver.github(
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
        try SourceResolver.altstore(
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
