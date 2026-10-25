import Foundation

/// `$SIDELOAD_HOME/ledger.json` (design section 9): what sideload has seen of the paid team's certificates and
/// provisioning profiles, and which Feather kits it exported. It holds no secrets: no password, no private key,
/// no full fingerprint (first 8 hex only), no identity name, no full device ID (last 4 only).
public struct Ledger: Codable, Sendable, Equatable {
    public static let schema = 1

    public var updated: Date?
    public var certificates: [LedgerCertificate]
    public var profiles: [LedgerProfile]
    public var exports: [LedgerExport]
    /// Free-team state (design section 18), written by `provision`. Each is written only when non-empty, so a ledger
    /// that never used the free team is byte-identical to before. Free profiles stay out of `profiles`.
    public var freeAppIds: [LedgerFreeAppId]
    public var freeProfiles: [LedgerFreeProfile]
    /// Set when a free-team hard stop (`FREE_CERT_CHANGED`) suspends auto-refresh; cleared by a manual success.
    public var freeSuspended: LedgerFreeSuspension?
    /// Written before an `xcodebuild` that may touch the free team's certificates and cleared once the identity
    /// set was compared and recorded afterwards. A marker found at the start of a free-team command means a run
    /// died in between (a signal, a crash): the next run compares first (`FreeIdentityGuard`).
    public var freeProvisionInFlight: LedgerFreeInFlight?
    /// The crash-safe record of `provision --renew` moving sideload's own cached profiles into `tmp/`: an entry is
    /// written before each rename, so a crash or kill at any point leaves a trace; the next `provision` reports what
    /// it finds (`cachedProfilesFromEarlierRun`) and keeps it until the owner clears it (`provision --renew-ack`).
    public var freeRenewMoves: [LedgerFreeRenewMove]
    /// The signed apps `sign` left under `builds/signed/` for `install` (design section 18), one per `<device>/<app>`.
    /// Written only when non-empty. Holds no profile content, no full device ID and no identity name.
    public var freeSigned: [LedgerFreeSigned]
    /// The free-team apps `install` put on devices (design section 18), one per `<device>/<app>`. Written only when
    /// non-empty. Holds no profile content, no full device ID and no identity name.
    public var installs: [LedgerInstall]
    /// Slots lent to the lab (`slot lend`), one per device. Written only when non-empty. A projection of `slots` (see
    /// `SlotRule.project`), kept so an older build reads something safe.
    public var lent: [LedgerLent]
    /// The unified pending-operation model (docs/design.md section 18): one record per `<device>/<app>` with what is known of
    /// the app's presence, who it is lent to, and the device operation that may still be in flight. The source of truth for
    /// `install`, `app remove`, `slot` and `status`; `installs[].present/opAt` and `lent` are projected from it on every write.
    /// Written only when non-empty.
    public var slots: [LedgerSlot]
    /// Keys this version does not model; they survive a rewrite (like `Config.extra`).
    public var extra: [String: JSONValue]

    public init(
        updated: Date? = nil, certificates: [LedgerCertificate] = [], profiles: [LedgerProfile] = [],
        exports: [LedgerExport] = [], freeAppIds: [LedgerFreeAppId] = [], freeProfiles: [LedgerFreeProfile] = [],
        freeSuspended: LedgerFreeSuspension? = nil, freeProvisionInFlight: LedgerFreeInFlight? = nil,
        freeRenewMoves: [LedgerFreeRenewMove] = [], freeSigned: [LedgerFreeSigned] = [], installs: [LedgerInstall] = [],
        lent: [LedgerLent] = [], slots: [LedgerSlot] = [], extra: [String: JSONValue] = [:]
    ) {
        self.updated = updated
        self.certificates = certificates
        self.profiles = profiles
        self.exports = exports
        self.freeAppIds = freeAppIds
        self.freeProfiles = freeProfiles
        self.freeSuspended = freeSuspended
        self.freeProvisionInFlight = freeProvisionInFlight
        self.freeRenewMoves = freeRenewMoves
        self.freeSigned = freeSigned
        self.installs = installs
        self.lent = lent
        self.slots = slots
        self.extra = extra
    }

