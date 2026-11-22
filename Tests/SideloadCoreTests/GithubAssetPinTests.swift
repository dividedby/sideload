import Foundation
import Testing

@testable import SideloadCore
@testable import SideloadMenu
@testable import sideload

// A custom GitHub source pinned to one exact release asset (design section 8, custom sources): a repository that publishes an
// iOS and a tvOS IPA. The resolver, the config loader, `source add`, the menu picker and `fetch` / `updates`. Offline: a temp
// home and scripted transports; nothing here has run against a real repository.

private let tvosName = "AIOStreams-tvOS.ipa"
private let iosName = "AIOStreams-iOS.ipa"
private let pinAPI = "https://api.github.com/repos/acme/widget/releases/latest"

private func pinURL(_ name: String, tag: String = "0.3.8") -> String {
    "https://github.com/acme/widget/releases/download/\(tag)/\(name)"
}

/// Distinct digests per file, so a test can tell which asset was resolved.
private func digestOf(_ name: String) -> String {
    sha256Hex(Data(name.utf8))
}

private func asset(_ name: String, tag: String = "0.3.8") -> ReleaseAsset {
    ReleaseAsset(name: name, digest: "sha256:" + digestOf(name), url: pinURL(name, tag: tag))
}

private func twoIPAs(tag: String = "0.3.8") -> Data {
    releaseJSON(
        tag: tag,
        assets: [asset(iosName, tag: tag), asset(tvosName, tag: tag), asset("notes.txt", tag: tag)])
}

private func resolve(_ json: Data, asset pin: String?) throws -> ResolvedAsset {
    try SourceResolver.customGithub(app: "myapp", repo: "acme/widget", asset: pin, json: json)
}

private func failure(_ body: () throws -> Any) -> SideloadError? {
    do {
        _ = try body()
        return nil
    } catch {
        return error as? SideloadError
    }
}

// MARK: resolver

@Suite("asset pin: resolver")
struct AssetPinResolverTests {
    @Test(
        "a pin picks that file out of several IPAs, whichever order they come in",
        arguments: [tvosName, iosName])
    func pinHit(name: String) throws {
        let resolved = try resolve(twoIPAs(), asset: name)
        #expect(resolved.fileName == name && resolved.version == "0.3.8")
        #expect(resolved.upstreamDigest == digestOf(name))
        #expect(resolved.url.absoluteString == pinURL(name))
    }

