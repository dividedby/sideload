import Foundation

/// The sources of the three apps that used to be built in (design section 8, "Migration"). They are ordinary `customSources`
/// entries now; this file holds their definitions only as the data of the one-time migration and of the `source add` command
/// that restores each one.
///
/// Owner decision 2026-11-21: this migration is the only case where sideload writes `customSources` entries without the owner's
/// confirm, and it only copies the definitions that shipped in code (same addresses, hosts and pins). It never adds an
/// `approvedSources` entry and never a host.
enum BuiltInSources {
    /// A top-level `config.json` key. Its presence, with any value, means the migration is done and never runs again, so a
    /// source the owner removed afterwards stays removed.
    static let markerKey = "builtInSourcesMigrated"
    static let warningCode = "BUILT_IN_SOURCES_MIGRATED"

    static let apolloRepo = "Apollo-Reborn/Apollo-Reborn"
    static let apolloBundleId = "com.christianselig.Apollo"
    static let apolloAsset = "Apollo-Reborn-{version}-GLASS-NOEXTENSIONS.ipa"
    static let stremioIndexBase = "https://raw.githubusercontent.com/gorlev/stremio-altstore/main/"
    static let stremioBundleId = "com.stremio.pal"
    static let stremioHost = "dl.strem.io"
    static let stremioTVOSPath = "/apple/{versionKey}/tvos/stremio_tvOS.ipa"

    struct Definition {
        let app: String
        /// The `customSources` entry, with no `addedAt` so the migration needs no clock.
        let entry: JSONValue
        /// The `source add` command (without `--confirm --yes`) that gives the app this source again.
        let readd: String
    }

    /// In the fixed order the migration appends them.
    static let definitions: [Definition] = [
        Definition(
            app: "apollo",
            entry: .object([
                "app": "apollo", "kind": "githubRelease", "repo": .string(apolloRepo),
                "asset": .string(apolloAsset), "tagRule": "underscoreSuffix",
                "bundleId": .string(apolloBundleId), "metadataHosts": ["api.github.com"],
                "downloadHosts": .array(
                    CustomSources.githubDownloadHosts.sorted().map(JSONValue.string)),
            ]),
            readd:
                "sideload source add --url 'https://github.com/\(apolloRepo)' --app apollo --bundle \(apolloBundleId) --asset '\(apolloAsset)' --tag-rule underscoreSuffix"
        ),
        stremio(app: "stremio-ios", index: "stremio-ios.json", tvos: false),
        stremio(app: "stremio-tvos", index: "stremio-tvos.json", tvos: true),
    ]

    private static func stremio(app: String, index: String, tvos: Bool) -> Definition {
        var entry: [String: JSONValue] = [
            "app": .string(app), "kind": "altstoreIndex", "url": .string(stremioIndexBase + index),
            "bundleId": .string(stremioBundleId), "requireBuild": true,
            "metadataHosts": ["raw.githubusercontent.com"],
            "downloadHosts": [.string(stremioHost)],
        ]
        if tvos { entry["downloadPath"] = .string(stremioTVOSPath) }
        return Definition(
            app: app, entry: .object(entry),
            readd:
                "sideload source add --url '\(stremioIndexBase + index)' --app \(app) --bundle \(stremioBundleId) --require-build"
                + (tvos ? " --download-path '\(stremioTVOSPath)'" : ""))
    }

    /// The `source add` command that restores the default source of `app`; nil for any other app.
    static func readd(app: String) -> String? {
        definitions.first { $0.app == app }?.readd
    }

    /// Adds the missing definitions and the marker to `config`; true when it changed anything. A pure function of the config:
    /// `ConfigStore.load()` applies it to every config it reads, so every process sees the same sources whether or not the
    /// file has been rewritten yet, and any later write persists the entries and the marker in one atomic rename.
    ///
    /// - The marker (any value) means done: nothing is added again.
    /// - A `customSources` that is not an array is left alone and gets no marker (the registry ignores it with a warning; the
    ///   migration runs once the owner fixes the key).
    /// - An app that already has an entry, valid or not, keeps it: no second entry is written for it.
    @discardableResult
    static func migrate(_ config: inout Config) -> Bool {
        guard config.extra[markerKey] == nil else { return false }
        var entries: [JSONValue] = []
        switch config.extra["customSources"] {
        case nil: break
        case .array(let list)?: entries = list
        default: return false
        }
        for definition in definitions
        where !entries.contains(where: { SourceAdd.field($0, "app") == definition.app }) {
            entries.append(definition.entry)
        }
        config.extra["customSources"] = .array(entries)
        config.extra[markerKey] = true
        return true
    }

    /// The warning `status`, `source list` and `updates` carry until a write persists the migration.
    static var pendingWarning: JSONValue {
        CanaryCommand.warning(
            warningCode,
            "The sources of apollo, stremio-ios and stremio-tvos are now ordinary customSources entries (same addresses, hosts and pins). config.json gets them at its next write.",
            "Nothing to do. `sideload source list` shows them; `source remove` and `source add` now work on them."
        )
    }
}
