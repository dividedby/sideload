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

    /// A read that omits every app the ledger says is installed (and idle) is not trusted: devicectl has returned a list
    /// without the apps that are plainly there, and one such read must not mark them gone. An empty `expected` never
    /// contradicts (nothing to compare), and a read that shows any one of them does not either, so a partial omission
    /// (one app really removed by hand) is believed.
    func contradicts(expected: Set<String>) -> Bool {
        !expected.isEmpty && expected.isDisjoint(with: apps.keys)
    }

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
            guard case .object(let fields) = item,
                case .string(let id)? = fields["bundleIdentifier"], !id.isEmpty
            else {
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
        /// Installed WebDriverAgent apps (`FreeTeamSigner.webDriverAgent`): the lab's. One counts when a free-team profile
        /// lists it, or, with no profile for it (expired and purged, or an `appIdentifier` form the parser ignores), when the
        /// app list shows it developer-built. Nil when the profile list was not read or was malformed.
        public let labApps: Int?
        /// Installed apps that are not ours and not the lab's with a free-team profile (SideStore, ...); nil like `labApps`.
        public let otherNonLab: Int?
        /// WebDriverAgent apps the app list alone identifies (label plus `builtByDeveloper`), whether or not the profiles were
        /// read: a subset of `labApps` when they were. It is what stands in for `labApps` when the profile read is missing
        /// (the menu card never reads profiles).
        let labFromAppList: Int
        /// The lab's apps on the device by the best evidence there is: `labApps` when the profiles were read, else the app
        /// list's. The one rule for "the lab's app is installed" (the preflight, `slot return`'s warning, the card's note).
        public var labCount: Int { labApps ?? labFromAppList }
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
        public var otherFreeTeamApps: Int? {
            labApps.flatMap { lab in otherNonLab.map { $0 + lab } }
        }

        /// The formula, stated once (design section 18). A lent slot and the lab's WebDriverAgent count once; the reserve is
        /// a floor for the unmanaged part, not added to it. Without a profile read only the app list's WebDriverAgent is known
        /// (`labFromAppList`, in place of `labApps`; `otherNonLab` is unknown and counts for nothing, the reserve covers it), and
        /// installd's refusal is the backstop.
        ///   unmanaged = max(reserved, otherNonLab + max(lent, labCount) - lent)
        ///   used      = managed + unmanaged + lent + pending
        public var unmanaged: Int {
            max(reserved, (otherNonLab ?? 0) + max(lent, labCount) - lent)
        }
        public var used: Int { managed + unmanaged + lent + pending }
        public var free: Int { max(0, FreeSlots.limit - used) }

        /// The `slots` object every command prints (same keys everywhere). `used` and `unmanaged` may be widened by installd's
        /// own list on a `FREE_APP_LIMIT` refusal.
        func json(used widenedUsed: Int? = nil, unmanaged widenedUnmanaged: Int? = nil) -> JSONValue
        {
            let used = widenedUsed ?? self.used
            func count(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
            return [
                "limit": .number(Double(FreeSlots.limit)), "used": .number(Double(used)),
                "free": .number(Double(max(0, FreeSlots.limit - used))),
                "reserved": count(reserved),
                "managed": count(managed), "unmanaged": count(widenedUnmanaged ?? unmanaged),
                "lent": count(lent),
                "pending": count(pending), "otherDeveloperApps": count(otherDeveloperApps),
                "otherFreeTeamApps": count(otherFreeTeamApps), "labApps": count(labApps),
                "otherNonLab": count(otherNonLab),
                "profilesRead": .bool(profilesRead),
            ]
        }

        /// The same keys with every count null, for a device whose stored reserve is out of range (the count is unknown).
        static let unknownJSON: JSONValue = [
            "limit": .number(Double(FreeSlots.limit)), "used": .null, "free": .null,
            "reserved": .null, "managed": .null,
            "unmanaged": .null, "lent": .null, "pending": .null, "otherDeveloperApps": .null,
            "otherFreeTeamApps": .null,
            "labApps": .null, "otherNonLab": .null, "profilesRead": false, "unknown": true,
        ]
    }

    func usage(
        prefix: String?, reserved: Int, outside: SlotBook.OutsideUse = .init(),
        profiles: FreeTeamProfiles? = nil
    )
        -> Usage
    {
        var managed = 0
        var other = 0
        var lab = 0
        var rest = 0
        var listed = 0
        for (id, developer) in apps {
            if Config.isFreeBundleId(id, prefix: prefix) {
                managed += 1
            } else {
                if developer { other += 1 }
                let inProfiles = profiles?.bundleIds.contains(id) == true
                if Self.countsAsLab(id: id, developer: developer, inProfiles: inProfiles) {
                    lab += 1
                } else if inProfiles {
                    rest += 1
                }
                if Self.countsAsLab(id: id, developer: developer, inProfiles: false) { listed += 1 }
            }
        }
        return Usage(
            managed: managed, otherDeveloperApps: other, labApps: profiles == nil ? nil : lab,
            otherNonLab: profiles == nil ? nil : rest, labFromAppList: listed, reserved: reserved,
            lent: outside.lent, pending: outside.pending)
    }

    /// Whether a non-managed installed app is the lab's WebDriverAgent. It is known by its label from the app list, not only
    /// by a profile: installd counts an installed app whose profile is expired, purged or not listed. The developer flag keeps
    /// a look-alike App Store app out when no profile lists it. Any other app needs a listed free-team profile instead
    /// (TestFlight betas look the same in the app list).
    private static func countsAsLab(id: String, developer: Bool, inProfiles: Bool) -> Bool {
        FreeTeamSigner.label(of: id) == .webDriverAgent && (developer || inProfiles)
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
        Delta(
            added: after.ids.subtracting(before.ids).sorted(),
            removed: before.ids.subtracting(after.ids).sorted())
    }

    /// A delta split into the apps a free-team install could have caused and everyone else's. `delta` holds the relevant IDs
    /// (what the commands judge); the rest are counted only, never named.
    public struct RelevantDelta: Sendable, Equatable {
        public let delta: Delta
        public let otherAdded: Int
        public let otherRemoved: Int
        /// The developer flag could not be trusted for this read, so every ID is relevant (the full-list comparison).
        public let strict: Bool
        /// Apps the ledger says were installed that an untrusted `before` (`contradicts`) omitted and `after` lists again: not
        /// a change, counted only. Always 0 for a trusted read.
        let reappeared: Int

        init(delta: Delta, otherAdded: Int, otherRemoved: Int, strict: Bool, reappeared: Int = 0) {
            self.delta = delta
            self.otherAdded = otherAdded
            self.otherRemoved = otherRemoved
            self.strict = strict
            self.reappeared = reappeared
        }

        public var hasOtherChanges: Bool { otherAdded + otherRemoved > 0 }
    }

    /// The delta restricted to IDs that matter: ours (`<prefix>.free.*`), `builtByDeveloper` in either snapshot, or listed in
    /// the installed free-team profiles (when those were read). App Store and system churn, which uses no free-team slot and
    /// cannot be caused by an install, lands in the `other` counts.
    ///
    /// Strict fallback: our app is free-signed, so devicectl flags it. If `target` is listed in a snapshot without the flag, or
    /// is in neither, there is no evidence the flag works (a devicectl format change may have dropped it) and the check is not
    /// weakened: every ID is relevant.
    ///
    /// `ledgerPresent` is only given when `before` is untrusted: the IDs it omitted that the ledger says are installed are not
    /// "added" when `after` lists them, they are counted in `reappeared`. Anything else new (an unknown `free.*`, a developer
    /// app) still counts, and so does every removal.
    public static func delta(
        from before: AppSnapshot, to after: AppSnapshot, relevantTo target: String, prefix: String?,
        profiles: FreeTeamProfiles?, ledgerPresent: Set<String> = []
    ) -> RelevantDelta {
        var full = delta(from: before, to: after)
        let reappeared = full.added.filter { ledgerPresent.contains($0) }.count
        if reappeared > 0 {
            full = Delta(
                added: full.added.filter { !ledgerPresent.contains($0) }, removed: full.removed)
        }
        let flagged = [before, after].compactMap { $0.apps[target] }
        guard !flagged.isEmpty, !flagged.contains(false) else {
            return RelevantDelta(
                delta: full, otherAdded: 0, otherRemoved: 0, strict: true, reappeared: reappeared)
        }
        func relevant(_ id: String) -> Bool {
            Config.isFreeBundleId(id, prefix: prefix) || before.apps[id] == true
                || after.apps[id] == true || profiles?.bundleIds.contains(id) == true
        }
        let added = full.added.filter(relevant)
        let removed = full.removed.filter(relevant)
        return RelevantDelta(
            delta: Delta(added: added, removed: removed),
            otherAdded: full.added.count - added.count,
            otherRemoved: full.removed.count - removed.count, strict: false,
            reappeared: reappeared)
    }
}

/// Known free-team signers whose apps keep the developer's trust on a device (design section 18).
enum FreeTeamSigner {
    case webDriverAgent, sideStore

    /// A label for a bundle ID (the team prefix, if any, already dropped); nil for anything else.
    static func label(of id: String) -> FreeTeamSigner? {
        if id.contains("WebDriverAgent") || id.contains("-wda-") || id.contains(".msl-wda") {
            return .webDriverAgent
        }
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
    public static func parse(json: JSONValue?, stderr: String, prefix: String?)
        -> InstalldLimitList?
    {
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
            if let dot = id.firstIndex(of: "."), id[..<dot].count == 10,
                id[..<dot].allSatisfy({ $0.isLetter || $0.isNumber })
            {
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
            "webDriverAgent": .number(Double(webDriverAgent)),
            "sideStore": .number(Double(sideStore)),
            "other": .number(Double(other)),
        ]
    }
}