    @Test(
        "an IPA whose extension is not lowercase can be pinned, as it can be added unpinned",
        arguments: ["Foo.IPA", "Foo.Ipa"])
    func upperExtension(name: String) throws {
        let json = releaseJSON(tag: "0.3.8", assets: [asset(name), asset(iosName)])
        #expect(CustomSources.isValidAssetName(name))
        #expect(try resolve(json, asset: name).fileName == name)
        // The name itself is still matched exactly.
        #expect(
            failure { try resolve(json, asset: name.lowercased()) }?.code == "SOURCE_NOT_ALLOWED")
    }

    @Test("a pin on a release with that one IPA resolves as before")
    func pinOnSingle() throws {
        let json = releaseJSON(tag: "0.3.8", assets: [asset(tvosName)])
        #expect(try resolve(json, asset: tvosName).fileName == tvosName)
    }

    @Test(
        "a pin that is not an asset of the release is refused; the fix lists the IPAs it has",
        arguments: ["Other.ipa", "aiostreams-tvos.ipa", "AIOStreams-tvOS.IPA", "AIOStreams-tvOS"])
    func pinMissing(pin: String) throws {
        let error = try #require(failure { try resolve(twoIPAs(), asset: pin) })
        #expect(error.code == "SOURCE_NOT_ALLOWED")
        #expect(error.message.contains("no asset named"))
        #expect(error.fix?.contains(tvosName) == true && error.fix?.contains(iosName) == true)
        #expect(error.fix?.contains("notes.txt") == false, "only IPAs are listed")
    }

    @Test("several IPAs and no pin: SOURCE_NOT_ALLOWED, with the names and the way to pin one")
    func ambiguous() throws {
        let error = try #require(failure { try resolve(twoIPAs(), asset: nil) })
        #expect(error.code == "SOURCE_NOT_ALLOWED")
        #expect(error.fix?.contains(tvosName) == true && error.fix?.contains(iosName) == true)
        #expect(error.fix?.contains("--asset") == true)
    }

    @Test("one IPA and no pin: unchanged, whatever the file is called")
    func singleUnpinned() throws {
        let json = releaseJSON(tag: "0.3.8", assets: [asset(tvosName), asset("notes.txt")])
        #expect(try resolve(json, asset: nil).fileName == tvosName)
    }

    @Test("a name that is not a plain file name never appears in a refusal")
    func unsafeNamesOmitted() throws {
        let evil = "x y\u{1b}[31m.ipa"
        let json = releaseJSON(
            tag: "0.3.8", assets: [asset(iosName), asset(tvosName), asset(evil)])
        let error = try #require(failure { try resolve(json, asset: nil) })
        let text = (error.message) + (error.fix ?? "")
        #expect(text.contains(iosName) && !text.contains("\u{1b}") && !text.contains("x y"))
        let missing = try #require(failure { try resolve(json, asset: "Other.ipa") })
        #expect(!((missing.fix ?? "").contains("\u{1b}")))
    }

    @Test("a long list of IPAs is cut in the fix")
    func listCut() throws {
        let many = (1...15).map { asset("App\($0).ipa") }
        let error = try #require(
            failure { try resolve(releaseJSON(tag: "0.3.8", assets: many), asset: nil) })
        #expect(
            error.fix?.contains("App10.ipa") == true && error.fix?.contains("App11.ipa") == false)
    }

    @Test("a pinned asset still has to pass every check an unpinned one does")
    func pinnedStillChecked() throws {
        var noDigest = asset(tvosName)
        noDigest.digest = nil
        #expect(
            failure { try resolve(releaseJSON(tag: "0.3.8", assets: [noDigest]), asset: tvosName) }?
                .code == "UPSTREAM_DIGEST_MISSING")
        var partial = asset(tvosName)
        partial.state = "starter"
        #expect(
            failure { try resolve(releaseJSON(tag: "0.3.8", assets: [partial]), asset: tvosName) }?
                .code == "SOURCE_NOT_ALLOWED")
        var wrongURL = asset(tvosName)
        wrongURL.url = "https://evil.example.org/\(tvosName)"
        #expect(
            failure { try resolve(releaseJSON(tag: "0.3.8", assets: [wrongURL]), asset: tvosName) }?
                .code == "SOURCE_NOT_ALLOWED")
        var huge = asset(tvosName)
        huge.size = Int(FetchLimits.maxIPABytes) + 1
        #expect(
            failure { try resolve(releaseJSON(tag: "0.3.8", assets: [huge]), asset: tvosName) }?
                .code == "DOWNLOAD_TOO_LARGE")
        #expect(
            failure {
                try resolve(
                    releaseJSON(tag: "0.3.8", assets: [asset(tvosName)], draft: true),
                    asset: tvosName)
            }?.code == "SOURCE_NOT_ALLOWED")
    }
}

// MARK: config

@Suite("asset pin: customSources")
struct AssetPinConfigTests {
    private func entry(_ asset: JSONValue?) -> [String: JSONValue] {
        var e = githubEntry
        if let asset { e["asset"] = asset }
        return e
    }

