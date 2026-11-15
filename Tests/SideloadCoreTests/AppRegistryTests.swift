import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

private let prefix = "io.github.dividedby"

/// A config with this `customApps` value (raw JSON) and the owner's prefix.
private func makeConfig(customApps json: String?) throws -> Config {
    let custom = json.map { #", "customApps": \#($0)"# } ?? ""
    return try Config.parse(Data(#"{"bundleIdPrefix": "\#(prefix)"\#(custom)}"#.utf8))
}

private func registry(_ json: String) throws -> AppRegistry {
    try makeConfig(customApps: json).appRegistry
}

private func warningMessages(_ registry: AppRegistry) -> [String] {
    registry.warnings.compactMap { $0["message"]?.string }
}

private func warningCodes(_ registry: AppRegistry) -> [String] {
    registry.warnings.compactMap { $0["code"]?.string }
}

/// Runs `argv` through the CLI over fakes and a temp home holding `config`.
private func invoke(_ argv: [String], config: Config) async throws -> (Envelope, FakeRunner) {
    try await withTestHome(config: config) { paths, _ in
        let (services, runner) = fakeServices(paths)
        return (await run(argv: argv, services: services), runner)
    }
}

@Suite("app registry")
struct AppRegistryTests {
    // MARK: built-ins

    @Test("golden: each built-in's bundle ID, platform, SDK and signer are today's values")
    func builtInGolden() throws {
        struct Golden: Equatable {
            let id, name, bundleId, platform, profilePlatform, sdk: String
            let signedByProvision: Bool
        }
        let expected = [
            Golden(
                id: "stremio-ios", name: "Stremio", bundleId: "io.github.dividedby.free.stremio",
                platform: "ios", profilePlatform: "iOS", sdk: "iphoneos", signedByProvision: false),
            Golden(
                id: "stremio-tvos", name: "Stremio", bundleId: "io.github.dividedby.free.stremio",
                platform: "tvos", profilePlatform: "tvOS", sdk: "appletvos",
                signedByProvision: false),
            Golden(
                id: "apollo", name: "Apollo", bundleId: "io.github.dividedby.free.apollo",
                platform: "ios", profilePlatform: "iOS", sdk: "iphoneos", signedByProvision: false),
            Golden(
                id: "filler", name: "Filler", bundleId: "io.github.dividedby.free.filler",
                platform: "ios", profilePlatform: "iOS", sdk: "iphoneos", signedByProvision: true),
        ]
        let actual = AppRegistry.builtIn.apps.map {
            Golden(
                id: $0.id, name: $0.displayName, bundleId: $0.freeBundleId(prefix: prefix) ?? "",
                platform: $0.devicePlatform, profilePlatform: $0.profilePlatform, sdk: $0.sdk,
                signedByProvision: $0.signedByProvision)
        }
        #expect(actual == expected)
        #expect(AppRegistry.builtIn.apps.allSatisfy { $0.builtIn })
        #expect(AppRegistry.builtIn.warnings.isEmpty)
        #expect(AppDefinition.apollo.freeBundleId(prefix: nil) == nil)
        #expect(AppDefinition.apollo.freeBundleId(prefix: "not valid!") == nil)
    }

    @Test("golden: the built-in sources, their order, and the usage lists")
    func builtInSources() throws {
        let sources = AppRegistry.builtIn.fetchSources
        #expect(sources.map(\.app) == ["apollo", "stremio-ios", "stremio-tvos"])
        #expect(
            sources[0].kind == .githubRelease(repo: "Apollo-Reborn/Apollo-Reborn")
                && sources[0].metadataHosts == ["api.github.com"]
                && sources[0].downloadHosts == [
                    "github.com", "objects.githubusercontent.com",
                    "release-assets.githubusercontent.com",
                ])
        for (source, tvos) in [(sources[1], false), (sources[2], true)] {
            let index = tvos ? "stremio-tvos.json" : "stremio-ios.json"
            #expect(
                source.kind
                    == .altstoreIndex(
                        url: "https://raw.githubusercontent.com/gorlev/stremio-altstore/main/"
                            + index, bundleId: "com.stremio.pal", host: "dl.strem.io", tvos: tvos))
            #expect(source.metadataHosts == ["raw.githubusercontent.com"])
            #expect(source.downloadHosts == ["dl.strem.io"])
        }
        #expect(AppRegistry.builtIn.names == ["stremio-ios", "stremio-tvos", "apollo", "filler"])
        #expect(AppRegistry.builtIn.choices(.all) == "apollo|stremio-ios|stremio-tvos|filler")
        #expect(AppRegistry.builtIn.choices(.signed) == "apollo|stremio-ios|stremio-tvos")
        #expect(AppRegistry.builtIn.choices(.fetchable) == "apollo|stremio-ios|stremio-tvos")
    }

    @Test("with no customApps the config's registry is the built-ins, with no warning")
    func noCustomApps() throws {
        let apps = try makeConfig(customApps: nil).appRegistry
        #expect(apps.names == AppRegistry.builtIn.names && apps.warnings.isEmpty)
        #expect(try registry("[]").names == AppRegistry.builtIn.names)
    }

    // MARK: custom entries

    @Test("a valid custom entry resolves after the built-ins, with its defaults")
    func validCustom() throws {
        let apps = try registry(
            #"[{"id": "myapp", "platform": "ios"}, {"id": "tv-thing", "platform": "tvos", "suffix": "tvthing", "name": "TV Thing"}]"#
        )
        #expect(apps.warnings.isEmpty)
        #expect(apps.names == AppRegistry.builtIn.names + ["myapp", "tv-thing"])
        let mine = try #require(apps.app("myapp"))
        #expect(!mine.builtIn && mine.displayName == "Myapp" && mine.suffix == "myapp")
        #expect(mine.freeBundleId(prefix: prefix) == "io.github.dividedby.free.myapp")
        #expect(mine.devicePlatform == "ios" && mine.sdk == "iphoneos" && !mine.signedByProvision)
        #expect(mine.fetchSource == nil)
        let tv = try #require(apps.app("tv-thing"))
        #expect(
            tv.displayName == "TV Thing" && tv.devicePlatform == "tvos" && tv.sdk == "appletvos")
        #expect(tv.freeBundleId(prefix: prefix) == "io.github.dividedby.free.tvthing")
        // A custom app has no source yet, so fetch and updates list exactly the built-in ones.
        #expect(apps.fetchSources == AppRegistry.builtIn.fetchSources)
        #expect(apps.apps(for: "tvos").map(\.id) == ["stremio-tvos", "tv-thing"])
        #expect(apps.choices(.all) == "apollo|myapp|stremio-ios|stremio-tvos|tv-thing|filler")
    }

    @Test(
        "each invalid kind of entry is left out with a warning, and the rest still load",
        arguments: [
            (#""myapp""#, "it is not an object"),
            (#"{"platform": "ios"}"#, "its id is missing or not a string"),
            (#"{"id": 7, "platform": "ios"}"#, "its id is missing or not a string"),
            (#"{"id": "MyApp", "platform": "ios"}"#, "its id is not 1 to 31"),
            (#"{"id": "-app", "platform": "ios"}"#, "its id is not 1 to 31"),
            (#"{"id": "", "platform": "ios"}"#, "its id is not 1 to 31"),
            (#"{"id": "a.b", "platform": "ios"}"#, "its id is not 1 to 31"),
            (
                #"{"id": "\#(String(repeating: "a", count: 32))", "platform": "ios"}"#,
                "its id is not 1 to 31"
            ),
            (#"{"id": "myapp"}"#, "its platform is not ios or tvos"),
            (#"{"id": "myapp", "platform": "macos"}"#, "its platform is not ios or tvos"),
            (
                #"{"id": "myapp", "platform": "ios", "suffix": "My.App"}"#,
                "its suffix is not 1 to 31"
            ),
            (#"{"id": "myapp", "platform": "ios", "suffix": 3}"#, "its suffix is not 1 to 31"),
            (#"{"id": "myapp", "platform": "ios", "name": ""}"#, "its name is not 1 to 64"),
            (#"{"id": "myapp", "platform": "ios", "name": " x"}"#, "its name is not 1 to 64"),
            (#"{"id": "myapp", "platform": "ios", "name": "a\nb"}"#, "its name is not 1 to 64"),
            (
                #"{"id": "myapp", "platform": "ios", "source": {}}"#,
                "it has the unknown field source"
            ),
            (#"{"id": "apollo", "platform": "ios"}"#, "apollo is a built-in app"),
            (#"{"id": "filler", "platform": "ios", "suffix": "x"}"#, "filler is a built-in app"),
            (
                #"{"id": "stremio-mac", "platform": "ios", "suffix": "stremio"}"#,
                "the suffix stremio belongs to the built-in app stremio-ios"
            ),
            (
                #"{"id": "apollo2", "platform": "ios", "suffix": "apollo"}"#,
                "the suffix apollo belongs"
            ),
        ])
    func invalidEntry(entry: String, reason: String) throws {
        let apps = try registry(#"[\#(entry), {"id": "good", "platform": "ios"}]"#)
        #expect(apps.names == AppRegistry.builtIn.names + ["good"])
        #expect(warningCodes(apps) == ["CUSTOM_APP_IGNORED"])
        let message = try #require(warningMessages(apps).first)
        #expect(message.hasPrefix("customApps entry 0 is ignored: \(reason)"), "\(message)")
        #expect(apps.warnings.first?["fix"]?.string?.contains("customApps") == true)
    }

    @Test("custom entries sharing an ID or a suffix are all refused, and the others load")
    func collisions() throws {
        let suffix = try registry(
            #"[{"id": "one", "platform": "ios", "suffix": "shared"}, {"id": "keep", "platform": "ios"}, {"id": "two", "platform": "tvos", "suffix": "shared"}]"#
        )
        #expect(suffix.names == AppRegistry.builtIn.names + ["keep"])
        #expect(
            warningMessages(suffix) == [
                "customApps entry 0 is ignored: another custom app has the suffix shared.",
                "customApps entry 2 is ignored: another custom app has the suffix shared.",
            ])
        // A custom ID equal to another's suffix is no clash: the bundle IDs differ.
        let crossed = try registry(
            #"[{"id": "dup", "platform": "ios"}, {"id": "dup", "platform": "tvos", "suffix": "other"}, {"id": "x", "platform": "ios", "suffix": "dupe"}]"#
        )
        #expect(crossed.names == AppRegistry.builtIn.names + ["x"])
        #expect(
            warningMessages(crossed) == [
                "customApps entry 0 is ignored: another custom app has the ID dup.",
                "customApps entry 1 is ignored: another custom app has the ID dup.",
            ])
    }

    @Test(
        "a malformed customApps leaves the built-ins working, with one warning",
        arguments: [#""apps""#, "{}", "7", "null", "true"])
    func malformed(json: String) throws {
        let apps = try registry(json)
        #expect(apps.names == AppRegistry.builtIn.names)
        #expect(warningCodes(apps) == ["CUSTOM_APP_IGNORED"])
        #expect(
            warningMessages(apps) == ["customApps is not an array, so every custom app is ignored."]
        )
    }

    @Test("the bundle ID check uses the configured prefix")
    func prefixCheck() throws {
        // No prefix: the entry loads (commands stop at CONFIG_MISSING before any bundle ID is used).
        let none = try Config.parse(
            Data(#"{"customApps": [{"id": "myapp", "platform": "ios"}]}"#.utf8)
        ).appRegistry
        #expect(none.app("myapp") != nil && none.warnings.isEmpty)
        #expect(none.app("myapp")?.freeBundleId(prefix: nil) == nil)
    }

    @Test("customApps stays in the config as written: reading it writes nothing back")
    func readOnly() async throws {
        let raw = #"[{"id": "myapp", "platform": "ios"}, "junk"]"#
        let loaded = try makeConfig(customApps: raw)
        _ = loaded.appRegistry
        let reparsed = try Config.parse(loaded.encoded())
        #expect(reparsed.extra["customApps"] == loaded.extra["customApps"])
        #expect(reparsed == loaded)
    }

    // MARK: through the commands

    @Test("a malformed customApps never stops a built-in: provision still reaches its confirm")
    func malformedKeepsCommands() async throws {
        var config = try makeConfig(customApps: #"{"not": "an array"}"#)
        config.devices = iphoneConfig().devices
        let (out, runner) = try await invoke(
            ["provision", "--app", "stremio-ios", "--device", "iphone"], config: config)
        #expect(out.errors.first?.code == "CONFIRM_REQUIRED")
        #expect(out.data["bundleId"] == "io.github.dividedby.free.stremio")
        #expect(runner.calls.isEmpty)
    }

    @Test("a valid custom app is known to the commands; an unknown one is still USAGE")
    func commandsSeeCustom() async throws {
        var config = try makeConfig(customApps: #"[{"id": "myapp", "platform": "ios"}]"#)
        config.devices = iphoneConfig().devices
        let (known, runner) = try await invoke(
            ["provision", "--app", "myapp", "--device", "iphone"], config: config)
        #expect(known.errors.first?.code == "CONFIRM_REQUIRED")
        #expect(known.data["bundleId"] == "io.github.dividedby.free.myapp")
        #expect(runner.calls.isEmpty)
        let (unknown, _) = try await invoke(
            ["install", "--app", "nope", "--device", "iphone"], config: config)
        #expect(unknown.errors.first?.code == "USAGE")
        #expect(
            unknown.errors.first?.fix
                == "Use one of: stremio-ios, stremio-tvos, apollo, filler, myapp.")
        // A custom app has no fetch source yet.
        let (fetch, _) = try await invoke(["fetch", "--app", "myapp"], config: config)
        #expect(fetch.errors.first?.code == "SOURCE_NOT_ALLOWED")
    }

    @Test(
        "a custom app cannot be made lendable: lending backs up data that only built-ins keep findable"
    )
    func customNotLendable() async throws {
        var config = try makeConfig(customApps: #"[{"id": "myapp", "platform": "ios"}]"#)
        config.devices = iphoneConfig().devices
        let (out, runner) = try await invoke(
            ["device", "lendable", "--alias", "iphone", "--app", "myapp"], config: config)
        #expect(out.errors.first?.code == "USAGE")
        #expect(
            out.errors.first?.message == "myapp is a custom app; only built-in apps can be lent.")
        #expect(out.errors.first?.fix == "Use one of: stremio-ios, stremio-tvos, apollo, filler.")
        #expect(runner.calls.isEmpty)
        // A built-in still reaches the owner's confirm.
        let (builtIn, _) = try await invoke(
            ["device", "lendable", "--alias", "iphone", "--app", "apollo"], config: config)
        #expect(builtIn.errors.first?.code == "CONFIRM_REQUIRED")
    }

    @Test("status lists an ignored custom entry as a warning, and nothing when there is none")
    func statusWarnings() async throws {
        let bad = try makeConfig(customApps: #"[{"id": "apollo", "platform": "ios"}]"#)
        let (out, _) = try await invoke(["status"], config: bad)
        let codes = out.data["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
        #expect(out.ok && codes == ["CUSTOM_APP_IGNORED"])
        let (clean, _) = try await invoke(["status"], config: try makeConfig(customApps: nil))
        #expect(clean.data["warnings"] == [])
    }
}
