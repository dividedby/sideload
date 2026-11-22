import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// Template pins in `customSources` and in `source add` (design: un-built-in sources, PR1): load validation, `source list`, the
// flags, the confirm value and the entry `--yes` writes. Offline: a temp home and a scripted transport.

private typealias Edit = @Sendable (inout [String: JSONValue]) -> Void

private struct Refusal: Sendable, CustomTestStringConvertible {
    let name: String
    let github: Bool
    let edit: Edit
    var testDescription: String { name }

    init(_ name: String, github: Bool, _ edit: @escaping Edit) {
        self.name = name
        self.github = github
        self.edit = edit
    }

    static func github(_ name: String, _ key: String, _ value: JSONValue) -> Refusal {
        Refusal(name, github: true) { $0[key] = value }
    }

    static func index(_ name: String, _ key: String, _ value: JSONValue) -> Refusal {
        Refusal(name, github: false) { $0[key] = value }
    }
}

private let longPath = "/" + String(repeating: "a/", count: 100) + "x.ipa"

private let refusals: [Refusal] = [
    .github("two {version}", "asset", "A-{version}-{version}.ipa"),
    .github("another placeholder", "asset", "A-{other}.ipa"),
    .github("{versionKey} in an asset", "asset", "A-{versionKey}.ipa"),
    .github("unclosed brace", "asset", "A-{version.ipa"),
    .github("stray closing brace", "asset", "A-version}.ipa"),
    .github("template not ending .ipa", "asset", "A-{version}.zip"),
    .github("only the placeholder", "asset", "{version}"),
    .github("a path in the template", "asset", "a/A-{version}.ipa"),
    .github(
        "template over 64 characters", "asset",
        .string(String(repeating: "a", count: 60) + "{version}.ipa")),
    .github("tagRule plain", "tagRule", "plain"),
    .github("tagRule other case", "tagRule", "UnderscoreSuffix"),
    .github("tagRule empty", "tagRule", ""),
    .github("tagRule not a string", "tagRule", true),
    .github("a download path on a GitHub entry", "downloadPath", "/a/x.ipa"),
    .github("requireBuild on a GitHub entry", "requireBuild", true),
    .index("tagRule on an index entry", "tagRule", "underscoreSuffix"),
    .index("requireBuild false", "requireBuild", false),
    .index("requireBuild a string", "requireBuild", "true"),
    .index("requireBuild a number", "requireBuild", 1),
    .index("downloadPath not a string", "downloadPath", 1),
    .index("downloadPath without a leading slash", "downloadPath", "a/{versionKey}/x.ipa"),
    .index("downloadPath with ..", "downloadPath", "/a/../x.ipa"),
    .index("downloadPath with .", "downloadPath", "/a/./x.ipa"),
    .index("downloadPath with an empty segment", "downloadPath", "/a//x.ipa"),
    .index(
        "downloadPath with two placeholders", "downloadPath", "/a/{versionKey}/{versionKey}.ipa"),
    .index("downloadPath with another placeholder", "downloadPath", "/a/{version}/x.ipa"),
    .index("downloadPath with an unclosed brace", "downloadPath", "/a/{versionKey/x.ipa"),
    .index("downloadPath not ending .ipa", "downloadPath", "/a/{versionKey}/x.zip"),
    .index("downloadPath ending in a slash", "downloadPath", "/a/x.ipa/"),
    .index("downloadPath only a slash", "downloadPath", "/"),
    .index("downloadPath with a query", "downloadPath", "/a/x.ipa?x=1"),
    .index("downloadPath with a fragment", "downloadPath", "/a/x.ipa#f"),
    .index("downloadPath with a percent escape", "downloadPath", "/a/%2e/x.ipa"),
    .index("downloadPath with a space", "downloadPath", "/a b/x.ipa"),
    .index("downloadPath with a backslash", "downloadPath", "/a\\b/x.ipa"),
    .index("downloadPath with non-ASCII", "downloadPath", "/é/x.ipa"),
    .index("downloadPath over 200 characters", "downloadPath", .string(longPath)),
]

