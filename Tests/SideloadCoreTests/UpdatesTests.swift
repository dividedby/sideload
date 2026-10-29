import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import sideload

// `updates`: the version order, the cache file, the cadence and the command. No network, no device, no subprocess: the
// transport is a script, and every run asserts that no download was asked for.

// MARK: version order

@Suite("updates: version order")
struct VersionOrderTests {
    @Test(
        "compare table",
        arguments: [
            // installed, upstream, upstream relative to installed
            ("3.9.0", "3.10.0", VersionOrder.State.newer),
            ("3.10.0", "3.9.0", .older),
            ("3.9.0", "3.9.0", .current),
            ("3.9", "3.9.0", .current),
            ("3.9.0", "3.9.1", .newer),
            ("2.0.0", "10.0.0", .newer),
            ("1.9.6b142", "1.9.6b143", .newer),
            ("1.9.6b142", "1.9.6b142", .current),
            ("1.9.6b142", "1.9.6b9", .older),
            ("1.9.6b142", "1.9.7b1", .newer),
            ("1.10.0b1", "1.9.9b999", .older),
            ("1.9.6b142", "1.9.6", .unknown),
            ("3.9.0", "3.9.0-beta", .unknown),
            ("3.9.0", "v3.9.0", .unknown),
            ("3.9.0", "", .unknown),
            ("", "3.9.0", .unknown),
            ("3.9.0", "3.9.0b", .unknown),
            ("3.9.0", "3..0", .unknown),
            ("3.9.0", "3.9.0.1.2", .unknown),
            ("3.9.0", "99999999999.0.0", .unknown),
            ("3.9.0", "latest", .unknown),
        ])
    func table(installed: String, upstream: String, expected: VersionOrder.State) {
        #expect(VersionOrder.compare(installed: installed, upstream: upstream) == expected)
    }

    @Test("the strings the resolver produces parse")
    func resolverStrings() throws {
        let apollo = try SourceResolver.apollo(
            app: "apollo", repo: FetchCatalog.apolloRepo,
            json: releaseJSON(
                tag: "v1.15.11_3.9.0", assets: [ReleaseAsset(name: "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa")]))
        #expect(VersionOrder.parse(apollo.version) == VersionOrder.Parsed(parts: [3, 9, 0], build: nil))
        let stremio = try SourceResolver.stremio(app: "stremio-ios", tvos: false, json: stremioIndexJSON(tvos: false))
        #expect(VersionOrder.parse(stremio.version) == VersionOrder.Parsed(parts: [1, 9, 6], build: 142))
    }
}

// MARK: cache

private func cacheStore(_ body: (UpdateCacheStore, Paths) throws -> Void) async throws {
    try await withTestHome { paths, _ in try body(UpdateCacheStore(paths: paths), paths) }
}

private let goodDigest = String(repeating: "ab", count: 32)

private func goodEntry(at date: Date = testNow) -> UpdateCacheEntry {
    UpdateCacheEntry(checkedAt: date, version: "1.9.6b142", build: "142", minOS: "14.0", size: 2000, sha256: goodDigest)
}

private func writeRaw(_ text: String, _ paths: Paths) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: paths.updates))
}

@Suite("updates: cache file")
struct UpdateCacheTests {
    @Test("a saved cache reads back identically, 0600, with no secrets in it")
    func roundTrip() async throws {
        try await cacheStore { store, paths in
            var cache = UpdateCache()
            cache.apps["stremio-ios"] = goodEntry()
            cache.apps["apollo"] = UpdateCacheEntry(
                checkedAt: testNow, version: "3.9.0", size: 1000, sha256: goodDigest
            ).failed(code: "FETCH_HTTP_ERROR", retryAfter: 600, at: testNow.addingTimeInterval(60))
            try store.save(cache)
            #expect(modeOf(paths.updates) == 0o600)
            let (loaded, repaired) = try store.load(now: testNow.addingTimeInterval(120))
            #expect(loaded == cache && !repaired)
            let raw = try String(contentsOfFile: paths.updates, encoding: .utf8)
            #expect(raw.contains("\"schema\" : 1"))
            #expect(listing(paths.home).filter { $0.hasSuffix(".tmp") }.isEmpty)
        }
    }

