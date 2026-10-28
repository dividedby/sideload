import Foundation

/// One thing that expires, as `status` (design sections 8 and 11) and `ledger` list it.
public struct ExpiryItem: Sendable, Equatable {
    public enum Level: String, Sendable, Equatable {
        case ok, warn, critical, expired
    }

    public enum Kind: String, Sendable, Equatable {
        case certificate, profile, install
    }

    public var kind: Kind
    /// `cert <fp8>`, `profile …<last 4 of the UUID>` or `<app> @ <device alias>`: never a full ID or a name.
    public var name: String
    public var notAfter: Date
    /// Whole days left, rounded down; negative once expired.
    public var daysLeft: Int
    public var level: Level

    public var json: JSONValue {
        [
            "kind": .string(kind.rawValue), "name": .string(name), "notAfter": .string(LedgerDates.string(notAfter)),
            "daysLeft": .number(Double(daysLeft)), "level": .string(level.rawValue),
        ]
    }
}

/// Pure expiry maths over the ledger. Levels: `ok` above 60 days, `warn` at 60 or fewer, `critical` at 14 or
/// fewer, `expired` once `notAfter` has passed. Only items seen at the last refresh (`present`) count; certificates
/// and profiles that have since left the keychain or Xcode's folder are history, not a warning.
public enum ExpiryItems {
    public static func level(notAfter: Date, now: Date) -> (daysLeft: Int, level: ExpiryItem.Level) {
        let days = Int((notAfter.timeIntervalSince(now) / 86_400).rounded(.down))
        if notAfter <= now { return (days, .expired) }
        if days <= CertCheck.criticalDays { return (days, .critical) }
        if days <= CertCheck.warnDays { return (days, .warn) }
        return (days, .ok)
    }

    /// Soonest expiry first.
    public static func compute(_ ledger: Ledger, now: Date) -> [ExpiryItem] {
        var items: [ExpiryItem] = []
        for cert in ledger.certificates where cert.present {
            let (days, level) = level(notAfter: cert.notAfter, now: now)
            items.append(
                ExpiryItem(
                    kind: .certificate, name: "cert " + cert.fp8, notAfter: cert.notAfter, daysLeft: days, level: level))
        }
        for profile in ledger.profiles where profile.present {
            let (days, level) = level(notAfter: profile.expires, now: now)
            items.append(
                ExpiryItem(
                    kind: .profile, name: "profile " + Redactor.tail4(profile.uuid), notAfter: profile.expires,
                    daysLeft: days, level: level))
        }
        return items.sorted { ($0.notAfter, $0.name) < ($1.notAfter, $1.name) }
    }

    /// One item per free-team install recorded present on a saved device (`devices`, the config's aliases; a retired
    /// device's records are ignored), at the install's `profileExpires` with the section 18 thresholds of
    /// `FreeInstallExpiry`. Soonest first. `ledger` keeps listing the paid items only.
    public static func installs(_ ledger: Ledger, devices: Set<String>, now: Date) -> [ExpiryItem] {
        presentInstalls(ledger, devices: devices)
            .map { install in
                let (days, level) = FreeInstallExpiry.assess(expires: install.profileExpires, now: now)
                return ExpiryItem(
                    kind: .install, name: "\(install.app) @ \(install.device)", notAfter: install.profileExpires,
                    daysLeft: days, level: level)
            }
            .sorted { ($0.notAfter, $0.name) < ($1.notAfter, $1.name) }
    }

    /// The free installs `status` shows: recorded present, on a device still saved in config. Soonest expiry first.
    static func presentInstalls(_ ledger: Ledger, devices: Set<String>) -> [LedgerInstall] {
        ledger.installs.filter { $0.present && devices.contains($0.device) }
            .sorted { ($0.profileExpires, $0.id) < ($1.profileExpires, $1.id) }
    }
}

enum LedgerDates {
    /// `2027-10-16T22:39:42Z`
    static func string(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
