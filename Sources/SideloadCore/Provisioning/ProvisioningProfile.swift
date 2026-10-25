import CoreFoundation
import Foundation

/// The non-secret facts of one decoded provisioning profile (`security cms -D -i` output). Full device UDIDs
/// stay in memory for matching; every report prints their last four characters only.
public struct ProvisioningProfile: Sendable, Equatable {
    /// Upper-case `UUID` from the profile (also its file name in Xcode's folder).
    public var uuid: String
    /// First entry of `TeamIdentifier`.
    public var team: String?
    /// `Entitlements` > `application-identifier`, team prefix included (`TEAM.*` for a wildcard profile).
    public var applicationIdentifier: String?
    /// `Entitlements` > `get-task-allow`; nil unless the plist holds a real boolean.
    public var getTaskAllow: Bool?
    /// `Platform` (`iOS`, `tvOS`, ...).
    public var platforms: [String]
    public var created: Date?
    public var expires: Date?
    /// `ProvisionedDevices`, lowercased. Never print.
    public var devices: [String]
    /// Upper-case hex SHA-1 of each `DeveloperCertificates` entry (the form of `KeychainCertificate.reference`).
    public var certFingerprints: [String]
    /// The file the profile was decoded from. Local use only (copying the original signed bytes): never print it.
    public var file: String?

    public init(
        uuid: String, team: String? = nil, applicationIdentifier: String? = nil, getTaskAllow: Bool? = nil,
        platforms: [String] = [], created: Date? = nil, expires: Date? = nil, devices: [String] = [],
        certFingerprints: [String] = [], file: String? = nil
    ) {
        self.uuid = uuid
        self.team = team
        self.applicationIdentifier = applicationIdentifier
        self.getTaskAllow = getTaskAllow
        self.platforms = platforms
        self.created = created
        self.expires = expires
        self.devices = devices
        self.certFingerprints = certFingerprints
        self.file = file
    }

    /// `TEAM.*`: one profile that covers every bundle ID of the team.
    public var isWildcard: Bool {
        guard let team, let applicationIdentifier else { return false }
        return applicationIdentifier == team + ".*"
    }

    /// A development profile: `get-task-allow` is true and it lists devices.
    public var isDevelopment: Bool { getTaskAllow == true && !devices.isEmpty }

    public func includes(device udid: String) -> Bool { devices.contains(udid.lowercased()) }

    public func contains(certificate reference: String) -> Bool {
        certFingerprints.contains { $0.caseInsensitiveCompare(reference) == .orderedSame }
    }

    /// Parses the XML plist `security cms -D` prints. Nil when it is not a plist dictionary or has no valid
    /// `UUID`. Only top-level keys (and `Entitlements`' own) are read, so a nested key of the same name cannot
    /// be mistaken for them. The keys `Guard.parseProfile` reads are taken from it, not read a second time.
    public static func parse(_ xml: String, file: String? = nil) -> ProvisioningProfile? {
        guard
            let shared = Guard.parseProfile(xml),
            let plist = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil),
            let dict = plist as? [String: Any],
            let rawUUID = dict["UUID"] as? String,
            let uuid = UUID(uuidString: rawUUID)
        else { return nil }
        let entitlements = dict["Entitlements"] as? [String: Any]
        return ProvisioningProfile(
            uuid: uuid.uuidString, team: shared.team,
            applicationIdentifier: entitlements?["application-identifier"] as? String,
            getTaskAllow: entitlements?["get-task-allow"].flatMap(strictBool),
            platforms: (dict["Platform"] as? [Any])?.compactMap { $0 as? String } ?? [],
            created: shared.creation, expires: shared.expiration, devices: shared.devices,
            certFingerprints: shared.certFingerprints, file: file)
    }

    /// A plist `<true/>` or `<false/>` only: not the integer 1, not a string.
    private static func strictBool(_ value: Any) -> Bool? {
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }
}