    @Test("an asset is read into the source's kind; none leaves it unpinned")
    func valid() throws {
        let pinned = customConfig(sources: [entry(.string(tvosName))]).appRegistry
        #expect(pinned.warnings.isEmpty)
        #expect(
            pinned.app("myapp")?.fetch?.kind
                == .customGithubRelease(repo: "acme/widget", asset: tvosName))
        #expect(pinned.app("myapp")?.fetch?.kind.pinnedAsset == tvosName)
        let plain = customConfig(sources: [entry(nil)]).appRegistry
        #expect(plain.app("myapp")?.fetch?.kind.pinnedAsset == nil)
    }

    @Test(
        "an asset that is not a plain file name ending in .ipa ignores the entry, with the reason",
        arguments: [
            JSONValue.number(1), .bool(true), .null, .array([]), .string(""), .string("App"),
            .string("App.zip"), .string("App.ipa.txt"), .string("a/App.ipa"), .string("../App.ipa"),
            .string("App ipa.ipa"), .string("App*.ipa"),
            .string(String(repeating: "a", count: 70) + ".ipa"), .string("é.ipa"),
        ])
    func invalid(value: JSONValue) {
        let registry = customConfig(sources: [entry(value)]).appRegistry
        #expect(registry.app("myapp")?.fetch == nil)
        let text = registry.warnings.first?["message"]?.string ?? ""
        #expect(text.contains("its asset is not a plain file name ending in .ipa"), "\(text)")
    }

    @Test("an AltStore entry cannot carry an asset")
    func altstoreRefuses() {
        var alt = altstoreEntry
        alt["asset"] = .string(tvosName)
        let registry = customConfig(sources: [alt]).appRegistry
        #expect(registry.app("myapp")?.fetch == nil && registry.warnings.count == 1)
    }

    @Test("source list shows the pin, and only for a pinned source")
    func list() async throws {
        let config = customConfig(sources: [entry(.string(tvosName))])
        try await withTestHome(config: config) { paths, _ in
            let out = await run(
                argv: ["source", "list"],
                services: fetchServices(paths, http: SourceHTTP()))
            let mine = try #require(out.data["sources"]?.array?.first { $0["app"] == "myapp" })
            #expect(mine["asset"] == .string(tvosName))
            let builtIn = try #require(out.data["sources"]?.array?.first { $0["app"] == "apollo" })
            #expect(builtIn["asset"] == nil)
        }
    }
}

// MARK: source add

private func addCode(_ out: Envelope) -> String? { out.errors.first?.code }

@Suite("asset pin: source add")
struct AssetPinAddTests {
    private func http(_ json: Data? = nil) -> SourceHTTP {
        SourceHTTP([widgetAPI: json ?? twoIPAs()])
    }

