import CryptoKit
import Darwin
import Foundation

/// One downloaded IPA (design section 9). `approved` is the owner's per-version approval (section 16); `sign`
/// refuses an entry that is not approved or whose file no longer hashes to `sha256`.
public struct ManifestEntry: Codable, Sendable, Equatable {
    public var app: String
    public var version: String
    /// `<app>/<version>/<file>`, relative to `$SIDELOAD_HOME/downloads`.
    public var file: String
    public var urlHost: String
    /// Our own SHA-256 of the file, computed while it streamed in.
    public var sha256: String
    /// What the publisher said it should be; always equal to `sha256` (a difference is `DIGEST_MISMATCH`).
    public var upstreamDigest: String
    /// Bytes actually received.
    public var size: Int64
    public var fetchedAt: Date
    public var approved: Bool
    public var approvedAt: Date?
    /// The upstream build number (Stremio's `buildVersion`), else the app's `CFBundleVersion` from `inspect`.
    public var build: String?
    /// The size the source declared (the download's cap). Compare with `size`.
    public var declaredSize: Int64?
    /// The minimum OS the source declares (Stremio only; Apollo declares none).
    public var minOS: String?
    /// The minimum OS `inspect` read from the app's binary (the value the OS enforces). `sign` checks this
    /// against the device's OS for every app.
    public var inspectMinOS: String?
}

/// `$SIDELOAD_HOME/manifest.json`, schema 1. Only commands holding `.op.lock` write it.
public struct Manifest: Codable, Sendable, Equatable {
    public static let schema = 1
    public var schema: Int = Manifest.schema
    public var entries: [ManifestEntry] = []

    public init() {}

    public func entry(app: String, version: String) -> ManifestEntry? {
        entries.first { $0.app == app && $0.version == version }
    }

    mutating func upsert(_ entry: ManifestEntry) {
        if let i = entries.firstIndex(where: { $0.app == entry.app && $0.version == entry.version }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }
}

public struct ManifestStore: Sendable {
    public let paths: Paths
    let writer: @Sendable (Data, String) throws -> Void

    public init(paths: Paths) {
        self.init(paths: paths) { data, path in try AtomicFile.write(data, to: path) }
    }

    init(paths: Paths, writer: @escaping @Sendable (Data, String) throws -> Void) {
        self.paths = paths
        self.writer = writer
    }

    /// A missing file is an empty manifest. One that does not parse is `MANIFEST_INVALID`; its content is never echoed.
    public func load() throws -> Manifest {
        guard let data = try readFile(paths.manifest) else { return Manifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data), manifest.schema == Manifest.schema else {
            throw SideloadError(
                "MANIFEST_INVALID", "manifest.json is not a valid schema \(Manifest.schema) manifest.",
                fix: "Move $SIDELOAD_HOME/manifest.json aside and run `sideload fetch --app <app>` again.")
        }
        return manifest
    }

    func save(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try writer(try encoder.encode(manifest) + Data("\n".utf8), paths.manifest)
        } catch {
            throw SideloadError(
                "MANIFEST_WRITE_FAILED", "manifest.json could not be written.",
                fix: "Check the permissions and free space of $SIDELOAD_HOME.")
        }
    }

    /// Absolute path of an entry's file. A `file` that is not `<app>/<version>/<name>` of plain names is refused,
    /// so a hand-edited manifest cannot point outside `downloads/`.
    public func path(of entry: ManifestEntry) throws -> String {
        let parts = entry.file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == entry.app, parts[1] == entry.version, parts.allSatisfy(SourceResolver.isSafeToken) else {
            throw SideloadError(
                "MANIFEST_INVALID", "A manifest entry names a file outside downloads/<app>/<version>/.",
                fix: "Move $SIDELOAD_HOME/manifest.json aside and run `sideload fetch --app <app>` again.")
        }
        return paths.downloads + "/" + entry.file
    }
}

/// Streaming SHA-256 of a file, opened without following a link. Nil when there is no regular file there.
enum FileDigest {
    static func sha256(path: String) throws -> (hex: String, size: Int64)? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT || errno == ELOOP { return nil }
            throw ioError("open")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ioError("stat") }
        guard st.st_mode & S_IFMT == S_IFREG else { return nil }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total: Int64 = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ioError("read")
            }
            if n == 0 { break }
            hasher.update(data: buffer[0..<n])
            total += Int64(n)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }
}
