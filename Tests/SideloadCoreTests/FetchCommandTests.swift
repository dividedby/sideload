import Darwin
import Foundation
import Synchronization
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
    expectLockFree(paths, sourceLocation: sourceLocation)
}

@Suite("fetch: download and record")
struct FetchDownloadTests {
    @Test("Apollo: downloads the exact asset, verifies it, inspects it and records an unapproved manifest entry")
    func apollo() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let transport = apolloTransport(ipa: ipa)
        try await withFetch(FetchOptions(app: "apollo"), http: transport, runner: RecordingRunner(), prepare: { paths in
            // A part file from an interrupted run is swept once it is older than the grace period.
            let loose = paths.tmp + "/fetch-stale.part"
            FileManager.default.createFile(atPath: loose, contents: Data("x".utf8))
            backdate(loose, by: 120)
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

    @Test("a busy operation lock stops --approve at once; a download is not stopped early, it stages its verified file")
    func busyLock() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let transport = apolloTransport(ipa: ipa)
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let held = try OperationLock.acquire(paths: paths)
            let services = fetchServices(paths, http: transport, runner: RecordingRunner())
            let approve = await FetchCommand.run(services, FetchOptions(app: "apollo", approve: true, version: "3.9.0"), registry: ScratchRegistry())
            #expect(approve.firstCode == "OPERATION_IN_PROGRESS")
            #expect(transport.callCount == 0, "--approve asks for the lock before anything else")

            let envelope = await FetchCommand.run(services, FetchOptions(app: "apollo"), registry: ScratchRegistry())
            #expect(envelope.firstCode == "OPERATION_IN_PROGRESS")
            #expect(transport.downloadRequests.count == 1, "no early lock check: the download ran")
            #expect(stagedFiles(paths) == ["staged-\(sha256Hex(ipa)).ipa"])
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
            #expect(Set(listing(folder)) == ["download.part", "live.lock"], "the partial file and the liveness lock")
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
            backdate(stale, by: 120)
            let envelope = await FetchCommand.run(
                fetchServices(paths, http: transport), FetchOptions(app: "apollo"), registry: ScratchRegistry())
            #expect(envelope.firstCode == "DIGEST_MISMATCH")
            #expect(partFiles(paths).isEmpty)
            expectLockFree(paths)
        }
    }
}

// MARK: the narrowed lock

private func launch(
    _ paths: Paths, _ http: any HTTPTransport, _ options: FetchOptions, runner: any Runner = RecordingRunner(), clock: (any WallClock)? = nil
) -> Task<Envelope, Never> {
    var services = fetchServices(paths, http: http, runner: runner)
    if let clock { services.clock = clock }
    return Task { await FetchCommand.run(services, options, registry: ScratchRegistry()) }
}

private func runFetch(
    _ paths: Paths, _ http: any HTTPTransport, _ options: FetchOptions, runner: any Runner = RecordingRunner(), clock: (any WallClock)? = nil
) async -> Envelope {
    await launch(paths, http, options, runner: runner, clock: clock).value
}

/// Waits until the gated download has delivered its first half; its folder then exists.
private func started(_ transport: GatedTransport) async {
    for await _ in transport.startedStream { break }
}

private func onlyFolder(_ paths: Paths) -> String {
    paths.tmp + "/" + (partFiles(paths).first ?? "none")
}

private func nothingStaged(_ paths: Paths, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(stagedFiles(paths).isEmpty, sourceLocation: sourceLocation)
    #expect(partFiles(paths).isEmpty, sourceLocation: sourceLocation)
}