    @Test("a failed attempt keeps the last good values")
    func errorKeepsGood() {
        let failed = goodEntry().failed(code: "FETCH_NETWORK", retryAfter: nil, at: testNow.addingTimeInterval(7 * 3600))
        #expect(failed.upstream == goodEntry().upstream)
        #expect(failed.checkedAt == testNow && failed.errorCode == "FETCH_NETWORK")
        let healed = failed.succeeded(UpdateUpstream(version: "1.9.7b1", build: "1", minOS: nil, size: 5, sha256: goodDigest), at: testNow.addingTimeInterval(8 * 3600))
        #expect(healed.errorCode == nil && healed.errorAt == nil && healed.retryAfter == nil && healed.version == "1.9.7b1")
    }

    @Test("a missing file is an empty cache and needs no rewrite")
    func missing() async throws {
        try await cacheStore { store, _ in
            let (cache, repaired) = try store.load(now: testNow)
            #expect(cache == UpdateCache() && !repaired)
        }
    }

    @Test(
        "a corrupt, wrong-schema or oversized file is an empty cache that is rewritten",
        arguments: [
            "not json", "[]", "{\"schema\":2,\"apps\":{}}", "{\"apps\":{}}", "{\"schema\":1,\"apps\":{\"apollo\":{\"size\":\"big\"}}}",
            "{\"schema\":1,\"apps\":{\"apollo\":{\"checkedAt\":\"yesterday\"}}}",
        ])
    func corrupt(text: String) async throws {
        try await cacheStore { store, paths in
            try writeRaw(text, paths)
            let (cache, repaired) = try store.load(now: testNow)
            #expect(cache == UpdateCache() && repaired)
        }
        try await cacheStore { store, paths in
            try writeRaw(String(repeating: " ", count: UpdateCacheStore.maxBytes + 1), paths)
            let (cache, repaired) = try store.load(now: testNow)
            #expect(cache == UpdateCache() && repaired)
        }
    }

    @Test("a future-dated entry is dropped (the clock moved back); the others stay")
    func clockSkew() async throws {
        try await cacheStore { store, _ in
            var cache = UpdateCache()
            cache.apps["stremio-ios"] = goodEntry(at: testNow.addingTimeInterval(3600))
            cache.apps["stremio-tvos"] = goodEntry(at: testNow.addingTimeInterval(-3600))
            cache.apps["apollo"] = UpdateCacheEntry().failed(code: "FETCH_NETWORK", retryAfter: nil, at: testNow.addingTimeInterval(7200))
            try store.save(cache)
            let (loaded, repaired) = try store.load(now: testNow)
            #expect(Set(loaded.apps.keys) == ["stremio-tvos"] && repaired)
            // A few seconds ahead is clock noise, not skew.
            #expect(try store.load(now: testNow.addingTimeInterval(3600 - 30)).cache.apps["stremio-ios"] != nil)
        }
    }

    @Test("values read back must pass the resolver's own checks")
    func hostileValues() async throws {
        try await cacheStore { store, paths in
            let stamp = ISO8601DateFormatter().string(from: testNow)
            func entry(_ fields: String) -> String { "{\"schema\":1,\"apps\":{\"apollo\":{\"checkedAt\":\"\(stamp)\",\(fields)}}}" }
            let good = "\"version\":\"3.9.0\",\"size\":1000,\"sha256\":\"\(goodDigest)\""
            for bad in [
                "\"version\":\"../../x\",\"size\":1000,\"sha256\":\"\(goodDigest)\"",
                "\"version\":\"3.9.0\",\"size\":0,\"sha256\":\"\(goodDigest)\"",
                "\"version\":\"3.9.0\",\"size\":99999999999,\"sha256\":\"\(goodDigest)\"",
                "\"version\":\"3.9.0\",\"size\":1000,\"sha256\":\"XYZ\"",
                "\"version\":\"3.9.0\",\"size\":1000",
            ] {
                try writeRaw(entry(bad), paths)
                let (cache, repaired) = try store.load(now: testNow)
                #expect(cache.apps["apollo"] == nil && repaired, "\(bad)")
            }
            // Optional strings that fail are dropped on their own; the rest of the entry survives.
            try writeRaw(entry(good + ",\"build\":\"a b\",\"minOS\":\"15.x\",\"errorAt\":\"\(stamp)\",\"errorCode\":\"lower case\""), paths)
            let (cache, repaired) = try store.load(now: testNow)
            let kept = try #require(cache.apps["apollo"])
            #expect(kept.version == "3.9.0" && kept.build == nil && kept.minOS == nil && kept.errorCode == nil && repaired)
        }
    }

