import Foundation

/// What one approved source last listed, as the panel keeps it (`updates.json`, design sections 8 and 12).
public struct MenuUpstream: Sendable, Equatable {
    /// The manifest's spelling ("3.10.0", "1.9.6b142").
    public var version: String
    public var minOS: String?
    /// When the values were read from the source.
    public var checkedAt: Date?
    /// The last attempt failed with this code; the values above are then the last good ones.
    public var errorCode: String?

    public init(version: String, minOS: String? = nil, checkedAt: Date? = nil, errorCode: String? = nil) {
        self.version = version
        self.minOS = minOS
        self.checkedAt = checkedAt
        self.errorCode = errorCode
    }
}

/// The panel's two ways to know what upstream lists: the local `updates.json` (`cached`, part of the local load) and one
/// network check (`check`, the only network call the panel makes on its own, run by the model as a task of its own after the
/// device reads). Both are advisory: `fetch` resolves the source again and every hash gate is unchanged.
public enum MenuUpdates {
    /// The last good listing per app from `updates.json`, with the failure of the last attempt if it was one. Reads one
    /// local file; an unreadable or invalid file says nothing.
    public static func cached(_ services: Services) -> [String: MenuUpstream] {
        guard let listed = try? UpdateCacheStore(paths: services.home).listings(now: services.clock.now()) else { return [:] }
        return listed.compactMapValues { upstream(version: $0.upstream, checkedAt: $0.checkedAt, errorCode: $0.errorCode) }
    }

    /// `sideload updates` in process: one metadata GET per approved source that has an install on a saved device, when the
    /// cadence allows (6 h per source, 1 h after an error; `force` is "Check status now", which keeps the 5-minute floor).
    /// Read from each source's own status, never from the envelope's `ok`: a replayed cached error would make that false
    /// although the listing is fine. A run that fails as a whole (config unreadable, cancelled) returns nothing.
    public static func check(_ services: Services, force: Bool) async -> [String: MenuUpstream] {
        guard let report = try? await UpdateCheck.run(services, app: nil, force: force) else { return [:] }
        var out: [String: MenuUpstream] = [:]
        for source in report.sources where source.status != .skipped {
            let code = source.status == .error ? source.failure?.code : nil
            if let listed = upstream(version: source.upstream, checkedAt: source.checkedAt, errorCode: code) { out[source.app] = listed }
        }
        return out
    }

    /// `fresh` over `stored`: a listing read at the same time or later wins, so a check whose file could not be written
    /// still shows, and an older in-memory answer never hides a newer file (the owner ran `sideload updates` meanwhile).
    static func merged(_ stored: [String: MenuUpstream], with fresh: [String: MenuUpstream]) -> [String: MenuUpstream] {
        var out = stored
        for (app, listed) in fresh where (listed.checkedAt ?? .distantPast) >= (stored[app]?.checkedAt ?? .distantPast) {
            out[app] = listed
        }
        return out
    }

    private static func upstream(version: UpdateUpstream?, checkedAt: Date?, errorCode: String?) -> MenuUpstream? {
        guard let version else { return nil }
        return MenuUpstream(version: version.version, minOS: version.minOS, checkedAt: checkedAt, errorCode: errorCode)
    }
}
