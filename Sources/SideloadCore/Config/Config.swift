import Foundation

/// The two teams (identities match on certificate OU, never name). `paid` is the locked team; every paid-only
/// path (`canary`, `export-cert`, `portal`, ledger certificates and profiles, `config.teamId`) rejects `free`
/// through `denied`. Only the explicit free signing context (design section 18) accepts it.
public enum Team {
    public static let paid = "7AGMPUPP64"
    public static let free = "6ZU5Z6ZKK7"
    /// The paid team, under its older name.
    public static let id = paid
    /// The paid-path deny-list: the free team's OU.
    public static let denied: Set<String> = [free]
}

/// Which team an app is signed with: `apps.<alias>.team`. Absent means paid; `free` is never a fallback.
public enum AppTeam: String, Sendable, Equatable {
    case paid, free
}

/// A key that is not known at compile time. Lets `Config` and `SavedDevice` carry fields they do not model.
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// One saved device. IDs come from `devicectl` only. `name` and `hostnames` are kept so canary logs can be
/// scrubbed; they are never echoed in output.
public struct SavedDevice: Codable, Sendable, Equatable {
    public var udid: String?
    public var coreDeviceId: String?
    /// `ios` or `tvos`.
    public var platform: String?
    public var name: String?
    public var hostnames: [String]
    /// Owner opt-in for `refresh --auto` on this device (design section 18); set only by `device auto-refresh`.
    public var autoRefresh: Bool
    /// Dev-signed apps on the device that sideload does not manage (WebDriverAgent, atvloadly's copy); counted
    /// against the free team's 3 apps per device. Owner-set through `device slots`, 0...3. The stored value is
    /// whatever the file held, so an out-of-range one cannot break config loading for the paid paths; every free
    /// path reads it through `freeSlotsReserved` / `requireFreeSlotsReserved` (nil / `CONFIG_INVALID` when invalid)
    /// and owner edits go through `setFreeSlotsReserved`. `init` and decoding store any Int as-is (`device save`
    /// carries an existing raw value forward), which is safe because every read is validated.
    public private(set) var freeSlotsReservedRaw: Int
    /// The app key (`stremio-ios`) the lab may borrow the slot of through `slot lend` (design section 18). Owner-set
    /// through `device lendable`; nil means nothing is lendable on this device.
    public var lendableApp: String?
    /// Fields this version does not model; written back unchanged so no update drops data.
    public var extra: [String: JSONValue]

    public static let freeSlotRange = 0...3

    /// The reserve, or nil when the stored value is outside 0...3. The one place the invariant is checked.
    public var freeSlotsReserved: Int? {
        Self.freeSlotRange.contains(freeSlotsReservedRaw) ? freeSlotsReservedRaw : nil
    }

    /// The reserve for a free-path operation on `alias`; an invalid stored value is `CONFIG_INVALID`.
    public func requireFreeSlotsReserved(alias: String) throws -> Int {
        guard let reserved = freeSlotsReserved else {
            throw SideloadError(
                "CONFIG_INVALID", "Saved device \"\(alias)\" has a freeSlotsReserved outside 0 to 3.",
                fix: "Run `sideload device slots --alias \(alias) --reserved <0-3> --yes` (owner) or fix config.json.")
        }
        return reserved
    }

    /// Sets the reserve; anything outside 0...3 throws and leaves the device unchanged.
    public mutating func setFreeSlotsReserved(_ value: Int) throws {
        guard Self.freeSlotRange.contains(value) else {
            throw SideloadError("INVALID_ARGUMENT", "freeSlotsReserved must be 0 to 3.")
        }
        freeSlotsReservedRaw = value
    }

    public init(
        udid: String? = nil, coreDeviceId: String? = nil, platform: String? = nil, name: String? = nil,
        hostnames: [String] = [], autoRefresh: Bool = false, freeSlotsReserved: Int = 0,
        lendableApp: String? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.udid = udid
        self.coreDeviceId = coreDeviceId
        self.platform = platform
        self.name = name
        self.hostnames = hostnames
        self.autoRefresh = autoRefresh
        self.freeSlotsReservedRaw = freeSlotsReserved
        self.lendableApp = lendableApp
        self.extra = extra
    }

