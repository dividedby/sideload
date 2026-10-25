import Foundation

// Free-team settings in `config.json` under `freeTeam` (design section 18). `Config` keeps the object in `extra`,
// so older builds carry it through a rewrite untouched.

extension Config {
    /// `freeTeam.reservedAppIds` default: App ID slots the owner keeps for other tools (Xcode, the lab).
    public static let defaultReservedAppIds = 4

    private func freeTeamObject() throws -> [String: JSONValue] {
        switch extra["freeTeam"] {
        case nil: return [:]
        case .object(let fields)?: return fields
        default:
            throw SideloadError(
                "CONFIG_INVALID", "config.json `freeTeam` must be an object.",
                fix: "Fix or remove `freeTeam` in $SIDELOAD_HOME/config.json.")
        }
    }

    private func invalidFreeTeam(_ key: String, _ want: String) -> SideloadError {
        SideloadError(
            "CONFIG_INVALID", "config.json `freeTeam.\(key)` must be \(want).",
            fix: "Fix or remove `freeTeam.\(key)` in $SIDELOAD_HOME/config.json.")
    }

    /// `freeTeam.certFp8`: the first 8 hex digits (lower case) of the pinned free identity's SHA-1, or nil when none
    /// is pinned yet. Anything else is `CONFIG_INVALID` (the value is not echoed).
    public func freeTeamCertFp8() throws -> String? {
        guard let value = try freeTeamObject()["certFp8"] else { return nil }
        guard case .string(let fp8) = value, fp8.wholeMatch(of: /[0-9a-f]{8}/) != nil else {
            throw invalidFreeTeam("certFp8", "8 lower-case hex digits")
        }
        return fp8
    }

    /// `freeTeam.reservedAppIds` (0 to 10, default 4): owner-set.
    public func freeTeamReservedAppIds() throws -> Int {
        guard let value = try freeTeamObject()["reservedAppIds"] else { return Self.defaultReservedAppIds }
        guard case .number(let n) = value, n == n.rounded(), (0...Double(FreeAppIdBudget.limit)).contains(n) else {
            throw invalidFreeTeam("reservedAppIds", "a whole number from 0 to \(FreeAppIdBudget.limit)")
        }
        return Int(n)
    }

    /// Pins the free identity. A different pin already in place is an error (only the owner re-pins); the same
    /// one is a no-op.
    public mutating func pinFreeTeamCert(fp8: String) throws {
        precondition(fp8.wholeMatch(of: /[0-9a-f]{8}/) != nil, "fp8 must be 8 lower-case hex digits")
        if let existing = try freeTeamCertFp8() {
            guard existing == fp8 else {
                throw SideloadError(
                    "FREE_IDENTITY_AMBIGUOUS", "A different free identity is already pinned.",
                    fix: "Only the owner changes `freeTeam.certFp8`.")
            }
            return
        }
        var fields = try freeTeamObject()
        fields["certFp8"] = .string(fp8)
        extra["freeTeam"] = .object(fields)
    }
}

/// The free team's App ID budget (design section 18): 10 new App IDs per 7 days, shared with every other tool and
/// not queryable, so sideload assumes each App ID it saw registered lives 7 days from its `epochStart`.
public enum FreeAppIdBudget {
    public static let limit = 10
    public static let window: TimeInterval = 7 * 86_400

    /// Entries whose epoch is under 7 days old.
    public static func live(_ entries: [LedgerFreeAppId], now: Date) -> [LedgerFreeAppId] {
        entries.filter { now.timeIntervalSince($0.epochStart) < window }
    }

    public struct Decision: Sendable, Equatable {
        /// The bundle ID has no live epoch, so a run would register it afresh.
        public let isNew: Bool
        /// Live epochs across all bundle IDs, before this run.
        public let recent: Int
        /// A new registration fits: `recent + reserved + 1 <= 10`. Always true for a bundle ID with a live epoch.
        public let allowed: Bool
    }

    public static func evaluate(
        _ entries: [LedgerFreeAppId], bundleId: String, reserved: Int, now: Date
    ) -> Decision {
        let live = live(entries, now: now)
        let isNew = !live.contains { $0.bundleId == bundleId }
        return Decision(isNew: isNew, recent: live.count, allowed: !isNew || live.count + reserved + 1 <= limit)
    }

    /// Records a run whose build succeeded for `bundleId`: with no live epoch it starts a fresh one at `now`
    /// (replacing the bundle ID's expired entry), a live one is left alone. One entry per bundle ID; entries
    /// a window old are dropped, since they no longer count.
    public static func recording(
        _ entries: [LedgerFreeAppId], bundleId: String, now: Date
    ) -> [LedgerFreeAppId] {
        var kept = live(entries, now: now)
        if !kept.contains(where: { $0.bundleId == bundleId }) {
            kept.append(LedgerFreeAppId(bundleId: bundleId, epochStart: now))
        }
        return kept.sorted { ($0.epochStart, $0.bundleId) < ($1.epochStart, $1.bundleId) }
    }
}
