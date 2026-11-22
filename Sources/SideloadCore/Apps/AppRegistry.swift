import Foundation

/// One app sideload can provision, sign and install with the free team: a built-in, or an entry of `customApps` in
/// `config.json` (design section 18, the app registry). Every per-app fact lives here and nowhere else. The bundle ID is
/// `<bundleIdPrefix>.free.<suffix>`; both Stremio apps share one App ID with two platform profiles (spike S7).
public struct AppDefinition: Sendable {
    /// Who signs the app.
    enum Signer: Sendable, Equatable {
        /// `sign` re-signs a fetched IPA.
        case sign
        /// `provision` signs it itself: the Xcode-built profile carrier, with no IPA.
        case provision
    }

    /// The app key the commands take and the ledger records ("stremio-ios").
    public let id: String
    /// How people see it ("Stremio").
    public let displayName: String
    /// The last label of the free bundle ID.
    public let suffix: String
    /// The saved device's `platform` this app needs: "ios" or "tvos".
    public let devicePlatform: String
    let signer: Signer
    /// Where `fetch` and `updates` read it from: its `customSources` entry; nil for an app with none (the filler, or one whose source was removed).
    let fetch: Fetch?
    /// Defined in code rather than in `customApps`.
    public let builtIn: Bool

    struct Fetch: Sendable, Equatable {
        let kind: FetchSource.Kind
        /// Hosts the metadata request may use.
        let metadataHosts: Set<String>
        /// Hosts the IPA download and every redirect hop may use.
        let downloadHosts: Set<String>
    }

    /// `<prefix>.free.<suffix>`, the bundle ID this app has on the free team; nil when the prefix is missing or invalid.
    /// The one place the formula is written.
    public func freeBundleId(prefix: String?) -> String? {
        guard let prefix, CanaryCommand.isValidPrefix(prefix) else { return nil }
        return prefix + ".free." + suffix
    }

    /// Signed by `provision` (Xcode signs the carrier), never by `sign`.
    var signedByProvision: Bool { signer == .provision }

    /// `Platform` as a provisioning profile spells it.
    var profilePlatform: String { Self.osName(devicePlatform: devicePlatform) }

    /// The SDK folder name under `Build/Products/Debug-<sdk>`.
    var sdk: String { devicePlatform == "tvos" ? "appletvos" : "iphoneos" }

    /// The OS as people and profiles spell it, from a saved device's `platform`.
    static func osName(devicePlatform: String?) -> String {
        devicePlatform == "tvos" ? "tvOS" : "iOS"
    }

    /// The source `fetch` reads, before `approvedSources` narrows it.
    var fetchSource: FetchSource? {
        fetch.map {
            FetchSource(
                app: id, kind: $0.kind, metadataHosts: $0.metadataHosts,
                downloadHosts: $0.downloadHosts)
        }
    }

    /// The one place that says how the owner gets a fresh signed build of this app: `provision` alone for an app that
    /// `provision` signs (the filler; `sign` refuses it), else `provision` then `sign`. `appName` is a ledger string and may
    /// not be a known app, which gets the general wording.
    static func resignSteps(
        app appName: String, device alias: String, apps: AppRegistry = .builtIn
    ) -> String {
        guard let app = apps.app(appName) else {
            return "`sideload provision` and then `sideload sign` for \(printableCut(appName))"
        }
        return app.resignSteps(device: alias)
    }

    func resignSteps(device alias: String) -> String {
        let provision = "`sideload provision --app \(id) --device \(alias) --yes`"
        return signedByProvision ? provision : provision + ", then " + signStep(device: alias)
    }

    /// What to run when only the signed build is missing: `sign` for most apps, `provision` for one it signs itself.
    func signStep(device alias: String) -> String {
        signedByProvision
            ? "`sideload provision --app \(id) --device \(alias) --yes`"
            : "`sideload sign --app \(id) --device \(alias) --yes`"
    }
}