    private static let known: Set<String> = [
        "udid", "coreDeviceId", "platform", "name", "hostnames", "autoRefresh", "freeSlotsReserved", "lendableApp",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        udid = try c.decodeIfPresent(String.self, forKey: AnyKey("udid"))
        coreDeviceId = try c.decodeIfPresent(String.self, forKey: AnyKey("coreDeviceId"))
        platform = try c.decodeIfPresent(String.self, forKey: AnyKey("platform"))
        name = try c.decodeIfPresent(String.self, forKey: AnyKey("name"))
        hostnames = try c.decodeIfPresent([String].self, forKey: AnyKey("hostnames")) ?? []
        autoRefresh = try c.decodeIfPresent(Bool.self, forKey: AnyKey("autoRefresh")) ?? false
        // Lenient on range: an out-of-range value must not stop every command from loading the config.
        freeSlotsReservedRaw = try c.decodeIfPresent(Int.self, forKey: AnyKey("freeSlotsReserved")) ?? 0
        lendableApp = try c.decodeIfPresent(String.self, forKey: AnyKey("lendableApp"))
        extra = [:]
        for key in c.allKeys where !Self.known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in extra { try c.encode(value, forKey: AnyKey(key)) }
        try c.encodeIfPresent(udid, forKey: AnyKey("udid"))
        try c.encodeIfPresent(coreDeviceId, forKey: AnyKey("coreDeviceId"))
        try c.encodeIfPresent(platform, forKey: AnyKey("platform"))
        try c.encodeIfPresent(name, forKey: AnyKey("name"))
        if !hostnames.isEmpty { try c.encode(hostnames, forKey: AnyKey("hostnames")) }
        // Written only when set, so a config that never used them is byte-identical to before.
        if autoRefresh { try c.encode(true, forKey: AnyKey("autoRefresh")) }
        if freeSlotsReservedRaw != 0 { try c.encode(freeSlotsReservedRaw, forKey: AnyKey("freeSlotsReserved")) }
        try c.encodeIfPresent(lendableApp, forKey: AnyKey("lendableApp"))
    }
}

/// A saved device resolved for use: `deviceId` is the CoreDevice UUID, else the UDID.
public struct ResolvedDevice: Sendable, Equatable {
    public let alias: String
    public let udid: String?
    public let coreDeviceId: String?
    public let platform: String?
    public let deviceId: String
    public let name: String?
    public let hostnames: [String]
}

/// `config.json`. Every field the commands read or write, with defaults.
public struct Config: Codable, Sendable, Equatable {
    public var teamId: String
    public var devices: [String: SavedDevice]
    /// Per-app state; its shape is owned by the later `fetch`/`sign` steps.
    public var apps: [String: JSONValue]
    /// Approved download sources; the entry shape is owned by the later `fetch` step.
    public var approvedSources: [JSONValue]
    public var minFreeGB: Double
    /// `lastNotified[item] = threshold` (design section 11).
    public var lastNotified: [String: Int]
    public var bundleIdPrefix: String?
    /// Optional owner-set Apple Developer Support case number; the canary evidence bundle carries it (null when unset).
    /// A JSON number is read as its decimal string (`appleSupportCaseWasNumber` remembers it so a rewrite keeps it a number).
    public var appleSupportCase: String?
    private var appleSupportCaseWasNumber = false
    public var extra: [String: JSONValue]

    public init(
        teamId: String = Team.id, devices: [String: SavedDevice] = [:], apps: [String: JSONValue] = [:],
        approvedSources: [JSONValue] = [], minFreeGB: Double = 2, lastNotified: [String: Int] = [:],
        bundleIdPrefix: String? = nil, appleSupportCase: String? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.teamId = teamId
        self.devices = devices
        self.apps = apps
        self.approvedSources = approvedSources
        self.minFreeGB = minFreeGB
        self.lastNotified = lastNotified
        self.bundleIdPrefix = bundleIdPrefix
        self.appleSupportCase = appleSupportCase
        self.extra = extra
    }