    @Test(
        "a pin previews that file: tvos by default, the pin in the JSON and in the printed command")
    func preview() async throws {
        let http = http()
        try await withSourceHome(http: http) { paths, services in
            let before = try configBytes(paths)
            let out = await source(addArgs(widgetURL, ["--asset", tvosName]), services)
            #expect(out.ok, "\(out.errors)")
            #expect(try configBytes(paths) == before)
            let json = try out.printed().json
            #expect(json["asset"] == .string(tvosName))
            #expect(json["app"]?["platform"] == "tvos")
            let apps = try #require(json["apps"]?.array)
            #expect(apps.count == 1 && apps[0]["name"] == .string(tvosName))
            let confirm = try #require(json["confirm"]?.string)
            let next = try #require(json["next"]?.string)
            #expect(
                next.contains(
                    "--app widget --asset '\(tvosName)' --platform tvos --confirm \(confirm) --yes")
            )
            #expect(http.getRequests.count == 1 && http.downloadCount == 0)
        }
    }

    @Test("the platform default is only a default: --platform wins, and an iOS name stays ios")
    func platform() async throws {
        try await withSourceHome(http: http()) { _, services in
            let forced = await source(
                addArgs(widgetURL, ["--asset", tvosName, "--platform", "ios"]), services)
            #expect(forced.data["app"]?["platform"] == "ios")
            let ios = await source(addArgs(widgetURL, ["--asset", iosName]), services)
            #expect(ios.data["app"]?["platform"] == "ios")
        }
    }

    @Test("an existing app keeps its own platform whatever the asset name suggests")
    func attachIgnoresDefault() async throws {
        let extra: [String: JSONValue] = [
            "customApps": [["id": "widget", "platform": "ios"]]
        ]
        try await withSourceHome(config: sourceBaseConfig(extra: extra), http: http()) {
            _, services in
            let out = await source(addArgs(widgetURL, ["--asset", tvosName]), services)
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["app"]?["exists"] == true && out.data["app"]?["platform"] == "ios")
        }
    }

    @Test("without a pin the confirm value is what it was before pins existed")
    func unpinnedGolden() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { _, services in
            let out = await source(addArgs(widgetURL), services)
            #expect(out.data["confirm"] == "24d35f470c3ba202")
            #expect(out.data["asset"] == nil)
            let next = try #require(out.data["next"]?.string)
            #expect(!next.contains("--asset"))
        }
    }

    @Test("a single tvOS-named IPA with no pin keeps the ios default and its old confirm value")
    func singleTvosNameUnpinned() async throws {
        let json = releaseJSON(tag: "0.3.8", assets: [asset(tvosName)])
        try await withSourceHome(http: http(json)) { _, services in
            let out = await source(addArgs(widgetURL), services)
            #expect(out.ok && out.data["app"]?["platform"] == "ios", "\(out.errors)")
            #expect(out.data["confirm"] == "24d35f470c3ba202")
        }
    }

    @Test("the pin is part of what is confirmed: with, without and another pin differ")
    func confirmCoversPin() async throws {
        try await withSourceHome(http: http()) { _, services in
            func confirm(_ extra: [String]) async -> String? {
                await source(addArgs(widgetURL, extra), services).data["confirm"]?.string
            }
            let tv = await confirm(["--asset", tvosName, "--platform", "ios"])
            let ios = await confirm(["--asset", iosName, "--platform", "ios"])
            #expect(tv != nil && ios != nil && tv != ios)
            #expect(tv != "24d35f470c3ba202" && ios != "24d35f470c3ba202")
        }
    }

    @Test("several IPAs and no --asset is SOURCE_AMBIGUOUS, listing the files; nothing is written")
    func ambiguous() async throws {
        try await withSourceHome(http: http()) { paths, services in
            let before = try configBytes(paths)
            let out = await source(addArgs(widgetURL), services)
            #expect(addCode(out) == "SOURCE_AMBIGUOUS")
            let names = out.data["candidates"]?.array?.compactMap { $0["name"]?.string }
            #expect(names == [iosName, tvosName])
            #expect(out.data["candidates"]?.array?.allSatisfy { $0["hasDigest"] == true } == true)
            let fix = out.errors.first?.fix ?? ""
            #expect(fix.contains("--asset") && fix.contains(tvosName))
            #expect(try configBytes(paths) == before)
        }
    }

    @Test(
        "a pin the release does not have is SOURCE_NOT_ALLOWED; a malformed one is INVALID_ARGUMENT"
    )
    func badPins() async throws {
        let http = http()
        try await withSourceHome(http: http) { _, services in
            let missing = await source(addArgs(widgetURL, ["--asset", "Nope.ipa"]), services)
            #expect(addCode(missing) == "SOURCE_NOT_ALLOWED")
            let before = http.getRequests.count
            for bad in ["Nope.zip", "a/b.ipa", "x*.ipa", ""] {
                let out = await source(addArgs(widgetURL, ["--asset", bad]), services)
                #expect(addCode(out) == "INVALID_ARGUMENT", "\(bad) \(out.errors)")
            }
            #expect(
                http.getRequests.count == before, "malformed pins are refused before any request")
        }
    }

    @Test("--asset on an AltStore index is INVALID_ARGUMENT, like --bundle on a release")
    func altstore() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON([IndexEntry()])])
        try await withSourceHome(http: http) { _, services in
            let out = await source(addArgs(sourceIndexURL, ["--asset", "App.ipa"]), services)
            #expect(addCode(out) == "INVALID_ARGUMENT")
        }
    }

    @Test("list and remove take no --asset")
    func usage() async throws {
        try await withSourceHome(http: http()) { _, services in
            #expect(addCode(await source(["list", "--asset", tvosName], services)) == "USAGE")
            #expect(
                addCode(await source(["remove", "--app", "widget", "--asset", tvosName], services))
                    == "USAGE")
        }
    }

    @Test("--yes writes the pin; a different pin than the one confirmed is SOURCE_CHANGED")
    func write() async throws {
        try await withSourceHome(http: http()) { paths, services in
            let preview = await source(addArgs(widgetURL, ["--asset", tvosName]), services)
            let confirm = try #require(preview.data["confirm"]?.string)
            let before = try configBytes(paths)
            let swapped = await source(
                addArgs(widgetURL, ["--asset", iosName, "--platform", "tvos"], confirm: confirm),
                services)
            #expect(addCode(swapped) == SourceAdd.changedCode)
            #expect(try configBytes(paths) == before)

            let yes = await source(
                addArgs(widgetURL, ["--asset", tvosName], confirm: confirm), services)
            #expect(yes.ok, "\(yes.errors)")
            let config = try loadConfig(paths)
            let entries = try #require(config.extra["customSources"]?.array)
            #expect(entries.count == 1 && entries[0]["asset"] == .string(tvosName))
            let registry = config.appRegistry
            #expect(registry.warnings.isEmpty)
            #expect(
                registry.app("widget")?.fetch?.kind
                    == .customGithubRelease(repo: "acme/widget", asset: tvosName))
            #expect(registry.app("widget")?.devicePlatform == "tvos")
        }
    }

    @Test("an unpinned source writes no asset key")
    func writeUnpinned() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(http: http) { paths, services in
            let preview = await source(addArgs(widgetURL), services)
            let confirm = try #require(preview.data["confirm"]?.string)
            #expect(await source(addArgs(widgetURL, confirm: confirm), services).ok)
            let entries = try #require(try loadConfig(paths).extra["customSources"]?.array)
            #expect(entries[0]["asset"] == nil)
        }
    }

    @Test(
        "SOURCE_EXISTS is per app, not per repository: two apps may pin two files of one repo")
    func twoAppsOneRepo() async throws {
        try await withSourceHome(http: http()) { paths, services in
            for (app, name) in [("aio-ios", iosName), ("aio-tv", tvosName)] {
                let args = ["--app", app, "--asset", name]
                let preview = await source(addArgs(widgetURL, args), services)
                let confirm = try #require(preview.data["confirm"]?.string)
                let yes = await source(addArgs(widgetURL, args, confirm: confirm), services)
                #expect(yes.ok, "\(app) \(yes.errors)")
            }
            let registry = try loadConfig(paths).appRegistry
            #expect(registry.warnings.isEmpty)
            #expect(registry.app("aio-ios")?.fetch?.kind.pinnedAsset == iosName)
            #expect(registry.app("aio-tv")?.fetch?.kind.pinnedAsset == tvosName)
            // The same app a second time is still SOURCE_EXISTS.
            let again = await source(
                addArgs(widgetURL, ["--app", "aio-tv", "--asset", tvosName]), services)
            #expect(addCode(again) == "SOURCE_EXISTS")
        }
    }
}

