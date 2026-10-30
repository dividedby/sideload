import CryptoKit
import Darwin
import Foundation
import Synchronization

public struct FetchOptions: Sendable, Equatable {
    public var app: String?
    /// The owner's approval of one version already in the manifest (design section 16). Agents must not pass it.
    public var approve: Bool
    /// The manifest version `--approve` applies to; required with `--approve`, not allowed without it.
    public var version: String?

    public init(app: String? = nil, approve: Bool = false, version: String? = nil) {
        self.app = app
        self.approve = approve
        self.version = version
    }
}

/// `fetch --app <app> [--approve]` (design section 8, approved sources). Without `--approve` it reads the
/// source's metadata, downloads the one IPA it names over `Services.http`, checks our own SHA-256 against the
/// publisher's, inspects the archive and records it in `manifest.json` as not approved. With `--approve` it
/// re-checks the stored file and marks that version approved; it does no network. The download runs without
/// `.op.lock` (it can take minutes and the lock is shared with the lab); the lock is taken only to record the
/// verified file, and for the whole of `--approve`. A busy lock at that point keeps the verified file as a staged
/// file for the re-run, so the bytes are not downloaded twice.
public enum FetchCommand {
    static let command = "fetch"
    static let downloadTimeout: TimeInterval = 900

    public static func run(_ services: Services, _ options: FetchOptions) async -> Envelope {
        await run(services, options, registry: .shared)
    }

    static func run(_ services: Services, _ options: FetchOptions, registry: ScratchRegistry) async -> Envelope {
        do {
            return .result(command, try await execute(services, options, registry: registry))
        } catch {
            return .from(error, command: command)
        }
    }

    private static func execute(_ services: Services, _ options: FetchOptions, registry: ScratchRegistry) async throws -> [String: JSONValue] {
        guard let app = options.app, !app.isEmpty else {
            throw SideloadError(
                "USAGE", "fetch needs --app.", fix: "sideload fetch --app <\(FetchCatalog.appNames.joined(separator: "|"))> [--approve --version <v>]")
        }
        if options.approve, options.version?.isEmpty != false {
            throw SideloadError(
                "USAGE", "--approve needs --version <v>, the exact version fetch reported.",
                fix: "sideload fetch --app \(app) --approve --version <v>")
        }
        if !options.approve, options.version != nil {
            throw SideloadError("USAGE", "--version only applies to --approve.", fix: "sideload fetch --app \(app) --approve --version <v>")
        }
        let source = try FetchCatalog.approved(app: app, config: try services.store.load())
        sweepStale(in: services.home.tmp)
        let run = FetchRun(services: services, source: source, registry: registry)
        guard options.approve else { return try await run.download() }
        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }
        return try await run.approve(version: options.version ?? "")
    }
}

private struct FetchRun {
    let services: Services
    let source: FetchSource
    let registry: ScratchRegistry
    var store: ManifestStore { ManifestStore(paths: services.home) }

    // MARK: fetch

    func download() async throws -> [String: JSONValue] {
        let manifest = try store.load()
        services.log("fetch: reading the \(source.app) metadata")
        let asset = try SourceResolver.resolve(source, json: try await metadata())
        try SourceResolver.requireDownloadHost(asset, source: source)

        let prior = manifest.entry(app: asset.app, version: asset.version)
        if let prior {
            guard prior.upstreamDigest == asset.upstreamDigest else { throw Self.contentChanged(asset) }
            // A pruned entry (`clean`) is not stored, whatever a crash left behind: the download below replaces it and clears the mark.
            if prior.prunedAt == nil, let stored = try? FileDigest.sha256(path: store.path(of: prior)), stored.hex == prior.sha256 {
                services.log("fetch: \(asset.app) \(asset.version) is already stored")
                // A file an earlier busy run kept for this digest is no longer needed.
                if isHex(asset.upstreamDigest, count: 64, lowercaseOnly: true) { unlink(FetchStaging.path(digest: asset.upstreamDigest, tmp: services.home.tmp)) }
                return try await report(prior, downloaded: false, alreadyApproved: prior.approved)
            }
        }

        // The partial file lives in a registered 0700 folder, so an interrupt removes it (the CLI's signal
        // handler empties the registry and exits without running this function's cleanup).
        let scratch = try FetchScratch.create(under: services.home.tmp, registry: registry)
        defer { scratch.remove() }
        let part = scratch.path + "/download.part"

        let (digest, count) =
            if let staged = FetchStaging.claim(asset: asset, into: part, services: services) {
                staged
            } else {
                try await downloadBody(asset, to: part)
            }

        try checkNotCancelled()
        services.log("fetch: inspecting the archive")
        let inspected = try await inspect(path: part)

        return try commit(asset, part: part, digest: digest, count: count, inspected: inspected)
    }