    private static let known: Set<String> = [
        "teamId", "devices", "apps", "approvedSources", "minFreeGB", "lastNotified", "bundleIdPrefix",
        "appleSupportCase",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        teamId = try c.decodeIfPresent(String.self, forKey: AnyKey("teamId")) ?? Team.id
        devices = try c.decodeIfPresent([String: SavedDevice].self, forKey: AnyKey("devices")) ?? [:]
        apps = try c.decodeIfPresent([String: JSONValue].self, forKey: AnyKey("apps")) ?? [:]
        approvedSources = try c.decodeIfPresent([JSONValue].self, forKey: AnyKey("approvedSources")) ?? []
        minFreeGB = try c.decodeIfPresent(Double.self, forKey: AnyKey("minFreeGB")) ?? 2
        lastNotified = try c.decodeIfPresent([String: Int].self, forKey: AnyKey("lastNotified")) ?? [:]
        bundleIdPrefix = try c.decodeIfPresent(String.self, forKey: AnyKey("bundleIdPrefix"))
        if let number = try? c.decode(Int.self, forKey: AnyKey("appleSupportCase")) {
            appleSupportCase = String(number)
            appleSupportCaseWasNumber = true
        } else {
            appleSupportCase = try c.decodeIfPresent(String.self, forKey: AnyKey("appleSupportCase"))
        }
        extra = [:]
        for key in c.allKeys where !Self.known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in extra { try c.encode(value, forKey: AnyKey(key)) }
        try c.encode(teamId, forKey: AnyKey("teamId"))
        try c.encode(devices, forKey: AnyKey("devices"))
        try c.encode(apps, forKey: AnyKey("apps"))
        try c.encode(approvedSources, forKey: AnyKey("approvedSources"))
        try c.encode(minFreeGB, forKey: AnyKey("minFreeGB"))
        try c.encode(lastNotified, forKey: AnyKey("lastNotified"))
        try c.encodeIfPresent(bundleIdPrefix, forKey: AnyKey("bundleIdPrefix"))
        if let text = appleSupportCase {
            if appleSupportCaseWasNumber, let number = Int(text) {
                try c.encode(number, forKey: AnyKey("appleSupportCase"))
            } else {
                try c.encode(text, forKey: AnyKey("appleSupportCase"))
            }
        }
    }
}

// MARK: - Validation and (de)serialisation

private let fixConfig = "Fix or remove $SIDELOAD_HOME/config.json."

private func teamError(_ team: JSONValue) -> SideloadError {
    if case .string(let s) = team, Team.denied.contains(s) {
        return SideloadError(
            "FREE_TEAM_SELECTED", "config.json selects the free team, which is deny-listed.",
            fix: "Set teamId to \(Team.id) or remove it.")
    }
    return SideloadError(
        "CONFIG_INVALID", "config.json teamId does not match the locked team.",
        fix: "Set teamId to \(Team.id) or remove it.")
}

extension Config {
    /// Parses `config.json` bytes. Parse and shape errors never echo file content.
    public static func parse(_ data: Data) throws -> Config {
        let json: JSONValue
        do {
            json = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw SideloadError("CONFIG_INVALID", "config.json is not valid JSON.", fix: fixConfig)
        }
        guard case .object(let fields) = json else {
            throw SideloadError("CONFIG_INVALID", "config.json must contain a JSON object.", fix: fixConfig)
        }
        if let team = fields["teamId"], team != .string(Team.id) { throw teamError(team) }
        if let devices = fields["devices"] {
            guard case .object = devices else {
                throw SideloadError("CONFIG_INVALID", "config.json devices must be an object.", fix: fixConfig)
            }
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            // Names the offending key path, never the value.
            let path = (error as? DecodingError).map(Self.keyPath) ?? ""
            let place = path.isEmpty ? "a field" : "`\(path)`"
            throw SideloadError(
                "CONFIG_INVALID", "config.json has \(place) of the wrong type.",
                fix: path.isEmpty
                    ? fixConfig : "Fix the value of `\(path)` in $SIDELOAD_HOME/config.json, or remove the key.")
        }
    }

