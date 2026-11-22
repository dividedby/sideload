import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// The one-time migration of the former built-in sources (apollo, stremio-ios, stremio-tvos) into `customSources` (design
// section 8, "Migration"): a pure function at load, persisted by the next config write; the pending warning; the restore
// through `source add`; and the bundle-ID pins the three now have. Offline: temp homes, fakes and a scripted transport.

private let apolloName = "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa"

/// A pre-upgrade `config.json`: written as the old build wrote it, with no marker and no source entries.
private func withLegacyHome(
    approved: [JSONValue] = apolloApproved + stremioApproved, extra: [String: JSONValue] = [:],
    _ body: (Paths, Services) async throws -> Void
) async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = Paths(home: dir.path)
    try paths.ensureHome()
    let config = Config(
        devices: iphoneConfig().devices, approvedSources: approved, bundleIdPrefix: customPrefix,
        extra: extra)
    try AtomicFile.write(try config.encoded(), to: paths.config)
    try await body(paths, fetchServices(paths, http: SourceHTTP()))
}

private func fileConfig(_ paths: Paths) throws -> Config {
    try Config.parse(try configBytes(paths))
}

private func sourceEntries(_ config: Config) -> [JSONValue] {
    config.extra["customSources"]?.array ?? []
}

private func apps(_ entries: [JSONValue]) -> [String] {
    entries.compactMap { SourceAdd.field($0, "app") }
}

private func warningCodes(_ envelope: Envelope) throws -> [String] {
    try envelope.printed().json["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
}

@Suite("migration: the function")
struct BuiltInMigrationFunctionTests {
    @Test("a config with no marker gets the three entries and the marker, in a fixed order")
    func adds() {
        var config = Config()
        #expect(BuiltInSources.migrate(&config))
        #expect(apps(sourceEntries(config)) == ["apollo", "stremio-ios", "stremio-tvos"])
        #expect(config.extra[BuiltInSources.markerKey] == true)
        #expect(sourceEntries(config) == BuiltInSources.definitions.map(\.entry))
        #expect(config.approvedSources.isEmpty, "an approval is never added")
    }

    @Test("a second run changes nothing")
    func idempotent() {
        var config = Config()
        BuiltInSources.migrate(&config)
        let once = config
        #expect(!BuiltInSources.migrate(&config))
        #expect(config == once)
    }

    @Test(
        "a source removed after the marker exists is not brought back",
        arguments: ["apollo", "stremio-ios", "stremio-tvos"])
    func notResurrected(removed: String) {
        var config = Config()
        BuiltInSources.migrate(&config)
        config.extra["customSources"] = .array(
            sourceEntries(config).filter { SourceAdd.field($0, "app") != removed })
        #expect(!BuiltInSources.migrate(&config))
        #expect(!apps(sourceEntries(config)).contains(removed))
        #expect(config.appRegistry.app(removed)?.fetch == nil)
        #expect(config.appRegistry.fetchSources.count == 2)
    }

    @Test("any marker value counts as done")
    func anyMarkerValue() {
        var config = Config(extra: [BuiltInSources.markerKey: "yes"])
        #expect(!BuiltInSources.migrate(&config))
        #expect(config.extra["customSources"] == nil)
    }

    @Test("an app that already has an entry, valid or not, keeps it and gets no second one")
    func existingEntryKept() {
        let mine: JSONValue = ["app": "apollo", "kind": "nonsense"]
        var config = Config(extra: ["customSources": [mine]])
        #expect(BuiltInSources.migrate(&config))
        #expect(
            apps(sourceEntries(config)) == ["apollo", "stremio-ios", "stremio-tvos"]
                && sourceEntries(config)[0] == mine)
    }

    @Test("a customSources that is not an array is left alone and gets no marker")
    func notAnArray() {
        var config = Config(extra: ["customSources": "oops"])
        #expect(!BuiltInSources.migrate(&config))
        #expect(
            config.extra[BuiltInSources.markerKey] == nil && config.extra["customSources"] == "oops"
        )
    }

    @Test("the migrated sources are the old built-ins': same addresses, hosts and pins")
    func sameSources() throws {
        let sources = Config().appRegistry.fetchSources
        #expect(sources.map(\.app) == ["apollo", "stremio-ios", "stremio-tvos"])
        #expect(sources[0].metadataURL.absoluteString == apolloAPI)
        #expect(sources[1].metadataURL.absoluteString == stremioIOSIndex)
        #expect(sources[2].metadataURL.absoluteString == stremioTVOSIndex)
        #expect(sources[0].kind.pinnedBundleId == "com.christianselig.Apollo")
        #expect(sources[0].kind.tagRule == .underscoreSuffix)
        #expect(sources[2].kind.downloadPath == "/apple/{versionKey}/tvos/stremio_tvOS.ipa")
        #expect(sources[1].kind.downloadPath == nil && sources[1].kind.requiresBuild)
        #expect(
            sources[1].downloadHosts == ["dl.strem.io"]
                && sources[2].downloadHosts == ["dl.strem.io"])
        #expect(
            Set(sources.flatMap { $0.downloadHosts.union($0.metadataHosts) }) == [
                "api.github.com", "github.com", "objects.githubusercontent.com",
                "release-assets.githubusercontent.com", "raw.githubusercontent.com", "dl.strem.io",
            ], "no host the old built-ins did not have")
    }

    @Test("approval is untouched: approved, unapproved and host-narrowed all stay as they were")
    func approvalCopiedExactly() throws {
        let approved: [JSONValue] = [
            ["app": "apollo", "hosts": ["api.github.com", "github.com"]], ["app": "stremio-tvos"],
        ]
        var config = Config(approvedSources: approved)
        BuiltInSources.migrate(&config)
        #expect(config.approvedSources == approved)
        let narrowed = try FetchCatalog.approved(app: "apollo", config: config)
        #expect(
            narrowed.downloadHosts == ["github.com"] && narrowed.metadataHosts == ["api.github.com"]
        )
        _ = try FetchCatalog.approved(app: "stremio-tvos", config: config)
        #expect(throws: SideloadError.self) {
            try FetchCatalog.approved(app: "stremio-ios", config: config)
        }
    }
}