    private static let known: Set<String> = [
        "schema", "updated", "certificates", "profiles", "exports", "freeAppIds", "freeProfiles", "freeSuspended",
        "freeProvisionInFlight", "freeRenewMoves", "freeSigned", "installs", "lent", "slots",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard try c.decode(Int.self, forKey: AnyKey("schema")) == Self.schema else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyKey("schema"), in: c, debugDescription: "unsupported schema")
        }
        updated = try c.decodeIfPresent(Date.self, forKey: AnyKey("updated"))
        certificates = try c.decode([LedgerCertificate].self, forKey: AnyKey("certificates"))
        profiles = try c.decode([LedgerProfile].self, forKey: AnyKey("profiles"))
        exports = try c.decode([LedgerExport].self, forKey: AnyKey("exports"))
        freeAppIds = try c.decodeIfPresent([LedgerFreeAppId].self, forKey: AnyKey("freeAppIds")) ?? []
        freeProfiles = try c.decodeIfPresent([LedgerFreeProfile].self, forKey: AnyKey("freeProfiles")) ?? []
        freeSuspended = try c.decodeIfPresent(LedgerFreeSuspension.self, forKey: AnyKey("freeSuspended"))
        freeProvisionInFlight = try c.decodeIfPresent(LedgerFreeInFlight.self, forKey: AnyKey("freeProvisionInFlight"))
        freeRenewMoves = try c.decodeIfPresent([LedgerFreeRenewMove].self, forKey: AnyKey("freeRenewMoves")) ?? []
        freeSigned = try c.decodeIfPresent([LedgerFreeSigned].self, forKey: AnyKey("freeSigned")) ?? []
        installs = try c.decodeIfPresent([LedgerInstall].self, forKey: AnyKey("installs")) ?? []
        lent = try c.decodeIfPresent([LedgerLent].self, forKey: AnyKey("lent")) ?? []
        slots = try c.decodeIfPresent([LedgerSlot].self, forKey: AnyKey("slots")) ?? []
        extra = try c.decodeExtra(excluding: Self.known)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtra(extra)
        try c.encode(Self.schema, forKey: AnyKey("schema"))
        try c.encodeIfPresent(updated, forKey: AnyKey("updated"))
        try c.encode(certificates, forKey: AnyKey("certificates"))
        try c.encode(profiles, forKey: AnyKey("profiles"))
        try c.encode(exports, forKey: AnyKey("exports"))
        if !freeAppIds.isEmpty { try c.encode(freeAppIds, forKey: AnyKey("freeAppIds")) }
        if !freeProfiles.isEmpty { try c.encode(freeProfiles, forKey: AnyKey("freeProfiles")) }
        try c.encodeIfPresent(freeSuspended, forKey: AnyKey("freeSuspended"))
        try c.encodeIfPresent(freeProvisionInFlight, forKey: AnyKey("freeProvisionInFlight"))
        if !freeRenewMoves.isEmpty { try c.encode(freeRenewMoves, forKey: AnyKey("freeRenewMoves")) }
        if !freeSigned.isEmpty { try c.encode(freeSigned, forKey: AnyKey("freeSigned")) }
        if !installs.isEmpty { try c.encode(installs, forKey: AnyKey("installs")) }
        if !lent.isEmpty { try c.encode(lent, forKey: AnyKey("lent")) }
        if !slots.isEmpty { try c.encode(slots, forKey: AnyKey("slots")) }
    }
}

/// One cached profile `provision --renew` is moving (or moved) out of Xcode's folder. Names only, never a path:
/// `from` is the file's name in the Xcode folder, `to` is `tmp/<name>` relative to `$SIDELOAD_HOME`. Holds no profile
/// content.
public struct LedgerFreeRenewMove: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Written before the rename: the file is still in the Xcode folder, or already in `tmp/` (the run died).
        case intent
        /// Renamed and checked: the file is in `tmp/`.
        case done
        /// Moved by mistake and could not be put back: it stays in `tmp/` for the owner to look at.
        case stray
    }

    public var from: String
    public var to: String
    public var at: Date
    public var state: State
    /// Which Xcode folder `from` was in, as a label (`xcode-userdata`, `mobiledevice`, else `folder-N`), never a path.
    public var folder: String?

    public init(from: String, to: String, at: Date, state: State = .intent, folder: String? = nil) {
        self.folder = folder
        self.from = from
        self.to = to
        self.at = at
        self.state = state
    }
}

