import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Fakes and fixtures for `fetch`. Nothing opens a socket: the transport is a script that hands out bytes, and the
// IPAs are synthetic archives built at runtime (InspectTestSupport).

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// What a scripted download delivers.
struct Delivery: Sendable {
    var status = 200
    /// Where the body "came from"; nil means the requested URL (no redirect).
    var finalURL: URL?
    var chunks: [Data] = []
    var failure: HTTPTransportError?

    init(_ body: Data = Data(), status: Int = 200, finalURL: URL? = nil, failure: HTTPTransportError? = nil, chunkSize: Int = 4096) {
        self.status = status
        self.finalURL = finalURL
        self.failure = failure
        var rest = body[...]
        while !rest.isEmpty {
            chunks.append(Data(rest.prefix(chunkSize)))
            rest = rest.dropFirst(chunkSize)
        }
    }
}

/// Serves metadata by URL and downloads by script. It does not enforce `maxBytes` or the redirect rules itself,
/// so a test can show that `fetch` checks them too.
final class FakeFetchTransport: HTTPTransport {
    typealias DownloadScript = @Sendable (DownloadRequest) throws -> Delivery

    private let metadata: [String: Data]
    private let script: DownloadScript
    private let gets = Mutex<[HTTPRequest]>([])
    private let downloads = Mutex<[DownloadRequest]>([])

    init(metadata: [String: Data], download: @escaping DownloadScript = { _ in Delivery() }) {
        self.metadata = metadata
        self.script = download
    }

    var getRequests: [HTTPRequest] { gets.withLock { $0 } }
    var downloadRequests: [DownloadRequest] { downloads.withLock { $0 } }
    var callCount: Int { getRequests.count + downloadRequests.count }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        gets.withLock { $0.append(request) }
        guard let body = metadata[request.url.absoluteString] else { return HTTPResponse(status: 404, body: Data()) }
        return HTTPResponse(status: 200, body: body)
    }

    func download(_ request: DownloadRequest, sink: @Sendable (Data) throws -> Void) async throws -> DownloadResponse {
        downloads.withLock { $0.append(request) }
        let delivery = try script(request)
        if let failure = delivery.failure { throw failure }
        var total: Int64 = 0
        if delivery.status == 200 {
            for chunk in delivery.chunks {
                try sink(chunk)
                total += Int64(chunk.count)
            }
        }
        return DownloadResponse(status: delivery.status, finalURL: delivery.finalURL ?? request.url, byteCount: total)
    }
}

// MARK: metadata fixtures

let apolloAPI = "https://api.github.com/repos/Apollo-Reborn/Apollo-Reborn/releases/latest"
let stremioIOSIndex = "https://raw.githubusercontent.com/gorlev/stremio-altstore/main/stremio-ios.json"
let stremioTVOSIndex = "https://raw.githubusercontent.com/gorlev/stremio-altstore/main/stremio-tvos.json"

struct ReleaseAsset {
    var name: String
    var size: Int = 1000
    var digest: String? = "sha256:" + String(repeating: "ab", count: 32)
    var url: String?
    var state = "uploaded"
}

/// The GitHub releases API shape for one release.
func releaseJSON(tag: String = "v1.15.11_3.9.0", assets: [ReleaseAsset], draft: Bool = false, prerelease: Bool = false) -> Data {
    let list: [JSONValue] = assets.map { asset in
        var object: [String: JSONValue] = [
            "name": .string(asset.name), "size": .number(Double(asset.size)), "state": .string(asset.state),
            "browser_download_url": .string(
                asset.url ?? "https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/\(tag)/\(asset.name)"),
        ]
        object["digest"] = asset.digest.map(JSONValue.string) ?? .null
        return .object(object)
    }
    let root: JSONValue = ["tag_name": .string(tag), "draft": .bool(draft), "prerelease": .bool(prerelease), "assets": .array(list)]
    return try! JSONEncoder().encode(root)
}

/// The look-alike assets a real release carries, dSYMs first.
func apolloDecoys(version: String = "3.9.0") -> [ReleaseAsset] {
    [
        ReleaseAsset(name: "Apollo-Reborn-\(version)-dSYMs.zip"),
        ReleaseAsset(name: "Apollo-Reborn-\(version)-NOEXTENSIONS.ipa"),
        ReleaseAsset(name: "Apollo-Reborn-\(version)-GLASSICONS-NOEXTENSIONS.ipa"),
        ReleaseAsset(name: "Apollo-Reborn-\(version)-GLASS.ipa"),
        ReleaseAsset(name: "apollo-reborn_\(version)_iphoneos-arm.deb"),
        ReleaseAsset(name: "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa.sig"),
        ReleaseAsset(name: "apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa"),
    ]
}