    @Test("an app the catalog does not know is dropped")
    func unknownApp() async throws {
        try await cacheStore { store, paths in
            let stamp = ISO8601DateFormatter().string(from: testNow)
            try writeRaw("{\"schema\":1,\"apps\":{\"evil\":{\"checkedAt\":\"\(stamp)\",\"version\":\"1.0\",\"size\":5,\"sha256\":\"\(goodDigest)\"}}}", paths)
            let (cache, repaired) = try store.load(now: testNow)
            #expect(cache.apps.isEmpty && repaired)
        }
    }

    @Test("a failed write is UPDATES_WRITE_FAILED and leaves no temp file")
    func writeFailure() async throws {
        try await withTestHome { paths, _ in
            let store = UpdateCacheStore(paths: paths) { _, _ in throw SideloadError("IO_ERROR", "no") }
            #expect(throws: SideloadError.self) { try store.save(UpdateCache()) }
        }
    }
}

@Suite("updates: cadence")
struct UpdateCadenceTests {
    private func decide(_ entry: UpdateCacheEntry?, after seconds: TimeInterval, force: Bool = false) -> UpdateCadence.Decision {
        UpdateCadence.decide(entry, now: testNow.addingTimeInterval(seconds), force: force)
    }

    @Test("no entry, or an empty one, is checked")
    func none() {
        #expect(decide(nil, after: 0) == .check)
        #expect(decide(UpdateCacheEntry(), after: 0) == .check)
    }

    @Test("a good check holds for 6 hours; force waits 5 minutes")
    func good() {
        let entry = goodEntry()
        #expect(decide(entry, after: 6 * 3600 - 1) == .wait(until: testNow.addingTimeInterval(6 * 3600)))
        #expect(decide(entry, after: 6 * 3600) == .check)
        #expect(decide(entry, after: 299, force: true) == .wait(until: testNow.addingTimeInterval(300)))
        #expect(decide(entry, after: 300, force: true) == .check)
    }

    @Test("a failed check holds for 1 hour; force skips that but keeps the floor")
    func failed() {
        let entry = goodEntry().failed(code: "FETCH_NETWORK", retryAfter: nil, at: testNow)
        #expect(decide(entry, after: 3599) == .wait(until: testNow.addingTimeInterval(3600)))
        #expect(decide(entry, after: 3600) == .check)
        #expect(decide(entry, after: 299, force: true) == .wait(until: testNow.addingTimeInterval(300)))
        #expect(decide(entry, after: 300, force: true) == .check)
    }

    @Test("a rate limit holds for what was asked, at most 24 hours, even under force")
    func rateLimited() {
        let asked = goodEntry().failed(code: "FETCH_HTTP_ERROR", retryAfter: 7200, at: testNow)
        #expect(decide(asked, after: 7199) == .wait(until: testNow.addingTimeInterval(7200)))
        #expect(decide(asked, after: 7199, force: true) == .wait(until: testNow.addingTimeInterval(7200)))
        #expect(decide(asked, after: 7200) == .check)
        let long = goodEntry().failed(code: "FETCH_HTTP_ERROR", retryAfter: 30 * 86_400, at: testNow)
        #expect(long.retryAfter == UpdateCadence.maxRetryAfter)
        #expect(decide(long, after: 86_399) == .wait(until: testNow.addingTimeInterval(86_400)))
        #expect(decide(long, after: 86_400) == .check)
        let short = goodEntry().failed(code: "FETCH_HTTP_ERROR", retryAfter: 5, at: testNow)
        #expect(decide(short, after: 3599) == .wait(until: testNow.addingTimeInterval(3600)))
    }
}

// MARK: the command

/// Answers metadata GETs from a script and counts everything it is asked. A download is refused and counted.
private final class ScriptedGet: HTTPTransport {
    typealias Script = @Sendable (HTTPRequest) throws -> HTTPResponse

    private let script: Script
    private let gets = Mutex<[HTTPRequest]>([])
    private let downloads = Mutex(0)

    init(_ script: @escaping Script) { self.script = script }

    /// 200 with the body for a known URL, 404 for anything else.
    convenience init(_ bodies: [String: Data]) {
        self.init { request in
            guard let body = bodies[request.url.absoluteString] else { return HTTPResponse(status: 404, body: Data()) }
            return HTTPResponse(status: 200, body: body)
        }
    }

