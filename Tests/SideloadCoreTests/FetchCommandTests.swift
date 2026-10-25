import Darwin
import Foundation
import Testing

@testable import SideloadCore

private let evil = URL(string: "https://evil.example/stremio_tvOS.ipa")!

/// Runs `fetch` over a temp home and hands the finished state to `check` before the home is removed.
private func withFetch(
    _ options: FetchOptions, config: [JSONValue] = apolloApproved + stremioApproved, http: any HTTPTransport,
    runner: any Runner = FakeRunner(), prepare: (Paths) throws -> Void = { _ in },
    check: (Envelope, Paths, Services) async throws -> Void
) async throws {
    try await withTestHome(config: Config(approvedSources: config)) { paths, _ in
        try prepare(paths)
        let services = fetchServices(paths, http: http, runner: runner)
        let envelope = await FetchCommand.run(services, options, registry: ScratchRegistry())
        try await check(envelope, paths, services)
    }
}

private func nothingKept(_ paths: Paths, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(partFiles(paths).isEmpty, "no download file is left in tmp", sourceLocation: sourceLocation)
    #expect(scratchFolders(paths).isEmpty, sourceLocation: sourceLocation)
    #expect(listing(paths.downloads).isEmpty, "nothing under downloads/", sourceLocation: sourceLocation)
    #expect(try ManifestStore(paths: paths).load().entries.isEmpty, "no manifest entry", sourceLocation: sourceLocation)
}