/// Apps are told apart by their ID, which the registry keeps unique.
extension AppDefinition: Hashable {
    public static func == (lhs: AppDefinition, rhs: AppDefinition) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Built-ins

extension AppDefinition {
    /// The built-ins define the app (ID, suffix, platform, signer); none defines its source. The sources of `apollo`,
    /// `stremio-ios` and `stremio-tvos` are `customSources` entries (`BuiltInSources`).
    static let stremioIOS = AppDefinition(
        id: "stremio-ios", displayName: "Stremio", suffix: "stremio", devicePlatform: "ios",
        signer: .sign, fetch: nil, builtIn: true)
    static let stremioTVOS = AppDefinition(
        id: "stremio-tvos", displayName: "Stremio", suffix: "stremio", devicePlatform: "tvos",
        signer: .sign, fetch: nil, builtIn: true)
    static let apollo = AppDefinition(
        id: "apollo", displayName: "Apollo", suffix: "apollo", devicePlatform: "ios",
        signer: .sign, fetch: nil, builtIn: true)
    /// A tiny app with no IPA: the Xcode-signed profile carrier itself. `provision` stages it as the `freeSigned`
    /// build, so `install` and `slot` can be exercised without a fetched IPA. Uses one App ID and one managed slot.
    static let filler = AppDefinition(
        id: "filler", displayName: "Filler", suffix: "filler", devicePlatform: "ios",
        signer: .provision, fetch: nil, builtIn: true)
}

// MARK: - Registry

/// Every app sideload knows, by ID: the built-ins, then the valid entries of `customApps` in `config.json`. The registry
/// only reads `customApps` and `customSources`; only `source add`, `source remove` and the one-time `BuiltInSources` migration
/// write them. Each custom entry is checked on its own
/// and fails closed: an invalid one is left out with a warning, and never stops a built-in or another valid entry.
public struct AppRegistry: Sendable {
    /// Built-ins first in their fixed order, then custom entries in `customApps` order.
    public let apps: [AppDefinition]
    /// One `{code, message, fix}` per custom app or custom source entry left out (or one for a `customApps` or `customSources`
    /// that is not an array).
    public let warnings: [JSONValue]

    static let builtIns: [AppDefinition] = [.stremioIOS, .stremioTVOS, .apollo, .filler]

    /// The built-in apps alone, with no source, for places with no config in hand.
    public static let builtIn = AppRegistry(apps: builtIns, warnings: [])