/// One free-team App ID sideload assumes is registered: the free team allows 10 new App IDs per 7 days and the
/// count cannot be queried, so each bundle ID's `epochStart` (when sideload first saw it registered, in this
/// window) stands in for it. One entry per bundle ID.
public struct LedgerFreeAppId: Codable, Sendable, Equatable {
    public var bundleId: String
    public var epochStart: Date

    public init(bundleId: String, epochStart: Date) {
        self.bundleId = bundleId
        self.epochStart = epochStart
    }
}

/// The current free-team development profile `provision` stored for one app on one device, keyed `<device>/<app>`.
/// Holds no profile content: the file lives under `profiles/free/` (0600), `file` is relative to `$SIDELOAD_HOME`,
/// the device is its alias and the last four characters of its ID.
public struct LedgerFreeProfile: Codable, Sendable, Equatable {
    public var id: String
    public var device: String
    public var deviceTail: String
    public var app: String
    public var bundleId: String
    public var profileUuid: String
    public var created: Date?
    public var expires: Date
    public var certFp8: String
    public var file: String

    public init(
        id: String, device: String, deviceTail: String, app: String, bundleId: String, profileUuid: String,
        created: Date?, expires: Date, certFp8: String, file: String
    ) {
        self.id = id
        self.device = device
        self.deviceTail = deviceTail
        self.app = app
        self.bundleId = bundleId
        self.profileUuid = profileUuid
        self.created = created
        self.expires = expires
        self.certFp8 = certFp8
        self.file = file
    }
}

/// One extension `sign` removed from an app (path inside the app and the extension's bundle ID).
public struct LedgerStrippedExtension: Codable, Sendable, Equatable {
    public var path: String
    public var bundleId: String?

    public init(path: String, bundleId: String?) {
        self.path = path
        self.bundleId = bundleId
    }
}

/// The signed app `sign` left for `install`, keyed `<device>/<app>`: one entry per key (a new sign replaces it).
/// `path` is relative to `$SIDELOAD_HOME` (`builds/signed/<app>/<device>/<Name>.app`). `sha256Prefix` is the first
/// 8 hex digits of the source IPA's SHA-256 (the manifest's `sha256`). Holds no profile content, no device ID and
/// no identity name.
public struct LedgerFreeSigned: Codable, Sendable, Equatable {
    public var id: String
    public var device: String
    public var app: String
    public var bundleId: String
    public var version: String
    public var sha256Prefix: String
    public var profileUuid: String
    public var profileExpires: Date
    public var certFp8: String
    public var signedAt: Date
    public var path: String
    public var strippedExtensions: [LedgerStrippedExtension]
    public var droppedEntitlements: [String]

    public init(
        id: String, device: String, app: String, bundleId: String, version: String, sha256Prefix: String,
        profileUuid: String, profileExpires: Date, certFp8: String, signedAt: Date, path: String,
        strippedExtensions: [LedgerStrippedExtension], droppedEntitlements: [String]
    ) {
        self.id = id
        self.device = device
        self.app = app
        self.bundleId = bundleId
        self.version = version
        self.sha256Prefix = sha256Prefix
        self.profileUuid = profileUuid
        self.profileExpires = profileExpires
        self.certFp8 = certFp8
        self.signedAt = signedAt
        self.path = path
        self.strippedExtensions = strippedExtensions
        self.droppedEntitlements = droppedEntitlements
    }
}

/// What the refresh machinery (design section 18, build step 9) keeps per install. `install` initialises it; a manual
/// success clears a suspension.
public struct LedgerInstallRefresh: Codable, Sendable, Equatable {
    public var lastAttempt: Date?
    public var lastResult: String?
    public var lastCode: String?
    public var consecutiveFailures: Int
    public var nextEligible: Date?
    /// Auto attempts per local day (`yyyy-MM-dd`), for the daily caps.
    public var attemptsByDay: [String: Int]
    public var suspended: Bool