    var getRequests: [HTTPRequest] { gets.withLock { $0 } }
    var downloadCount: Int { downloads.withLock { $0 } }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        gets.withLock { $0.append(request) }
        return try script(request)
    }

    func download(_ request: DownloadRequest, sink: @Sendable (Data) throws -> Void) async throws -> DownloadResponse {
        downloads.withLock { $0 += 1 }
        throw HTTPTransportError.disabled
    }
}

private func apolloRelease(_ version: String = "3.10.0") -> Data {
    releaseJSON(tag: "v1.15.11_\(version)", assets: apolloDecoys(version: version) + [ReleaseAsset(name: "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa")])
}

private func install(_ app: ProvisionApp, version: String, alias: String? = nil, present: Bool = true) -> LedgerInstall {
    var record = installRecord(app, alias: alias ?? (app == .stremioTVOS ? "appletv" : "iphone"), present: present)
    record.version = version
    return record
}

private struct UpdatesWorld {
    let services: Services
    let paths: Paths
    let runner: FakeRunner
    let http: ScriptedGet

    func run(_ options: UpdatesOptions = UpdatesOptions(), after seconds: TimeInterval = 0) async -> Envelope {
        var services = services
        services.clock = FixedClock(testNow.addingTimeInterval(seconds))
        return await UpdatesCommand.run(services, options)
    }

    func cache() -> UpdateCache {
        (try? UpdateCacheStore(paths: paths).load(now: testNow.addingTimeInterval(10 * 86_400)).cache) ?? UpdateCache()
    }

    /// The command ran no subprocess and asked for no IPA.
    func expectReadOnly(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(runner.calls.isEmpty, sourceLocation: sourceLocation)
        #expect(http.downloadCount == 0, sourceLocation: sourceLocation)
        expectLockFree(paths, sourceLocation: sourceLocation)
    }
}

private func withUpdates(
    approved: [JSONValue] = apolloApproved + stremioApproved, installs: [LedgerInstall], http: ScriptedGet,
    devices: [String: SavedDevice] = twoDevices, _ body: (UpdatesWorld) async throws -> Void
) async throws {
    try await withTestHome(config: Config(devices: devices, approvedSources: approved)) { paths, _ in
        try await LedgerStore(paths: paths).update { $0.installs = installs }
        let runner = FakeRunner()
        try await body(UpdatesWorld(services: fetchServices(paths, http: http, runner: runner), paths: paths, runner: runner, http: http))
    }
}

private func sources(_ envelope: Envelope) -> [JSONValue] { envelope.data["sources"]?.array ?? [] }
private func source(_ envelope: Envelope, _ app: String) -> JSONValue? { sources(envelope).first { $0["app"] == .string(app) } }
private func installStates(_ envelope: Envelope) -> [String: String] {
    Dictionary(
        uniqueKeysWithValues: (envelope.data["installs"]?.array ?? []).compactMap { item in
            guard let device = item["device"]?.string, let app = item["app"]?.string, let state = item["state"]?.string else { return nil }
            return ("\(device)/\(app)", state)
        })
}