@Suite("fetch: download and record")
struct FetchDownloadTests {
    @Test("Apollo: downloads the exact asset, verifies it, inspects it and records an unapproved manifest entry")
    func apollo() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let transport = apolloTransport(ipa: ipa)
        try await withFetch(FetchOptions(app: "apollo"), http: transport, runner: RecordingRunner(), prepare: { paths in
            // A part file from an interrupted run is swept (the operation lock means nobody else owns it).
            FileManager.default.createFile(atPath: paths.tmp + "/fetch-stale.part", contents: Data("x".utf8))
        }) { envelope, paths, _ in
            #expect(envelope.ok, "\(envelope.errors)")
            let json = try envelope.printed().json
            #expect(json["app"] == "apollo")
            #expect(json["version"] == "3.9.0")
            #expect(json["downloaded"] == true && json["approved"] == false)
            #expect(json["sha256"] == .string(sha256Hex(ipa)))
            #expect(json["upstreamDigest"] == .string(sha256Hex(ipa)))
            #expect(json["file"] == "apollo/3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa")
            #expect(json["urlHost"] == "github.com")
            #expect(json["next"]?.string?.contains("--approve") == true)

            // The file is where the manifest says, byte for byte, owner-only.
            let stored = paths.downloads + "/apollo/3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa"
            #expect(try Data(contentsOf: URL(fileURLWithPath: stored)) == ipa)
            #expect(modeOf(stored) == 0o600)
            #expect(modeOf(paths.downloads + "/apollo/3.9.0") == 0o700)
            #expect(partFiles(paths).isEmpty && scratchFolders(paths).isEmpty)

            // Exactly one metadata GET (no token) and one download, both inside the allowlist.
            let gets = transport.getRequests
            #expect(gets.count == 1 && gets[0].url.absoluteString == apolloAPI && gets[0].bearer == nil)
            let downloads = transport.downloadRequests
            #expect(downloads.count == 1)
            #expect(downloads[0].allowedHosts == ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"])
            #expect(downloads[0].maxBytes == Int64(ipa.count), "the cap is the size the release declares")
            #expect(downloads[0].maxRedirects == FetchLimits.maxRedirects && downloads[0].timeout > 0)

            // The lock is free again.
            let lock = try OperationLock.acquire(paths: paths)
            lock.release()
        }
    }

    @Test("the manifest records app, version, host, hashes, size, time and approved:false")
    func manifestRecord() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withFetch(FetchOptions(app: "apollo"), http: apolloTransport(ipa: ipa), runner: RecordingRunner()) { envelope, paths, _ in
            #expect(envelope.ok)
            let manifest = try ManifestStore(paths: paths).load()
            let entry = try #require(manifest.entries.first)
            #expect(manifest.entries.count == 1 && manifest.schema == 1)
            #expect(entry.app == "apollo" && entry.version == "3.9.0")
            #expect(entry.file == "apollo/3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa")
            #expect(entry.urlHost == "github.com")
            #expect(entry.sha256 == sha256Hex(ipa) && entry.upstreamDigest == sha256Hex(ipa))
            #expect(entry.size == Int64(ipa.count))
            #expect(entry.fetchedAt == testNow)
            #expect(entry.approved == false && entry.approvedAt == nil)
            #expect(modeOf(paths.manifest) == 0o600)
            // Apollo declares no minimum OS; the build and the OS floor come from inspect.
            #expect(entry.declaredSize == Int64(ipa.count) && entry.size == entry.declaredSize)
            #expect(entry.minOS == nil)
            #expect(entry.inspectMinOS == "15.0" && entry.build == "45")

            // On disk as plain JSON with the documented keys.
            let raw = try decodeJSON(String(decoding: try Data(contentsOf: URL(fileURLWithPath: paths.manifest)), as: UTF8.self))
            let first = try #require(raw["entries"]?.array?.first)
            for key in ["app", "version", "file", "urlHost", "sha256", "upstreamDigest", "size", "fetchedAt", "approved"] {
                #expect(first[key] != nil, "\(key)")
            }
            #expect(first["approved"] == false)
        }
    }

    @Test("Stremio iOS and tvOS download from dl.strem.io, only that host may redirect", arguments: [false, true])
    func stremio(tvos: Bool) async throws {
        let ipa = try await SampleIPAs.shared.data("withExtension")
        let transport = stremioTransport(tvos: tvos, ipa: ipa)
        let app = tvos ? "stremio-tvos" : "stremio-ios"
        try await withFetch(FetchOptions(app: app), http: transport, runner: RecordingRunner()) { envelope, paths, _ in
            #expect(envelope.ok, "\(envelope.errors)")
            let json = try envelope.printed().json
            #expect(json["app"] == .string(app))
            #expect(json["version"] == "1.9.6b142")
            #expect(json["urlHost"] == "dl.strem.io")
            #expect(transport.getRequests.map(\.url.host) == ["raw.githubusercontent.com"])
            #expect(transport.downloadRequests.map(\.allowedHosts) == [["dl.strem.io"]])
            let entry = try #require(try ManifestStore(paths: paths).load().entry(app: app, version: "1.9.6b142"))
            #expect(entry.approved == false)
            #expect(entry.build == "142", "the index's buildVersion")
            #expect(entry.minOS == (tvos ? "15.0" : "14.0"), "the index's minOSVersion")
            #expect(entry.inspectMinOS == "15.0", "what the binary enforces, read by inspect")
            #expect(entry.declaredSize == Int64(ipa.count) && entry.size == Int64(ipa.count))
            #expect(FileManager.default.fileExists(atPath: paths.downloads + "/" + entry.file))
        }
    }

    @Test("the inspect summary names the bundle ID, version, platform and the extensions found")
    func inspectSummary() async throws {
        let ipa = try await SampleIPAs.shared.data("withExtension")
        try await withFetch(FetchOptions(app: "stremio-ios"), http: stremioTransport(tvos: false, ipa: ipa), runner: RecordingRunner()) { envelope, _, _ in
            #expect(envelope.ok, "\(envelope.errors)")
            let summary = try #require(try envelope.printed().json["inspect"])
            #expect(summary["bundleId"] == "com.stremio.pal")
            #expect(summary["version"] == "1.2.3")
            #expect(summary["platform"] == "ios")
            #expect(summary["extensionCount"] == 1)
            let extensions = try #require(summary["extensions"]?.array)
            #expect(extensions.count == 1)
            #expect(extensions[0]["path"] == "PlugIns/Share.appex")
            #expect(extensions[0]["bundleId"] == "com.stremio.pal.share")
            #expect(extensions[0]["extensionPoint"] == "com.apple.share-services")
        }
    }

    @Test("an unsafe archive with a correct digest is a hard failure and nothing is kept")
    func unsafeArchive() async throws {
        let bad = rawZip([RawZipEntry("Payload/App.app/Info.plist", [1]), RawZipEntry("Payload/../../escape", [2])])
        try await withFetch(FetchOptions(app: "apollo"), http: apolloTransport(ipa: bad), runner: RecordingRunner()) { envelope, paths, _ in
            #expect(!envelope.ok)
            #expect(envelope.firstCode == "IPA_UNSAFE_ENTRY", "\(envelope.errors)")
            try nothingKept(paths)
        }
    }

    @Test("not a zip at all is refused by inspect too")
    func notAnArchive() async throws {
        let junk = Data("this is not an ipa".utf8)
        try await withFetch(FetchOptions(app: "apollo"), http: apolloTransport(ipa: junk), runner: RecordingRunner()) { envelope, paths, _ in
            #expect(envelope.firstCode == "IPA_NOT_ZIP")
            try nothingKept(paths)
        }
    }
}