@Suite("migration: persistence and reporting")
struct BuiltInMigrationPersistenceTests {
    @Test("a missing config.json yields the sources, no warning and no file")
    func freshHome() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(home: dir.path)
        let loaded = try ConfigStore(paths: paths).loadReporting()
        #expect(!loaded.migrationPending && loaded.config.appRegistry.fetchSources.count == 3)
        #expect(!FileManager.default.fileExists(atPath: paths.config))
    }

    @Test("status, source list and updates never write and each report BUILT_IN_SOURCES_MIGRATED")
    func readOnlyCommands() async throws {
        try await withLegacyHome { paths, services in
            let before = try configBytes(paths)
            let status = StatusCommand.run(services)
            let list = await source(["list"], services)
            let updates = await UpdatesCommand.run(services, UpdatesOptions())
            #expect(try configBytes(paths) == before, "the config is byte for byte the same")
            for out in [status, list, updates] {
                #expect(try warningCodes(out).contains(BuiltInSources.warningCode))
            }
            let sources = try #require(try list.printed().json["sources"]?.array)
            #expect(
                sources.compactMap { $0["app"]?.string } == [
                    "apollo", "stremio-ios", "stremio-tvos",
                ])
            #expect(sources.allSatisfy { $0["builtIn"] == true && $0["approved"] == true })
            #expect(try fileConfig(paths).extra[BuiltInSources.markerKey] == nil)
        }
    }

    @Test(
        "the first config write persists the entries and the marker together, and the warning goes")
    func firstWritePersists() async throws {
        try await withLegacyHome { paths, services in
            try await services.store.update { $0.lastNotified["x"] = 1 }
            let written = try fileConfig(paths)
            #expect(written.extra[BuiltInSources.markerKey] == true)
            #expect(sourceEntries(written) == BuiltInSources.definitions.map(\.entry))
            #expect(written.approvedSources == apolloApproved + stremioApproved)
            let again = try await services.store.loadReporting()
            #expect(!again.migrationPending)
            let list = await source(["list"], services)
            #expect(try !warningCodes(list).contains(BuiltInSources.warningCode))
            // A second write leaves the sources and the marker as they are.
            let bytes = try configBytes(paths)
            try await services.store.update { _ in }
            #expect(try configBytes(paths) == bytes)
        }
    }

    @Test("status --notify persists the migration even with nothing to announce")
    func notifyNudge() async throws {
        try await withLegacyHome { paths, services in
            let out = await StatusCommand.runNotify(services)
            let marker = try fileConfig(paths).extra[BuiltInSources.markerKey]
            let codes = try warningCodes(out)
            #expect(marker == true)
            #expect(!codes.contains(BuiltInSources.warningCode))
        }
    }

    @Test(
        "source remove --yes as the first write keeps the other two and the marker; the removed one stays removed"
    )
    func removeFirst() async throws {
        try await withLegacyHome { paths, services in
            let out = await source(["remove", "--app", "stremio-tvos", "--yes"], services)
            #expect(out.ok, "\(out.errors)")
            let json = try out.printed().json
            #expect(json["wrote"]?["customSources"] == 1 && json["wrote"]?["approvedSources"] == 1)
            let written = try fileConfig(paths)
            #expect(apps(sourceEntries(written)) == ["apollo", "stremio-ios"])
            #expect(written.extra[BuiltInSources.markerKey] == true)
            #expect(written.approvedSources == apolloApproved + [["app": "stremio-ios"]])
            #expect(try loadConfig(paths).appRegistry.app("stremio-tvos")?.fetch == nil)
        }
    }

    @Test("the printed restore command is the exact one, and the preview of a remove carries it")
    func removePrintsRestore() async throws {
        try await withLegacyHome { _, services in
            for definition in BuiltInSources.definitions {
                let preview = try await source(["remove", "--app", definition.app], services)
                    .printed().json
                #expect(preview["readd"] == .string(definition.readd))
                #expect(preview["next"]?.string?.contains(definition.readd) == true)
            }
            let ok = await source(["remove", "--app", "filler"], services)
            #expect(ok.errorCodes == ["SOURCE_NOT_FOUND"])
        }
    }

    @Test("a removed source: the app stays, and fetch and updates no longer know it")
    func removedSource() async throws {
        try await withLegacyHome { paths, services in
            #expect(await source(["remove", "--app", "apollo", "--yes"], services).ok)
            let config = try loadConfig(paths)
            #expect(config.appRegistry.app("apollo") != nil)
            let fetched = await FetchCommand.run(
                services, FetchOptions(app: "apollo"), registry: ScratchRegistry())
            #expect(fetched.firstCode == "SOURCE_NOT_ALLOWED")
            let updates = await UpdatesCommand.run(services, UpdatesOptions(app: "apollo"))
            #expect(updates.firstCode == "SOURCE_NOT_ALLOWED")
            #expect(FetchCatalog.appNames(config) == ["stremio-ios", "stremio-tvos"])
        }
    }
}