    private static func keyPath(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            context = c
        @unknown default:
            return ""
        }
        var path = ""
        for key in context.codingPath {
            if let i = key.intValue {
                path += "[\(i)]"
            } else {
                path += (path.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return path
    }

    /// What `saveConfig` checks before writing.
    public func validate() throws {
        if teamId != Team.id { throw teamError(.string(teamId)) }
    }

    /// Pretty-printed with sorted keys and a trailing newline.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

// MARK: - Free-team policy (design section 18)

extension Config {
    /// `apps.<alias>.team`: `free` selects the free signing context; absent (or an app with no entry) is paid.
    /// Any other value is `CONFIG_INVALID` (the value is not echoed). No command reads this yet.
    public func appTeam(_ alias: String) throws -> AppTeam {
        guard case .object(let app)? = apps[alias], let team = app["team"] else { return .paid }
        guard case .string(let value) = team, let parsed = AppTeam(rawValue: value) else {
            throw SideloadError(
                "CONFIG_INVALID", "config.json has `apps.\(alias).team` of the wrong type or value.",
                fix: "Set `apps.\(alias).team` to \"free\" in $SIDELOAD_HOME/config.json, or remove the key.")
        }
        return parsed
    }

    /// Whether `bundleId` is exactly `<prefix>.free.<name>`: case-sensitive, at least one non-empty dotted
    /// component after `.free.`, letters, digits and hyphens only (so no `*`). An invalid or missing prefix
    /// allows nothing. WebDriverAgent's and atvloadly's IDs can never match.
    public static func isFreeBundleId(_ bundleId: String, prefix: String?) -> Bool {
        guard let prefix, CanaryCommand.isValidPrefix(prefix) else { return false }
        let head = prefix + ".free."
        guard bundleId.hasPrefix(head) else { return false }
        return String(bundleId.dropFirst(head.count)).wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*/) != nil
    }
}

// MARK: - Saved-device lookup

extension Config {
    /// The saved device for `alias`, with its id resolved (CoreDevice UUID preferred, else UDID).
    public func requireDevice(_ alias: String) throws -> ResolvedDevice {
        guard let d = devices[alias] else {
            throw SideloadError(
                "DEVICE_NOT_SAVED", "No saved device with alias \"\(alias)\".",
                fix: "sideload device save --alias <alias> --match <device name> --platform ios|tvos --yes")
        }
        guard let deviceId = Self.nonEmpty(d.coreDeviceId) ?? Self.nonEmpty(d.udid) else {
            throw SideloadError(
                "CONFIG_INVALID", "Saved device \"\(alias)\" has no ids.",
                fix: "Re-save it with `sideload device save`.")
        }
        return ResolvedDevice(
            alias: alias, udid: d.udid, coreDeviceId: d.coreDeviceId, platform: d.platform, deviceId: deviceId,
            name: d.name, hostnames: d.hostnames)
    }

    /// Every saved UDID and CoreDevice UUID.
    public var savedDeviceIDs: Set<String> {
        var ids = Set<String>()
        for d in devices.values {
            if let udid = Self.nonEmpty(d.udid) { ids.insert(udid) }
            if let core = Self.nonEmpty(d.coreDeviceId) { ids.insert(core) }
        }
        return ids
    }

    /// Whether `id` is exactly a saved UDID or CoreDevice UUID (names, serials and DNS names never are).
    public func isSavedDeviceID(_ id: String) -> Bool {
        savedDeviceIDs.contains(id)
    }

    /// Saved devices, optionally of one platform, sorted by alias.
    public func savedDevices(platform: String? = nil) throws -> [ResolvedDevice] {
        try devices.keys.sorted()
            .filter { platform == nil || devices[$0]?.platform == platform }
            .map { try requireDevice($0) }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
