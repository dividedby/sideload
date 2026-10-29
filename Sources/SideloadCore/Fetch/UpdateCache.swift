import Foundation

/// What a source's metadata said was the latest release, the fields `updates` keeps. `version` is the same string the manifest
/// and `installs[].version` use (Apollo `3.9.0`, Stremio `1.9.6b142`).
struct UpdateUpstream: Sendable, Equatable {
    var version: String
    var build: String?
    var minOS: String?
    var size: Int64
    var sha256: String

    init(version: String, build: String?, minOS: String?, size: Int64, sha256: String) {
        self.version = version
        self.build = build
        self.minOS = minOS
        self.size = size
        self.sha256 = sha256
    }

    init(_ asset: ResolvedAsset) {
        self.init(version: asset.version, build: asset.build, minOS: asset.minOS, size: asset.size, sha256: asset.upstreamDigest)
    }
}

/// One source's line in `updates.json`. The good values and `checkedAt` come from the last check that worked and survive a
/// failed one; `errorCode`, `errorAt` and `retryAfter` describe the last attempt only while it failed.
struct UpdateCacheEntry: Codable, Sendable, Equatable {
    var checkedAt: Date?
    var version: String?
    var build: String?
    var minOS: String?
    var size: Int64?
    var sha256: String?
    var errorCode: String?
    var errorAt: Date?
    /// Seconds from `errorAt` that a rate-limiting answer (403, 429) asked us to wait, capped at a day.
    var retryAfter: Int?

    var upstream: UpdateUpstream? {
        guard let version, let size, let sha256 else { return nil }
        return UpdateUpstream(version: version, build: build, minOS: minOS, size: size, sha256: sha256)
    }

    var isEmpty: Bool { checkedAt == nil && errorAt == nil }

    func succeeded(_ upstream: UpdateUpstream, at now: Date) -> UpdateCacheEntry {
        UpdateCacheEntry(
            checkedAt: now, version: upstream.version, build: upstream.build, minOS: upstream.minOS, size: upstream.size,
            sha256: upstream.sha256)
    }

    /// The last good values stay; only the error fields change.
    func failed(code: String, retryAfter: Int?, at now: Date) -> UpdateCacheEntry {
        var next = self
        next.errorCode = code
        next.errorAt = now
        next.retryAfter = retryAfter.map { min(max($0, 0), UpdateCadence.maxRetryAfter) }
        return next
    }
}

/// `$SIDELOAD_HOME/updates.json`, schema 1: advisory only. `fetch` always resolves the source again and every hash gate is
/// unchanged, so nothing here can approve, sign or install anything. Holds no secrets.
struct UpdateCache: Codable, Sendable, Equatable {
    static let schema = 1
    var schema: Int = UpdateCache.schema
    var apps: [String: UpdateCacheEntry] = [:]
}

enum UpdateCadence {
    static let interval: TimeInterval = 6 * 3600
    static let errorInterval: TimeInterval = 3600
    /// The least time between two attempts for a source, even for `--force`.
    static let forceFloor: TimeInterval = 5 * 60
    static let maxRetryAfter = 24 * 3600

    enum Decision: Equatable {
        case check
        case wait(until: Date)
    }

    /// Whether `now` allows a network check: 6 h after a good one, 1 h after a failed one (or what a 403 or 429 asked for, at
    /// most 24 h). `force` skips those two waits but keeps the 5-minute floor and a rate limit the server asked for.
    static func decide(_ entry: UpdateCacheEntry?, now: Date, force: Bool) -> Decision {
        guard let entry, !entry.isEmpty else { return .check }
        var notBefore = Date.distantPast
        if let errorAt = entry.errorAt, errorAt >= (entry.checkedAt ?? .distantPast) {
            notBefore = errorAt.addingTimeInterval(force ? forceFloor : errorInterval)
            if let asked = entry.retryAfter { notBefore = max(notBefore, errorAt.addingTimeInterval(TimeInterval(min(asked, maxRetryAfter)))) }
        } else if let checkedAt = entry.checkedAt {
            notBefore = checkedAt.addingTimeInterval(force ? forceFloor : interval)
        }
        return now >= notBefore ? .check : .wait(until: notBefore)
    }
}