@Suite("fetch: refusals leave nothing behind")
struct FetchRefusalTests {
    @Test("a digest mismatch deletes the file, writes no manifest entry and names DIGEST_MISMATCH")
    func digestMismatch() async throws {
        let ipa = Data("the real bytes".utf8)
        let tampered = Data("swapped bytes!".utf8)
        let transport = apolloTransport(ipa: ipa, body: tampered)
        try await withFetch(FetchOptions(app: "apollo"), http: transport) { envelope, paths, services in
            #expect(envelope.firstCode == "DIGEST_MISMATCH")
            let data = try envelope.printed().json
            #expect(data["errors"]?.array?.first?["message"]?.string?.contains("deleted") == true)
            try nothingKept(paths)
            #expect((services.runner as? FakeRunner)?.calls.isEmpty == true, "an unverified file is never inspected")
        }
    }

    @Test("a body shorter than the declared size is SIZE_MISMATCH even if it is a clean prefix; nothing is kept")
    func shortBody() async throws {
        let ipa = Data(count: 10_000)
        for received in [9_999, 1, 0] {
            let transport = apolloTransport(ipa: ipa, body: ipa.prefix(received))
            try await withFetch(FetchOptions(app: "apollo"), http: transport) { envelope, paths, services in
                #expect(envelope.firstCode == "SIZE_MISMATCH", "\(received): \(envelope.errors)")
                #expect(try envelope.printed().json["errors"]?.array?.first?["message"]?.string?.contains("deleted") == true)
                try nothingKept(paths)
                #expect((services.runner as? FakeRunner)?.calls.isEmpty == true, "a wrong-sized file is never inspected")
            }
        }
        // The same for a Stremio index whose declared size is larger than the file served.
        let served = Data(count: 500)
        let json = stremioIndexJSON(tvos: false, sha256: sha256Hex(served), size: 501)
        let stremio = FakeFetchTransport(metadata: [stremioIOSIndex: json], download: { _ in Delivery(served) })
        try await withFetch(FetchOptions(app: "stremio-ios"), http: stremio) { envelope, paths, _ in
            #expect(envelope.firstCode == "SIZE_MISMATCH")
            try nothingKept(paths)
        }
    }

    @Test("a host not on the allowlist is refused before any download")
    func hostNotAllowed() async throws {
        let ipa = Data("x".utf8)
        let transport = stremioTransport(tvos: true, ipa: ipa, downloadURL: "https://evil.example/apple/1.9.6b142/tvos/stremio_tvOS.ipa")
        try await withFetch(FetchOptions(app: "stremio-tvos"), http: transport) { envelope, paths, _ in
            #expect(envelope.firstCode == "SOURCE_NOT_ALLOWED")
            #expect(transport.downloadRequests.isEmpty)
            try nothingKept(paths)
        }
    }

    @Test("an owner-narrowed host list that drops the CDN refuses the download")
    func narrowedHosts() async throws {
        let ipa = Data("x".utf8)
        let transport = stremioTransport(tvos: true, ipa: ipa)
        let config: [JSONValue] = [["app": "stremio-tvos", "hosts": ["raw.githubusercontent.com"]]]
        try await withFetch(FetchOptions(app: "stremio-tvos"), config: config, http: transport) { envelope, paths, _ in
            #expect(envelope.firstCode == "SOURCE_NOT_ALLOWED")
            #expect(transport.getRequests.count == 1 && transport.downloadRequests.isEmpty)
            try nothingKept(paths)
        }
    }

    @Test("a non-HTTPS download URL is refused before any download")
    func notHTTPS() async throws {
        let ipa = Data("x".utf8)
        let transport = stremioTransport(tvos: false, ipa: ipa, downloadURL: "http://dl.strem.io/apple/1.9.6b142/ios/stremio_iOS.ipa")
        try await withFetch(FetchOptions(app: "stremio-ios"), http: transport) { envelope, paths, _ in
            #expect(envelope.firstCode == "SOURCE_NOT_ALLOWED")
            #expect(transport.downloadRequests.isEmpty)
            try nothingKept(paths)
        }
    }

