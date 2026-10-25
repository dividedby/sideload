import Foundation

/// Options for `ledger [refresh]`.
public struct LedgerOptions: Sendable, Equatable {
    public enum Sub: Sendable, Equatable {
        case show, refresh
    }

    public var sub: Sub

    public init(sub: Sub = .show) {
        self.sub = sub
    }
}

/// `ledger`: read-only view of `ledger.json` plus the expiry items. `ledger refresh`: reads the PUBLIC
/// certificates (no private key, so no keychain prompt) and the provisioning profiles, and merges them into the
/// ledger. No device, portal or network contact; no confirmation, because it writes only `ledger.json`.
public enum LedgerCommand {
    static let fixKeychain = "Check that the login keychain is unlocked."

    public static func run(_ services: Services, _ options: LedgerOptions) async -> Envelope {
        switch options.sub {
        case .show: return show(services)
        case .refresh: return await refresh(services)
        }
    }

    private static func show(_ services: Services) -> Envelope {
        do {
            return .result("ledger", report(try services.ledgerStore.load(), now: services.clock.now()))
        } catch {
            return .from(error, command: "ledger")
        }
    }

    private static func refresh(_ services: Services) async -> Envelope {
        let command = "ledger refresh"
        let store = services.ledgerStore
        do {
            // A corrupt ledger stops the command before anything is read.
            _ = try store.load()

            let certificates: [KeychainCertificate]
            do {
                certificates = try services.keychain.developmentIdentities()
            } catch let error as KeychainError {
                throw SideloadError(
                    "KEYCHAIN_READ_FAILED", "Could not read signing identities: \(error.message).", fix: fixKeychain)
            }
            let scan = try await services.profiles.candidates()

            let now = services.clock.now()
            let (summary, ledger) = try await store.update { ledger in
                (LedgerSync.merge(&ledger, certificates: certificates, profiles: scan.profiles, now: now), ledger)
            }
            var data = report(ledger, now: now)
            data["refreshed"] = [
                "certificates": .number(Double(summary.certificates)),
                "profiles": .number(Double(summary.profiles)),
                "ignoredCertificates": .number(Double(summary.ignoredCertificates)),
                "ignoredProfiles": .number(Double(summary.ignoredProfiles)),
                "skippedProfiles": .number(Double(scan.skipped)),
            ]
            return .result(command, data)
        } catch {
            return .from(error, command: command)
        }
    }

    /// The ledger as printed: `items` (expiry), then each certificate, profile and export. Dates are ISO 8601 UTC.
    /// Profile UUIDs go out whole; `Redactor` masks them to their last four characters in the printed envelope.
    static func report(_ ledger: Ledger, now: Date) -> [String: JSONValue] {
        let certFp8s = Set(ledger.certificates.map(\.fp8))
        let profileUuids = Set(ledger.profiles.map(\.uuid))
        return [
            "schema": .number(Double(Ledger.schema)),
            "updated": ledger.updated.map { .string(LedgerDates.string($0)) } ?? .null,
            "items": .array(ExpiryItems.compute(ledger, now: now).map(\.json)),
            "certificates": .array(ledger.certificates.map { certificate($0, now: now) }),
            "profiles": .array(ledger.profiles.map { profile($0, now: now) }),
            "exports": .array(
                ledger.exports.map { export($0, certKnown: certFp8s.contains($0.certFp8), profileKnown: profileUuids.contains($0.profileUuid)) }),
        ]
    }

    private static func date(_ date: Date?) -> JSONValue { date.map { .string(LedgerDates.string($0)) } ?? .null }

    private static func certificate(_ c: LedgerCertificate, now: Date) -> JSONValue {
        let (days, level) = ExpiryItems.level(notAfter: c.notAfter, now: now)
        return [
            "fp8": .string(c.fp8), "team": .string(c.team), "notBefore": date(c.notBefore), "notAfter": date(c.notAfter),
            "daysLeft": .number(Double(days)), "level": .string(level.rawValue), "valid": .bool(c.valid),
            "present": .bool(c.present), "firstSeen": date(c.firstSeen), "lastSeen": date(c.lastSeen),
        ]
    }

    private static func profile(_ p: LedgerProfile, now: Date) -> JSONValue {
        let (days, level) = ExpiryItems.level(notAfter: p.expires, now: now)
        return [
            "uuid": .string(p.uuid), "team": .string(p.team), "applicationId": p.applicationId.map(JSONValue.string) ?? .null,
            "wildcard": .bool(p.wildcard), "created": date(p.created), "expires": date(p.expires),
            "daysLeft": .number(Double(days)), "level": .string(level.rawValue),
            "deviceCount": .number(Double(p.deviceCount)), "deviceTails": .array(p.deviceTails.map { .string($0) }),
            "certFp8s": .array(p.certFp8s.map { .string($0) }), "source": .string(p.source), "present": .bool(p.present),
            "firstSeen": date(p.firstSeen), "lastSeen": date(p.lastSeen),
        ]
    }

    private static func export(_ e: LedgerExport, certKnown: Bool, profileKnown: Bool) -> JSONValue {
        [
            "id": .string(e.id), "createdAt": date(e.createdAt), "certFp8": .string(e.certFp8),
            "profileUuid": .string(e.profileUuid), "p12File": .string(e.p12File),
            "p12Sha256Prefix": .string(e.p12Sha256Prefix), "encryption": .string(e.encryption),
            "passwordItem": .string(e.passwordItem), "kitPath": .string(e.kitPath), "verified": .bool(e.verified),
            "certificateInLedger": .bool(certKnown), "profileInLedger": .bool(profileKnown),
        ]
    }
}
