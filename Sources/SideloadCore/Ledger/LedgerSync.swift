import Foundation

/// Merges what the keychain and a profile source report right now into the ledger (`ledger refresh`). Pure.
/// Only the paid team is recorded: a certificate whose first OU is not the locked team (or that carries a
/// deny-listed OU anywhere), and a profile of another team, are counted and dropped. Entries not seen this time
/// stay as history with `present` false (and a certificate with `valid` false); they never feed expiry warnings.
public enum LedgerSync {
    public static let profileSource = "xcode-managed"

    public struct Summary: Sendable, Equatable {
        public var certificates = 0
        public var profiles = 0
        public var ignoredCertificates = 0
        public var ignoredProfiles = 0
    }

    public static func fp8(_ reference: String) -> String {
        String(reference.prefix(8)).lowercased()
    }

    @discardableResult
    public static func merge(
        _ ledger: inout Ledger, certificates: [KeychainCertificate], profiles: [ProvisioningProfile], now: Date
    ) -> Summary {
        // Whole seconds, so the stamp survives the ISO 8601 round trip unchanged.
        let stamp = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        var summary = Summary()
        mergeCertificates(&ledger, certificates, stamp: stamp, summary: &summary)
        mergeProfiles(&ledger, profiles, stamp: stamp, summary: &summary)
        ledger.updated = stamp
        return summary
    }

    private static func mergeCertificates(
        _ ledger: inout Ledger, _ certificates: [KeychainCertificate], stamp: Date, summary: inout Summary
    ) {
        for i in ledger.certificates.indices {
            ledger.certificates[i].present = false
            ledger.certificates[i].valid = false
        }
        var seen = Set<String>()
        for cert in certificates {
            guard cert.info.isPaidTeam, let notAfter = cert.info.notAfter else {
                summary.ignoredCertificates += 1
                continue
            }
            guard seen.insert(cert.reference).inserted else { continue }
            upsert(
                &ledger.certificates, key: \.fp8,
                LedgerCertificate(
                    fp8: fp8(cert.reference), team: Team.id, notBefore: cert.info.notBefore, notAfter: notAfter,
                    firstSeen: stamp, lastSeen: stamp, valid: cert.isValidForCodeSigning && notAfter > stamp,
                    present: true))
            summary.certificates += 1
        }
        ledger.certificates.sort { $0.fp8 < $1.fp8 }
    }

    private static func mergeProfiles(
        _ ledger: inout Ledger, _ profiles: [ProvisioningProfile], stamp: Date, summary: inout Summary
    ) {
        for i in ledger.profiles.indices { ledger.profiles[i].present = false }
        var seen = Set<String>()
        for profile in profiles {
            guard profile.team == Team.id, let expires = profile.expires else {
                summary.ignoredProfiles += 1
                continue
            }
            guard seen.insert(profile.uuid).inserted else { continue }
            upsert(
                &ledger.profiles, key: \.uuid,
                LedgerProfile(
                    uuid: profile.uuid, team: Team.id, applicationId: profile.applicationIdentifier,
                    wildcard: profile.isWildcard, created: profile.created, expires: expires,
                    deviceCount: profile.devices.count, deviceTails: profile.devices.map { String($0.suffix(4)) }.sorted(),
                    certFp8s: profile.certFingerprints.map(fp8).sorted(), source: profileSource, firstSeen: stamp,
                    lastSeen: stamp, present: true))
            summary.profiles += 1
        }
        ledger.profiles.sort { $0.uuid < $1.uuid }
    }

    /// Replaces the entry with the same key by `fresh`, keeping its `firstSeen` and unknown keys; appends otherwise.
    private static func upsert<T: LedgerEntry>(_ entries: inout [T], key: KeyPath<T, String>, _ fresh: T) {
        guard let i = entries.firstIndex(where: { $0[keyPath: key] == fresh[keyPath: key] }) else {
            entries.append(fresh)
            return
        }
        var merged = fresh
        merged.firstSeen = entries[i].firstSeen
        merged.extra = entries[i].extra
        entries[i] = merged
    }
}

/// What `upsert` needs from a ledger entry that is tracked across refreshes.
protocol LedgerEntry {
    var firstSeen: Date { get set }
    var extra: [String: JSONValue] { get set }
}

extension LedgerCertificate: LedgerEntry {}
extension LedgerProfile: LedgerEntry {}