    @Test("a redirect to a host off the allowlist is refused, whoever noticed it")
    func crossHostRedirect() async throws {
        let ipa = Data("body".utf8)
        // The transport reports where the bytes came from.
        let reported = stremioTransport(tvos: true, ipa: ipa, delivery: { _ in Delivery(ipa, finalURL: evil) })
        try await withFetch(FetchOptions(app: "stremio-tvos"), http: reported) { envelope, paths, _ in
            #expect(envelope.firstCode == "REDIRECT_NOT_ALLOWED")
            try nothingKept(paths)
        }
        // The transport itself refused a hop.
        let refused = stremioTransport(tvos: true, ipa: ipa, delivery: { _ in Delivery(failure: .redirectRefused) })
        try await withFetch(FetchOptions(app: "stremio-tvos"), http: refused) { envelope, paths, _ in
            #expect(envelope.firstCode == "REDIRECT_NOT_ALLOWED")
            try nothingKept(paths)
        }
        // A same-host final URL over http would not pass either.
        let downgraded = stremioTransport(
            tvos: true, ipa: ipa,
            delivery: { _ in Delivery(ipa, finalURL: URL(string: "http://dl.strem.io/apple/1.9.6b142/tvos/stremio_tvOS.ipa")) })
        try await withFetch(FetchOptions(app: "stremio-tvos"), http: downgraded) { envelope, paths, _ in
            #expect(envelope.firstCode == "REDIRECT_NOT_ALLOWED")
            try nothingKept(paths)
        }
    }

    @Test("a body larger than the declared size stops at the cap and leaves nothing")
    func sizeCap() async throws {
        let declared = Data(count: 10_000)
        let big = Data(count: 10_001)
        let transport = apolloTransport(ipa: declared, body: big)
        try await withFetch(FetchOptions(app: "apollo"), http: transport) { envelope, paths, _ in
            #expect(envelope.firstCode == "DOWNLOAD_TOO_LARGE")
            #expect(transport.downloadRequests.first?.maxBytes == 10_000)
            try nothingKept(paths)
        }
    }

    @Test("a transport that stops at the cap is reported the same way; a declared size over 2 GiB never starts")
    func transportCap() async throws {
        let ipa = Data(count: 100)
        let capped = apolloTransport(ipa: ipa, delivery: { _ in Delivery(failure: .bodyTooLarge) })
        try await withFetch(FetchOptions(app: "apollo"), http: capped) { envelope, paths, _ in
            #expect(envelope.firstCode == "DOWNLOAD_TOO_LARGE")
            try nothingKept(paths)
        }
        let huge = apolloTransport(ipa: ipa, declaredSize: 3 << 30)
        try await withFetch(FetchOptions(app: "apollo"), http: huge) { envelope, paths, _ in
            #expect(envelope.firstCode == "DOWNLOAD_TOO_LARGE")
            #expect(huge.downloadRequests.isEmpty)
            try nothingKept(paths)
        }
    }

    @Test("a missing upstream digest stops before the download")
    func missingDigest() async throws {
        let name = "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa"
        let json = releaseJSON(assets: apolloDecoys() + [ReleaseAsset(name: name, digest: nil)])
        let transport = FakeFetchTransport(metadata: [apolloAPI: json])
        try await withFetch(FetchOptions(app: "apollo"), http: transport) { envelope, paths, _ in
            #expect(envelope.firstCode == "UPSTREAM_DIGEST_MISSING")
            #expect(transport.downloadRequests.isEmpty)
            try nothingKept(paths)
        }
    }

