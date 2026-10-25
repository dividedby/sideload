import Foundation

/// The free team's cap: a device holds at most this many apps signed with a free developer profile (design section 18).
public enum FreeSlots {
    public static let limit = 3
}

/// One `devicectl device info apps` document, reduced to the bundle IDs on the device and, where the JSON says so,
/// which of them are developer-signed. Parsed from `DeviceCtl` output; runs nothing.
public struct AppSnapshot: Sendable, Equatable {
    /// Every bundle ID found, with whether the entry carries `builtByDeveloper: true` (spike S1: the field is
    /// expected from devicectl's app records; when absent the app is simply not known to be developer-signed, which
    /// is why `freeSlotsReserved` must cover the unmanaged apps and a failed install's installd list is read too).
    public private(set) var apps: [String: Bool]

    public var ids: Set<String> { Set(apps.keys) }

    public init(apps: [String: Bool]) {
        self.apps = apps
    }

    /// Nil unless the document is a complete listing: a top-level object whose `info.outcome` is `"success"`, with
    /// `result.apps` an array of objects that each carry a non-empty string `bundleIdentifier`. Anything else (garbage, a
    /// document without `result.apps`, an `apps` that is not an array, one malformed element) is not a snapshot, so a
    /// failed or partial read can never look like an empty device; `apps: []` is a valid empty device. IDs come only
    /// from `result.apps` elements, never from a walk of the document.
    public static func parse(_ json: JSONValue?) -> AppSnapshot? {
        guard case .object(let top)? = json,
            case .object(let info)? = top["info"], info["outcome"] == .string("success"),
            case .object(let result)? = top["result"], case .array(let items)? = result["apps"]
        else { return nil }
        var apps: [String: Bool] = [:]
        for item in items {
            guard case .object(let fields) = item, case .string(let id)? = fields["bundleIdentifier"], !id.isEmpty else {
                return nil
            }
            let developer = fields["builtByDeveloper"] == .bool(true)
            apps[id] = (apps[id] ?? false) || developer
        }
        return AppSnapshot(apps: apps)
    }

    /// What the snapshot adds to the slot count on a device (design section 18, "Preflight").
    public struct Usage: Sendable, Equatable {
        /// Our managed installs present: bundle IDs in the free allowlist (`<prefix>.free.*`).
        public let managed: Int
        /// Developer-built apps the JSON shows that are not ours. Information only, never counted: devicectl marks
        /// TestFlight betas `builtByDeveloper` exactly like free-team apps (WebDriverAgent, SideStore, ...), and nothing
        /// Apple ships shows an app's signing team, so these cannot be told apart. installd is the backstop.
        public let otherDeveloperApps: Int
        /// Installed WebDriverAgent apps (`FreeTeamSigner.webDriverAgent`) with a free-team profile: the lab's. Nil when the
        /// profile list was not read or was malformed.
        public let labApps: Int?
        /// Installed apps that are not ours and not the lab's with a free-team profile (SideStore, ...); nil like `labApps`.
        public let otherNonLab: Int?
        /// The owner's `freeSlotsReserved`.
        public let reserved: Int
        /// Records with `lentTo` set that the snapshot does not show: the app is gone and the lab holds the room, so the
        /// lab's app lives there (`SlotBook.OutsideUse`).
        public let lent: Int
        /// The other used records the snapshot does not show: an op of one of our other apps that may still land. It never
        /// holds the lab's app.
        public let pending: Int

        public var profilesRead: Bool { labApps != nil }
        /// All installed non-managed apps with a free-team profile; nil when the profiles were not read.
        public var otherFreeTeamApps: Int? { labApps.flatMap { lab in otherNonLab.map { $0 + lab } } }

        /// The formula, stated once (design section 18). A lent slot and the lab's WebDriverAgent count once; the reserve is
        /// a floor for the unmanaged part, not added to it; without a profile read it is the reserve alone, and installd's
        /// refusal is the backstop.
        ///   unmanaged = max(reserved, otherNonLab + max(lent, labApps) - lent)
        ///   used      = managed + unmanaged + lent + pending
        public var unmanaged: Int {
            guard let lab = labApps, let rest = otherNonLab else { return reserved }
            return max(reserved, rest + max(lent, lab) - lent)
        }
        public var used: Int { managed + unmanaged + lent + pending }
        public var free: Int { max(0, FreeSlots.limit - used) }

        /// The `slots` object every command prints (same keys everywhere). `used` and `unmanaged` may be widened by installd's
        /// own list on a `FREE_APP_LIMIT` refusal.
        func json(used widenedUsed: Int? = nil, unmanaged widenedUnmanaged: Int? = nil) -> JSONValue {
            let used = widenedUsed ?? self.used
            func count(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
            return [
                "limit": .number(Double(FreeSlots.limit)), "used": .number(Double(used)),
                "free": .number(Double(max(0, FreeSlots.limit - used))), "reserved": count(reserved),
                "managed": count(managed), "unmanaged": count(widenedUnmanaged ?? unmanaged), "lent": count(lent),
                "pending": count(pending), "otherDeveloperApps": count(otherDeveloperApps),
                "otherFreeTeamApps": count(otherFreeTeamApps), "labApps": count(labApps), "otherNonLab": count(otherNonLab),
                "profilesRead": .bool(profilesRead),
            ]
        }

        /// The same keys with every count null, for a device whose stored reserve is out of range (the count is unknown).
        static let unknownJSON: JSONValue = [
            "limit": .number(Double(FreeSlots.limit)), "used": .null, "free": .null, "reserved": .null, "managed": .null,
            "unmanaged": .null, "lent": .null, "pending": .null, "otherDeveloperApps": .null, "otherFreeTeamApps": .null,
            "labApps": .null, "otherNonLab": .null, "profilesRead": false, "unknown": true,
        ]
    }

