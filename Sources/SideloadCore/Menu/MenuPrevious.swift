import Foundation

/// A fetched, approved IPA that is still on disk: what "Reinstall previous version" shows and signs. The rule that picks one
/// for a row is `pick`; the loader reads the manifest once (`stored`), the snapshot builder only applies the rule.
public struct MenuPrevious: Sendable, Hashable {
    /// The manifest's spelling ("3.9.0", "1.9.6b142").
    public var version: String
    public var build: String?
    /// The full SHA-256 of the stored file.
    public var sha256: String
    public var size: Int64
    /// The stricter of the source's declared minimum OS and the one the binary says; nil when neither is known.
    public var minOS: String?

    public init(version: String, build: String? = nil, sha256: String, size: Int64, minOS: String? = nil) {
        self.version = version
        self.build = build
        self.sha256 = sha256
        self.size = size
        self.minOS = minOS
    }

    /// The manifest's approved entries whose file is on disk, by app (`hasFile` is false for a pruned entry, a missing file
    /// and a link). Pure over its arguments.
    static func candidates(in manifest: Manifest, hasFile: (ManifestEntry) -> Bool) -> [String: [MenuPrevious]] {
        var out: [String: [MenuPrevious]] = [:]
        for entry in manifest.entries where entry.approved && entry.prunedAt == nil && hasFile(entry) {
            out[entry.app, default: []].append(
                MenuPrevious(
                    version: entry.version, build: entry.build, sha256: entry.sha256, size: entry.size,
                    minOS: OSVersion.strictest([entry.minOS, entry.inspectMinOS])))
        }
        return out
    }

    /// The local read the panel's load makes: `manifest.json` and one `lstat` per approved entry. An unreadable manifest says
    /// nothing (no offer).
    public static func stored(_ services: Services) -> [String: [MenuPrevious]] {
        let store = ManifestStore(paths: services.home)
        guard let manifest = try? store.load() else { return [:] }
        return candidates(in: manifest, hasFile: store.hasFile)
    }

    /// The newest candidate that compares older than `installed`. A candidate or an installed version that cannot be parsed,
    /// and one that is equal or newer, is never offered; nil when none is left.
    static func pick(_ candidates: [MenuPrevious], installed: String) -> MenuPrevious? {
        var best: MenuPrevious?
        for candidate in candidates
        where VersionOrder.compare(installed: installed, upstream: candidate.version) == .older {
            guard let current = best else {
                best = candidate
                continue
            }
            if VersionOrder.compare(installed: current.version, upstream: candidate.version) == .newer { best = candidate }
        }
        return best
    }
}