// MARK: menu

private func menuServices(_ paths: Paths, http: SourceHTTP) -> Services {
    fetchServices(paths, http: http)
}

@Suite("asset pin: menu")
struct AssetPinMenuTests {
    @Test("a release with several IPAs goes to the picker; a pick carries the pin into the plan")
    func picker() async throws {
        let http = SourceHTTP([widgetAPI: twoIPAs()])
        try await withSourceHome(config: menuConfig(), http: http) { paths, services in
            let before = try configBytes(paths)
            guard
                case .choose(let choices) = await MenuSourceAdd.preview(services, url: widgetURL)
            else {
                Issue.record("expected the picker")
                return
            }
            #expect(choices.choices.map(\.title) == ["\(iosName) · 0.3.8", "\(tvosName) · 0.3.8"])
            #expect(choices.choices.allSatisfy { $0.bundleId == nil && $0.blocked == nil })
            #expect(choices.intro == MenuSourceAdd.releaseIntro)
            #expect(choices.truncatedNote == MenuSourceAdd.releaseTruncatedNote)
            #expect(http.getRequests.count == 1)

            let step = MenuSourceAdd.choose(choices, choices.choices[1], services: services)
            guard case .confirm(let source) = step else {
                Issue.record("expected the confirm: \(step)")
                return
            }
            #expect(source.plan.asset == tvosName && source.plan.platform == "tvos")
            #expect(http.getRequests.count == 1, "the pick reads no more than the config")
            #expect(try configBytes(paths) == before)

            // The CLI makes the same plan from the same flags.
            let cli = await run(
                argv: ["source"] + addArgs(widgetURL, ["--asset", tvosName]), services: services)
            #expect(cli.data["confirm"] == .string(source.confirm))

            // The confirm card says which file, and the click is source add --asset ... --yes.
            let lines = MenuSourceAdd.prompt(source).lines
            #expect(lines.contains("Asset \(tvosName)"))
            let options = MenuSourceAdd.options(source)
            #expect(options.asset == tvosName && options.bundle == nil && options.yes)
            #expect(options.platform == "tvos" && options.confirm == source.confirm)

            // The platform toggle keeps the pin and changes only what the platform changes.
            let toggled = MenuSourceAdd.choosePlatform(source, "ios", services: services)
            guard case .confirm(let ios) = toggled else {
                Issue.record("expected the confirm: \(toggled)")
                return
            }
            #expect(ios.plan.asset == tvosName && ios.plan.platform == "ios")
            #expect(ios.confirm != source.confirm)
            #expect(MenuSourceAdd.options(ios).asset == tvosName)
        }
    }