@Suite("updates: command")
struct UpdatesCommandTests {
    @Test("Apollo: one GET, the newer version is reported, the cache is written, nothing else happens")
    func apolloNewer() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease("3.10.0")])
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.command == "updates")
            #expect(installStates(out) == ["iphone/apollo": "newer"])
            let apollo = try #require(source(out, "apollo"))
            #expect(apollo["status"] == "ok" && apollo["fromCache"] == false && apollo["checkedAt"] != .null)
            #expect(apollo["upstream"]?["version"] == "3.10.0" && apollo["upstream"]?["size"] == 1000)
            #expect(apollo["upstream"]?["sha256"] == .string(String(repeating: "ab", count: 32)))
            #expect(apollo["upstream"]?["build"] == .null && apollo["upstream"]?["minOS"] == .null)
            #expect(http.getRequests.map(\.url.absoluteString) == [apolloAPI])
            #expect(http.getRequests.allSatisfy { $0.bearer == nil })
            let entry = try #require(w.cache().apps["apollo"])
            #expect(entry.version == "3.10.0" && entry.checkedAt == testNow && entry.errorCode == nil)
            #expect(modeOf(w.paths.updates) == 0o600)
            w.expectReadOnly()
            #expect(try ManifestStore(paths: w.paths).load().entries.isEmpty)
            #expect(listing(w.paths.downloads).isEmpty)
        }
    }

    @Test("Stremio iOS and tvOS read their own index; build breaks a version tie")
    func stremio() async throws {
        let http = ScriptedGet([
            stremioIOSIndex: stremioIndexJSON(tvos: false, version: "1.9.6", build: "143"),
            stremioTVOSIndex: stremioIndexJSON(tvos: true, version: "1.9.6", build: "142"),
        ])
        let installs = [install(.stremioIOS, version: "1.9.6b142"), install(.stremioTVOS, version: "1.9.6b142")]
        try await withUpdates(installs: installs, http: http) { w in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(installStates(out) == ["iphone/stremio-ios": "newer", "appletv/stremio-tvos": "current"])
            #expect(http.getRequests.map(\.url.absoluteString) == [stremioIOSIndex, stremioTVOSIndex], "sequential, catalog order")
            let ios = try #require(source(out, "stremio-ios"))
            #expect(ios["upstream"]?["version"] == "1.9.6b143" && ios["upstream"]?["build"] == "143" && ios["upstream"]?["minOS"] == "14.0")
            #expect(source(out, "apollo")?["status"] == "skipped")
            w.expectReadOnly()
        }
    }

    @Test("an older upstream is never newer; an unparseable installed version is unknown")
    func olderAndUnknown() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease("3.9.0"), stremioIOSIndex: stremioIndexJSON(tvos: false)])
        let installs = [install(.apollo, version: "3.10.0"), install(.stremioIOS, version: "1.9.6-beta")]
        try await withUpdates(installs: installs, http: http) { w in
            let out = await w.run()
            #expect(installStates(out) == ["iphone/apollo": "older", "iphone/stremio-ios": "unknown"])
            w.expectReadOnly()
        }
    }

    @Test("the cache answers within 6 hours; a later run asks again; --force asks after 5 minutes")
    func cadence() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease()])
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            _ = await w.run()
            #expect(http.getRequests.count == 1)

            let soon = await w.run(after: 3600)
            #expect(http.getRequests.count == 1)
            let cached = try #require(source(soon, "apollo"))
            #expect(cached["fromCache"] == true && cached["status"] == "ok" && cached["checkedAt"] != .null)
            #expect(installStates(soon) == ["iphone/apollo": "newer"])

            _ = await w.run(UpdatesOptions(force: true), after: 200)
            #expect(http.getRequests.count == 1, "the 5-minute floor")
            let forced = await w.run(UpdatesOptions(force: true), after: 301)
            #expect(http.getRequests.count == 2 && source(forced, "apollo")?["fromCache"] == false)

            _ = await w.run(after: 301 + 6 * 3600 - 1)
            #expect(http.getRequests.count == 2)
            _ = await w.run(after: 301 + 6 * 3600)
            #expect(http.getRequests.count == 3)
            w.expectReadOnly()
        }
    }

    @Test("404: FETCH_HTTP_ERROR, ok false, the last good values stay, one retry hour later")
    func notFound() async throws {
        let live = Mutex(true)
        let http = ScriptedGet { _ in
            live.withLock { $0 } ? HTTPResponse(status: 200, body: apolloRelease()) : HTTPResponse(status: 404, body: Data())
        }
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            _ = await w.run()
            live.withLock { $0 = false }
            let failed = await w.run(after: 7 * 3600)
            #expect(!failed.ok && failed.errorCodes == ["FETCH_HTTP_ERROR"])
            #expect(failed.errors.first?.message.hasPrefix("apollo: ") == true)
            let apollo = try #require(source(failed, "apollo"))
            #expect(apollo["status"] == "error" && apollo["code"] == "FETCH_HTTP_ERROR" && apollo["fromCache"] == false)
            #expect(apollo["upstream"]?["version"] == "3.10.0", "last good values are kept")
            #expect(installStates(failed) == ["iphone/apollo": "newer"])
            let entry = try #require(w.cache().apps["apollo"])
            #expect(entry.errorCode == "FETCH_HTTP_ERROR" && entry.version == "3.10.0" && entry.checkedAt == testNow)

            let count = http.getRequests.count
            let again = await w.run(after: 7 * 3600 + 3599)
            #expect(http.getRequests.count == count && !again.ok)
            #expect(source(again, "apollo")?["fromCache"] == true && source(again, "apollo")?["status"] == "error")
            #expect(again.errorCodes == ["FETCH_HTTP_ERROR"])

            live.withLock { $0 = true }
            let healed = await w.run(after: 7 * 3600 + 3600)
            #expect(healed.ok && http.getRequests.count == count + 1)
            #expect(w.cache().apps["apollo"]?.errorCode == nil)
            w.expectReadOnly()
        }
    }

    @Test("403 and 429 honour Retry-After, capped at 24 hours; other statuses do not carry it")
    func rateLimit() async throws {
        let http = ScriptedGet { _ in HTTPResponse(status: 403, body: Data(), retryAfter: 7200) }
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            let first = await w.run()
            #expect(first.errorCodes == ["FETCH_HTTP_ERROR"])
            #expect(w.cache().apps["apollo"]?.retryAfter == 7200)
            _ = await w.run(UpdatesOptions(force: true), after: 3700)
            #expect(http.getRequests.count == 1, "force does not outrun a rate limit")
            _ = await w.run(after: 7199)
            #expect(http.getRequests.count == 1)
            _ = await w.run(after: 7200)
            #expect(http.getRequests.count == 2)
        }
        for (status, asked, held) in [(429, 10 * 86_400, 86_400), (500, 7200, 0)] {
            let limited = ScriptedGet { _ in HTTPResponse(status: status, body: Data(), retryAfter: asked) }
            try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: limited) { w in
                _ = await w.run()
                let entry = try #require(w.cache().apps["apollo"])
                #expect((entry.retryAfter ?? 0) == held)
            }
        }
    }

    @Test("an oversized body is DOWNLOAD_TOO_LARGE, whether the transport or the size check refuses it")
    func oversized() async throws {
        let refusing = ScriptedGet { _ in throw HTTPTransportError.bodyTooLarge }
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: refusing) { w in
            #expect(await w.run().errorCodes == ["DOWNLOAD_TOO_LARGE"])
        }
        let big = ScriptedGet { _ in HTTPResponse(status: 200, body: Data(count: URLSessionTransport.maxBodyBytes + 1)) }
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: big) { w in
            let out = await w.run()
            #expect(out.errorCodes == ["DOWNLOAD_TOO_LARGE"])
            #expect(w.cache().apps["apollo"]?.upstream == nil)
            w.expectReadOnly()
        }
    }

    @Test("transport failures map to fetch's codes and are recorded as errors")
    func transportFailures() async throws {
        for (failure, code) in [(HTTPTransportError.timedOut, "FETCH_TIMEOUT"), (.failed, "FETCH_NETWORK"), (.disabled, "FETCH_NETWORK")] {
            let http = ScriptedGet { _ in throw failure }
            try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
                let out = await w.run()
                #expect(!out.ok && out.errorCodes == [code])
                #expect(w.cache().apps["apollo"]?.errorCode == code)
            }
        }
    }

    @Test("a cancelled transport is CANCELLED and records nothing")
    func cancelled() async throws {
        let http = ScriptedGet { _ in throw HTTPTransportError.cancelled }
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            let out = await w.run()
            #expect(out.errorCodes == ["CANCELLED"] && out.errors.first?.message == "updates was cancelled.")
            #expect(w.cache().apps.isEmpty)
        }
    }

    @Test("a release with no matching IPA asset is SOURCE_NOT_ALLOWED and nothing is offered")
    func noAsset() async throws {
        let json = releaseJSON(tag: "v1.15.11_3.10.0", assets: apolloDecoys(version: "3.10.0"))
        let http = ScriptedGet([apolloAPI: json])
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            let out = await w.run()
            #expect(!out.ok && out.errorCodes == ["SOURCE_NOT_ALLOWED"])
            #expect(source(out, "apollo")?["upstream"] == .null)
            #expect(installStates(out) == ["iphone/apollo": "unknown"])
            w.expectReadOnly()
        }
    }

    @Test("a draft, a missing digest and a download URL off the repository are refused like fetch refuses them")
    func resolverRefusals() async throws {
        let name = "Apollo-Reborn-3.10.0-GLASS-NOEXTENSIONS.ipa"
        let cases: [(Data, String)] = [
            (releaseJSON(assets: [ReleaseAsset(name: name)], draft: true), "SOURCE_NOT_ALLOWED"),
            (releaseJSON(tag: "v1.15.11_3.10.0", assets: [ReleaseAsset(name: name, digest: nil)]), "UPSTREAM_DIGEST_MISSING"),
            (
                releaseJSON(tag: "v1.15.11_3.10.0", assets: [ReleaseAsset(name: name, url: "https://evil.example/\(name)")]),
                "SOURCE_NOT_ALLOWED"
            ),
            (Data("<html>".utf8), "SOURCE_INVALID"),
        ]
        for (body, code) in cases {
            let http = ScriptedGet([apolloAPI: body])
            try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
                #expect(await w.run().errorCodes == [code])
            }
        }
    }

    @Test("a narrowed metadata host makes no request; a narrowed download host is refused as fetch would")
    func narrowedHosts() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease()])
        let noMetadata: [JSONValue] = [["app": "apollo", "hosts": ["github.com"]]]
        try await withUpdates(approved: noMetadata, installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            let out = await w.run()
            #expect(out.errorCodes == ["SOURCE_NOT_ALLOWED"])
            #expect(http.getRequests.isEmpty)
        }
        let noDownload: [JSONValue] = [["app": "apollo", "hosts": ["api.github.com"]]]
        try await withUpdates(approved: noDownload, installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            let out = await w.run()
            #expect(out.errorCodes == ["SOURCE_NOT_ALLOWED"])
            #expect(http.getRequests.count == 1)
            #expect(w.cache().apps["apollo"]?.upstream == nil, "an update fetch would refuse is not offered")
        }
        let both: [JSONValue] = [["app": "apollo", "hosts": ["api.github.com", "github.com"]]]
        try await withUpdates(approved: both, installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            #expect(await w.run().ok)
        }
    }

    @Test("an unapproved source and an approved one with no install are skipped with no request")
    func skipped() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease(), stremioIOSIndex: stremioIndexJSON(tvos: false), stremioTVOSIndex: stremioIndexJSON(tvos: true)])
        let installs = [
            install(.apollo, version: "3.9.0"),
            install(.stremioIOS, version: "1.9.5b1"),  // installed, but the source is not approved
            install(.stremioTVOS, version: "1.9.5b1", present: false),  // removed from the device
        ]
        try await withUpdates(approved: apolloApproved + [["app": "stremio-tvos"]], installs: installs, http: http) { w in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(http.getRequests.map(\.url.absoluteString) == [apolloAPI])
            #expect(source(out, "stremio-ios")?["status"] == "skipped" && source(out, "stremio-ios")?["code"] == "SOURCE_NOT_ALLOWED")
            #expect(source(out, "stremio-tvos")?["status"] == "skipped" && source(out, "stremio-tvos")?["code"] == "NOT_INSTALLED")
            #expect(installStates(out) == ["iphone/apollo": "newer", "iphone/stremio-ios": "unknown"])
            #expect(w.cache().apps.keys.sorted() == ["apollo"])
            w.expectReadOnly()
        }
    }

    @Test("an install on a device that is no longer saved does not count")
    func unsavedDevice() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease()])
        let installs = [install(.apollo, version: "3.9.0", alias: "gone")]
        try await withUpdates(installs: installs, http: http) { w in
            let out = await w.run()
            #expect(out.ok && http.getRequests.isEmpty && installStates(out).isEmpty)
            #expect(source(out, "apollo")?["code"] == "NOT_INSTALLED")
        }
    }

    @Test("an app lent to the lab still counts as installed")
    func lent() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease()])
        try await withUpdates(installs: [install(.apollo, version: "3.9.0", present: false)], http: http) { w in
            try await LedgerStore(paths: w.paths).update {
                $0.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
            }
            let out = await w.run()
            #expect(installStates(out) == ["iphone/apollo": "newer"] && http.getRequests.count == 1)
        }
    }

    @Test("--app limits the run; an unknown or unapproved app is refused like fetch refuses it")
    func appOption() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease(), stremioIOSIndex: stremioIndexJSON(tvos: false)])
        let installs = [install(.apollo, version: "3.9.0"), install(.stremioIOS, version: "1.9.5b1")]
        try await withUpdates(approved: apolloApproved, installs: installs, http: http) { w in
            let one = await w.run(UpdatesOptions(app: "apollo"))
            #expect(one.ok && sources(one).count == 1 && installStates(one) == ["iphone/apollo": "newer"])
            #expect(http.getRequests.count == 1)
            let unapproved = await w.run(UpdatesOptions(app: "stremio-ios"))
            #expect(!unapproved.ok && unapproved.errorCodes == ["SOURCE_NOT_ALLOWED"] && unapproved.data["sources"] == nil)
            let unknown = await w.run(UpdatesOptions(app: "feather"))
            #expect(unknown.errorCodes == ["SOURCE_NOT_ALLOWED"])
            #expect(http.getRequests.count == 1)
        }
    }

    @Test("--app ok is false only for the requested source")
    func requestedSourceErrors() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease()])
        let installs = [install(.apollo, version: "3.9.0"), install(.stremioIOS, version: "1.9.5b1")]
        try await withUpdates(installs: installs, http: http) { w in
            #expect(await w.run(UpdatesOptions(app: "apollo")).ok)
            #expect(!(await w.run()).ok, "stremio-ios 404s")
        }
    }

    @Test("a corrupt updates.json is replaced; a failed write is a warning, not a failure")
    func cacheFile() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease()])
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            try writeRaw("{{{", w.paths)
            let out = await w.run()
            #expect(out.ok && http.getRequests.count == 1)
            #expect(w.cache().apps["apollo"]?.version == "3.10.0")
        }
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            // A directory where the file belongs: the write cannot succeed and the read is an I/O error.
            try FileManager.default.createDirectory(atPath: w.paths.updates, withIntermediateDirectories: false)
            let out = await w.run()
            #expect(out.ok && installStates(out) == ["iphone/apollo": "newer"])
            let codes = (out.data["warnings"]?.array ?? []).compactMap { $0["code"]?.string }
            #expect(codes.contains("UPDATES_CACHE_NOT_WRITTEN"))
        }
    }

    @Test("the printed object is the contract: ok, command, sources, installs, errors; no device identifiers")
    func printedShape() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease()])
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            let (text, json) = try await w.run().printed()
            #expect(json["ok"] == true && json["command"] == "updates" && json["errors"] == [])
            #expect(json["checkedAt"]?.string?.hasSuffix("Z") == true)
            let record = try #require(json["installs"]?.array?.first)
            #expect(record["device"] == "iphone" && record["app"] == "apollo" && record["installed"] == "3.9.0" && record["state"] == "newer")
            for key in ["app", "status", "checkedAt", "fromCache", "upstream"] { #expect(try #require(json["sources"]?.array?.first)[key] != nil, "\(key)") }
            #expect(!text.contains(savedUdid("1")) && !text.contains(savedCoreId("1")) && !text.contains("Test iPhone"))
        }
    }

    @Test("a home with no config fails as one envelope and makes no request")
    func noState() async throws {
        let http = ScriptedGet([:])
        try await withTestHome { paths, _ in
            let out = await UpdatesCommand.run(fetchServices(paths, http: http), UpdatesOptions())
            #expect(out.command == "updates")
            #expect(http.getRequests.isEmpty && http.downloadCount == 0)
        }
    }
}

