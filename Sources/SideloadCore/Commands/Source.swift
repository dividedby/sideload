import Foundation

public struct SourceOptions: Sendable, Equatable {
    public var sub: String?
    public var url: String?
    public var app: String?
    public var bundle: String?
    public var platform: String?
    public var name: String?
    public var asset: String?
    public var confirm: String?
    public var yes: Bool

    public init(
        sub: String? = nil, url: String? = nil, app: String? = nil, bundle: String? = nil,
        platform: String? = nil, name: String? = nil, asset: String? = nil,
        confirm: String? = nil, yes: Bool = false
    ) {
        self.sub = sub
        self.url = url
        self.app = app
        self.bundle = bundle
        self.platform = platform
        self.name = name
        self.asset = asset
        self.confirm = confirm
        self.yes = yes
    }

    var request: SourceAddRequest? {
        url.map {
            SourceAddRequest(
                url: $0, app: app, bundle: bundle, platform: platform, name: name, asset: asset)
        }
    }
}

/// `source list`, `source add` and `source remove` (design section 8, custom sources).
///
/// `list` is read-only and offline: every source `fetch` knows, built-in and custom, with the metadata URL, the exact hosts and
/// whether the owner approved it in `approvedSources`. No network, no `.op.lock`, no write; it is safe for an agent to run. A
/// `customSources` entry that was left out is a `CUSTOM_SOURCE_IGNORED` warning.
///
/// `add --url U` is a preview: one bounded metadata GET through `Services.http`, no lock, no write. With `--confirm <value>
/// --yes` (owner-only; the menu's confirm click is the same) it repeats the GET outside the lock, refuses with
/// `SOURCE_CHANGED` when the confirm value differs, and under `.op.lock` writes the `customApps`, `customSources` and
/// `approvedSources` entries in one config edit. It fetches nothing.
///
/// `remove --app a` previews; with `--yes` (owner-only), under `.op.lock`, it removes that app's `customSources` and
/// `approvedSources` entries and nothing else: the custom app, its manifest entries, downloads, ledger and installs stay.
public enum SourceCommand {
    static let command = "source"

    public static func run(_ services: Services, _ options: SourceOptions) async -> Envelope {
        switch options.sub {
        case "list":
            if let stray = stray(options, allowed: []) { return stray }
            do {
                return .result("source list", try list(services))
            } catch {
                return .from(error, command: "source list")
            }
        case "add":
            do {
                return try await add(services, options)
            } catch {
                return .from(error, command: SourceAdd.command)
            }
        case "remove":
            do {
                return try await remove(services, options)
            } catch {
                return .from(error, command: removeCommand)
            }
        default:
            return .fail(
                command, code: "USAGE",
                message: "source needs the subcommand `list`, `add` or `remove`.",
                fix: "Run `sideload help`.")
        }
    }

    /// A USAGE refusal when an option the subcommand does not take was given.
    private static func stray(_ options: SourceOptions, allowed: Set<String>) -> Envelope? {
        let given: [(String, Bool)] = [
            ("url", options.url != nil), ("app", options.app != nil),
            ("bundle", options.bundle != nil), ("platform", options.platform != nil),
            ("name", options.name != nil), ("asset", options.asset != nil),
            ("confirm", options.confirm != nil),
            ("yes", options.yes),
        ]
        guard let option = given.first(where: { $0.1 && !allowed.contains($0.0) })?.0 else {
            return nil
        }
        return .fail(
            "source \(options.sub ?? "")", code: "USAGE",
            message: "source \(options.sub ?? "") does not take --\(option).",
            fix: "Run `sideload help`.")
    }

    // MARK: list

    private static func list(_ services: Services) throws -> [String: JSONValue] {
        let config = try services.store.load()
        let registry = config.appRegistry
        let sources = registry.fetchSources.map { declared -> JSONValue in
            // The approved source carries the hosts as `approvedSources` narrowed them: what a fetch may actually use.
            let approved = try? FetchCatalog.approved(app: declared.app, config: config)
            let source = approved ?? declared
            let builtIn = registry.app(declared.app)?.builtIn ?? false
            var entry: [String: JSONValue] = [
                "app": .string(source.app), "builtIn": .bool(builtIn),
                "kind": .string(source.kind.configKind),
                "url": .string(source.metadataURL.absoluteString),
                "metadataHosts": .array(source.metadataHosts.sorted().map(JSONValue.string)),
                "downloadHosts": .array(source.downloadHosts.sorted().map(JSONValue.string)),
                "approved": .bool(approved != nil),
            ]
            if let asset = source.kind.pinnedAsset { entry["asset"] = .string(asset) }
            return .object(entry)
        }
        return ["sources": .array(sources), "warnings": .array(registry.warnings)]
    }

    // MARK: add