    @Test("a release asset with no digest is blocked in the picker")
    func blocked() async throws {
        var noDigest = asset(tvosName)
        noDigest.digest = nil
        let json = releaseJSON(tag: "0.3.8", assets: [asset(iosName), noDigest])
        let http = SourceHTTP([widgetAPI: json])
        try await withSourceHome(config: menuConfig(), http: http) { _, services in
            guard
                case .choose(let choices) = await MenuSourceAdd.preview(services, url: widgetURL)
            else {
                Issue.record("expected the picker")
                return
            }
            #expect(choices.choices.map { $0.blocked != nil } == [false, true])
            let step = MenuSourceAdd.choose(choices, choices.choices[1], services: services)
            if case .failed(let issue) = step {
                #expect(issue.code == SourceResolver.missingDigestCode)
            } else {
                Issue.record("expected a refusal: \(step)")
            }
        }
    }

    @Test("a release with one IPA goes straight to the confirm, unpinned, as before")
    func single() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(config: menuConfig(), http: http) { _, services in
            let step = await MenuSourceAdd.preview(services, url: widgetURL)
            guard case .confirm(let source) = step else {
                Issue.record("expected the confirm: \(step)")
                return
            }
            #expect(source.plan.asset == nil)
            #expect(!MenuSourceAdd.prompt(source).lines.contains { $0.hasPrefix("Asset ") })
            #expect(MenuSourceAdd.options(source).asset == nil)
        }
    }
}

// MARK: fetch and updates

private func transport(_ metadata: Data, bodies: [String: Data] = [:]) -> FakeFetchTransport {
    FakeFetchTransport(
        metadata: [pinAPI: metadata],
        download: { request in
            Delivery(bodies[request.url.lastPathComponent] ?? Data())
        })
}

@Suite("asset pin: fetch and updates")
struct AssetPinFetchTests {
    private func pinnedEntry(_ name: String?) -> [String: JSONValue] {
        var e = githubEntry
        if let name { e["asset"] = .string(name) }
        return e
    }