struct UpdateCacheStore: Sendable {
    let paths: Paths
    /// The final write; injectable so tests can fail it.
    let writer: @Sendable (Data, String) throws -> Void
    static let maxBytes = 64 << 10
    /// How far ahead of `now` a stored time may be before the clock is assumed to have moved back.
    static let skew: TimeInterval = 60

    init(paths: Paths) {
        self.init(paths: paths) { data, path in try AtomicFile.write(data, to: path) }
    }

    init(paths: Paths, writer: @escaping @Sendable (Data, String) throws -> Void) {
        self.paths = paths
        self.writer = writer
    }

    /// Never throws for a bad file: a missing, oversized, unparseable, wrong-schema file is an empty cache, and an entry that
    /// is future-dated or carries a value that fails the resolver's own checks is dropped. `repaired` says the file on disk is
    /// not what a clean write would leave, so the caller rewrites it. Only an unreadable file (an I/O error) throws.
    func load(now: Date) throws -> (cache: UpdateCache, repaired: Bool) {
        guard let data = try readFile(paths.updates) else { return (UpdateCache(), false) }
        guard data.count <= Self.maxBytes, let raw = try? Self.decoder.decode(UpdateCache.self, from: data),
            raw.schema == UpdateCache.schema
        else { return (UpdateCache(), true) }
        var clean = UpdateCache()
        for (app, entry) in raw.apps where FetchCatalog.appNames.contains(app) {
            let kept = Self.sanitized(entry, now: now)
            if !kept.isEmpty { clean.apps[app] = kept }
        }
        return (clean, clean != raw)
    }

    func save(_ cache: UpdateCache) throws {
        var stamped = cache
        for (app, entry) in cache.apps {
            var e = entry
            e.checkedAt = e.checkedAt.map(wholeSeconds)
            e.errorAt = e.errorAt.map(wholeSeconds)
            stamped.apps[app] = e
        }
        do {
            try writer(try Self.encoder.encode(stamped) + Data("\n".utf8), paths.updates)
        } catch {
            throw SideloadError(
                "UPDATES_WRITE_FAILED", "updates.json could not be written.",
                fix: "Check the permissions and free space of $SIDELOAD_HOME.")
        }
    }

    // MARK: validation

    private static let minOSShape = try! NSRegularExpression(pattern: #"^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$"#)
    private static let codeShape = try! NSRegularExpression(pattern: #"^[A-Z][A-Z0-9_]{0,47}$"#)
    private static let digestShape = try! NSRegularExpression(pattern: #"^[0-9a-f]{64}$"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Strings read from the file go through the same checks the resolver applies to the source's own metadata.
    static func sanitized(_ entry: UpdateCacheEntry, now: Date) -> UpdateCacheEntry {
        let limit = now.addingTimeInterval(skew)
        var out = UpdateCacheEntry()
        if let checkedAt = entry.checkedAt, checkedAt <= limit,
            let version = entry.version, SourceResolver.isSafeToken(version),
            let size = entry.size, size > 0, size <= FetchLimits.maxIPABytes,
            let sha256 = entry.sha256, matches(digestShape, sha256)
        {
            out.checkedAt = checkedAt
            out.version = version
            out.size = size
            out.sha256 = sha256
            out.build = entry.build.flatMap { SourceResolver.isSafeToken($0) ? $0 : nil }
            out.minOS = entry.minOS.flatMap { matches(minOSShape, $0) ? $0 : nil }
        }
        if let errorAt = entry.errorAt, errorAt <= limit, errorAt >= (out.checkedAt ?? .distantPast),
            let code = entry.errorCode, matches(codeShape, code)
        {
            out.errorAt = errorAt
            out.errorCode = code
            out.retryAfter = entry.retryAfter.flatMap { (0...UpdateCadence.maxRetryAfter).contains($0) ? $0 : nil }
        }
        return out
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