    private static func add(_ services: Services, _ options: SourceOptions) async throws
        -> Envelope
    {
        let usage =
            "sideload source add --url <https url> [--app <id>] [--asset <file.ipa>] [--confirm <value> --yes]"
        if options.sub == "add", options.url == nil {
            return .fail(
                SourceAdd.command, code: "USAGE", message: "source add needs --url.", fix: usage)
        }
        if options.yes, options.confirm == nil {
            return .fail(
                SourceAdd.command, code: "USAGE",
                message: "source add --yes needs --confirm <value> from the preview.",
                fix: "Run `sideload source add --url <url>` first and use the command it prints.")
        }
        if options.confirm != nil, !options.yes {
            return .fail(
                SourceAdd.command, code: "USAGE", message: "--confirm belongs to --yes.",
                fix: usage)
        }
        if let confirm = options.confirm, confirm.wholeMatch(of: /[0-9a-f]{16}/) == nil {
            return .fail(
                SourceAdd.command, code: "USAGE",
                message: "--confirm is the 16 hex characters the preview printed.", fix: usage)
        }
        guard let request = options.request else {
            return .fail(
                SourceAdd.command, code: "USAGE", message: "source add needs --url.", fix: usage)
        }
        try SourceAdd.validate(request)

        // The one metadata GET, outside the lock. The config is read after it, so the checks see the file as it is now.
        let probe = try await SourceAdd.probe(services, url: request.url)
        let preview = try SourceAdd.preview(
            probe, request: request, config: try services.store.load())
        guard options.yes, let confirm = options.confirm else {
            return .result(SourceAdd.command, SourceAdd.previewJSON(preview))
        }
        let plan = preview.plan
        guard confirm == plan.confirm else {
            throw SideloadError(
                SourceAdd.changedCode,
                "The source is not what the preview showed: its address, app, bundle ID, pinned asset or hosts differ.",
                fix:
                    "Nothing was written. Run `sideload source add --url <url>` again and review it."
            )
        }

        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }
        let now = services.clock.now()
        let written = try await services.store.update { config in
            try SourceAdd.write(plan, into: &config, now: now)
        }
        return .result(
            SourceAdd.command,
            [
                "added": true, "written": true, "kind": .string(plan.kind),
                "url": .string(plan.url), "app": plan.appJSON,
                "freeBundleId": .string(plan.freeBundleId),
                "wrote": [
                    "customApps": .bool(written.customApps),
                    "customSources": .bool(written.customSources),
                    "approvedSources": .bool(written.approvedSources),
                ],
                "next": .string(
                    "Nothing was fetched. Next: `sideload fetch --app \(plan.appId)`, then the owner checks the version and SHA-256 and runs `sideload fetch --app \(plan.appId) --approve --version <version>`; or Add app… in the menu bar app does both."
                ),
            ])
    }

    // MARK: remove

    static let removeCommand = "source remove"

    private static func remove(_ services: Services, _ options: SourceOptions) async throws
        -> Envelope
    {
        if let stray = stray(options, allowed: ["app", "yes"]) { return stray }
        guard let app = options.app else {
            return .fail(
                removeCommand, code: "USAGE", message: "source remove needs --app.",
                fix: "sideload source remove --app <id> [--yes]")
        }
        if AppRegistry.builtIns.contains(where: { $0.id == app }) {
            throw SideloadError(
                "SOURCE_BUILT_IN", "\(app) is a built-in app; its source is part of sideload.",
                fix:
                    "A built-in source cannot be removed. Narrow its hosts in approvedSources instead."
            )
        }
        let config = try services.store.load()
        let entries = try SourceAdd.entries(config, "customSources").filter {
            SourceAdd.field($0, "app") == app
        }
        guard let entry = entries.first else {
            throw notFound(app)
        }
        let stays = staying(services, app: app, registry: config.appRegistry)
        let approvals = config.approvedSources.filter { approval(app, $0) }.count
        guard options.yes else {
            return .result(
                removeCommand,
                [
                    "preview": true, "written": false, "app": .string(app),
                    "kind": .string(printableCut(SourceAdd.field(entry, "kind") ?? "")),
                    "source": .string(
                        printableCut(
                            SourceAdd.field(entry, "url") ?? SourceAdd.field(entry, "repo") ?? "",
                            to: 200)),
                    "customSourcesEntries": .number(Double(entries.count)),
                    "approvedSourcesEntries": .number(Double(approvals)),
                    "stays": .object(stays),
                    "next": .string(
                        "Nothing was removed. The owner removes the source with: sideload source remove --app \(app) --yes"
                    ),
                ])
        }

        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }
        let removed = try await services.store.update { config -> (sources: Int, approvals: Int) in
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
        return .result(
            removeCommand,
            [
                "removed": true, "written": true, "app": .string(app),
                "wrote": [
                    "customSources": .number(Double(removed.sources)),
                    "approvedSources": .number(Double(removed.approvals)),
                ],
                "stays": .object(stays),
                "next": .string(
                    "The app, its fetched files and its installs are unchanged: sign and refresh keep working. `fetch` and `updates` no longer know \(app); add the source again with `sideload source add`."
                ),
            ])
    }

    private static func notFound(_ app: String) -> SideloadError {
        SideloadError(
            "SOURCE_NOT_FOUND",
            "\"\(printableCut(app))\" has no entry in customSources.",
            fix: "Run `sideload source list` for the sources there are.")
    }

    private static func approval(_ app: String, _ value: JSONValue) -> Bool {
        guard case .object(let o) = value else { return false }
        return o["app"] == .string(app)
    }

    /// What `source remove` leaves alone, as counts and booleans.
    private static func staying(_ services: Services, app: String, registry: AppRegistry)
        -> [String: JSONValue]
    {
        let manifest = (try? ManifestStore(paths: services.home).load())?.entries.filter {
            $0.app == app
        }.count
        let installs = (try? services.ledgerStore.load())?.installs.filter { $0.app == app }.count
        return [
            "customApp": .bool(registry.app(app) != nil),
            "manifestEntries": manifest.map { .number(Double($0)) } ?? .null,
            "installs": installs.map { .number(Double($0)) } ?? .null,
        ]
    }
}