    @Test("fetch downloads only the pinned asset; the other platform's IPA is never requested")
    func fetchPinned() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let json = releaseJSON(
            tag: "0.3.8",
            assets: [
                asset(iosName),
                ReleaseAsset(
                    name: tvosName, size: ipa.count, digest: "sha256:" + sha256Hex(ipa),
                    url: pinURL(tvosName)),
            ])
        let config = customConfig(sources: [pinnedEntry(tvosName)])
        try await withTestHome(config: config) { paths, _ in
            let http = transport(json, bodies: [tvosName: ipa])
            let out = await FetchCommand.run(
                fetchServices(paths, http: http, runner: RecordingRunner()),
                FetchOptions(app: "myapp", approve: false, version: nil),
                registry: ScratchRegistry())
            #expect(out.ok, "\(out.errors)")
            let printed = try out.printed().json
            #expect(printed["file"] == .string("myapp/0.3.8/\(tvosName)"))
            #expect(printed["upstreamDigest"] == .string(sha256Hex(ipa)))
            #expect(http.downloadRequests.map(\.url.absoluteString) == [pinURL(tvosName)])
        }
    }

    @Test(
        "fetch without a pin on a two-IPA release is refused before any download, naming the files")
    func fetchUnpinned() async throws {
        let config = customConfig(sources: [pinnedEntry(nil)])
        try await withTestHome(config: config) { paths, _ in
            let http = transport(twoIPAs())
            let out = await FetchCommand.run(
                fetchServices(paths, http: http, runner: RecordingRunner()),
                FetchOptions(app: "myapp", approve: false, version: nil),
                registry: ScratchRegistry())
            #expect(out.firstCode == "SOURCE_NOT_ALLOWED")
            let fix = out.errors.first?.fix ?? ""
            #expect(fix.contains(tvosName) && fix.contains("--asset"))
            #expect(http.downloadRequests.isEmpty)
        }
    }

    @Test("a renamed pin fails closed: nothing is downloaded and the files on offer are named")
    func fetchRenamed() async throws {
        let config = customConfig(sources: [pinnedEntry("AIOStreams-tvOS-old.ipa")])
        try await withTestHome(config: config) { paths, _ in
            let http = transport(twoIPAs())
            let out = await FetchCommand.run(
                fetchServices(paths, http: http, runner: RecordingRunner()),
                FetchOptions(app: "myapp", approve: false, version: nil),
                registry: ScratchRegistry())
            #expect(out.firstCode == "SOURCE_NOT_ALLOWED")
            #expect(out.errors.first?.fix?.contains(tvosName) == true)
            #expect(http.downloadRequests.isEmpty)
        }
    }

    @Test(
        "updates reads the pinned asset's release; an unpinned two-IPA source is a per-source error"
    )
    func updates() async throws {
        let installed = { (config: Config, paths: Paths) async throws in
            let app = try #require(config.appRegistry.app("myapp"))
            var record = installRecord(app)
            record.version = "0.3.0"
            try await LedgerStore(paths: paths).update { $0.installs = [record] }
        }
        let pinned = customConfig(sources: [pinnedEntry(tvosName)])
        try await withTestHome(config: pinned) { paths, _ in
            try await installed(pinned, paths)
            let http = transport(twoIPAs())
            let out = await UpdatesCommand.run(
                fetchServices(paths, http: http), UpdatesOptions(app: "myapp"))
            #expect(out.ok, "\(out.errors)")
            let mine = try #require(out.data["sources"]?.array?.first { $0["app"] == "myapp" })
            #expect(mine["upstream"]?["version"] == "0.3.8")
            #expect(mine["upstream"]?["sha256"] == .string(digestOf(tvosName)))
        }
        let unpinned = customConfig(sources: [pinnedEntry(nil)])
        try await withTestHome(config: unpinned) { paths, _ in
            try await installed(unpinned, paths)
            let out = await UpdatesCommand.run(
                fetchServices(paths, http: transport(twoIPAs())), UpdatesOptions(app: "myapp"))
            #expect(out.firstCode == "SOURCE_NOT_ALLOWED")
        }
    }
}