    public init(
        lastAttempt: Date? = nil, lastResult: String? = nil, lastCode: String? = nil, consecutiveFailures: Int = 0,
        nextEligible: Date? = nil, attemptsByDay: [String: Int] = [:], suspended: Bool = false
    ) {
        self.lastAttempt = lastAttempt
        self.lastResult = lastResult
        self.lastCode = lastCode
        self.consecutiveFailures = consecutiveFailures
        self.nextEligible = nextEligible
        self.attemptsByDay = attemptsByDay
        self.suspended = suspended
    }
}

/// One free-team app `install` put on a saved device, keyed `<device>/<app>` (design section 18). `present` is false after
/// `app remove` or `slot lend`. `device` is the alias and `deviceTail` the last four characters of the device's ID.
public struct LedgerInstall: Codable, Sendable, Equatable {
    public var id: String
    public var device: String
    public var deviceTail: String
    public var app: String
    public var bundleId: String
    public var team: String
    public var profileUuid: String
    public var profileCreated: Date?
    public var profileExpires: Date
    public var certFp8: String
    public var version: String
    public var sha256Prefix: String
    public var signedAt: Date
    public var installedAt: Date
    public var strippedExtensions: [LedgerStrippedExtension]
    public var droppedEntitlements: [String]
    public var present: Bool
    public var refresh: LedgerInstallRefresh
    /// Projection of the slot's `op.startedAt` (nil when no device operation is in flight). `present` and `opAt` are rewritten
    /// from `slots` on every write; this entry keeps the install's metadata.
    public var opAt: Date?

    public init(
        id: String, device: String, deviceTail: String, app: String, bundleId: String, team: String = "free",
        profileUuid: String, profileCreated: Date?, profileExpires: Date, certFp8: String, version: String,
        sha256Prefix: String, signedAt: Date, installedAt: Date, strippedExtensions: [LedgerStrippedExtension],
        droppedEntitlements: [String], present: Bool = true, refresh: LedgerInstallRefresh = LedgerInstallRefresh(),
        opAt: Date? = nil
    ) {
        self.id = id
        self.device = device
        self.deviceTail = deviceTail
        self.app = app
        self.bundleId = bundleId
        self.team = team
        self.profileUuid = profileUuid
        self.profileCreated = profileCreated
        self.profileExpires = profileExpires
        self.certFp8 = certFp8
        self.version = version
        self.sha256Prefix = sha256Prefix
        self.signedAt = signedAt
        self.installedAt = installedAt
        self.strippedExtensions = strippedExtensions
        self.droppedEntitlements = droppedEntitlements
        self.present = present
        self.refresh = refresh
        self.opAt = opAt
    }
}

/// A slot sideload freed for the lab (`slot lend`): the app that was uninstalled, the saved device (alias), who it was
/// lent to (`lab`) and when. One per device; no record means no lend. Since the unified pending-operation model this is a
/// PROJECTION of `Ledger.slots` (`SlotRule.project`), rewritten on every write so an older build reads something safe:
/// `lent` (the slot has no operation in flight and the app is absent: the lab holds it), `returning` (an install or reinstall
/// may be in flight) and `lending` (anything else pending). Only `lent` holds the slot for the lab. A record without `state`
/// (written before the state machine) reads as `lending`; `SlotRule.migrate` turns the legacy shapes into slots. `opAt` is the
/// projected `op.startedAt`.
public struct LedgerLent: Codable, Sendable, Equatable {
    public static let lending = "lending"
    public static let lent = "lent"
    public static let returning = "returning"

    public var app: String
    public var device: String
    public var to: String
    public var since: Date
    public var state: String
    public var opAt: Date?