    private func checkNotCancelled() throws {
        if registry.isClosed || Task.isCancelled {
            throw SideloadError("CANCELLED", "fetch was interrupted.", fix: "Re-run the command.")
        }
    }

    /// Streams the body into `part`, then checks the byte count and our SHA-256 against what the source declared.
    private func downloadBody(_ asset: ResolvedAsset, to part: String) async throws -> (digest: String, count: Int64) {
        let sink = try DownloadSink(path: part, maxBytes: asset.size)
        defer { sink.abort() }

        services.log("fetch: downloading \(asset.fileName)")
        let response: DownloadResponse
        do {
            let request = DownloadRequest(
                url: asset.url, allowedHosts: source.downloadHosts, maxRedirects: FetchLimits.maxRedirects, maxBytes: asset.size,
                timeout: FetchCommand.downloadTimeout)
            response = try await services.http.download(request) { try sink.accept($0) }
        } catch {
            throw SourceMetadata.map(error)
        }
        guard response.status == 200 else {
            throw SideloadError(
                "FETCH_HTTP_ERROR", "The download answered HTTP \(response.status).", fix: "Retry later.",
                data: ["status": .number(Double(response.status))])
        }
        guard DownloadPolicy.permits(response.finalURL, hosts: source.downloadHosts) else {
            throw SourceMetadata.redirectRefused
        }
        let (digest, count) = try sink.finish()
        // The source declared this size and it was the cap; a short body is as wrong as a long one.
        guard count == asset.size else {
            throw SideloadError(
                "SIZE_MISMATCH", "The download is \(count) bytes but the source declared \(asset.size). The file was deleted.",
                fix: "Retry; if it repeats, do not use this release.",
                data: ["declared": .number(Double(asset.size)), "received": .number(Double(count))])
        }
        guard digest == asset.upstreamDigest else {
            throw SideloadError(
                "DIGEST_MISMATCH", "The downloaded file's SHA-256 does not match the publisher's. The file was deleted.",
                fix: "Retry; if it repeats, do not use this release.",
                data: ["expected": .string(asset.upstreamDigest), "actual": .string(digest)])
        }
        return (digest, count)
    }

    /// The short critical section: under `.op.lock`, reload the manifest, re-check the version, move the file into
    /// the store and save. No awaits. A busy lock keeps the verified file staged for the re-run instead.
    private func commit(
        _ asset: ResolvedAsset, part: String, digest: String, count: Int64, inspected: Inspected
    ) throws -> [String: JSONValue] {
        try checkNotCancelled()
        let lock: OperationLock
        do {
            lock = try OperationLock.acquire(paths: services.home)
        } catch let busy as SideloadError where busy.code == OperationLock.busyCode {
            let staged = rename(part, FetchStaging.path(digest: digest, tmp: services.home.tmp)) == 0
            throw SideloadError(
                busy.code, busy.message,
                fix: staged
                    ? "Re-run `sideload fetch --app \(asset.app)` when it finishes; the verified download is kept for 24 h and is not downloaded again."
                    : busy.fix)
        }
        defer { lock.release() }

        var manifest = try store.load()
        let prior = manifest.entry(app: asset.app, version: asset.version)
        if let prior {
            guard prior.upstreamDigest == asset.upstreamDigest else { throw Self.contentChanged(asset) }
            // Another fetch recorded this version while ours downloaded: keep theirs.
            if prior.prunedAt == nil, let stored = try? FileDigest.sha256(path: store.path(of: prior)), stored.hex == prior.sha256 {
                services.log("fetch: \(asset.app) \(asset.version) was stored by another run")
                return Self.data(prior, store: store, downloaded: false, alreadyApproved: prior.approved, inspected: inspected)
            }
        }

        let directory = "\(services.home.downloads)/\(asset.app)/\(asset.version)"
        try makeDirectories(directory, mode: 0o700)
        guard rename(part, directory + "/" + asset.fileName) == 0 else { throw ioError("rename") }

        let keepApproval = prior?.sha256 == digest
        let entry = ManifestEntry(
            app: asset.app, version: asset.version, file: "\(asset.app)/\(asset.version)/\(asset.fileName)",
            urlHost: asset.url.host ?? "", sha256: digest, upstreamDigest: asset.upstreamDigest, size: count,
            fetchedAt: services.clock.now(), approved: keepApproval && prior?.approved == true,
            approvedAt: keepApproval ? prior?.approvedAt : nil, build: asset.build ?? inspected.build,
            declaredSize: asset.size, minOS: asset.minOS, inspectMinOS: inspected.minOS)
        manifest.upsert(entry)
        do {
            try store.save(manifest)
        } catch {
            if prior == nil { unlink(directory + "/" + asset.fileName) }
            throw error
        }
        return Self.data(entry, store: store, downloaded: true, alreadyApproved: false, inspected: inspected)
    }