@Suite("template pins: customSources validation")
struct TemplatePinValidationTests {
    @Test("a value outside the grammar ignores the entry", arguments: refusals)
    private func refused(case refusal: Refusal) {
        var entry = refusal.github ? githubEntry : altstoreEntry
        refusal.edit(&entry)
        let registry = customConfig(sources: [entry]).appRegistry
        #expect(registry.app("myapp")?.fetch == nil)
        #expect(registry.warnings.count == 1)
        #expect(registry.warnings.first?["code"]?.string == "CUSTOM_SOURCE_IGNORED")
    }

    @Test("the valid shapes load, with the pins in the source's kind")
    func valid() throws {
        var github = githubEntry
        github["asset"] = "Apollo-Reborn-{version}-GLASS-NOEXTENSIONS.ipa"
        github["tagRule"] = "underscoreSuffix"
        let ghRegistry = customConfig(sources: [github]).appRegistry
        #expect(ghRegistry.warnings.isEmpty)
        #expect(
            ghRegistry.app("myapp")?.fetch?.kind
                == .customGithubRelease(
                    repo: "acme/widget", asset: "Apollo-Reborn-{version}-GLASS-NOEXTENSIONS.ipa",
                    tagRule: .underscoreSuffix))

        var index = altstoreEntry
        index["downloadPath"] = "/apple/{versionKey}/tvos/stremio_tvOS.ipa"
        index["requireBuild"] = true
        let idxRegistry = customConfig(sources: [index]).appRegistry
        #expect(idxRegistry.warnings.isEmpty)
        #expect(
            idxRegistry.app("myapp")?.fetch?.kind
                == .customAltstoreIndex(
                    url: "https://index.example.org/apps/index.json", bundleId: "io.example.apollo",
                    downloadPath: "/apple/{versionKey}/tvos/stremio_tvOS.ipa", requireBuild: true))
    }

    @Test(
        "edge shapes that are valid: a placeholder at either end, one in the file name, none at all",
        arguments: [
            "{version}.ipa", "{version}-iOS.IPA", "App-{version}.ipa", "App.ipa",
        ])
    func validAssets(asset: String) {
        var entry = githubEntry
        entry["asset"] = .string(asset)
        #expect(customConfig(sources: [entry]).appRegistry.warnings.isEmpty)
    }

    @Test(
        "valid download paths",
        arguments: ["/a/x.ipa", "/{versionKey}/x.ipa", "/a/App-{versionKey}.ipa"]
    )
    func validPaths(path: String) {
        var entry = altstoreEntry
        entry["downloadPath"] = .string(path)
        #expect(customConfig(sources: [entry]).appRegistry.warnings.isEmpty)
    }

    @Test(
        "source list shows tagRule, downloadPath and requireBuild only for a source that sets them")
    func list() async throws {
        var github = githubEntry
        github["asset"] = "Widget-{version}.ipa"
        github["tagRule"] = "underscoreSuffix"
        var index = altstoreEntry
        index["app"] = "other"
        index["downloadPath"] = "/apple/{versionKey}/x.ipa"
        index["requireBuild"] = true
        var plain = githubEntry
        plain["app"] = "plain"
        let config = Config(
            devices: iphoneConfig().devices, approvedSources: apolloApproved,
            bundleIdPrefix: customPrefix,
            extra: [
                "customApps": [
                    ["id": "myapp", "platform": "ios"], ["id": "other", "platform": "ios"],
                    ["id": "plain", "platform": "ios"],
                ],
                "customSources": [.object(github), .object(index), .object(plain)],
            ])
        try await withTestHome(config: config) { paths, _ in
            let out = await run(
                argv: ["source", "list"], services: fetchServices(paths, http: SourceHTTP()))
            let sources = try #require(out.data["sources"]?.array)
            func entry(_ app: String) throws -> JSONValue {
                try #require(sources.first { $0["app"] == .string(app) })
            }
            let mine = try entry("myapp")
            #expect(
                mine["asset"] == "Widget-{version}.ipa" && mine["tagRule"] == "underscoreSuffix")
            #expect(mine["downloadPath"] == nil && mine["requireBuild"] == nil)
            let other = try entry("other")
            #expect(other["downloadPath"] == "/apple/{versionKey}/x.ipa")
            #expect(other["requireBuild"] == true && other["tagRule"] == nil)
            let bare = try entry("plain")
            #expect(bare["tagRule"] == nil && bare["asset"] == nil && bare["requireBuild"] == nil)
            let apollo = try entry("apollo")
            #expect(apollo["tagRule"] == nil && apollo["downloadPath"] == nil)
        }
    }
}