    public init(app: String, device: String, to: String, since: Date, state: String = LedgerLent.lent, opAt: Date? = nil) {
        self.app = app
        self.device = device
        self.to = to
        self.since = since
        self.state = state
        self.opAt = opAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        app = try c.decode(String.self, forKey: AnyKey("app"))
        device = try c.decode(String.self, forKey: AnyKey("device"))
        to = try c.decode(String.self, forKey: AnyKey("to"))
        since = try c.decode(Date.self, forKey: AnyKey("since"))
        state = try c.decodeIfPresent(String.self, forKey: AnyKey("state")) ?? Self.lending
        opAt = try c.decodeIfPresent(Date.self, forKey: AnyKey("opAt"))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(app, forKey: AnyKey("app"))
        try c.encode(device, forKey: AnyKey("device"))
        try c.encode(self.to, forKey: AnyKey("to"))
        try c.encode(since, forKey: AnyKey("since"))
        try c.encode(state, forKey: AnyKey("state"))
        try c.encodeIfPresent(opAt, forKey: AnyKey("opAt"))
    }
}

/// What a device operation on one slot was: a first `install`, a `reinstall` over an app already there, or an `uninstall`.
public enum LedgerSlotKind: String, Codable, Sendable, Equatable {
    case install, reinstall, uninstall

    public init(from decoder: any Decoder) throws {
        // An unknown kind reads as the strictest one: settled only by a definite result.
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .reinstall
    }
}

/// Which command started the operation.
public enum LedgerSlotBy: String, Codable, Sendable, Equatable {
    case install, lend
    case giveBack = "return"
    case remove

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .remove
    }
}

/// What is known of the app's presence. `unknown` only appears with an operation in flight (it is migrated from a legacy
/// pending record).
public enum LedgerSlotPresence: String, Codable, Sendable, Equatable {
    case present, absent, unknown

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// A device operation that may still be in flight: written durably BEFORE the device call, with `startedAt` the clock at the
/// write rounded up, and `window` (seconds) the longest it can run plus the settle grace. The effective window is
/// `max(window, SlotRule.window(kind))`, so changed constants never shorten a pending record.
public struct LedgerSlotOp: Codable, Sendable, Equatable {
    public var kind: LedgerSlotKind
    public var by: LedgerSlotBy
    public var startedAt: Date
    public var window: Int

    public init(kind: LedgerSlotKind, by: LedgerSlotBy, startedAt: Date, window: Int) {
        self.kind = kind
        self.by = by
        self.startedAt = startedAt
        self.window = window
    }
}

/// One `<device>/<app>` record of the unified pending-operation model (docs/design.md section 18): what is known of the app's
/// presence, who it is lent to (`lentTo` with `since`), and the device operation that may still be in flight (`op`).
/// `seenAt` is the `takenAt` of the last snapshot that set `presence`. Holds no device ID.
public struct LedgerSlot: Codable, Sendable, Equatable {
    public var id: String
    public var device: String
    public var app: String
    public var presence: LedgerSlotPresence
    public var lentTo: String?
    public var since: Date?
    public var op: LedgerSlotOp?
    public var seenAt: Date?

    public init(
        device: String, app: String, presence: LedgerSlotPresence, lentTo: String? = nil, since: Date? = nil,
        op: LedgerSlotOp? = nil, seenAt: Date? = nil
    ) {
        self.id = "\(device)/\(app)"
        self.device = device
        self.app = app
        self.presence = presence
        self.lentTo = lentTo
        self.since = since
        self.op = op
        self.seenAt = seenAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        device = try c.decode(String.self, forKey: AnyKey("device"))
        app = try c.decode(String.self, forKey: AnyKey("app"))
        presence = try c.decode(LedgerSlotPresence.self, forKey: AnyKey("presence"))
        lentTo = try c.decodeIfPresent(String.self, forKey: AnyKey("lentTo"))
        since = try c.decodeIfPresent(Date.self, forKey: AnyKey("since"))
        op = try c.decodeIfPresent(LedgerSlotOp.self, forKey: AnyKey("op"))
        seenAt = try c.decodeIfPresent(Date.self, forKey: AnyKey("seenAt"))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(device, forKey: AnyKey("device"))
        try c.encode(app, forKey: AnyKey("app"))
        try c.encode(presence, forKey: AnyKey("presence"))
        try c.encodeIfPresent(lentTo, forKey: AnyKey("lentTo"))
        try c.encodeIfPresent(since, forKey: AnyKey("since"))
        try c.encodeIfPresent(op, forKey: AnyKey("op"))
        try c.encodeIfPresent(seenAt, forKey: AnyKey("seenAt"))
    }
}

/// The crash-safe "a build that may change the free team's identities is running" marker. `beforeFp8` is the first
/// 8 hex digits (lower case) of the SHA-1 of every free-team identity, valid or not, taken before the build (the
/// ledger keeps no full fingerprint); `device` is the alias.
public struct LedgerFreeInFlight: Codable, Sendable, Equatable {
    public var beforeFp8: [String]
    public var startedAt: Date
    public var app: String
    public var device: String