    @Test("transport failures, HTTP errors and a non-200 download are named and keep nothing")
    func failures() async throws {
        let ipa = Data("x".utf8)
        let cases: [(HTTPTransportError, String)] = [
            (.timedOut, "FETCH_TIMEOUT"), (.failed, "FETCH_NETWORK"), (.disabled, "FETCH_NETWORK"), (.cancelled, "CANCELLED"),
        ]
        for (failure, code) in cases {
            let transport = apolloTransport(ipa: ipa, delivery: { _ in Delivery(failure: failure) })
            try await withFetch(FetchOptions(app: "apollo"), http: transport) { envelope, paths, _ in
                #expect(envelope.firstCode == code)
                try nothingKept(paths)
            }
        }
        let notFound = apolloTransport(ipa: ipa, delivery: { _ in Delivery(status: 404) })
        try await withFetch(FetchOptions(app: "apollo"), http: notFound) { envelope, paths, _ in
            #expect(envelope.firstCode == "FETCH_HTTP_ERROR")
            try nothingKept(paths)
        }
        // No metadata served at all: the GET answers 404.
        let missing = FakeFetchTransport(metadata: [:])
        try await withFetch(FetchOptions(app: "apollo"), http: missing) { envelope, paths, _ in
            #expect(envelope.firstCode == "FETCH_HTTP_ERROR")
            try nothingKept(paths)
        }
    }

    @Test("a source the owner has not approved is refused before any request; so is an unknown one and a missing --app")
    func approvedSourcesGate() async throws {
        let transport = FakeFetchTransport(metadata: [:])
        try await withFetch(FetchOptions(app: "apollo"), config: stremioApproved, http: transport) { envelope, _, _ in
            #expect(envelope.firstCode == "SOURCE_NOT_ALLOWED")
        }
        try await withFetch(FetchOptions(app: "feather"), http: transport) { envelope, _, _ in
            #expect(envelope.firstCode == "SOURCE_NOT_ALLOWED")
        }
        try await withFetch(FetchOptions(app: nil), http: transport) { envelope, _, _ in
            #expect(envelope.firstCode == "USAGE")
        }
        #expect(transport.callCount == 0)
    }

    @Test("the default transport throws, so a forgotten fake can never reach the network")
    func defaultTransport() async throws {
        try await withFetch(FetchOptions(app: "apollo"), http: DisabledTransport()) { envelope, paths, _ in
            #expect(envelope.firstCode == "FETCH_NETWORK")
            try nothingKept(paths)
        }
    }

    @Test("a busy operation lock is OPERATION_IN_PROGRESS and nothing is requested")
    func busyLock() async throws {
        let ipa = Data("x".utf8)
        let transport = apolloTransport(ipa: ipa)
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let held = try OperationLock.acquire(paths: paths)
            let services = fetchServices(paths, http: transport)
            let envelope = await FetchCommand.run(services, FetchOptions(app: "apollo"), registry: ScratchRegistry())
            #expect(envelope.firstCode == "OPERATION_IN_PROGRESS")
            #expect(transport.callCount == 0)
            let approve = await FetchCommand.run(services, FetchOptions(app: "apollo", approve: true, version: "3.9.0"), registry: ScratchRegistry())
            #expect(approve.firstCode == "OPERATION_IN_PROGRESS")
            held.release()
            try nothingKept(paths)
        }
    }
}

@Suite("fetch: approval")
struct FetchApprovalTests {
    private func run(
        _ options: FetchOptions, _ paths: Paths, _ http: any HTTPTransport
    ) async -> Envelope {
        await FetchCommand.run(fetchServices(paths, http: http, runner: RecordingRunner()), options, registry: ScratchRegistry())
    }

    @Test("--approve marks the fetched version approved without touching the network")
    func approveFlow() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let transport = apolloTransport(ipa: ipa)
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let fetched = await run(FetchOptions(app: "apollo"), paths, transport)
            #expect(fetched.ok, "\(fetched.errors)")
            #expect(try ManifestStore(paths: paths).load().entries.first?.approved == false)
            let calls = transport.callCount

            let approvedRun = await run(FetchOptions(app: "apollo", approve: true, version: "3.9.0"), paths, transport)
            #expect(approvedRun.ok, "\(approvedRun.errors)")
            let json = try approvedRun.printed().json
            #expect(json["approved"] == true && json["alreadyApproved"] == false && json["downloaded"] == false)
            #expect(json["approvedAt"] != nil && json["next"] == nil)
            #expect(json["inspect"]?["bundleId"] == "io.example.apollo")
            #expect(json["sha256"] == .string(sha256Hex(ipa)) && json["upstreamDigest"] == .string(sha256Hex(ipa)))
            // Everything the owner decides on: version, build as its own field, size (both), minimum OS, both hashes.
            #expect(json["version"] == "3.9.0" && json["build"] == "45")
            #expect(json["size"] == .number(Double(ipa.count)) && json["declaredSize"] == .number(Double(ipa.count)))
            #expect(json["inspectMinOS"] == "15.0" && json["minOS"] == .null)
            #expect(transport.callCount == calls, "approve does no network")

