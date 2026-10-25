import Foundation

/// The bundle IDs that have a free-team provisioning profile installed on a device, from one read-only
/// `devicectl device profile list --type provisioning`. This is the exact signal for "another free-team app" (WebDriverAgent,
/// SideStore, ...): `devicectl device info apps` marks TestFlight betas `builtByDeveloper` just like free-team apps, but their
/// profiles belong to other teams. Expired profiles count too (fail-safe), and a profile whose app is gone counts for nothing
/// (the caller intersects with the installed apps). The IDs are never printed: only counts leave this type.
public struct FreeTeamProfiles: Sendable, Equatable {
    public let bundleIds: Set<String>

    public init(bundleIds: Set<String>) {
        self.bundleIds = bundleIds
    }

    /// Nil unless the document is a complete listing: a top-level object whose `info.outcome` is `"success"`, with
    /// `result.provisioningProfiles` an array of objects that each carry string `teamIdentifier` and `appIdentifier`. Anything
    /// else is a failed read, so the caller falls back to the reserve. A free-team profile whose `appIdentifier` is not
    /// `<team>.<id>` is ignored.
    public static func parse(_ json: JSONValue?) -> FreeTeamProfiles? {
        guard case .object(let top)? = json,
            case .object(let info)? = top["info"], info["outcome"] == .string("success"),
            case .object(let result)? = top["result"], case .array(let items)? = result["provisioningProfiles"]
        else { return nil }
        let prefix = Team.free + "."
        var ids: Set<String> = []
        for item in items {
            guard case .object(let fields) = item, case .string(let team)? = fields["teamIdentifier"],
                case .string(let app)? = fields["appIdentifier"]
            else { return nil }
            if team == Team.free, app.hasPrefix(prefix), app.count > prefix.count {
                ids.insert(String(app.dropFirst(prefix.count)))
            }
        }
        return FreeTeamProfiles(bundleIds: ids)
    }
}
