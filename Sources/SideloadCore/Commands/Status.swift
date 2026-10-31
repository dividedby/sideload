import Foundation

/// The worst state `status` reports, in the menu bar's icon vocabulary (design section 12). Expiry severity
/// outranks `blocked`; an expired item is `critical`.
public enum StatusState: String, Sendable, Equatable {
    case ok, blocked, warn, critical, unknown

    /// `canaryStatus` is the status of the last canary run (nil when there is none). With no canary run and no
    /// expiry item there is nothing to judge, so the state is `unknown`. Only a last run of `working` is `ok`: `error`,
    /// `skipped` or any status this version does not know proves nothing, so it is `unknown` (never `ok`); expiry
    /// items can still raise it to `warn` or `critical`.
    public static func worst(canaryStatus: String?, items: [ExpiryItem]) -> StatusState {
        if items.contains(where: { $0.level == .expired || $0.level == .critical }) { return .critical }
        if items.contains(where: { $0.level == .warn }) { return .warn }
        if canaryStatus == "blocked" { return .blocked }
        if let canaryStatus { return canaryStatus == "working" ? .ok : .unknown }
        return items.isEmpty ? .unknown : .ok
    }
}

/// `status` v1 (design sections 8, 11, 12 and 18): the menu bar snapshot gathered from local files only, with no
/// subprocess, keychain, device, portal or network use and no lock. A missing or unreadable source is a warning
/// and an empty section, never a failure. Device visibility needs `devicectl`, so it is always `unknown` here
/// and the app fills it from `device list`. Free installs on saved devices join `items` (kind `install`, the 3 and 1 day
/// levels) and `installs`, and warn once due; a pending app-data restore is a warning too. The app-data backups are
/// secrets-class: only their manifests are read (`PendingRestores`), and only aliases and app names are printed.
/// `status --notify` (`runNotify`, `StatusNotify.swift`) is the exception: it runs `osascript`, writes `lastNotified` and reads
/// `updates.json`; with `--check-updates` it also makes the `updates` metadata GETs (one per approved source) and writes that file.
public enum StatusCommand {
    static let command = "status"

    public static func run(_ services: Services) -> Envelope {
        let snapshot = gather(services)
        return .result(command, snapshot.data.merging(["warnings": .array(snapshot.warnings)]) { $1 })
    }

    /// What one read of the local files found: the envelope's fields, and the parts `--notify` needs beyond them.
    struct Snapshot {
        var data: [String: JSONValue]
        var warnings: [JSONValue]
        /// Paid and (once the ledger and the config are both read) free-install items, soonest first.
        var items: [ExpiryItem]
        /// The app-data restores waiting; empty when they could not be looked up.
        var pending: [PendingRestores.Entry]
        /// The free installs recorded present on a saved device; empty unless `complete`.
        var installs: [LedgerInstall]
        /// The config as read; nil when it could not be read.
        var config: Config?
        /// True when the ledger and the config were both read, so `items` and `pending` are the whole picture.
        var complete: Bool
    }