            let entry = try #require(try ManifestStore(paths: paths).load().entries.first)
            #expect(entry.approved && entry.approvedAt == testNow)

            // Approving again changes nothing and says so.
            let again = await run(FetchOptions(app: "apollo", approve: true, version: "3.9.0"), paths, transport)
            #expect(try again.printed().json["alreadyApproved"] == true)
            #expect(try ManifestStore(paths: paths).load().entries == [entry])
        }
    }

    @Test("--approve with nothing fetched is NOT_FETCHED")
    func nothingToApprove() async throws {
        let transport = FakeFetchTransport(metadata: [:])
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let envelope = await run(FetchOptions(app: "apollo", approve: true, version: "3.9.0"), paths, transport)
            #expect(envelope.firstCode == "NOT_FETCHED")
            #expect(transport.callCount == 0)
        }
    }

    @Test("a stored file that changed after the fetch is not approved")
    func tamperedFile() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let transport = apolloTransport(ipa: ipa)
            #expect(await run(FetchOptions(app: "apollo"), paths, transport).ok)
            let stored = paths.downloads + "/apollo/3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa"
            try (ipa + Data("tail".utf8)).write(to: URL(fileURLWithPath: stored))
            let envelope = await run(FetchOptions(app: "apollo", approve: true, version: "3.9.0"), paths, transport)
            #expect(envelope.firstCode == "DIGEST_MISMATCH")
            #expect(try ManifestStore(paths: paths).load().entries.first?.approved == false)

            try FileManager.default.removeItem(atPath: stored)
            #expect(await run(FetchOptions(app: "apollo", approve: true, version: "3.9.0"), paths, transport).firstCode == "IPA_MISSING")
        }
    }

    @Test("fetching the same version again downloads nothing and keeps the approval")
    func refetchUnchanged() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let transport = apolloTransport(ipa: ipa)
            #expect(await run(FetchOptions(app: "apollo"), paths, transport).ok)
            #expect(await run(FetchOptions(app: "apollo", approve: true, version: "3.9.0"), paths, transport).ok)
            let downloads = transport.downloadRequests.count

            let again = await run(FetchOptions(app: "apollo"), paths, transport)
            #expect(again.ok, "\(again.errors)")
            let json = try again.printed().json
            #expect(json["downloaded"] == false && json["approved"] == true)
            #expect(transport.downloadRequests.count == downloads)
        }
    }

    @Test("a deleted file is downloaded again and, being the same bytes, stays approved")
    func redownloadKeepsApproval() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let transport = apolloTransport(ipa: ipa)
            #expect(await run(FetchOptions(app: "apollo"), paths, transport).ok)
            #expect(await run(FetchOptions(app: "apollo", approve: true, version: "3.9.0"), paths, transport).ok)
            try FileManager.default.removeItem(atPath: paths.downloads + "/apollo/3.9.0/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa")

            let again = await run(FetchOptions(app: "apollo"), paths, transport)
            #expect(again.ok, "\(again.errors)")
            #expect(try again.printed().json["downloaded"] == true)
            #expect(try ManifestStore(paths: paths).load().entries.first?.approved == true)
        }
    }

    @Test("the publisher changing a version's digest is VERSION_CONTENT_CHANGED, and the old entry stays")
    func contentChanged() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            #expect(await run(FetchOptions(app: "apollo"), paths, apolloTransport(ipa: ipa)).ok)
            let before = try ManifestStore(paths: paths).load()
            let other = Data("a different file".utf8)
            let swapped = apolloTransport(ipa: other)
            let envelope = await run(FetchOptions(app: "apollo"), paths, swapped)
            #expect(envelope.firstCode == "VERSION_CONTENT_CHANGED")
            #expect(swapped.downloadRequests.isEmpty)
            #expect(try ManifestStore(paths: paths).load() == before)
        }
    }

    @Test("--approve applies to the exact --version only; another version stays unapproved")
    func exactVersion() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            #expect(await run(FetchOptions(app: "apollo"), paths, apolloTransport(ipa: ipa, version: "3.9.0")).ok)
            #expect(await run(FetchOptions(app: "apollo"), paths, apolloTransport(ipa: ipa, version: "3.10.0")).ok)
            let none = FakeFetchTransport(metadata: [:])

            // The older version is approved by name even though 3.10.0 is newer.
            let older = await run(FetchOptions(app: "apollo", approve: true, version: "3.9.0"), paths, none)
            #expect(older.ok, "\(older.errors)")
            let json = try older.printed().json
            #expect(json["version"] == "3.9.0" && json["approved"] == true)
            #expect(json["sha256"] == .string(sha256Hex(ipa)))
            #expect(json["inspect"]?["bundleId"] == "io.example.apollo")
            var manifest = try ManifestStore(paths: paths).load()
            #expect(manifest.entries.map(\.version) == ["3.9.0", "3.10.0"])
            #expect(manifest.entries.map(\.approved) == [true, false])

            // A version that is not in the manifest is NOT_FETCHED and changes nothing.
            let before = manifest
            #expect(await run(FetchOptions(app: "apollo", approve: true, version: "9.9.9"), paths, none).firstCode == "NOT_FETCHED")
            #expect(await run(FetchOptions(app: "apollo", approve: true, version: "3.9"), paths, none).firstCode == "NOT_FETCHED")
            manifest = try ManifestStore(paths: paths).load()
            #expect(manifest == before)
            #expect(none.callCount == 0)
        }
    }

    @Test("--approve needs --version, and --version needs --approve")
    func versionUsage() async throws {
        let transport = FakeFetchTransport(metadata: [:])
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            #expect(await run(FetchOptions(app: "apollo", approve: true), paths, transport).firstCode == "USAGE")
            #expect(await run(FetchOptions(app: "apollo", approve: true, version: ""), paths, transport).firstCode == "USAGE")
            #expect(await run(FetchOptions(app: "apollo", version: "3.9.0"), paths, transport).firstCode == "USAGE")
            #expect(transport.callCount == 0)
        }
    }

    @Test("Stremio's approve output carries the index's build, size and minimum OS next to both hashes")
    func approveStremioFields() async throws {
        let ipa = try await SampleIPAs.shared.data("withExtension")
        try await withTestHome(config: Config(approvedSources: stremioApproved)) { paths, _ in
            let transport = stremioTransport(tvos: true, ipa: ipa)
            #expect(await run(FetchOptions(app: "stremio-tvos"), paths, transport).ok)
            let approved = await run(FetchOptions(app: "stremio-tvos", approve: true, version: "1.9.6b142"), paths, transport)
            let json = try approved.printed().json
            #expect(approved.ok, "\(approved.errors)")
            #expect(json["version"] == "1.9.6b142" && json["build"] == "142")
            #expect(json["size"] == .number(Double(ipa.count)) && json["declaredSize"] == .number(Double(ipa.count)))
            #expect(json["minOS"] == "15.0" && json["inspectMinOS"] == "15.0")
            #expect(json["sha256"] == .string(sha256Hex(ipa)) && json["upstreamDigest"] == .string(sha256Hex(ipa)))
        }
    }

    @Test("a manifest written before the new fields still loads, with them absent")
    func oldManifest() async throws {
        try await withTestHome { paths, _ in
            let old = """
                {"schema":1,"entries":[{"app":"apollo","version":"3.9.0","file":"apollo/3.9.0/x.ipa","urlHost":"github.com",
                "sha256":"a","upstreamDigest":"a","size":5,"fetchedAt":"2026-10-19T12:00:00Z","approved":true}]}
                """
            try Data(old.utf8).write(to: URL(fileURLWithPath: paths.manifest))
            let entry = try #require(try ManifestStore(paths: paths).load().entries.first)
            #expect(entry.build == nil && entry.declaredSize == nil && entry.minOS == nil && entry.inspectMinOS == nil)
            #expect(entry.approved)
        }
    }

    @Test("a corrupt manifest is MANIFEST_INVALID and is not echoed; a path outside downloads/ is refused")
    func manifestIntegrity() async throws {
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            try Data("{ SECRETMARKER".utf8).write(to: URL(fileURLWithPath: paths.manifest))
            let transport = apolloTransport(ipa: Data("x".utf8))
            let envelope = await run(FetchOptions(app: "apollo"), paths, transport)
            #expect(envelope.firstCode == "MANIFEST_INVALID")
            #expect(!(try envelope.printed().text.contains("SECRETMARKER")))
            #expect(transport.downloadRequests.isEmpty)
        }
        try await withTestHome { paths, _ in
            let entry = ManifestEntry(
                app: "apollo", version: "3.9.0", file: "apollo/3.9.0/../../../etc/passwd", urlHost: "github.com", sha256: "a", upstreamDigest: "a",
                size: 1, fetchedAt: testNow, approved: true, approvedAt: nil)
            #expect(throws: SideloadError.self) { try ManifestStore(paths: paths).path(of: entry) }
        }
    }
}