    static let warningCode = "CUSTOM_APP_IGNORED"
    /// IDs and suffixes: a lowercase DNS-style label, at most 31 characters.
    static func isValidName(_ text: String) -> Bool {
        text.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,30}/) != nil
    }
    static let platforms: Set<String> = ["ios", "tvos"]
    static let entryKeys: Set<String> = ["id", "name", "suffix", "platform"]
    static let maxDisplayName = 64

    /// 1 to 64 printable ASCII characters with no space at either end.
    static func isValidDisplayName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxDisplayName
            && text == printableCut(text, to: maxDisplayName)
            && text.trimmingCharacters(in: .whitespaces) == text
    }

    init(apps: [AppDefinition], warnings: [JSONValue]) {
        self.apps = apps
        self.warnings = warnings
    }

    /// The built-ins plus the valid entries of `config.customApps`. `customApps` is an optional array of
    /// `{"id", "platform", "suffix"?, "name"?}` objects; `suffix` defaults to the ID and `name` to the ID capitalised. A valid
    /// entry of `config.customSources` (design section 8) becomes the `fetch` of the app it names, a built-in `sign` app included.
    /// A config that has not had the one-time source migration yet (one built in memory, not read by `ConfigStore`) gets it
    /// here, so every registry sees the same sources.
    public init(config: Config) {
        var config = config
        BuiltInSources.migrate(&config)
        var (custom, warnings) = Self.customApps(config)
        let signed = Self.builtIns.filter { !$0.signedByProvision }
        let sources = CustomSources.load(config.extra["customSources"], apps: signed + custom)
        func attach(_ app: AppDefinition) -> AppDefinition {
            guard let fetch = sources.fetches[app.id] else { return app }
            return AppDefinition(
                id: app.id, displayName: app.displayName, suffix: app.suffix,
                devicePlatform: app.devicePlatform, signer: app.signer, fetch: fetch,
                builtIn: app.builtIn)
        }
        custom = custom.map(attach)
        warnings.append(contentsOf: sources.warnings)
        self.init(apps: Self.builtIns.map(attach) + custom, warnings: warnings)
    }

    /// The valid `customApps` entries, without a source, and a warning for each one left out.
    private static func customApps(_ config: Config) -> (
        apps: [AppDefinition], warnings: [JSONValue]
    ) {
        guard let raw = config.extra["customApps"] else { return ([], []) }
        guard case .array(let entries) = raw else {
            return ([], [warning("customApps is not an array, so every custom app is ignored.")])
        }
        var warnings: [JSONValue] = []
        var parsed: [(index: Int, app: AppDefinition)] = []
        for (index, entry) in entries.enumerated() {
            switch Self.parse(entry, prefix: config.bundleIdPrefix) {
            case .success(let app): parsed.append((index, app))
            case .failure(let reason): warnings.append(Self.ignored(index, reason))
            }
        }
        // A custom entry that shares its ID or suffix with any other custom entry is ambiguous, so all of them are left out.
        let ids = Dictionary(grouping: parsed, by: \.app.id)
        let suffixes = Dictionary(grouping: parsed, by: \.app.suffix)
        var custom: [AppDefinition] = []
        for (index, app) in parsed {
            if ids[app.id, default: []].count > 1 {
                warnings.append(Self.ignored(index, "another custom app has the ID \(app.id)"))
            } else if suffixes[app.suffix, default: []].count > 1 {
                warnings.append(
                    Self.ignored(index, "another custom app has the suffix \(app.suffix)"))
            } else {
                custom.append(app)
            }
        }
        warnings.sort { (Self.index(of: $0) ?? -1) < (Self.index(of: $1) ?? -1) }
        return (custom, warnings)
    }

    /// The app with this ID.
    public func app(_ id: String) -> AppDefinition? { apps.first { $0.id == id } }

    /// Every app ID, in registry order.
    public var names: [String] { apps.map(\.id) }

    /// The apps `sign` handles (not the ones `provision` signs itself).
    var signedBySign: [AppDefinition] { apps.filter { !$0.signedByProvision } }

    /// The apps that run on a saved device of this platform.
    func apps(for devicePlatform: String?) -> [AppDefinition] {
        apps.filter { $0.devicePlatform == devicePlatform }
    }

    /// Every app with a fetch source, in app-ID order (the order `fetch` and `updates` list them).
    var fetchSources: [FetchSource] {
        apps.compactMap(\.fetchSource).sorted { $0.app < $1.app }
    }

    /// Which apps a `help` usage line offers.
    public enum Choices: Sendable {
        /// Every app.
        case all
        /// The apps `sign` signs.
        case signed
        /// The apps with a fetch source.
        case fetchable
    }

    /// "apollo|stremio-ios|stremio-tvos|filler": the apps as `help` lists them, those `sign` signs by ID, then the rest by ID.
    public func choices(_ which: Choices) -> String {
        let picked: [AppDefinition]
        switch which {
        case .all: picked = apps
        case .signed: picked = signedBySign
        case .fetchable: picked = apps.filter { $0.fetch != nil }
        }
        return
            picked
            .sorted {
                ($0.signedByProvision ? 1 : 0, $0.id) < ($1.signedByProvision ? 1 : 0, $1.id)
            }
            .map(\.id).joined(separator: "|")
    }

    // MARK: custom entries

    private static func parse(_ entry: JSONValue, prefix: String?) -> Result<
        AppDefinition, Reason
    > {
        guard case .object(let fields) = entry else { return .failure("it is not an object") }
        if let extra = fields.keys.sorted().first(where: { !entryKeys.contains($0) }) {
            return .failure("it has the unknown field \(printableCut(extra, to: 32))")
        }
        guard case .string(let id)? = fields["id"] else {
            return .failure("its id is missing or not a string")
        }
        guard isValidName(id) else {
            return .failure(
                "its id is not 1 to 31 of a-z, 0-9 and -, starting with a letter or digit")
        }
        guard case .string(let platform)? = fields["platform"], platforms.contains(platform) else {
            return .failure("its platform is not ios or tvos")
        }
        var suffix = id
        if let raw = fields["suffix"] {
            guard case .string(let text) = raw, isValidName(text) else {
                return .failure(
                    "its suffix is not 1 to 31 of a-z, 0-9 and -, starting with a letter or digit")
            }
            suffix = text
        }
        var name = MenuFormat.capitalised(id)
        if let raw = fields["name"] {
            guard case .string(let text) = raw, isValidDisplayName(text) else {
                return .failure(
                    "its name is not 1 to \(maxDisplayName) printable characters with no outer spaces"
                )
            }
            name = text
        }
        if builtIns.contains(where: { $0.id == id }) {
            return .failure("\(id) is a built-in app")
        }
        if let taken = builtIns.first(where: { $0.suffix == suffix }) {
            return .failure("the suffix \(suffix) belongs to the built-in app \(taken.id)")
        }
        let app = AppDefinition(
            id: id, displayName: name, suffix: suffix, devicePlatform: platform, signer: .sign,
            fetch: nil, builtIn: false)
        // The suffix rule already keeps the bundle ID in the namespace; this says so where the prefix is known.
        if let prefix, CanaryCommand.isValidPrefix(prefix) {
            guard let bundleId = app.freeBundleId(prefix: prefix),
                Config.isFreeBundleId(bundleId, prefix: prefix)
            else { return .failure("its bundle ID is not under \(prefix).free.") }
        }
        return .success(app)
    }

    struct Reason: Error, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let text: String
        init(stringLiteral value: String) { text = value }
        init(stringInterpolation: DefaultStringInterpolation) {
            text = String(stringInterpolation: stringInterpolation)
        }
    }

    private static func ignored(_ index: Int, _ reason: Reason) -> JSONValue {
        var w = warning("customApps entry \(index) is ignored: \(reason.text).")
        if case .object(var o) = w {
            o["index"] = .number(Double(index))
            w = .object(o)
        }
        return w
    }

    private static func index(of warning: JSONValue) -> Int? {
        guard case .object(let o) = warning, case .number(let n)? = o["index"] else { return nil }
        return Int(n)
    }

    private static func warning(_ message: String) -> JSONValue {
        CanaryCommand.warning(
            warningCode, message,
            "Fix or remove the entry in customApps in $SIDELOAD_HOME/config.json. Built-in apps are not affected."
        )
    }
}

extension Config {
    /// The apps this config knows: the built-ins and its valid `customApps` entries.
    public var appRegistry: AppRegistry { AppRegistry(config: self) }
}

extension AppRegistry {
    /// The app named `name` for a command that has not read the config yet: a built-in without reading it, else a custom
    /// entry of the config. Nil when neither knows it, also when the config cannot be read (the command's own load then
    /// says why). With the config's registry, for the "Use one of" list.
    static func lookup(_ name: String, services: Services) -> (
        app: AppDefinition?, registry: AppRegistry
    ) {
        if let app = builtIn.app(name) { return (app, builtIn) }
        guard let config = try? services.store.load() else { return (nil, builtIn) }
        let registry = config.appRegistry
        return (registry.app(name), registry)
    }
}