    static func gather(_ services: Services) -> Snapshot {
        let now = services.clock.now()
        var warnings: [JSONValue] = []

        func warn(_ error: any Error, source: String) {
            if let e = error as? SideloadError {
                warnings.append(warning(e.code, e.message, e.fix))
            } else {
                warnings.append(
                    warning("STATUS_SOURCE_UNREADABLE", "\(source) could not be read.", "Check $SIDELOAD_HOME and re-run."))
            }
        }

        var canary: [String: JSONValue] = [
            "last": .null, "lastWorking": .null, "firstBlockedAfterWorking": .null, "runs": 0, "skipped": 0,
        ]
        var canaryStatus: String?
        do {
            let summary = CanaryHistory.summarize(try CanaryHistory.read(services.home.canaryLog))
            for key in canary.keys { canary[key] = summary[key] ?? canary[key] }
            if case .object(let last)? = summary["last"], case .string(let status)? = last["status"] { canaryStatus = status }
        } catch {
            warn(error, source: "canary.jsonl")
        }

        var items: [ExpiryItem] = []
        var ledgerUpdated: JSONValue = .null
        var ledgerRead = Ledger()
        // An unreadable ledger leaves the slots unknown: an empty `Ledger()` would read every slot as free.
        var ledgerReadable = false
        do {
            let ledger = try services.ledgerStore.load()
            ledgerRead = ledger
            ledgerReadable = true
            items = ExpiryItems.compute(ledger, now: now)
            ledgerUpdated = ledger.updated.map { .string(LedgerDates.string($0)) } ?? .null
        } catch {
            warn(error, source: "ledger.json")
        }
        // The file exists even when it does not parse.
        let ledgerPresent = FileManager.default.fileExists(atPath: services.home.ledger)

        var devices: [JSONValue] = []
        var apps: [JSONValue] = []
        var slotDevices: [JSONValue] = []
        var loadedConfig: Config?
        do {
            let config = try services.store.load()
            loadedConfig = config
            slotDevices = Self.slotDevices(config: config, ledger: ledgerRead, readable: ledgerReadable, now: now)
            apps = config.apps.keys.sorted().map { .string($0) }
            // A device without IDs is its own warning; the apps above still count.
            do {
                devices = try config.savedDevices().map { d in
                    [
                        "alias": .string(d.alias),
                        "platform": d.platform.map(JSONValue.string) ?? .null,
                        "udid": tail(d.udid),
                        "coreDeviceId": tail(d.coreDeviceId),
                        "visibility": "unknown",
                    ]
                }
            } catch {
                warn(error, source: "config.json")
            }
        } catch {
            warn(error, source: "config.json")
        }

        let appIdsLast7Days = JSONValue.number(Double(FreeAppIdBudget.live(ledgerRead.freeAppIds, now: now).count))
        // The slots, migrated in memory (status never writes): `lent` is the projection of the unified records.
        let projected = SlotRule.migrated(ledgerRead, now: now)
        let lent: [JSONValue] = projected.lent.sorted { $0.device < $1.device }.map { entry in
            [
                "app": .string(entry.app), "device": .string(entry.device), "to": .string(entry.to),
                "state": .string(entry.state), "since": .string(LedgerDates.string(entry.since)),
                // Only `lent` is the lab's. `lending` and `returning` are pending: the device may or may not have changed, so
                // the slot is neither the lab's nor free until the next `slot lend` or `slot return` settles it.
                "holds": .bool(SlotPhase(entry).holds),
            ]
        }
        for entry in projected.lent.sorted(by: { $0.device < $1.device }) where SlotPhase(entry).pending {
            warnings.append(
                warning(
                    "SLOT_STATE_PENDING",
                    "The slot on device \"\(printableAlias(entry.device))\" is \(entry.state): an uninstall or install may or may not have finished, so the slot is neither free nor held.",
                    "`sideload slot lend --device \(printableAlias(entry.device)) --to lab` or `sideload slot return --device \(printableAlias(entry.device))` settles it with a fresh device snapshot."))
        }

        // Free installs: only with both the ledger and the config read (the config says which devices are still saved).
        var installs: JSONValue = .null
        var pendingRestores: JSONValue = .null
        var pendingFound: [PendingRestores.Entry] = []
        var presentFound: [LedgerInstall] = []
        if ledgerReadable, let config = loadedConfig {
            let saved = Set(config.devices.keys)
            items = (items + ExpiryItems.installs(projected, devices: saved, now: now))
                .sorted { ($0.notAfter, $0.name) < ($1.notAfter, $1.name) }
            let present = ExpiryItems.presentInstalls(projected, devices: saved)
            presentFound = present
            installs = .array(
                present.map { Self.installRow($0, autoRefresh: config.devices[$0.device]?.autoRefresh ?? false, now: now) })
            for install in present {
                if let w = Self.expiryWarning(install, now: now) { warnings.append(w) }
            }
            let pending = PendingRestores.find(services, config: config, ledger: ledgerRead, now: now)
            pendingFound = pending
            pendingRestores = .array(pending.map { ["device": .string($0.device), "app": .string($0.app)] })
            for entry in pending {
                let e = PendingRestores.warning(entry)
                warnings.append(warning(e.code, e.message, e.fix))
            }
        }

        let state = StatusState.worst(canaryStatus: canaryStatus, items: items)
        let data: [String: JSONValue] = [
            "generated": .string(LedgerDates.string(now)),
            "state": .string(state.rawValue),
            "canary": .object(canary),
            "items": .array(items.map(\.json)),
            "ledger": ["updated": ledgerUpdated, "present": .bool(ledgerPresent)],
            "devices": .array(devices),
            "apps": .array(apps),
            "lent": ledgerReadable ? .array(lent) : .null,
            "slots": ["devices": .array(slotDevices), "appIdsLast7Days": appIdsLast7Days],
            "appIdsLast7Days": appIdsLast7Days,
            "installs": installs,
            "pendingRestores": pendingRestores,
        ]
        return Snapshot(
            data: data, warnings: warnings, items: items, pending: pendingFound, installs: presentFound, config: loadedConfig,
            complete: ledgerReadable && loadedConfig != nil)
    }

