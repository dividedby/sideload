import Foundation

/// What `source remove --app a` would remove and what it leaves, read from local files only (config, manifest, ledger): no
/// network, no lock, no write. The command's preview and the menu bar app's Remove source confirm both show this.
public struct SourceRemovePreview: Sendable, Hashable {
    public var app: String
    /// The first entry's `kind` ("altstoreIndex", "githubRelease"), cut to printable ASCII.
    public var kind: String
    /// The first entry's address (`url`, or `repo`), cut to printable ASCII.
    public var source: String
    /// The app's `customSources` entries (an entry the loader ignored counts too).
    public var sourceEntries: Int
    /// The app's `approvedSources` entries.
    public var approvalEntries: Int
    /// What stays: the `customApps` entry, and the manifest entries and installs (nil when that file cannot be read).
    public var customApp: Bool
    public var manifestEntries: Int?
    public var installs: Int?

    /// What the removal removes: compared under the lock when the remove is checked against a preview the owner saw.
    var target: SourceRemove.Target {
        SourceRemove.Target(
            kind: kind, source: source, sourceEntries: sourceEntries,
            approvalEntries: approvalEntries)
    }

    var staysJSON: [String: JSONValue] {
        [
            "customApp": .bool(customApp),
            "manifestEntries": manifestEntries.map { .number(Double($0)) } ?? .null,
            "installs": installs.map { .number(Double($0)) } ?? .null,
        ]
    }
}

/// One app `source remove` can take: an app with a `customSources` entry that is not built in.
public struct SourceRemovable: Sendable, Equatable {
    public var app: String
    public var kind: String
    public var source: String
}

public enum SourceRemove {
    public static let builtInCode = "SOURCE_BUILT_IN"
    public static let notFoundCode = "SOURCE_NOT_FOUND"

    /// The part of the config a removal acts on: the first entry's kind and address, and the entry counts.
    struct Target: Sendable, Hashable {
        var kind: String
        var source: String
        var sourceEntries: Int
        var approvalEntries: Int
    }

    /// `app`'s target in `config`; nil when it has no `customSources` entry.
    static func target(_ config: Config, app: String) throws -> Target? {
        let entries = try SourceAdd.entries(config, "customSources").filter {
            SourceAdd.field($0, "app") == app
        }
        guard let entry = entries.first else { return nil }
        return Target(
            kind: printableCut(SourceAdd.field(entry, "kind") ?? ""), source: address(entry),
            sourceEntries: entries.count,
            approvalEntries: config.approvedSources.filter { approval(app, $0) }.count)
    }

    /// The preview for `app`. Throws `SOURCE_BUILT_IN` for a built-in app and `SOURCE_NOT_FOUND` for an app with no entry.
    public static func preview(_ services: Services, app: String) throws -> SourceRemovePreview {
        if AppRegistry.builtIns.contains(where: { $0.id == app }) {
            throw SideloadError(
                builtInCode, "\(app) is a built-in app; its source is part of sideload.",
                fix:
                    "A built-in source cannot be removed. Narrow its hosts in approvedSources instead."
            )
        }
        let config = try services.store.load()
        guard let target = try target(config, app: app) else { throw notFound(app) }
        let manifest = (try? ManifestStore(paths: services.home).load())?.entries.filter {
            $0.app == app
        }.count
        let installs = (try? services.ledgerStore.load())?.installs.filter { $0.app == app }.count
        return SourceRemovePreview(
            app: app, kind: target.kind, source: target.source,
            sourceEntries: target.sourceEntries, approvalEntries: target.approvalEntries,
            customApp: config.appRegistry.app(app) != nil, manifestEntries: manifest,
            installs: installs)
    }

    /// The write behind `source remove --yes`: under `.op.lock`, one config edit removes `app`'s `customSources` and
    /// `approvedSources` entries. With `expected` (the menu's confirm click), the edit first compares the config with the
    /// preview the owner saw, under the same lock, and refuses with `SOURCE_CHANGED`, writing nothing, when the source is gone
    /// or differs. Returns how many entries of each went.
    static func remove(_ services: Services, app: String, expected: SourceRemovePreview?)
        async throws -> (sources: Int, approvals: Int)
    {
        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }
        return try await services.store.update { config -> (sources: Int, approvals: Int) in
            if let expected, try target(config, app: app) != expected.target {
                throw changed()
            }
            let all = try SourceAdd.entries(config, "customSources")
            let kept = all.filter { SourceAdd.field($0, "app") != app }
            guard kept.count < all.count else { throw notFound(app) }
            if kept.isEmpty {
                config.extra.removeValue(forKey: "customSources")
            } else {
                config.extra["customSources"] = .array(kept)
            }
            let approvalsBefore = config.approvedSources.count
            config.approvedSources.removeAll { approval(app, $0) }
            return (all.count - kept.count, approvalsBefore - config.approvedSources.count)
        }
    }

    static func changed() -> SideloadError {
        SideloadError(
            SourceAdd.changedCode,
            "The source is not what the preview showed: it was removed, or its address, kind or entries differ.",
            fix: "Nothing was removed. Review the source again before removing it.")
    }

    /// Every app with a `customSources` entry, once each in file order, built-in apps left out (their entry cannot be
    /// removed). Reads only the config.
    public static func removable(_ config: Config) throws -> [SourceRemovable] {
        var seen = Set<String>()
        var listed: [SourceRemovable] = []
        for entry in try SourceAdd.entries(config, "customSources") {
            guard let app = SourceAdd.field(entry, "app"), !seen.contains(app),
                !AppRegistry.builtIns.contains(where: { $0.id == app })
            else { continue }
            seen.insert(app)
            listed.append(
                SourceRemovable(
                    app: app, kind: printableCut(SourceAdd.field(entry, "kind") ?? ""),
                    source: address(entry)))
        }
        return listed
    }

    static func notFound(_ app: String) -> SideloadError {
        SideloadError(
            notFoundCode,
            "\"\(printableCut(app))\" has no entry in customSources.",
            fix: "Run `sideload source list` for the sources there are.")
    }

    static func approval(_ app: String, _ value: JSONValue) -> Bool {
        guard case .object(let o) = value else { return false }
        return o["app"] == .string(app)
    }

    private static func address(_ entry: JSONValue) -> String {
        printableCut(SourceAdd.field(entry, "url") ?? SourceAdd.field(entry, "repo") ?? "", to: 200)
    }
}
