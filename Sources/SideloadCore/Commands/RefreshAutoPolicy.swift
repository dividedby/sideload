import Foundation

/// The gates of `refresh --auto` (design section 18). Like `RefreshPolicy` they are pure: the caller reads the kill-switch file,
/// the ledger, the lock and the device list, and passes what it found.
extension RefreshPolicy {
    /// The automatic run renews what has this many days or fewer left (the manual default).
    static let autoWithin = defaultWithin
    /// No new app is started once a run is this old (launchd runs every 30 minutes, so a run never overlaps the next).
    static let autoDeadline: TimeInterval = 20 * 60
    /// An install is left alone for this long after its last attempt.
    static let minAttemptGap: TimeInterval = 5 * 60
    /// The code of an app whose installed version cannot be signed again (not a permanent failure, so it backs off).
    static let versionNotAvailable = "VERSION_NOT_AVAILABLE"

    /// Why the automatic run did not act, as the `code` of a skipped result and the key of the envelope's `skipped` counts.
    /// The first four end the whole run; of them only `ledgerUnreadable` is a failure, the rest are skips.
    enum AutoSkip: Equatable {
        case killSwitch, freeCertChanged, ledgerUnreadable, operationInProgress
        case notRecorded, lent, notPresent, suspended, slotPending, signedVersionDiffers, notDue
        case backoff, installCap, deviceCap, recentAttempt
        case deviceNotVisible, deadline
        /// An opted-in device whose slot reserve is out of range, one of a platform none of our apps runs on, and the
        /// config that could not be read at all.
        case configInvalid, platformMismatch

        /// The code, which is also the key of the envelope's `skipped` counts. The two the manual run shares are spelled once.
        var code: String {
            switch self {
            case .killSwitch: "KILL_SWITCH"
            case .freeCertChanged: "FREE_CERT_CHANGED"
            case .ledgerUnreadable: "LEDGER_INVALID"
            case .operationInProgress: OperationLock.busyCode
            case .notRecorded: "NOT_RECORDED"
            case .lent: "LENT"
            case .notPresent: RefreshPolicy.notPresent
            case .suspended: "SUSPENDED"
            case .slotPending: "SLOT_PENDING"
            case .signedVersionDiffers: "SIGNED_VERSION_DIFFERS"
            case .notDue: RefreshPolicy.notDue
            case .backoff: "BACKOFF"
            case .installCap: "INSTALL_CAP"
            case .deviceCap: "DEVICE_CAP"
            case .recentAttempt: "RECENT_ATTEMPT"
            case .deviceNotVisible: "DEVICE_NOT_VISIBLE"
            case .deadline: "DEADLINE"
            case .configInvalid: "CONFIG_INVALID"
            case .platformMismatch: "PLATFORM_MISMATCH"
            }
        }
    }

    /// The whole-run gates, cheapest first: the kill switch, then the ledger (unreadable, or the free team's suspension), then
    /// the operation lock. The later inputs are autoclosures, so nothing is read or probed once an earlier gate has stopped
    /// the run. Nil means go on.
    static func runGate(
        killSwitch: Bool, ledger: @autoclosure () -> Ledger?, lockBusy: @autoclosure () -> Bool
    ) -> AutoSkip? {
        if killSwitch { return .killSwitch }
        guard let ledger = ledger() else { return .ledgerUnreadable }
        if ledger.freeSuspended != nil { return .freeCertChanged }
        if lockBusy() { return .operationInProgress }
        return nil
    }

    /// The saved devices the owner opted in (valid alias) whose slot reserve is valid, and those opted in whose reserve is out
    /// of range. Both sorted, so a run is deterministic.
    static func autoDevices(_ devices: [String: SavedDevice]) -> (eligible: [String], invalid: [String]) {
        let optedIn = devices.filter { $0.value.autoRefresh && DeviceCommand.isValidAlias($0.key) }
        return (
            optedIn.filter { $0.value.freeSlotsReserved != nil }.keys.sorted(),
            optedIn.filter { $0.value.freeSlotsReserved == nil }.keys.sorted()
        )
    }

    /// The per-install gates of one app on an opted-in device, in this order. Nil means the install may be renewed (the device
    /// still has to be visible). `slotPending` is the device's (`SlotBook.pending`); `deviceAttempts` is
    /// `deviceAttempts(_:device:today:)` as of now.
    static func autoGate(
        _ subject: Subject, slotPending: Bool, deviceAttempts: Int, now: Date, timeZone: TimeZone
    ) -> AutoSkip? {
        guard let install = subject.install else { return .notRecorded }
        // A lent slot has `present: false` too; the lend is the better reason.
        if subject.lent { return .lent }
        guard install.present else { return .notPresent }
        if install.refresh.suspended { return .suspended }
        if slotPending { return .slotPending }
        // The signed build is what goes on the device. A version other than the installed one is an update that is half done,
        // which only the owner finishes (Install update); auto never changes the installed version.
        if let signed = subject.signed, signed.version != install.version { return .signedVersionDiffers }
        guard isDue(expires: install.profileExpires, now: now, within: autoWithin) else { return .notDue }
        if let next = install.refresh.nextEligible, now < next { return .backoff }
        if (install.refresh.attemptsByDay[dayKey(now, timeZone: timeZone)] ?? 0) >= installDailyCap { return .installCap }
        if deviceAttempts >= deviceDailyCap { return .deviceCap }
        if let last = install.refresh.lastAttempt, now.timeIntervalSince(last) < minAttemptGap { return .recentAttempt }
        return nil
    }

    /// The fatal codes that are about one device and not the free team: the run goes on with the next device.
    static let deviceScopedFatalCodes: Set<String> = ["SLOT_PENDING", "UNEXPECTED_APP_DELTA"]

    /// Whether this failure ends the automatic run for every device (a certificate, keychain, account, ledger or config
    /// problem belongs to the team or the machine) and not just for the device it happened on.
    static func stopsWholeRun(_ code: String) -> Bool { isFatal(code) && !deviceScopedFatalCodes.contains(code) }
}