    func usage(prefix: String?, reserved: Int, outside: SlotBook.OutsideUse = .init(), profiles: FreeTeamProfiles? = nil)
        -> Usage
    {
        var managed = 0
        var other = 0
        var lab = 0
        var rest = 0
        for (id, developer) in apps {
            if Config.isFreeBundleId(id, prefix: prefix) {
                managed += 1
            } else {
                if developer { other += 1 }
                if profiles?.bundleIds.contains(id) == true {
                    if FreeTeamSigner.label(of: id) == .webDriverAgent { lab += 1 } else { rest += 1 }
                }
            }
        }
        return Usage(
            managed: managed, otherDeveloperApps: other, labApps: profiles == nil ? nil : lab,
            otherNonLab: profiles == nil ? nil : rest, reserved: reserved, lent: outside.lent,
            pending: outside.pending)
    }

    /// The managed installs (free allowlist) in the snapshot, sorted.
    public func managedIds(prefix: String?) -> [String] {
        apps.keys.filter { Config.isFreeBundleId($0, prefix: prefix) }.sorted()
    }

    /// What changed between two snapshots.
    public struct Delta: Sendable, Equatable {
        public let added: [String]
        public let removed: [String]
        public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    public static func delta(from before: AppSnapshot, to after: AppSnapshot) -> Delta {
        Delta(added: after.ids.subtracting(before.ids).sorted(), removed: before.ids.subtracting(after.ids).sorted())
    }
}

/// Known free-team signers whose apps keep the developer's trust on a device (design section 18).
enum FreeTeamSigner {
    case webDriverAgent, sideStore

    /// A label for a bundle ID (the team prefix, if any, already dropped); nil for anything else.
    static func label(of id: String) -> FreeTeamSigner? {
        if id.contains("WebDriverAgent") || id.contains("-wda-") || id.contains(".msl-wda") { return .webDriverAgent }
        if id.hasPrefix("com.SideStore.") { return .sideStore }
        return nil
    }
}

/// The list installd puts in the "maximum number of installed apps using a free developer profile" failure
/// (`NSLocalizedRecoverySuggestion`: `{( "6ZU5Z6ZKK7.<bundle id>", ... )}`), reduced so no foreign ID is ever echoed:
/// only IDs under our allowlist are kept, the rest are counted, and two known signers get a label.
public struct InstalldLimitList: Sendable, Equatable {
    public let total: Int
    /// Our `<prefix>.free.*` IDs among them, sorted.
    public let ours: [String]
    public let webDriverAgent: Int
    public let sideStore: Int
    public let other: Int

    /// Apps in the list that are not ours: what `freeSlotsReserved` has to cover.
    public var unmanaged: Int { total - ours.count }

    static let phrase = "maximum number of installed apps using a free developer profile"

    /// Parses the first string leaf of `json` (or `stderr`) that holds the phrase; nil when none does or no ID follows.
    public static func parse(json: JSONValue?, stderr: String, prefix: String?) -> InstalldLimitList? {
        var texts = Leaf.walk(json).compactMap { leaf -> String? in
            if case .string(let s) = leaf.value { return s }
            return nil
        }
        texts.append(stderr)
        for text in texts {
            guard let range = text.range(of: phrase, options: .caseInsensitive) else { continue }
            let tail = String(text[range.upperBound...])
            let ids = tail.matches(of: /"([^"\s]+)"/).map { String($0.output.1) }
            if ids.isEmpty { continue }
            return InstalldLimitList(ids: ids, prefix: prefix)
        }
        return nil
    }

    init(ids: [String], prefix: String?) {
        var ours: [String] = []
        var wda = 0
        var side = 0
        var other = 0
        for raw in ids {
            // installd lists `<team>.<bundle id>`; drop the team and a trailing `.<team>` some signers append.
            var id = raw
            if let dot = id.firstIndex(of: "."), id[..<dot].count == 10, id[..<dot].allSatisfy({ $0.isLetter || $0.isNumber }) {
                id = String(id[id.index(after: dot)...])
            }
            if Config.isFreeBundleId(id, prefix: prefix) {
                ours.append(id)
            } else {
                switch FreeTeamSigner.label(of: id) {
                case .webDriverAgent?: wda += 1
                case .sideStore?: side += 1
                case nil: other += 1
                }
            }
        }
        total = ids.count
        self.ours = ours.sorted()
        webDriverAgent = wda
        sideStore = side
        self.other = other
    }

    public var json: JSONValue {
        [
            "total": .number(Double(total)), "ours": .array(ours.map { .string($0) }),
            "webDriverAgent": .number(Double(webDriverAgent)), "sideStore": .number(Double(sideStore)),
            "other": .number(Double(other)),
        ]
    }
}