/// Serves the metadata, delivers one chunk of the body, then waits to be released.
private final class GatedTransport: HTTPTransport {
    let metadata: [String: Data]
    let first: Data
    let rest: Data
    private let started: AsyncStream<Void>.Continuation
    let startedStream: AsyncStream<Void>
    private let gate: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation

    init(metadata: [String: Data], first: Data, rest: Data) {
        self.metadata = metadata
        self.first = first
        self.rest = rest
        (startedStream, started) = AsyncStream.makeStream(of: Void.self)
        (gate, release) = AsyncStream.makeStream(of: Void.self)
    }

    func letGo() { release.yield() }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 200, body: metadata[request.url.absoluteString] ?? Data())
    }

    func download(_ request: DownloadRequest, sink: @Sendable (Data) throws -> Void) async throws -> DownloadResponse {
        try sink(first)
        started.yield()
        for await _ in gate { break }
        try sink(rest)
        return DownloadResponse(status: 200, finalURL: request.url, byteCount: Int64(first.count + rest.count))
    }
}

@Suite("fetch: interrupt cleanup")
struct FetchInterruptTests {
    @Test("a download in flight keeps its partial file in a registered 0700 folder that the interrupt path removes")
    func interruptRemovesPartial() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let split = ipa.count / 2
        let (name, digest) = ("Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa", sha256Hex(ipa))
        let json = releaseJSON(assets: [ReleaseAsset(name: name, size: ipa.count, digest: "sha256:" + digest)])
        let transport = GatedTransport(metadata: [apolloAPI: json], first: ipa.prefix(split), rest: ipa.dropFirst(split))
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let registry = ScratchRegistry()
            let services = fetchServices(paths, http: transport, runner: RecordingRunner())
            let running = Task { await FetchCommand.run(services, FetchOptions(app: "apollo"), registry: registry) }
            for await _ in transport.startedStream { break }

