import Foundation

/// The rules of `refresh` that need no device, ledger write or clock of their own (design section 18): which apps to renew,
/// which step each one still needs, the attempt counters and the backoff, and which failure codes stop the run. Everything
/// here is a pure function of its arguments.
enum RefreshPolicy {
    /// `--within` default and ceiling, in days. 6 is a hard ceiling: a renewal has to move the expiry by more than 24 hours
    /// (`ProvisionCommand.renewalMargin`), and a profile with more than 6 days left cannot.
    static let defaultWithin = 5
    static let maxWithin = 6
    /// Attempts per local day that the future auto-refresh honours. A manual run warns past them and goes on.
    static let installDailyCap = 2
    static let deviceDailyCap = 4
    /// A step only counts as having moved the expiry when it passed this margin (the same one `provision` enforces).
    static let margin = ProvisionCommand.renewalMargin
    /// Wait after the 1st, 2nd, ... consecutive failure before the future auto-refresh tries again; the last one repeats.
    static let backoff: [TimeInterval] = [30 * 60, 3600, 2 * 3600, 4 * 3600, 8 * 3600, 12 * 3600]
    static let counterDays = 7

    /// A failure with one of these codes will not fix itself, so the install is marked `suspended` (the future auto-refresh
    /// leaves it alone until a manual success clears it).
    static let permanentCodes: Set<String> = [
        "PROFILE_NOT_RENEWED", "PROFILE_INVALID", "FREE_CERT_CHANGED", "IDENTITY_CHECK_FAILED", "UNTRUSTED_DEVELOPER",
        "UNEXPECTED_APP_DELTA", "WRONG_TEAM", "GUARD_FAILED", "BUNDLE_ID_NOT_ALLOWED", "PLATFORM_MISMATCH",
        "ACCOUNT_NOT_SIGNED_IN", "FREE_APP_LIMIT", "FREE_APP_ID_LIMIT",
    ]

    /// A failure with one of these codes stops the run: the rest of the apps are skipped with the same code. Anything else
    /// is that app's own failure and the run goes on.
    static let fatalCodes: Set<String> = [
        "FREE_CERT_CHANGED", "IDENTITY_CHECK_FAILED", "KEYCHAIN_LOCKED", "ACCOUNT_NOT_SIGNED_IN", "UNEXPECTED_APP_DELTA",
        "SLOT_PENDING", "RENEW_CROSS_VOLUME", "PROFILE_MOVE_FAILED", "PROFILES_UNREADABLE", "DERIVED_DATA_NOT_CLEARED",
        "LEDGER_WRITE_FAILED", "LEDGER_INVALID", "WRONG_TEAM", "GUARD_FAILED", "INTERRUPTED", "CONFIG_INVALID", "CONFIG_MISSING",
    ]

    /// Provision and sign do not need the device, so they still run; the install is skipped for the rest of the run.
    static let deviceUnavailableCodes: Set<String> = ["DEVICE_LOCKED", "DEVICE_NOT_CONNECTED", "DEVICE_NOT_PAIRED"]

    static func isFatal(_ code: String) -> Bool { fatalCodes.contains(code) || code.hasPrefix("FREE_IDENTITY_") }

    // MARK: options

    /// `--within`: whole days, 1 to 6; `--force` is 6 and excludes `--within`.
    static func within(_ raw: String?, force: Bool) throws -> Int {
        let fix = "sideload refresh --device iphone [--app <app>] [--within 1-\(maxWithin) | --force] --yes"
        if force {
            guard raw == nil else {
                throw SideloadError("USAGE", "--force is --within \(maxWithin); give one of them.", fix: fix)
            }
            return maxWithin
        }
        guard let raw else { return defaultWithin }
        guard let days = Int(raw), (1...maxWithin).contains(days) else {
            throw SideloadError(
                "USAGE", "--within takes a whole number of days from 1 to \(maxWithin).",
                fix: "A renewal must move the expiry by more than 24 hours, so more than \(maxWithin) days left cannot be renewed. \(fix)")
        }
        return days
    }