    // MARK: approve

    /// Marks exactly `version` of the app approved, after re-hashing the stored file against the manifest and
    /// inspecting it again. No network.
    func approve(version: String) async throws -> [String: JSONValue] {
        var manifest = try store.load()
        guard var entry = manifest.entry(app: source.app, version: version) else {
            throw SideloadError(
                "NOT_FETCHED", "Version \(printableCut(version)) of \(source.app) is not in the manifest, so there is nothing to approve.",
                fix: "Run `sideload fetch --app \(source.app)`, then approve the version it reports: --approve --version <v>.")
        }
        let already = entry.approved
        let inspected = try await verifiedInspection(of: entry)
        if !already {
            entry.approved = true
            entry.approvedAt = services.clock.now()
            manifest.upsert(entry)
            try store.save(manifest)
        }
        return Self.data(entry, store: store, downloaded: false, alreadyApproved: already, inspected: inspected)
    }

    // MARK: shared

    private func report(_ entry: ManifestEntry, downloaded: Bool, alreadyApproved: Bool) async throws -> [String: JSONValue] {
        Self.data(entry, store: store, downloaded: downloaded, alreadyApproved: alreadyApproved, inspected: try await verifiedInspection(of: entry))
    }

    /// The stored file must still hash to the manifest's value; then it is inspected.
    private func verifiedInspection(of entry: ManifestEntry) async throws -> Inspected {
        if entry.prunedAt != nil {
            throw SideloadError(
                "IPA_PRUNED", "The fetched file for \(entry.app) \(printableCut(entry.version)) was deleted by `sideload clean`.",
                fix: "Run `sideload fetch --app \(entry.app)` to download it again.")
        }
        let path = try store.path(of: entry)
        guard let stored = try FileDigest.sha256(path: path) else {
            throw SideloadError(
                "IPA_MISSING", "The fetched file for \(entry.app) \(entry.version) is gone.",
                fix: "Remove its manifest entry and run `sideload fetch --app \(entry.app)` again.")
        }
        guard stored.hex == entry.sha256 else {
            throw SideloadError(
                "DIGEST_MISMATCH", "The stored file no longer matches the manifest's SHA-256. Nothing was approved.",
                fix: "Remove the file and its manifest entry, then fetch again.",
                data: ["expected": .string(entry.sha256), "actual": .string(stored.hex)])
        }
        return try await inspect(path: path)
    }

    private func metadata() async throws -> Data {
        try await SourceMetadata.fetch(services, source)
    }

    struct Inspected {
        var summary: JSONValue
        var warnings: [JSONValue]
        /// The app's `CFBundleVersion` and the Mach-O minimum OS, as `inspect` read them.
        var build: String?
        var minOS: String?
    }

    private func inspect(path: String) async throws -> Inspected {
        let inspector = IPAInspector(
            runner: services.runner, tmp: services.home.tmp, registry: registry, limits: InspectLimits(), log: services.log)
        let report = try await inspector.inspect(path: path)
        let app = report["app"]?.fields ?? [:]
        return Inspected(
            summary: Self.summarize(report), warnings: report["warnings"]?.list ?? [], build: app["build"]?.text,
            minOS: app["minOS"]?.text)
    }