/// A gorlev AltStore-style index with the Stremio app.
func stremioIndexJSON(
    tvos: Bool, version: String = "1.9.6", build: String = "142", downloadURL: String? = nil, sha256: String? = String(repeating: "cd", count: 32),
    size: Int = 2000, bundleId: String = "com.stremio.pal"
) -> Data {
    let url = downloadURL ?? (tvos
        ? "https://dl.strem.io/apple/\(version)b\(build)/tvos/stremio_tvOS.ipa"
        : "https://dl.strem.io/apple/\(version)b\(build)/ios/stremio_iOS.ipa")
    var entry: [String: JSONValue] = [
        "version": .string(version), "buildVersion": .string(build), "downloadURL": .string(url), "size": .number(Double(size)),
        "minOSVersion": .string(tvos ? "15.0" : "14.0"),
    ]
    entry["sha256"] = sha256.map(JSONValue.string) ?? .null
    let older: JSONValue = ["version": "0.0.1", "buildVersion": "1", "downloadURL": "https://dl.strem.io/old.ipa", "size": 1, "sha256": "00"]
    let root: JSONValue = [
        "name": "Stremio", "apps": [["name": "Stremio", "bundleIdentifier": .string(bundleId), "versions": [.object(entry), older]]],
    ]
    return try! JSONEncoder().encode(root)
}

// MARK: synthetic IPAs

/// IPAs are built once per process (codesign is slow) and shared.
actor SampleIPAs {
    static let shared = SampleIPAs()
    private var cache: [String: Task<Data, any Error>] = [:]

    /// `plain`: one app and no extension. `withExtension`: the app plus a Share extension.
    func data(_ kind: String) async throws -> Data {
        if let task = cache[kind] { return try await task.value }
        let task = Task<Data, any Error> {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let bundles: [BundleSpec] = kind == "withExtension"
                ? [.app(bundleId: "com.stremio.pal"), .appex(bundleId: "com.stremio.pal.share", point: "com.apple.share-services")]
                : [.app(bundleId: "io.example.apollo")]
            return try Data(contentsOf: URL(fileURLWithPath: try await makeIPA(bundles, in: dir.path)))
        }
        cache[kind] = task
        return try await task.value
    }
}

// MARK: world

let apolloApproved: [JSONValue] = [["app": "apollo"]]
let stremioApproved: [JSONValue] = [["app": "stremio-ios"], ["app": "stremio-tvos"]]

func fetchServices(_ paths: Paths, http: any HTTPTransport, runner: any Runner = FakeRunner()) -> Services {
    Services(
        runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: FakeKeychain(), home: paths, http: http)
}

/// A transport that serves the Apollo release for `ipa` (digest taken from the bytes unless overridden).
func apolloTransport(
    ipa: Data, version: String = "3.9.0", digest: String? = nil, declaredSize: Int? = nil, body: Data? = nil,
    assets: [ReleaseAsset]? = nil, delivery: (@Sendable (DownloadRequest) throws -> Delivery)? = nil
) -> FakeFetchTransport {
    let name = "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa"
    let exact = ReleaseAsset(name: name, size: declaredSize ?? ipa.count, digest: "sha256:" + (digest ?? sha256Hex(ipa)))
    let json = releaseJSON(tag: "v1.15.11_\(version)", assets: assets ?? (apolloDecoys(version: version) + [exact]))
    let served = body ?? ipa
    return FakeFetchTransport(metadata: [apolloAPI: json], download: delivery ?? { _ in Delivery(served) })
}

func stremioTransport(
    tvos: Bool, ipa: Data, version: String = "1.9.6", build: String = "142", downloadURL: String? = nil,
    delivery: (@Sendable (DownloadRequest) throws -> Delivery)? = nil
) -> FakeFetchTransport {
    let json = stremioIndexJSON(
        tvos: tvos, version: version, build: build, downloadURL: downloadURL, sha256: sha256Hex(ipa), size: ipa.count)
    return FakeFetchTransport(metadata: [tvos ? stremioTVOSIndex : stremioIOSIndex: json], download: delivery ?? { _ in Delivery(ipa) })
}

extension Envelope {
    var firstCode: String? { errors.first?.code }
}

func partFiles(_ paths: Paths) -> [String] {
    listing(paths.tmp).filter { $0.hasPrefix("fetch-") }
}

func stagedFiles(_ paths: Paths) -> [String] {
    listing(paths.tmp).filter { $0.hasPrefix("staged-") }
}

/// Sets a file's times `seconds` before the real current time. The sweep reads real mtimes against real time.
func backdate(_ path: String, by seconds: Int) {
    let stamp = timeval(tv_sec: time(nil) - seconds, tv_usec: 0)
    var times = [stamp, stamp]
    #expect(utimes(path, &times) == 0)
}

/// The operation lock is free: nothing in the command left it held.
func expectLockFree(_ paths: Paths, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try OperationLock.acquire(paths: paths).release()
    } catch {
        Issue.record("the operation lock is still held: \(error)", sourceLocation: sourceLocation)
    }
}

func scratchFolders(_ paths: Paths) -> [String] {
    listing(paths.tmp).filter { $0.hasPrefix("inspect-") }
}

// MARK: gated downloads

/// Serves the metadata, delivers one chunk of the body, then waits to be released.
final class GatedTransport: HTTPTransport {
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

/// The Apollo release for `ipa`, delivered in two halves with the gap between them under the test's control.
func gatedApollo(_ ipa: Data, version: String = "3.9.0") -> GatedTransport {
    let name = "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa"
    let json = releaseJSON(tag: "v1.15.11_\(version)", assets: [ReleaseAsset(name: name, size: ipa.count, digest: "sha256:" + sha256Hex(ipa))])
    let split = ipa.count / 2
    return GatedTransport(metadata: [apolloAPI: json], first: ipa.prefix(split), rest: ipa.dropFirst(split))
}