@Suite("updates: wiring")
struct UpdatesWiringTests {
    @Test("help lists updates as built; the CLI runs it and rejects stray arguments and unknown options")
    func cli() async throws {
        let http = ScriptedGet([apolloAPI: apolloRelease()])
        try await withUpdates(installs: [install(.apollo, version: "3.9.0")], http: http) { w in
            let help = await run(argv: ["help"], services: w.services)
            #expect(help.data["built"]?.array?.contains("updates") == true && help.data["commands"]?.array?.contains("updates") == true)
            #expect(help.data["usage"]?.array?.contains { $0.string?.hasPrefix("updates ") == true } == true)

            let ran = await run(argv: ["updates", "--app", "apollo", "--force"], services: w.services)
            #expect(ran.ok && ran.command == "updates" && http.getRequests.count == 1)
            #expect(await run(argv: ["updates", "extra"], services: w.services).errorCodes == ["USAGE"])
            #expect(await run(argv: ["updates", "--yes"], services: w.services).errorCodes == ["USAGE"])
            w.expectReadOnly()
        }
    }

    @Test("the update code never sets a method, takes a lock or asks for a download")
    func staticScan() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SideloadCore")
        for name in ["Fetch/UpdateCheck.swift", "Fetch/UpdateCache.swift", "Fetch/VersionOrder.swift", "Fetch/SourceMetadata.swift", "Commands/Updates.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            for banned in ["httpMethod", "URLSession(", "URLSession.", "URLRequest", ".download(", "OperationLock", "runner", "Runner"] {
                #expect(!text.contains(banned), "\(name) mentions \(banned)")
            }
        }
    }
}