    /// What the owner needs to decide on `--approve`: bundle ID, version, platform and the extensions found.
    static func summarize(_ report: [String: JSONValue]) -> JSONValue {
        let app = report["app"]?.fields ?? [:]
        var out: [String: JSONValue] = [:]
        for key in ["bundleId", "name", "version", "build", "minOS", "platform", "deviceFamily"] { out[key] = app[key] ?? .null }
        let extensions = (report["extensions"]?.list ?? []).map { item -> JSONValue in
            let fields = item.fields ?? [:]
            return .object(["path", "bundleId", "extensionPoint"].reduce(into: [:]) { $0[$1] = fields[$1] ?? .null })
        }
        out["extensions"] = .array(extensions)
        out["extensionCount"] = .number(Double(extensions.count))
        out["appGroups"] = report["appGroups"] ?? .array([])
        out["hasEmbeddedProvision"] = report["hasEmbeddedProvision"] ?? .null
        return .object(out)
    }

    private static func data(
        _ entry: ManifestEntry, store: ManifestStore, downloaded: Bool, alreadyApproved: Bool, inspected: Inspected
    ) -> [String: JSONValue] {
        let stamp = ISO8601DateFormatter()
        var out: [String: JSONValue] = [
            "app": .string(entry.app), "version": .string(entry.version), "file": .string(entry.file),
            "path": .string((try? store.path(of: entry)) ?? ""), "downloaded": .bool(downloaded),
            "approved": .bool(entry.approved), "alreadyApproved": .bool(alreadyApproved), "sha256": .string(entry.sha256),
            "upstreamDigest": .string(entry.upstreamDigest), "size": .number(Double(entry.size)), "urlHost": .string(entry.urlHost),
            "build": entry.build.map(JSONValue.string) ?? .null,
            "declaredSize": entry.declaredSize.map { .number(Double($0)) } ?? .null,
            "minOS": entry.minOS.map(JSONValue.string) ?? .null,
            "inspectMinOS": entry.inspectMinOS.map(JSONValue.string) ?? .null,
            "fetchedAt": .string(stamp.string(from: entry.fetchedAt)), "inspect": inspected.summary,
            "warnings": .array(inspected.warnings),
        ]
        if let at = entry.approvedAt { out["approvedAt"] = .string(stamp.string(from: at)) }
        if !entry.approved { out["next"] = .string("Review `inspect`, then the owner runs: sideload fetch --app \(entry.app) --approve --version \(entry.version)") }
        return out
    }

    // MARK: errors

    private static func contentChanged(_ asset: ResolvedAsset) -> SideloadError {
        SideloadError(
            "VERSION_CONTENT_CHANGED", "The publisher now lists a different SHA-256 for \(asset.app) \(asset.version) than the one fetched before.",
            fix: "Treat this as a swapped file. Inspect it by hand; the owner removes the manifest entry and its folder to start over.")
    }

}

/// Streams a body to a 0600 file while hashing it. Refuses to take more than `maxBytes`.
private final class DownloadSink: Sendable {
    private struct State {
        var fd: Int32
        var hasher = SHA256()
        var count: Int64 = 0
    }

    private let state: Mutex<State>
    private let maxBytes: Int64

    init(path: String, maxBytes: Int64) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 { throw ioError("create download file") }
        state = Mutex(State(fd: fd))
        self.maxBytes = maxBytes
    }

    func accept(_ chunk: Data) throws {
        try state.withLock { s in
            guard s.fd >= 0 else { throw ioError("write", EBADF) }
            s.count += Int64(chunk.count)
            if s.count > maxBytes {
                throw SideloadError("DOWNLOAD_TOO_LARGE", "The download is larger than the size the source declared.", fix: "Nothing was kept.")
            }
            s.hasher.update(data: chunk)
            try chunk.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(s.fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw ioError("write")
                    }
                    offset += n
                }
            }
        }
    }

    /// Flushes and closes; returns the SHA-256 (lowercase hex) and the byte count.
    func finish() throws -> (digest: String, count: Int64) {
        try state.withLock { s in
            guard s.fd >= 0 else { throw ioError("close", EBADF) }
            let synced = fsync(s.fd) == 0
            let syncError = errno
            let closed = close(s.fd) == 0
            let closeError = errno
            s.fd = -1
            if !synced { throw ioError("fsync", syncError) }
            if !closed { throw ioError("close", closeError) }
            return (s.hasher.finalize().map { String(format: "%02x", $0) }.joined(), s.count)
        }
    }

    /// Idempotent.
    func abort() {
        state.withLock { s in
            if s.fd >= 0 { close(s.fd) }
            s.fd = -1
        }
    }
}

private extension JSONValue {
    var list: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var text: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var fields: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
