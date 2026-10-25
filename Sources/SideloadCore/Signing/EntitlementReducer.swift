import Foundation

/// The entitlements the re-signed main app gets, and what was left out (design section 18, `sign` step 4).
///
/// A free team's profile grants only a handful of entitlements, so the main app's originals are reduced to:
/// `application-identifier` and `com.apple.developer.team-identifier` (always, from the profile), `get-task-allow`
/// (always, with the profile's value: the original's is never copied and never listed as dropped) and `keychain-access-groups` rewritten to the single group
/// `<team>.<bundle id>` (when the original had any). Everything else (`aps-environment`, app groups, iCloud,
/// associated domains, ...) is dropped and listed in `dropped`.
struct EntitlementReduction: Equatable, Sendable {
    var applicationIdentifier: String
    var teamIdentifier: String
    var getTaskAllow: Bool
    var keychainGroup: String?
    /// Sorted names of the original keys that are not in the result.
    var dropped: [String]
    /// The groups the original declared under `com.apple.security.application-groups`.
    var appGroups: [String]

    static let applicationIdentifierKey = "application-identifier"
    static let teamIdentifierKey = "com.apple.developer.team-identifier"
    static let getTaskAllowKey = "get-task-allow"
    static let keychainGroupsKey = "keychain-access-groups"
    static let appGroupsKey = "com.apple.security.application-groups"

    /// The property list `codesign --entitlements` reads.
    var plist: [String: Any] {
        var out: [String: Any] = [
            Self.applicationIdentifierKey: applicationIdentifier, Self.teamIdentifierKey: teamIdentifier,
        ]
        out[Self.getTaskAllowKey] = getTaskAllow
        if let keychainGroup { out[Self.keychainGroupsKey] = [keychainGroup] }
        return out
    }

    func plistData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

enum EntitlementReducer {
    /// `original` is the main app's entitlements as `inspect` read them (nil or a non-object: none). `applicationIdentifier`
    /// is the profile's (`<team>.<bundle id>`), `team` the profile's team, `getTaskAllow` the profile's
    /// `get-task-allow` (already verified true).
    static func reduce(
        original: JSONValue?, applicationIdentifier: String, team: String, getTaskAllow: Bool
    ) -> EntitlementReduction {
        var fields: [String: JSONValue] = [:]
        if case .object(let object)? = original { fields = object }

        let bundleId = String(applicationIdentifier.dropFirst(team.count + 1))
        var reduction = EntitlementReduction(
            applicationIdentifier: applicationIdentifier, teamIdentifier: team, getTaskAllow: getTaskAllow, keychainGroup: nil,
            dropped: [], appGroups: BinaryTools.appGroups(original))

        // All three are written from the profile, so an original of the same name is replaced, not dropped.
        var kept: Set<String> = [
            EntitlementReduction.applicationIdentifierKey, EntitlementReduction.teamIdentifierKey,
            EntitlementReduction.getTaskAllowKey,
        ]
        if case .array(let groups)? = fields[EntitlementReduction.keychainGroupsKey],
            groups.contains(where: { if case .string = $0 { true } else { false } })
        {
            reduction.keychainGroup = team + "." + bundleId
            kept.insert(EntitlementReduction.keychainGroupsKey)
        }
        reduction.dropped = fields.keys.filter { !kept.contains($0) }.sorted()
        return reduction
    }

    /// Splits the groups that go away: those the main app declares (a warning) and those only a stripped
    /// extension declared (information). Both lists are sorted and de-duplicated.
    static func groupSplit(app: [String], stripped: [StrippedBundle]) -> (declaredByApp: [String], extensionsOnly: [String]) {
        let mine = Set(app)
        let theirs = Set(stripped.flatMap(\.appGroups))
        return (mine.sorted(), theirs.subtracting(mine).sorted())
    }
}