    /// The free team's slots per saved device, from the ledger and the config only (no devicectl): every used slot record
    /// (present, lent, or with a device operation in flight, whatever the legacy `installs[].present` says) plus the owner's
    /// `freeSlotsReserved` (an out-of-range stored value makes the row unknown; `device list` warns about it). The unmanaged
    /// dev-signed apps a live `device info apps` could show are the reserve's job. Read through `SlotRule.view`, so a
    /// pending or lent record is never free and never counted twice. `lent` is `{app,state}` or null; `pending` is true while
    /// any record has an operation that is not settled; `retryAfter` is the seconds until the last open window on the device
    /// ends (null when none is open). With the ledger unreadable (`readable` false) or the stored reserve out of range, nothing is known about the slots:
    /// `unknown` is true and `used`, `free`, `apps`, `lent`, `pending` and `retryAfter` are null, never a guessed free count.
    static func slotDevices(config: Config, ledger: Ledger, readable: Bool = true, now: Date) -> [JSONValue] {
        config.devices.keys.sorted().map { alias in
            // An out-of-range stored reserve (a hand-edited config) is `CONFIG_INVALID` for every slot command; here it
            // leaves the row unknown, never a free count computed from a guessed reserve.
            let reserved = config.devices[alias]?.freeSlotsReserved
            guard readable, let reserved else {
                return [
                    "alias": .string(alias), "limit": .number(Double(FreeSlots.limit)), "used": .null, "free": .null,
                    "reserved": reserved.map { .number(Double($0)) } ?? .null, "apps": .null, "lent": .null, "pending": .null,
                    "retryAfter": .null, "unknown": true,
                ]
            }
            let view = SlotRule.view(ledger, alias: alias, now: now)
            let used = view.used + reserved
            let lent: JSONValue =
                view.app.map { ["app": .string($0), "state": .string(view.state.rawValue)] } ?? .null
            return [
                "alias": .string(alias), "limit": .number(Double(FreeSlots.limit)), "used": .number(Double(used)),
                "free": .number(Double(max(0, FreeSlots.limit - used))), "reserved": .number(Double(reserved)),
                "apps": .array(view.apps.map { .string($0) }), "lent": lent, "pending": .bool(view.pending),
                "retryAfter": view.retryAfter.map { .number(Double($0)) } ?? .null, "unknown": false,
            ]
        }
    }

    /// One free install on a saved device: its expiry and the refresh bookkeeping `refresh` keeps on the record.
    /// `autoRefresh` is the device's opt-in (the automatic mode itself is not built).
    static func installRow(_ install: LedgerInstall, autoRefresh: Bool, now: Date) -> JSONValue {
        let (days, level) = FreeInstallExpiry.assess(expires: install.profileExpires, now: now)
        return [
            "id": .string(install.id), "device": .string(install.device), "app": .string(install.app),
            "notAfter": .string(LedgerDates.string(install.profileExpires)), "daysLeft": .number(Double(days)),
            "level": .string(level.rawValue), "autoRefresh": .bool(autoRefresh),
            "lastResult": install.refresh.lastResult.map(JSONValue.string) ?? .null,
            "nextEligible": install.refresh.nextEligible.map { .string(LedgerDates.string($0)) } ?? .null,
            "suspended": .bool(install.refresh.suspended),
        ]
    }

    /// `INSTALL_EXPIRING` at 3 days or fewer (1 day or fewer is `critical` in `items`), `INSTALL_EXPIRED` once expired,
    /// nil while `ok`. The fix is the owner's manual `refresh` of that app on that device.
    static func expiryWarning(_ install: LedgerInstall, now: Date) -> JSONValue? {
        let (days, level) = FreeInstallExpiry.assess(expires: install.profileExpires, now: now)
        let device = printableAlias(install.device)
        let fix = "The owner runs `sideload refresh --device \(device) --app \(install.app) --yes`."
        switch level {
        case .ok:
            return nil
        case .expired:
            return warning(
                "INSTALL_EXPIRED", "The signing of \(install.app) on device \"\(device)\" has expired, so the app no longer opens.",
                fix)
        case .warn, .critical:
            let left = days < 1 ? "less than a day" : days == 1 ? "1 day" : "\(days) days"
            return warning(
                "INSTALL_EXPIRING", "The signing of \(install.app) on device \"\(device)\" ends in \(left) (\(level.rawValue)).", fix)
        }
    }

    private static func warning(_ code: String, _ message: String, _ fix: String?) -> JSONValue {
        ["code": .string(code), "message": .string(message), "fix": fix.map(JSONValue.string) ?? .null]
    }

    private static func tail(_ id: String?) -> JSONValue {
        guard let id, !id.isEmpty else { return .null }
        return .string(Redactor.tail4(id))
    }
}