    public init(beforeFp8: [String], startedAt: Date, app: String, device: String) {
        self.beforeFp8 = beforeFp8
        self.startedAt = startedAt
        self.app = app
        self.device = device
    }
}

/// Auto-refresh of the free team is suspended until a manual `provision` succeeds (design section 18).
public struct LedgerFreeSuspension: Codable, Sendable, Equatable {
    public var code: String
    public var at: Date
    /// First 8 hex of the SHA-1 of each free identity that appeared or went away.
    public var addedFp8: [String]
    public var removedFp8: [String]

    public init(code: String, at: Date, addedFp8: [String] = [], removedFp8: [String] = []) {
        self.code = code
        self.at = at
        self.addedFp8 = addedFp8
        self.removedFp8 = removedFp8
    }
}

/// A paid-team Apple Development certificate. Never the free team's.
public struct LedgerCertificate: Sendable, Equatable {
    /// First 8 hex digits of the SHA-1, lowercase (the form `canary.jsonl` uses).
    public var fp8: String
    public var team: String
    public var notBefore: Date?
    public var notAfter: Date
    public var firstSeen: Date
    public var lastSeen: Date
    /// Seen at the last refresh, trusted for code signing and not expired.
    public var valid: Bool
    /// Seen at the last refresh. Only present items feed expiry warnings.
    public var present: Bool
    /// Keys this version does not model; they survive a rewrite.
    public var extra: [String: JSONValue] = [:]
}

/// A provisioning profile of the paid team.
public struct LedgerProfile: Sendable, Equatable {
    public var uuid: String
    public var team: String
    /// `application-identifier`, team prefix included.
    public var applicationId: String?
    public var wildcard: Bool
    public var created: Date?
    public var expires: Date
    public var deviceCount: Int
    /// Last four characters of each provisioned device ID.
    public var deviceTails: [String]
    /// First 8 hex of each embedded certificate's SHA-1.
    public var certFp8s: [String]
    public var source: String
    public var firstSeen: Date
    public var lastSeen: Date
    /// Seen at the last refresh. Only present items feed expiry warnings.
    public var present: Bool
    public var extra: [String: JSONValue] = [:]
}

/// One `export-cert` run (written by that command, not by `ledger refresh`).
public struct LedgerExport: Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var certFp8: String
    public var profileUuid: String
    /// Relative to `$SIDELOAD_HOME`.
    public var p12File: String
    public var p12Sha256Prefix: String
    public var encryption: String
    /// `keychain`: the password lives in the keychain, never here.
    public var passwordItem: String
    public var kitPath: String
    public var verified: Bool
    public var extra: [String: JSONValue] = [:]
}

// MARK: - Coding
// Entries decode every known key (a missing or mistyped one is an error) and keep the rest in `extra`.
// Declared in extensions so the memberwise initialisers stay.

extension KeyedDecodingContainer where K == AnyKey {
    func decodeExtra(excluding known: Set<String>) throws -> [String: JSONValue] {
        var extra: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try decode(JSONValue.self, forKey: key)
        }
        return extra
    }

    fileprivate func value<T: Decodable>(_ key: String) throws -> T { try decode(T.self, forKey: AnyKey(key)) }

    fileprivate func optional<T: Decodable>(_ key: String) throws -> T? { try decodeIfPresent(T.self, forKey: AnyKey(key)) }
}