@Suite("fetch: the download holds no operation lock")
struct FetchLockTests {
    @Test("mid-download the operation lock is free, and it is free again after every path")
    func downloadHoldsNoLock() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let transport = gatedApollo(ipa)
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let running = launch(paths, transport, FetchOptions(app: "apollo"))
            await started(transport)
            // The lab (or another sideload command) can take the lock while the bytes are still arriving.
            let other = try OperationLock.acquire(paths: paths)
            other.release()
            transport.letGo()
            let envelope = await running.value
            #expect(envelope.ok, "\(envelope.errors)")
            expectLockFree(paths)
            nothingStaged(paths)
        }
    }

    @Test("a busy lock at commit keeps the verified file for 24 h; the re-run downloads nothing and records it")
    func stagedThenClaimed() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let digest = sha256Hex(ipa)
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let held = try OperationLock.acquire(paths: paths)
            let first = apolloTransport(ipa: ipa)
            let busy = await runFetch(paths, first, FetchOptions(app: "apollo"))
            #expect(busy.firstCode == "OPERATION_IN_PROGRESS")
            #expect(busy.errors.first?.fix?.contains("kept for 24 h") == true)
            #expect(first.downloadRequests.count == 1)
            let staged = paths.tmp + "/staged-\(digest).ipa"
            #expect(stagedFiles(paths) == ["staged-\(digest).ipa"])
            #expect(modeOf(staged) == 0o600)
            #expect(try Data(contentsOf: URL(fileURLWithPath: staged)) == ipa)
            #expect(partFiles(paths).isEmpty && listing(paths.downloads).isEmpty)
            #expect(try ManifestStore(paths: paths).load().entries.isEmpty)
            held.release()

            let second = apolloTransport(ipa: ipa)
            let envelope = await runFetch(paths, second, FetchOptions(app: "apollo"))
            #expect(envelope.ok, "\(envelope.errors)")
            #expect(second.downloadRequests.isEmpty, "the staged file stood in for the download")
            #expect(second.getRequests.count == 1)
            let json = try envelope.printed().json
            #expect(json["downloaded"] == true && json["approved"] == false)
            let entry = try #require(try ManifestStore(paths: paths).load().entries.first)
            #expect(try Data(contentsOf: URL(fileURLWithPath: paths.downloads + "/" + entry.file)) == ipa)
            #expect(entry.sha256 == digest)
            nothingStaged(paths)
            expectLockFree(paths)
        }
    }

    @Test("a re-run that finds the version already stored deletes the staged file for that digest")
    func storedDropsStaged() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let digest = sha256Hex(ipa)
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let first = await runFetch(paths, apolloTransport(ipa: ipa), FetchOptions(app: "apollo"))
            #expect(first.ok, "\(first.errors)")
            // An earlier run that found the lock busy left this behind while another run recorded the file.
            try ipa.write(to: URL(fileURLWithPath: paths.tmp + "/staged-\(digest).ipa"))
            #expect(stagedFiles(paths) == ["staged-\(digest).ipa"])

            let second = apolloTransport(ipa: ipa)
            let again = await runFetch(paths, second, FetchOptions(app: "apollo"))
            #expect(again.ok, "\(again.errors)")
            #expect(second.downloadRequests.isEmpty)
            #expect(stagedFiles(paths).isEmpty)
        }
    }

    @Test("a corrupted staged file, a wrong-sized one and a staged symlink are deleted and the file is downloaded")
    func badStagedFile() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let name = "staged-\(sha256Hex(ipa)).ipa"
        let flipped = Data(ipa.map { $0 ^ 0xff })
        for variant in ["corrupt", "short", "symlink"] {
            try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
                let staged = paths.tmp + "/" + name
                let target = paths.home + "/elsewhere.ipa"
                switch variant {
                case "corrupt": try flipped.write(to: URL(fileURLWithPath: staged))
                case "short": try ipa.prefix(ipa.count - 1).write(to: URL(fileURLWithPath: staged))
                default:
                    try ipa.write(to: URL(fileURLWithPath: target))
                    #expect(symlink(target, staged) == 0)
                }
                let transport = apolloTransport(ipa: ipa)
                let envelope = await runFetch(paths, transport, FetchOptions(app: "apollo"))
                #expect(envelope.ok, "\(variant): \(envelope.errors)")
                #expect(transport.downloadRequests.count == 1, "\(variant): a staged file that does not verify is not used")
                #expect(try envelope.printed().json["sha256"] == .string(sha256Hex(ipa)))
                nothingStaged(paths)
                if variant == "symlink" { #expect(FileManager.default.fileExists(atPath: target), "the link was removed, not what it pointed at") }
                expectLockFree(paths)
            }
        }
    }

    @Test("a second fetch sweeps the dead and spares the living: a running download's backdated folder survives")
    func sweepSparesLiveRun() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let other = try await SampleIPAs.shared.data("withExtension")
        let transport = gatedApollo(ipa)
        try await withTestHome(config: Config(approvedSources: apolloApproved + stremioApproved)) { paths, _ in
            let running = launch(paths, transport, FetchOptions(app: "apollo"))
            await started(transport)
            let live = onlyFolder(paths)
            backdate(live, by: 120)

            func folder(_ name: String, files: [String]) throws -> String {
                let path = paths.tmp + "/" + name
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                for file in files { FileManager.default.createFile(atPath: path + "/" + file, contents: Data("x".utf8)) }
                return path
            }
            let deadWithLock = try folder("fetch-DEAD01", files: ["download.part", "live.lock"])
            let noLock = try folder("fetch-NOLOCK", files: ["download.part"])
            let freshNoLock = try folder("fetch-FRESH1", files: ["download.part"])
            let loose = paths.tmp + "/fetch-x.part"
            FileManager.default.createFile(atPath: loose, contents: Data("x".utf8))
            let oldStaged = paths.tmp + "/staged-" + String(repeating: "a", count: 64) + ".ipa"
            let newStaged = paths.tmp + "/staged-" + String(repeating: "b", count: 64) + ".ipa"
            for path in [oldStaged, newStaged] { FileManager.default.createFile(atPath: path, contents: Data("x".utf8)) }
            for path in [deadWithLock, noLock, loose] { backdate(path, by: 120) }
            backdate(oldStaged, by: 25 * 3600)
            backdate(newStaged, by: 3600)

            // The sweeping run's clock is a year ahead of real time. If the sweep read it, the fresh folder and the
            // newer staged file would look old, and so would the running download's.
            let ahead = FixedClock(Date().addingTimeInterval(365 * 86400))
            let stremio = stremioTransport(tvos: false, ipa: other)
            let swept = await runFetch(paths, stremio, FetchOptions(app: "stremio-ios"), clock: ahead)
            #expect(swept.ok, "\(swept.errors)")

            let fm = FileManager.default
            #expect(fm.fileExists(atPath: live + "/download.part"), "the running download's folder survived")
            #expect(!fm.fileExists(atPath: deadWithLock), "a folder whose lock can be taken is stale")
            #expect(!fm.fileExists(atPath: noLock), "a backdated folder with no live.lock is stale")
            #expect(!fm.fileExists(atPath: loose))
            #expect(!fm.fileExists(atPath: oldStaged), "a staged file past 24 h goes")
            #expect(fm.fileExists(atPath: newStaged), "a younger staged file stays")
            #expect(fm.fileExists(atPath: freshNoLock), "a fresh folder with no lock is inside the grace period")

            transport.letGo()
            let finished = await running.value
            #expect(finished.ok, "\(finished.errors)")
            let manifest = try ManifestStore(paths: paths).load()
            #expect(Set(manifest.entries.map(\.app)) == ["apollo", "stremio-ios"])
            expectLockFree(paths)
        }
    }

    @Test("sweep: a held live.lock is live, a free or missing one is stale, and age is real file time")
    func sweepUnit() async throws {
        try await withTestHome { paths, _ in
            let path = paths.tmp + "/fetch-HELD01"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            let lock = try #require(try FileLock.tryAcquire(path: path + "/live.lock"))
            FileManager.default.createFile(atPath: path + "/download.part", contents: Data("x".utf8))
            backdate(path, by: 600)

            FetchCommand.sweepStale(in: paths.tmp)
            #expect(FileManager.default.fileExists(atPath: path), "held, so alive")

            // The same process holds it: flock belongs to the open file description, so a second open sees it held.
            guard case .held = try FileLock.tryAcquireExisting(path: path + "/live.lock") else {
                Issue.record("expected the lock to read as held")
                return
            }
            #expect(lock.isLinked)

            lock.release()
            FetchCommand.sweepStale(in: paths.tmp)
            #expect(!FileManager.default.fileExists(atPath: path), "released, so stale")

            // A fresh unlocked folder is left alone, then swept once `now` says it is old enough.
            let fresh = paths.tmp + "/fetch-FRESH2"
            try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: false)
            FetchCommand.sweepStale(in: paths.tmp)
            #expect(FileManager.default.fileExists(atPath: fresh))
            FetchCommand.sweepStale(in: paths.tmp, now: time(nil) + 120)
            #expect(!FileManager.default.fileExists(atPath: fresh))

            // The variant never creates the file, and notices an unlinked one.
            guard case .missing = try FileLock.tryAcquireExisting(path: paths.tmp + "/nothing.lock") else {
                Issue.record("expected missing")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: paths.tmp + "/nothing.lock"))
            let gone = paths.tmp + "/gone.lock"
            let taken = try #require(try FileLock.tryAcquire(path: gone))
            unlink(gone)
            #expect(!taken.isLinked)
        }
    }

    @Test("two fetches of one version: the one that commits second returns downloaded:false and keeps the approval")
    func sameVersionLoser() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let transport = gatedApollo(ipa)
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let slow = launch(paths, transport, FetchOptions(app: "apollo"))
            await started(transport)

            let fast = await runFetch(paths, apolloTransport(ipa: ipa), FetchOptions(app: "apollo"))
            #expect(fast.ok, "\(fast.errors)")
            let approved = await runFetch(paths, FakeFetchTransport(metadata: [:]), FetchOptions(app: "apollo", approve: true, version: "3.9.0"))
            #expect(approved.ok, "\(approved.errors)")
            let before = try ManifestStore(paths: paths).load()

            transport.letGo()
            let envelope = await slow.value
            #expect(envelope.ok, "\(envelope.errors)")
            let json = try envelope.printed().json
            #expect(json["downloaded"] == false && json["approved"] == true && json["alreadyApproved"] == true)
            #expect(json["inspect"]?["bundleId"] == "io.example.apollo", "reported from its own inspection")
            let manifest = try ManifestStore(paths: paths).load()
            #expect(manifest == before && manifest.entries.count == 1 && manifest.entries[0].approved)
            nothingStaged(paths)
            expectLockFree(paths)
        }
    }

    @Test("lost update: a fetch that finishes while another is downloading does not drop its manifest entry")
    func noLostUpdate() async throws {
        let apollo = try await SampleIPAs.shared.data("plain")
        let stremio = try await SampleIPAs.shared.data("withExtension")
        let transport = gatedApollo(apollo)
        try await withTestHome(config: Config(approvedSources: apolloApproved + stremioApproved)) { paths, _ in
            let slow = launch(paths, transport, FetchOptions(app: "apollo"))
            await started(transport)
            let fast = await runFetch(paths, stremioTransport(tvos: false, ipa: stremio), FetchOptions(app: "stremio-ios"))
            #expect(fast.ok, "\(fast.errors)")
            transport.letGo()
            let envelope = await slow.value
            #expect(envelope.ok, "\(envelope.errors)")
            let manifest = try ManifestStore(paths: paths).load()
            #expect(Set(manifest.entries.map(\.app)) == ["apollo", "stremio-ios"])
            for entry in manifest.entries { #expect(FileManager.default.fileExists(atPath: paths.downloads + "/" + entry.file)) }
        }
    }

    @Test("a conflicting digest recorded while a download ran is VERSION_CONTENT_CHANGED at commit; nothing is staged")
    func conflictAtCommit() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        let transport = gatedApollo(ipa)
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let running = launch(paths, transport, FetchOptions(app: "apollo"))
            await started(transport)
            var manifest = Manifest()
            manifest.entries = [
                ManifestEntry(
                    app: "apollo", version: "3.9.0", file: "apollo/3.9.0/other.ipa", urlHost: "github.com", sha256: String(repeating: "1", count: 64),
                    upstreamDigest: String(repeating: "1", count: 64), size: 5, fetchedAt: testNow, approved: false, approvedAt: nil)
            ]
            try ManifestStore(paths: paths).save(manifest)

            transport.letGo()
            let envelope = await running.value
            #expect(envelope.firstCode == "VERSION_CONTENT_CHANGED", "\(envelope.errors)")
            #expect(try ManifestStore(paths: paths).load() == manifest)
            #expect(listing(paths.downloads).isEmpty)
            nothingStaged(paths)
            expectLockFree(paths)
        }
    }

    @Test("a cancelled task is CANCELLED during the download and after it, and keeps, stages and records nothing")
    func cancelled() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let transport = gatedApollo(ipa)
            let running = launch(paths, transport, FetchOptions(app: "apollo"))
            await started(transport)
            running.cancel()
            transport.letGo()
            let envelope = await running.value
            #expect(envelope.firstCode == "CANCELLED", "\(envelope.errors)")
            try nothingKept(paths)
            nothingStaged(paths)
        }

        // After the download, with the archive inspected and only the commit left: count the inspector's runner
        // calls once, then cancel the task right after the last of them.
        let calls = try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let recording = RecordingRunner()
            #expect(await runFetch(paths, apolloTransport(ipa: ipa), FetchOptions(app: "apollo"), runner: recording).ok)
            return recording.calls.count
        }
        #expect(calls > 0)
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let transport = gatedApollo(ipa)
            let task = Mutex<Task<Envelope, Never>?>(nil)
            let seen = Mutex(0)
            let runner = RecordingRunner(afterRun: { _ in
                if seen.withLock({ $0 += 1; return $0 }) == calls { task.withLock { $0?.cancel() } }
            })
            let running = launch(paths, transport, FetchOptions(app: "apollo"), runner: runner)
            task.withLock { $0 = running }
            await started(transport)
            transport.letGo()
            let envelope = await running.value
            #expect(seen.withLock { $0 } == calls, "the run got as far as its last inspection step")
            #expect(envelope.firstCode == "CANCELLED", "\(envelope.errors)")
            try nothingKept(paths)
            nothingStaged(paths)
        }
    }
}