            // Mid-transfer: a registered folder holds the partial file; nothing is under downloads/.
            #expect(!registry.isEmpty)
            let folders = partFiles(paths)
            #expect(folders.count == 1)
            let folder = paths.tmp + "/" + (folders.first ?? "")
            #expect(modeOf(folder) == 0o700)
            #expect(listing(folder) == ["download.part"])
            #expect(listing(paths.downloads).isEmpty)

            // What the CLI's signal handler does before it exits (it never runs fetch's own cleanup).
            registry.removeAllAndClose()
            #expect(!FileManager.default.fileExists(atPath: folder), "the partial file is gone")
            #expect(partFiles(paths).isEmpty)

            // The command, if it were still alive, must not complete: nothing is moved into place or recorded.
            transport.letGo()
            let envelope = await running.value
            #expect(!envelope.ok)
            #expect(envelope.firstCode == "CANCELLED", "\(envelope.errors)")
            #expect(listing(paths.downloads).isEmpty)
            let recorded = try ManifestStore(paths: paths).load()
            #expect(recorded.entries.isEmpty)
            #expect(partFiles(paths).isEmpty && scratchFolders(paths).isEmpty)
        }
    }

    @Test("the download folder is gone after a failure too, and a killed run's leftovers are swept")
    func failureAndSweep() async throws {
        let transport = apolloTransport(ipa: Data("real".utf8), body: Data("swap".utf8))
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let stale = paths.tmp + "/fetch-STALE1"
            try FileManager.default.createDirectory(atPath: stale, withIntermediateDirectories: false)
            FileManager.default.createFile(atPath: stale + "/download.part", contents: Data("x".utf8))
            let envelope = await FetchCommand.run(
                fetchServices(paths, http: transport), FetchOptions(app: "apollo"), registry: ScratchRegistry())
            #expect(envelope.firstCode == "DIGEST_MISMATCH")
            #expect(partFiles(paths).isEmpty)
        }
    }
}