@Suite("migration: restoring a default source with source add")
struct BuiltInRestoreTests {
    private func args(_ readd: String) -> [String] {
        Array(
            readd.replacingOccurrences(of: "'", with: "").split(separator: " ").dropFirst(2).map(
                String.init))
    }

    private func documents() -> SourceHTTP {
        SourceHTTP([
            apolloAPI: releaseJSON(assets: [ReleaseAsset(name: apolloName)]),
            stremioIOSIndex: stremioIndexJSON(tvos: false),
            stremioTVOSIndex: stremioIndexJSON(tvos: true),
        ])
    }

    @Test(
        "each default is added back as an attach: the entry is the migrated one plus addedAt, and approved again",
        arguments: BuiltInSources.definitions.map(\.app))
    func restore(app: String) async throws {
        let definition = try #require(BuiltInSources.definitions.first { $0.app == app })
        try await withLegacyHome { paths, _ in
            let services = fetchServices(paths, http: documents())
            #expect(
                await source(
                    [
                        "add", "--url", "https://github.com/Apollo-Reborn/Apollo-Reborn", "--app",
                        app,
                    ], services
                ).errorCodes == ["SOURCE_EXISTS"])
            #expect(await source(["remove", "--app", app, "--yes"], services).ok)

            let preview = await source(args(definition.readd), services)
            #expect(preview.ok, "\(preview.errors)")
            let json = try preview.printed().json
            #expect(json["app"]?["exists"] == true && json["app"]?["id"] == .string(app))
            let confirm = try #require(json["confirm"]?.string)
            let added = await source(
                args(definition.readd) + ["--confirm", confirm, "--yes"], services)
            #expect(added.ok, "\(added.errors)")
            #expect(try added.printed().json["wrote"]?["customApps"] == false)

            let config = try loadConfig(paths)
            var entry = try #require(
                sourceEntries(config).first { SourceAdd.field($0, "app") == app }
            ).object
            #expect(entry?["addedAt"] != nil)
            entry?["addedAt"] = nil
            #expect(entry.map(JSONValue.object) == definition.entry)
            #expect(config.approvedSources.filter { SourceAdd.field($0, "app") == app }.count == 1)
            #expect(config.appRegistry.app(app)?.fetch != nil)
        }
    }

    @Test(
        "an attach to a built-in app takes the app's platform, refuses --name, and never the filler"
    )
    func attachRules() async throws {
        try await withLegacyHome { paths, _ in
            let services = fetchServices(paths, http: documents())
            #expect(await source(["remove", "--app", "apollo", "--yes"], services).ok)
            let url = "https://github.com/Apollo-Reborn/Apollo-Reborn"
            let asset = "Apollo-Reborn-{version}-GLASS-NOEXTENSIONS.ipa"
            let base = [
                "add", "--url", url, "--app", "apollo", "--asset", asset, "--tag-rule",
                "underscoreSuffix",
            ]
            #expect(
                await source(base + ["--platform", "tvos"], services).errorCodes == ["APP_EXISTS"])
            #expect(
                await source(base + ["--name", "Other"], services).errorCodes == [
                    "INVALID_ARGUMENT"
                ])
            #expect(await source(base + ["--platform", "ios"], services).ok)
            let filler = await source(base.map { $0 == "apollo" ? "filler" : $0 }, services)
            #expect(filler.errorCodes == ["APP_EXISTS"])
        }
    }
}

