import Foundation

/// Picks the certificate and the provisioning profile for a Feather kit (design section 8, `export-cert`).
/// Pure: no keychain, no filesystem, so the paid-team rules are testable on their own.
///
/// Certificate: a valid, unexpired paid-team certificate (first OU is the paid team, the free OU nowhere).
/// Profile: the paid team's, unexpired, a development profile (`get-task-allow`, devices listed) for iOS, that
/// includes the device and embeds the certificate. Ranking: a wildcard profile first, then the later certificate
/// expiry, then the later profile expiry; the profile UUID and certificate reference only make ties deterministic.
enum ExportPlanner {
    struct Plan: Equatable {
        var certificate: KeychainCertificate
        var profile: ProvisioningProfile
        /// Explicit-only: zsign matches by bundle-ID suffix, so Feather may not sign every app with it.
        var warnsNotWildcard: Bool { !profile.isWildcard }
    }

    enum Failure: Error, Equatable {
        case certNotFound
        case profileNotFound
        case deviceNotInProfile
        case certMismatch

        var sideloadError: SideloadError {
            switch self {
            case .certNotFound:
                return SideloadError(
                    "CERT_NOT_FOUND", "No valid Apple Development certificate for team \(Team.id) is in the keychain.",
                    fix: "Run `sideload doctor`; create the certificate in Xcode > Settings > Accounts (owner action).")
            case .profileNotFound:
                return SideloadError(
                    "PROFILE_NOT_FOUND",
                    "No unexpired iOS development profile for team \(Team.id) was found (or the --profile UUID is not one).",
                    fix: "Let Xcode create one (build any app for the device once), then run `sideload ledger refresh`.")
            case .deviceNotInProfile:
                return SideloadError(
                    "DEVICE_NOT_IN_PROFILE", "No development profile of the paid team lists this device.",
                    fix: "Register the device in Xcode (build once from the IDE) so a profile includes it, then retry.")
            case .certMismatch:
                return SideloadError(
                    "PROFILE_CERT_MISMATCH",
                    "No profile that includes this device embeds a valid paid-team certificate from the keychain.",
                    fix: "Regenerate the profile in Xcode so it carries the current certificate, then retry.")
            }
        }
    }

    static func plan(
        certificates: [KeychainCertificate], profiles: [ProvisioningProfile], udid: String, profileUUID: String?,
        now: Date
    ) throws -> Plan {
        let certs = CertCheck.paidCandidates(certificates, now: now)
        guard !certs.isEmpty else { throw Failure.certNotFound }

        var pool = profiles
        if let profileUUID {
            pool = profiles.filter { $0.uuid.caseInsensitiveCompare(profileUUID) == .orderedSame }
        }
        let usable = pool.filter { profile in
            profile.team == Team.id && (profile.expires.map { $0 > now } ?? false) && profile.isDevelopment
                && profile.platforms.contains { $0.caseInsensitiveCompare("iOS") == .orderedSame }
        }
        guard !usable.isEmpty else { throw Failure.profileNotFound }
        let withDevice = usable.filter { $0.includes(device: udid) }
        guard !withDevice.isEmpty else { throw Failure.deviceNotInProfile }

        var pairs: [Plan] = []
        for profile in withDevice {
            for cert in certs where profile.contains(certificate: cert.reference) {
                pairs.append(Plan(certificate: cert, profile: profile))
            }
        }
        guard !pairs.isEmpty else { throw Failure.certMismatch }

        let ranked = pairs.sorted { a, b in
            if a.profile.isWildcard != b.profile.isWildcard { return a.profile.isWildcard }
            let (certA, certB) = (a.certificate.info.notAfter ?? .distantPast, b.certificate.info.notAfter ?? .distantPast)
            if certA != certB { return certA > certB }
            let (expA, expB) = (a.profile.expires ?? .distantPast, b.profile.expires ?? .distantPast)
            if expA != expB { return expA > expB }
            if a.profile.uuid != b.profile.uuid { return a.profile.uuid < b.profile.uuid }
            return a.certificate.reference < b.certificate.reference
        }
        return ranked[0]
    }
}
