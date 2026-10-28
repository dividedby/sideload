import Foundation

/// The app-data restores still waiting for `slot restore` (design section 18, "App data"), for `status` and the menu bar
/// app. Per saved device and free app, the same newest-backup check `slot restore` makes (`AppDataBackup.pending`: the
/// manifest is read and the listed files are `lstat`ed and opened, never read). Skipped: a device with an operation still
/// inside its window on any slot (exactly what `slot restore`'s gate refuses; a stale op past its window does not hide it),
/// an app whose slot is lent (its backup is the return's to restore), and an app whose slot was last seen less than
/// `settleWindow` ago, either way, so a clock set back does not hide it for long. `slot return` records the slot returned at `return.final`
/// and only then pushes the data, for up to `AppDataBackup.totalBudgetSec`; with no lock, that push would otherwise read as
/// pending. Whether the app is on the device is not known here; if it is not, `slot restore` answers `APP_NOT_INSTALLED`.
/// No lock, no subprocess, no write. The result is aliases and app names only, never a path, a file name or a count
/// of files.
enum PendingRestores {
    /// The restore's whole allowance plus a margin for the return's post-install snapshot (`seenAt` is taken before it), the
    /// relisting, the manifest write and a slow Mac.
    static let settleWindow = TimeInterval(AppDataBackup.totalBudgetSec + 180)

    struct Entry: Sendable, Equatable {
        var device: String
        var app: String
    }

    /// `ledger` must be the readable ledger (an unreadable one says nothing about which apps are lent). Sorted by device,
    /// then app.
    static func find(_ services: Services, config: Config, ledger: Ledger, now: Date) -> [Entry] {
        let migrated = SlotRule.migrated(ledger, now: now)
        let slots = migrated.slots
        var found: [Entry] = []
        for alias in config.devices.keys.sorted() {
            // `slot restore`'s own gate, on the same migrated ledger.
            guard SlotBook(services: services, config: config, alias: alias).pending(migrated, now: now) == nil else { continue }
            for app in ProvisionApp.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
                let busy = slots.contains { slot in
                    guard slot.device == alias, slot.app == app.rawValue else { return false }
                    return slot.lentTo != nil || slot.seenAt.map { abs(now.timeIntervalSince($0)) < settleWindow } == true
                }
                guard !busy, let target = try? FreeTarget.resolve(app: app, alias: alias, config: config) else { continue }
                if case .found = AppDataBackup.pending(services, target) {
                    found.append(Entry(device: alias, app: app.rawValue))
                }
            }
        }
        return found
    }

    /// The warning `status` prints and the menu shows, with the owner's retry in `fix`.
    static func warning(_ entry: Entry) -> SideloadError {
        SideloadError(
            "DATA_RESTORE_PENDING",
            "Saved app data of \(entry.app) on device \"\(printableAlias(entry.device))\" is waiting to be restored (a `slot return` did not finish restoring it).",
            fix: "The owner runs `sideload slot restore --device \(printableAlias(entry.device)) --app \(entry.app) --yes`.")
    }
}