@Suite("migration: the bundle-ID pins")
struct BuiltInBundlePinTests {
    private func fetch(
        _ paths: Paths, _ http: any HTTPTransport, app: String, approve: String? = nil
    )
        async -> Envelope
    {
        await FetchCommand.run(
            fetchServices(paths, http: http, runner: RecordingRunner()),
            FetchOptions(app: app, approve: approve != nil, version: approve),
            registry: ScratchRegistry())
    }

    @Test(
        "Apollo's pin is com.christianselig.Apollo from the first fetch; another app's IPA is refused"
    )
    func apolloPinned() async throws {
        let apollo = try await SampleIPAs.shared.data("apollo")
        let other = try await SampleIPAs.shared.data("plain")
        try await withLegacyHome { paths, _ in
            let refused = await fetch(paths, apolloTransport(ipa: other), app: "apollo")
            #expect(refused.firstCode == "BUNDLE_ID_MISMATCH")
            #expect(try ManifestStore(paths: paths).load().entries.isEmpty)
            let ok = await fetch(paths, apolloTransport(ipa: apollo), app: "apollo")
            #expect(ok.ok, "\(ok.errors)")
            let entry = try #require(
                try ManifestStore(paths: paths).load().entry(app: "apollo", version: "3.9.0"))
            #expect(entry.bundleId == "com.christianselig.Apollo")
        }
    }

    @Test("a Stremio IPA with another bundle ID is refused, on both platforms")
    func stremioPinned() async throws {
        let other = try await SampleIPAs.shared.data("plain")
        try await withLegacyHome { paths, _ in
            for (app, tvos) in [("stremio-ios", false), ("stremio-tvos", true)] {
                let out = await fetch(paths, stremioTransport(tvos: tvos, ipa: other), app: app)
                #expect(out.firstCode == "BUNDLE_ID_MISMATCH", Comment(rawValue: app))
            }
            let stored = try ManifestStore(paths: paths).load().entries
            #expect(stored.isEmpty)
        }
    }

    @Test("a Stremio IPA with com.stremio.pal is stored with its bundle ID")
    func stremioRecorded() async throws {
        let ipa = try await SampleIPAs.shared.data("withExtension")
        try await withLegacyHome { paths, _ in
            let out = await fetch(
                paths, stremioTransport(tvos: false, ipa: ipa), app: "stremio-ios")
            #expect(out.ok, "\(out.errors)")
            let entry = try #require(try ManifestStore(paths: paths).load().entries.first)
            #expect(entry.bundleId == "com.stremio.pal")
        }
    }

    @Test(
        "an unpinned built-in GitHub source skips approved entries with no recorded bundle ID, then pins the first that has one"
    )
    func legacyEntriesSkipped() async throws {
        let apollo = try await SampleIPAs.shared.data("apollo")
        let other = try await SampleIPAs.shared.data("plain")
        // The source as `source add` without --bundle would leave it: no pin in the entry.
        var unpinned = BuiltInSources.definitions[0].entry.object ?? [:]
        unpinned["bundleId"] = nil
        try await withLegacyHome(
            approved: apolloApproved,
            extra: [
                "customSources": .array([.object(unpinned)]), BuiltInSources.markerKey: true,
            ]
        ) { paths, _ in
            let store = ManifestStore(paths: paths)
            // 3.8.0 was fetched and approved by the old build: no bundle ID recorded.
            #expect(
                await fetch(paths, apolloTransport(ipa: apollo, version: "3.8.0"), app: "apollo").ok
            )
            #expect(
                await fetch(
                    paths, apolloTransport(ipa: apollo, version: "3.8.0"), app: "apollo",
                    approve: "3.8.0"
                ).ok)
            var manifest = try store.load()
            var legacy = try #require(manifest.entry(app: "apollo", version: "3.8.0"))
            #expect(legacy.approved)
            legacy.bundleId = nil
            manifest.upsert(legacy)
            try store.save(manifest)

            let next = await fetch(
                paths, apolloTransport(ipa: apollo, version: "3.9.0"), app: "apollo")
            #expect(next.ok, "the legacy entry does not refuse: \(next.errors)")
            #expect(
                try store.load().entry(app: "apollo", version: "3.9.0")?.bundleId
                    == "com.christianselig.Apollo")
            #expect(
                await fetch(
                    paths, apolloTransport(ipa: apollo, version: "3.9.0"), app: "apollo",
                    approve: "3.9.0"
                ).ok)

            let swapped = await fetch(
                paths, apolloTransport(ipa: other, version: "3.9.1"), app: "apollo")
            #expect(swapped.firstCode == "BUNDLE_ID_MISMATCH")
            #expect(
                swapped.errors.first?.message.contains(
                    "pinned for apollo (com.christianselig.Apollo)") == true)
        }
    }
}

private extension JSONValue {
    var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
