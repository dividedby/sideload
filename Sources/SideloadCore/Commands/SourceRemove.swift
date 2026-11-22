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
        let entries = try SourceAdd.entries(config, "customSources").filter {
            SourceAdd.field($0, "app") == app
        }
        guard let entry = entries.first else { throw notFound(app) }
        let manifest = (try? ManifestStore(paths: services.home).load())?.entries.filter {
            $0.app == app
        }.count
        let installs = (try? services.ledgerStore.load())?.installs.filter { $0.app == app }.count
        return SourceRemovePreview(
            app: app, kind: printableCut(SourceAdd.field(entry, "kind") ?? ""),
            source: address(entry), sourceEntries: entries.count,
            approvalEntries: config.approvedSources.filter { approval(app, $0) }.count,
            customApp: config.appRegistry.app(app) != nil, manifestEntries: manifest,
            installs: installs)
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
