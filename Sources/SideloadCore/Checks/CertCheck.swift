import Foundation

/// Pure selection logic: the locked team is matched on the
/// certificate OU, never the name; other teams are reported as info; the deny-listed free team is never selected.
public enum CertCheck {
    public static let warnDays = 60
    public static let criticalDays = 14
    private static let fixRenew = "Renew the certificate in Xcode > Settings > Accounts > Manage Certificates."
    private static let fixCreate =
        "In Xcode > Settings > Accounts > Manage Certificates, create an Apple Development certificate for the paid team (owner action)."

    public static func run(keychain: some KeychainClient, now: Date) -> [CheckResult] {
        do {
            return evaluate(try keychain.developmentIdentities(), now: now)
        } catch let error as KeychainError {
            return [unreadable(error.message)]
        } catch {
            return [unreadable("keychain read failed")]
        }
    }

    /// Identities `security find-identity -v -p codesigning` would list: trusted, unexpired, de-duplicated.
    private static func validCertificates(_ certificates: [KeychainCertificate], now: Date) -> [KeychainCertificate] {
        var seen = Set<String>()
        return certificates.filter {
            $0.isValidForCodeSigning && $0.info.isAppleDevelopment && ($0.info.notAfter.map { $0 > now } ?? false)
                && seen.insert($0.reference).inserted
        }
    }

    /// The valid paid-team certificate with the latest `notAfter`: the one `evaluate` reports, and what the
    /// canary evidence calls the keychain certificate (not proof of what Xcode signed with).
    public static func selectedPaid(_ certificates: [KeychainCertificate], now: Date) -> KeychainCertificate? {
        validCertificates(certificates, now: now)
            .compactMap { cert in cert.info.notAfter.map { (cert, $0) } }
            .filter { $0.0.info.isPaidTeam }
            .max { $0.1 < $1.1 }?.0
    }

    /// Every valid paid-team certificate, latest `notAfter` first (`export-cert` ranks these against profiles).
    public static func paidCandidates(_ certificates: [KeychainCertificate], now: Date) -> [KeychainCertificate] {
        validCertificates(certificates, now: now)
            .filter { $0.info.isPaidTeam }
            .compactMap { cert in cert.info.notAfter.map { (cert, $0) } }
            .sorted { ($0.1, $1.0.reference) > ($1.1, $0.0.reference) }
            .map(\.0)
    }

    public static func evaluate(_ certificates: [KeychainCertificate], now: Date) -> [CheckResult] {
        let others = validCertificates(certificates, now: now).map(\.info).filter { !$0.isPaidTeam }
        var out: [CheckResult] = []

        if let best = selectedPaid(certificates, now: now)?.info.notAfter {
            let days = Int(((best.timeIntervalSince(now)) / 86_400).rounded(.down))
            let base = "Apple Development (team \(Team.id)) valid until \(isoDate(best)) (\(days) days)."
            out.append(
                days < warnDays
                    ? CheckResult(id: "cert", severity: .warn, message: base, fix: fixRenew, daysLeft: days)
                    : CheckResult(id: "cert", severity: .ok, message: base, daysLeft: days))
        } else {
            out.append(
                CheckResult(
                    id: "cert", severity: .fail,
                    message: "No Apple Development certificate for team \(Team.id) in the keychain.",
                    fix: fixCreate))
        }

        var reported = Set<String>()
        for cert in others {
            // De-duplicated on the first OU; flagged when any OU is deny-listed, so a
            // [paid, free] subject (never selected as paid) is not shown as a plain other team.
            guard reported.insert(cert.teamOU ?? "").inserted else { continue }
            let denied = cert.ous.first { Team.denied.contains($0) }
            out.append(
                CheckResult(
                    id: "cert-other-team", severity: .info,
                    message: "other team, ignored" + (denied.map { " (\($0), deny-listed)" } ?? "")))
        }
        return out
    }

    private static func unreadable(_ detail: String) -> CheckResult {
        CheckResult(
            id: "cert", severity: .fail, message: "Could not read signing identities: \(detail).",
            fix: "Check that the login keychain is unlocked.")
    }

    /// `YYYY-MM-DD` in UTC.
    static func isoDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

// MARK: - Free team (design section 18)

/// The outcome of requiring the pinned free identity.
public enum PinnedFreeIdentity: Sendable, Equatable {
    case found(FreeIdentity)
    /// No valid free-team identity has that fp8 (absent, expired, untrusted, or the pin is not 8 hex digits).
    case notFound
    /// More than one valid free-team identity shares the fp8: not exactly one, so not usable.
    case ambiguous
}

extension CertCheck {
    /// Valid free-team identities (trusted, unexpired, de-duplicated; first OU free, paid OU absent), latest
    /// `notAfter` first. Matched on OU, never name.
    public static func freeIdentities(_ certificates: [KeychainCertificate], now: Date) -> [FreeIdentity] {
        validCertificates(certificates, now: now)
            .filter { $0.info.isFreeTeam }
            .compactMap { cert in cert.info.notAfter.map { FreeIdentity(sha1: cert.reference.uppercased(), notAfter: $0) } }
            .sorted { ($0.notAfter, $1.sha1) > ($1.notAfter, $0.sha1) }
    }

    /// Requires exactly the identity whose SHA-1 starts with `fp8` (`freeTeam.certFp8`) among the valid
    /// free-team identities. A different or additional free certificate never substitutes for it.
    public static func pinnedFree(_ certificates: [KeychainCertificate], fp8: String, now: Date) -> PinnedFreeIdentity {
        guard fp8.wholeMatch(of: /[0-9A-Fa-f]{8}/) != nil else { return .notFound }
        let matches = freeIdentities(certificates, now: now).filter { $0.fp8 == fp8.lowercased() }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous
        }
    }

    /// One `info` row per valid free-team identity: fp8 and expiry only, never a name. Empty when there is none.
    public static func freeRows(_ certificates: [KeychainCertificate], now: Date) -> [CheckResult] {
        freeIdentities(certificates, now: now).map { identity in
            let days = Int((identity.notAfter.timeIntervalSince(now) / 86_400).rounded(.down))
            return CheckResult(
                id: "cert-free", severity: .info,
                message:
                    "Apple Development (free team \(Team.free)) \(identity.fp8) valid until \(isoDate(identity.notAfter)) (\(days) days).",
                daysLeft: days)
        }
    }
}

/// The doctor `cert-free` check: an info row for each valid free-team identity, nothing otherwise (so a
/// keychain without one prints exactly what it did before). A keychain read failure is already reported by
/// the `cert` check, so it adds nothing here.
public struct FreeCertificateCheck: Check {
    public let id = "cert-free"

    public init() {}

    public func run(_ services: Services) async throws -> [CheckResult] {
        guard let identities = try? services.keychain.developmentIdentities() else { return [] }
        return CertCheck.freeRows(identities, now: services.clock.now())
    }
}

/// The doctor `cert` check: `CertCheck` over the injected keychain and clock.
public struct CertificateCheck: Check {
    public let id = "cert"

    public init() {}

    public func run(_ services: Services) async throws -> [CheckResult] {
        CertCheck.run(keychain: services.keychain, now: services.clock.now())
    }
}