    // MARK: time

    static func daysLeft(_ expires: Date, now: Date) -> Int {
        Int((expires.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    /// Due when the exact time left is within `within` days (an expired profile is due).
    static func isDue(expires: Date, now: Date, within: Int) -> Bool {
        expires.timeIntervalSince(now) <= Double(within) * 86_400
    }

    /// The local calendar day, `yyyy-MM-dd`, the key of `attemptsByDay`.
    static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func nextEligible(failures: Int, now: Date) -> Date {
        let index = min(max(failures, 1), backoff.count) - 1
        return now.addingTimeInterval(backoff[index])
    }

    // MARK: selection

    /// What the ledger says about one app on the device.
    struct Subject {
        let app: ProvisionApp
        let install: LedgerInstall?
        let signed: LedgerFreeSigned?
        let profile: LedgerFreeProfile?
        /// The slot is lent to the lab (any state).
        let lent: Bool
    }

    /// The live snapshot's word on the app's bundle ID.
    enum Presence: Equatable {
        case unknown, present, absent
    }

    struct Target: Equatable {
        /// The expiry of the copy the owner has, the baseline every step is judged against: the device copy's (`installs[]`),
        /// or, for a lent app and one installed by hand, what `sign` last left.
        let expires: Date
        let lent: Bool
        /// There is an `installs[]` record. False: installed by hand, so the install step records it.
        let recorded: Bool
        /// `expires` is within the window. Always true for a recorded or lent app (they are only selected when due). False only
        /// for an app installed by hand whose signed copy is fresh: the device copy's expiry is unknown (`sign` overwrites
        /// the signed copy's, so it says nothing about what is on the device), so the install is due but provision and sign
        /// are not.
        var stale = true
    }

    enum Decision: Equatable {
        case renew(Target)
        /// A policy skip, ok in the result. `expires` is the baseline when there is one.
        case skip(code: String, expires: Date?)
    }

    static func decide(_ subject: Subject, now: Date, within: Int, presence: Presence) -> Decision {
        let signed = subject.signed
        if subject.lent {
            // Not on the device, so there is nothing to install: provision and sign only, judged by the signed copy.
            guard let signed else { return .skip(code: "NOT_SIGNED", expires: nil) }
            guard isDue(expires: signed.profileExpires, now: now, within: within) else {
                return .skip(code: "NOT_DUE", expires: signed.profileExpires)
            }
            return .renew(Target(expires: signed.profileExpires, lent: true, recorded: subject.install != nil))
        }
        if let install = subject.install {
            guard install.present else { return .skip(code: "NOT_PRESENT", expires: install.profileExpires) }
            guard isDue(expires: install.profileExpires, now: now, within: within) else {
                return .skip(code: "NOT_DUE", expires: install.profileExpires)
            }
            // Refresh never installs a new app: one the device does not show is skipped, not put back.
            if presence == .absent { return .skip(code: "NOT_PRESENT", expires: install.profileExpires) }
            return .renew(Target(expires: install.profileExpires, lent: false, recorded: true))
        }
        // No install record: only an own app that is signed and that the device shows (installed by hand) is a candidate.
        // The device copy's expiry is unknown (`sign` overwrites the signed copy's with the new profile's, so after a sign whose
        // install was blocked it would read as fresh), so the install is always due: one slot-neutral reinstall records it and
        // the normal rules apply from then on. Provision and sign run only if the signed copy itself is within the window.
        guard let signed else { return .skip(code: "NOT_INSTALLED", expires: nil) }
        if presence == .absent { return .skip(code: "NOT_INSTALLED", expires: signed.profileExpires) }
        let stale = isDue(expires: signed.profileExpires, now: now, within: within)
        // With no word from the device the install cannot run and the device copy's expiry is unknown, so this is never a
        // passing skip: the caller fails the app with the device's code, after provision and sign if the signed copy is due.
        return .renew(Target(expires: signed.profileExpires, lent: false, recorded: false, stale: stale))
    }

    // MARK: steps

    /// Which of the three steps a run still has to do for an app, from the ledger as it is now. This is what lets a rerun
    /// after a partial failure resume instead of hitting `PROFILE_NOT_RENEWED`: `provision` refuses a profile that does not
    /// move the expiry, so a profile that already does is not asked for again.
    struct StepPlan: Equatable {
        var provision: Bool
        var sign: Bool
        var install: Bool
    }

    static func steps(_ subject: Subject, target: Target) -> StepPlan {
        // Installed by hand with a fresh signed copy: straight to the install, which records it.
        if !target.stale { return StepPlan(provision: false, sign: false, install: true) }
        let profile = subject.profile
        let signed = subject.signed
        let provision = !(profile.map { $0.expires > target.expires.addingTimeInterval(margin) } ?? false)
        // A new profile makes the signed copy stale; a fresh one still needs signing if `sign` has not seen it. The filler is
        // signed by `provision` itself and `sign` refuses it.
        let signedWithProfile = signed != nil && profile != nil && signed?.profileUuid == profile?.profileUuid
        let sign = !subject.app.signedByProvision && (provision || !signedWithProfile)
        // With both steps done or skipped the signed copy is the fresh one, so it is what goes on the device. A lent app has
        // no device to put it on.
        return StepPlan(provision: provision, sign: sign, install: !target.lent)
    }

    // MARK: counters

    /// Attempts today across the device's installs.
    static func deviceAttempts(_ installs: [LedgerInstall], device: String, today: String) -> Int {
        installs.filter { $0.device == device }.reduce(0) { $0 + ($1.refresh.attemptsByDay[today] ?? 0) }
    }

    /// The day counters after one more attempt, with days past the window dropped.
    static func counting(_ refresh: LedgerInstallRefresh, now: Date, timeZone: TimeZone) -> LedgerInstallRefresh {
        var next = refresh
        let today = dayKey(now, timeZone: timeZone)
        let cutoff = dayKey(now.addingTimeInterval(-Double(counterDays) * 86_400), timeZone: timeZone)
        next.attemptsByDay = next.attemptsByDay.filter { $0.key >= cutoff }
        next.attemptsByDay[today, default: 0] += 1
        next.lastAttempt = now
        return next
    }

    enum Result: Equatable {
        case refreshed
        /// A lent app: its signed copy was renewed, but no copy went to the device (`slot return` installs it).
        case renewedNotInstalled
        case failed(code: String)
        /// Nothing went wrong and nothing was done: a busy lock. Not an attempt and not a failure.
        case busy
    }

    /// The refresh fields after an attempt. `busy` gives the attempt back and records the skip; a failure counts and backs
    /// off; a permanent failure suspends; a success clears all of it.
    static func applying(
        _ result: Result, to refresh: LedgerInstallRefresh, now: Date, timeZone: TimeZone
    ) -> LedgerInstallRefresh {
        var next = refresh
        switch result {
        case .refreshed, .renewedNotInstalled:
            next.lastResult = result == .refreshed ? "refreshed" : "renewed-not-installed"
            next.lastCode = nil
            next.consecutiveFailures = 0
            next.nextEligible = nil
            next.suspended = false
        case .failed(let code):
            next.lastResult = "failed"
            next.lastCode = code
            next.consecutiveFailures += 1
            next.nextEligible = nextEligible(failures: next.consecutiveFailures, now: now)
            if permanentCodes.contains(code) { next.suspended = true }
        case .busy:
            let today = dayKey(now, timeZone: timeZone)
            if let count = next.attemptsByDay[today] {
                if count <= 1 { next.attemptsByDay[today] = nil } else { next.attemptsByDay[today] = count - 1 }
            }
            next.lastResult = "skipped"
            next.lastCode = "OPERATION_IN_PROGRESS"
        }
        return next
    }
}