extension KeyedEncodingContainer where K == AnyKey {
    mutating func encodeExtra(_ extra: [String: JSONValue]) throws {
        for (key, value) in extra { try encode(value, forKey: AnyKey(key)) }
    }

    fileprivate mutating func put(_ value: some Encodable, _ key: String) throws { try encode(value, forKey: AnyKey(key)) }

    fileprivate mutating func putIfPresent(_ value: (some Encodable)?, _ key: String) throws {
        try encodeIfPresent(value, forKey: AnyKey(key))
    }
}

extension LedgerCertificate: Codable {
    private static let known: Set<String> = [
        "fp8", "team", "notBefore", "notAfter", "firstSeen", "lastSeen", "valid", "present",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        fp8 = try c.value("fp8")
        team = try c.value("team")
        notBefore = try c.optional("notBefore")
        notAfter = try c.value("notAfter")
        firstSeen = try c.value("firstSeen")
        lastSeen = try c.value("lastSeen")
        valid = try c.value("valid")
        present = try c.value("present")
        extra = try c.decodeExtra(excluding: Self.known)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtra(extra)
        try c.put(fp8, "fp8")
        try c.put(team, "team")
        try c.putIfPresent(notBefore, "notBefore")
        try c.put(notAfter, "notAfter")
        try c.put(firstSeen, "firstSeen")
        try c.put(lastSeen, "lastSeen")
        try c.put(valid, "valid")
        try c.put(present, "present")
    }
}

extension LedgerProfile: Codable {
    private static let known: Set<String> = [
        "uuid", "team", "applicationId", "wildcard", "created", "expires", "deviceCount", "deviceTails", "certFp8s",
        "source", "firstSeen", "lastSeen", "present",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        uuid = try c.value("uuid")
        team = try c.value("team")
        applicationId = try c.optional("applicationId")
        wildcard = try c.value("wildcard")
        created = try c.optional("created")
        expires = try c.value("expires")
        deviceCount = try c.value("deviceCount")
        deviceTails = try c.value("deviceTails")
        certFp8s = try c.value("certFp8s")
        source = try c.value("source")
        firstSeen = try c.value("firstSeen")
        lastSeen = try c.value("lastSeen")
        present = try c.value("present")
        extra = try c.decodeExtra(excluding: Self.known)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtra(extra)
        try c.put(uuid, "uuid")
        try c.put(team, "team")
        try c.putIfPresent(applicationId, "applicationId")
        try c.put(wildcard, "wildcard")
        try c.putIfPresent(created, "created")
        try c.put(expires, "expires")
        try c.put(deviceCount, "deviceCount")
        try c.put(deviceTails, "deviceTails")
        try c.put(certFp8s, "certFp8s")
        try c.put(source, "source")
        try c.put(firstSeen, "firstSeen")
        try c.put(lastSeen, "lastSeen")
        try c.put(present, "present")
    }
}

extension LedgerExport: Codable {
    private static let known: Set<String> = [
        "id", "createdAt", "certFp8", "profileUuid", "p12File", "p12Sha256Prefix", "encryption", "passwordItem",
        "kitPath", "verified",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.value("id")
        createdAt = try c.value("createdAt")
        certFp8 = try c.value("certFp8")
        profileUuid = try c.value("profileUuid")
        p12File = try c.value("p12File")
        p12Sha256Prefix = try c.value("p12Sha256Prefix")
        encryption = try c.value("encryption")
        passwordItem = try c.value("passwordItem")
        kitPath = try c.value("kitPath")
        verified = try c.value("verified")
        extra = try c.decodeExtra(excluding: Self.known)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtra(extra)
        try c.put(id, "id")
        try c.put(createdAt, "createdAt")
        try c.put(certFp8, "certFp8")
        try c.put(profileUuid, "profileUuid")
        try c.put(p12File, "p12File")
        try c.put(p12Sha256Prefix, "p12Sha256Prefix")
        try c.put(encryption, "encryption")
        try c.put(passwordItem, "passwordItem")
        try c.put(kitPath, "kitPath")
        try c.put(verified, "verified")
    }
}