// MARK: source add

private let underscoreTag = "v1_0.3.8"

private func underscoreRelease(version: String = "0.3.8") -> Data {
    let name = "Widget-\(version).ipa"
    return releaseJSON(
        tag: underscoreTag,
        assets: [
            ReleaseAsset(
                name: name,
                url: "https://github.com/acme/widget/releases/download/\(underscoreTag)/\(name)")
        ])
}

private func buildIndex(build: String? = "7", url: String? = nil) -> Data {
    var version: [String: JSONValue] = [
        "version": "1.2.0",
        "downloadURL": .string(url ?? "https://cdn.example.org/apple/1.2.0b7/Widget.ipa"),
        "size": 1000, "sha256": .string(String(repeating: "cd", count: 32)),
    ]
    if let build { version["buildVersion"] = .string(build) }
    let app: JSONValue = [
        "name": "Widget", "bundleIdentifier": "io.example.widget", "versions": [.object(version)],
    ]
    return try! JSONEncoder().encode(JSONValue.object(["apps": [app]]))
}

private let githubFlags = ["--asset", "Widget-{version}.ipa", "--tag-rule", "underscoreSuffix"]
private let indexFlags = [
    "--bundle", "io.example.widget", "--require-build", "--download-path",
    "/apple/{versionKey}/Widget.ipa",
]

private func code(_ out: Envelope) -> String? { out.errors.first?.code }

@Suite("template pins: source add")
struct TemplatePinAddTests {
    @Test(
        "a GitHub preview shows the template and the tag rule, and prints a command that carries them"
    )
    func githubPreview() async throws {
        let http = SourceHTTP([widgetAPI: underscoreRelease()])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            let out = await source(addArgs(widgetURL, githubFlags), services)
            #expect(out.ok, "\(out.errors)")
            #expect(try configBytes(paths) == before)
            #expect(out.data["asset"] == "Widget-{version}.ipa")
            #expect(out.data["tagRule"] == "underscoreSuffix")
            #expect(out.data["version"] == "0.3.8")
            let confirm = try #require(out.data["confirm"]?.string)
            let next = try #require(out.data["next"]?.string)
            #expect(
                next.contains(
                    "--app widget --asset 'Widget-{version}.ipa' --tag-rule underscoreSuffix --platform ios --confirm \(confirm) --yes"
                ))
        }
    }

    @Test("--yes writes the template and the tag rule, and the entry loads as that source")
    func githubWrite() async throws {
        let http = SourceHTTP([widgetAPI: underscoreRelease()])
        try await withSourceHome(http: http) { paths, services in
            let preview = await source(addArgs(widgetURL, githubFlags), services)
            let confirm = try #require(preview.data["confirm"]?.string)
            let yes = await source(addArgs(widgetURL, githubFlags, confirm: confirm), services)
            #expect(yes.ok, "\(yes.errors)")
            let config = try loadConfig(paths)
            let entry = try #require(config.extra["customSources"]?.array?.first)
            #expect(
                entry["asset"] == "Widget-{version}.ipa" && entry["tagRule"] == "underscoreSuffix")
            #expect(entry["downloadPath"] == nil && entry["requireBuild"] == nil)
            #expect(config.appRegistry.warnings.isEmpty)
            #expect(
                config.appRegistry.app("widget")?.fetch?.kind
                    == .customGithubRelease(
                        repo: "acme/widget", asset: "Widget-{version}.ipa",
                        tagRule: .underscoreSuffix))
        }
    }

    @Test("an index preview, --yes and the entry: the download path and the required build")
    func indexWrite() async throws {
        let http = SourceHTTP([sourceIndexURL: buildIndex()])
        try await withSourceHome(http: http) { paths, services in
            let preview = await source(addArgs(sourceIndexURL, indexFlags), services)
            #expect(preview.ok, "\(preview.errors)")
            #expect(preview.data["downloadPath"] == "/apple/{versionKey}/Widget.ipa")
            #expect(preview.data["requireBuild"] == true && preview.data["tagRule"] == nil)
            #expect(preview.data["version"] == "1.2.0b7")
            let confirm = try #require(preview.data["confirm"]?.string)
            let next = try #require(preview.data["next"]?.string)
            #expect(
                next.contains(
                    "--bundle io.example.widget --require-build --download-path '/apple/{versionKey}/Widget.ipa' --platform ios --confirm \(confirm) --yes"
                ))
            let yes = await source(addArgs(sourceIndexURL, indexFlags, confirm: confirm), services)
            #expect(yes.ok, "\(yes.errors)")
            let config = try loadConfig(paths)
            let entry = try #require(config.extra["customSources"]?.array?.first)
            #expect(entry["downloadPath"] == "/apple/{versionKey}/Widget.ipa")
            #expect(entry["requireBuild"] == true && entry["tagRule"] == nil)
            #expect(config.appRegistry.warnings.isEmpty)
            #expect(
                config.appRegistry.app("widget")?.fetch?.kind
                    == .customAltstoreIndex(
                        url: sourceIndexURL, bundleId: "io.example.widget",
                        downloadPath: "/apple/{versionKey}/Widget.ipa", requireBuild: true))
        }
    }

    @Test("the three fields are part of what is confirmed, and an absent one changes nothing")
    func confirmCoversPins() {
        let target = SourceAdd.AppTarget(
            id: "myapp", suffix: "myapp", platform: "ios", name: "Myapp", attaches: false)
        func confirm(
            tagRule: String? = nil, downloadPath: String? = nil, requireBuild: Bool = false,
            github: Bool = true
        ) -> String {
            SourceAdd.confirmValue(
                kind: github ? "githubRelease" : "altstoreIndex",
                url: "https://github.com/acme/widget",
                repo: github ? "acme/widget" : nil, asset: github ? "W-{version}.ipa" : nil,
                tagRule: tagRule, downloadPath: downloadPath, requireBuild: requireBuild,
                bundleId: github ? nil : "com.acme.widget", app: target,
                metadataHosts: ["api.github.com"], downloadHosts: ["github.com"])
        }
        let values = [
            confirm(), confirm(tagRule: "underscoreSuffix"),
            confirm(downloadPath: "/a/{versionKey}.ipa", github: false),
            confirm(downloadPath: "/a/{versionKey}/x.ipa", github: false),
            confirm(requireBuild: true, github: false), confirm(github: false),
        ]
        #expect(Set(values).count == values.count)
    }

    @Test("a flag for the other kind of source is INVALID_ARGUMENT and nothing is written")
    func wrongKind() async throws {
        let http = SourceHTTP([widgetAPI: underscoreRelease(), sourceIndexURL: buildIndex()])
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            for extra in [
                ["--download-path", "/a/x.ipa"], ["--require-build"],
            ] {
                let out = await source(addArgs(widgetURL, extra), services)
                #expect(code(out) == "INVALID_ARGUMENT", "\(extra)")
            }
            let out = await source(
                addArgs(
                    sourceIndexURL,
                    ["--bundle", "io.example.widget", "--tag-rule", "underscoreSuffix"]),
                services)
            #expect(code(out) == "INVALID_ARGUMENT")
            #expect(try configBytes(paths) == before)
        }
    }

    @Test(
        "a value outside the grammar is INVALID_ARGUMENT before any request",
        arguments: [
            ["--tag-rule", "plain"], ["--tag-rule", "underscore"],
            ["--asset", "W-{version}-{version}.ipa"], ["--asset", "W-{other}.ipa"],
            ["--download-path", "no-slash/x.ipa"], ["--download-path", "/a/../x.ipa"],
            ["--download-path", "/a/{versionKey}/{versionKey}.ipa"],
            ["--download-path", "/a/x.zip"],
        ])
    func badValues(extra: [String]) async throws {
        let http = SourceHTTP([widgetAPI: underscoreRelease()])
        try await withSourceHome(http: http) { _, services in
            let out = await source(addArgs(widgetURL, extra), services)
            #expect(code(out) == "INVALID_ARGUMENT")
            #expect(http.getRequests.isEmpty)
        }
    }

    @Test("a document the pins do not fit is refused by the preview, as fetch would")
    func previewRefuses() async throws {
        // The tag is not v<x>_<ver>.
        let plainTag = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: plainTag) { _, services in
            let out = await source(addArgs(widgetURL, githubFlags), services)
            #expect(code(out) == "SOURCE_NOT_ALLOWED")
        }
        // The index declares no build; the path is not the template's.
        for (doc, expected) in [
            (buildIndex(build: nil), "SOURCE_INVALID"),
            (
                buildIndex(url: "https://cdn.example.org/apple/1.2.0b8/Widget.ipa"),
                "SOURCE_NOT_ALLOWED"
            ),
        ] {
            try await withSourceHome(http: SourceHTTP([sourceIndexURL: doc])) { _, services in
                let out = await source(addArgs(sourceIndexURL, indexFlags), services)
                #expect(code(out) == expected)
            }
        }
    }

    @Test("an exact --asset and no flags print the commands they always did")
    func unchangedCommand() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { _, services in
            let out = await source(addArgs(widgetURL, ["--asset", "App.ipa"]), services)
            #expect(out.ok, "\(out.errors)")
            let next = try #require(out.data["next"]?.string)
            #expect(!next.contains("--tag-rule") && !next.contains("--download-path"))
            #expect(!next.contains("--require-build"))
            #expect(out.data["tagRule"] == nil && out.data["downloadPath"] == nil)
        }
    }

    @Test("the menu's confirm click carries the pins, so the same preview is the same confirm")
    func menuOptions() async throws {
        let probe = SourceProbe(
            kind: .github(repo: "acme/widget"), url: widgetURL, metadataHost: "api.github.com",
            body: underscoreRelease())
        let request = SourceAddRequest(
            url: widgetURL, app: "widget", asset: "Widget-{version}.ipa",
            tagRule: "underscoreSuffix")
        let preview = try SourceAdd.preview(probe, request: request, config: sourceBaseConfig())
        let options = MenuSourceAdd.options(MenuSourcePlan(plan: preview.plan, probe: probe))
        #expect(options.asset == "Widget-{version}.ipa" && options.tagRule == "underscoreSuffix")
        let again = try SourceAdd.preview(
            probe, request: try #require(options.request), config: sourceBaseConfig())
        #expect(
            again.plan.confirm == preview.plan.confirm && options.confirm == preview.plan.confirm)
    }

    @Test(
        "the template flags belong to add alone",
        arguments: [
            ["source", "list", "--require-build"],
            ["source", "remove", "--app", "widget", "--tag-rule", "underscoreSuffix"],
            ["source", "remove", "--app", "widget", "--download-path", "/a/x.ipa"],
        ])
    func strays(argv: [String]) async throws {
        try await withSourceHome(http: SourceHTTP()) { _, services in
            let out = await run(argv: argv, services: services)
            #expect(code(out) == "USAGE")
        }
    }
}
