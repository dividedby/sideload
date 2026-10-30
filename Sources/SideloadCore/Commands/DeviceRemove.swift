import Darwin
import Foundation

/// `device remove --alias a [--yes]`: retires a saved device. Owner-only; touches no device and no portal.
///
/// An alias is accepted when it is saved in config or when the ledger still holds records for it (a device whose config
/// entry was removed by hand). The records and files of that alias go; app-data backups stay (secrets-class: only their
/// folders are counted). Refused while the lab holds a slot, a lend or return (or any slot operation) may still be in
/// flight, or a saved app-data restore is waiting. Installs still recorded present are forgotten, not uninstalled.
///
/// With `--yes`, under `.op.lock`: one ledger write, then the files, then the config entry. A crash leaves the alias visible
/// (through config, or the ledger records not yet dropped) so a rerun finishes the rest.
enum DeviceRemove {
    static let command = "device remove"

    /// What the alias holds, as counts. `slots` counts the migrated `slots[]`; `installsPresent` reads the projection.
    struct Counts: Sendable, Equatable {
        var profiles = 0
        var signedBuilds = 0
        var installs = 0
        var installsPresent = 0
        var slots = 0
    }

    static func run(_ services: Services, _ options: DeviceOptions) async throws -> Envelope {
        let usageFix = "sideload device remove --alias <alias> --yes (owner)"
        if options.match != nil || options.platform != nil || options.on || options.off || options.reserved != nil {
            return .fail(
                command, code: "USAGE", message: "device remove takes only --alias and --yes.", fix: usageFix)
        }
        guard let alias = options.alias, !alias.isEmpty else {
            return .fail(command, code: "USAGE", message: "device remove needs --alias.", fix: usageFix)
        }
        guard DeviceCommand.isValidAlias(alias) else {
            return .fail(
                command, code: "USAGE", message: "Alias must be 1-32 chars of letters, digits, \"-\" or \"_\".",
                fix: "Use the alias from `sideload device list`.")
        }

        let config = try services.store.load()
        let inConfig = config.devices[alias] != nil
        let ledger = try services.ledgerStore.load()
        // Folders count too: a run that died after the ledger write left an alias with only those.
        guard inConfig || hasRecords(ledger, alias: alias) || !aliasFolders(services.home, alias: alias).paths.isEmpty else {
            throw SideloadError(
                "DEVICE_NOT_SAVED",
                "No saved device with alias \"\(printableAlias(alias))\", and nothing is left for it in the ledger or on disk.",
                fix: "sideload device list")
        }

        let now = services.clock.now()
        let migrated = SlotRule.migrated(ledger, now: now)
        if let busy = refusal(migrated.slots, alias: alias, now: now) { throw busy }
        if let busy = pendingRestore(services, config: config, alias: alias) { throw busy }

        guard options.yes else {
            var preview = counts(migrated, alias: alias).json
            preview["alias"] = .string(alias)
            preview["inConfig"] = .bool(inConfig)
            preview["backups"] = .number(Double(backupCount(services, alias: alias)))
            return .fail(
                command, code: "CONFIRM_REQUIRED",
                message: "device remove forgets this device's ledger records and deletes its profiles and signed builds. Apps on the device stay until their profiles expire; app-data backups are kept.",
                fix: "The owner confirms by re-running with --yes: \(usageFix)", data: ["preview": .object(preview)])
        }

        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }
        return try await remove(services, alias: alias)
    }

    // MARK: remove

    private static func remove(_ services: Services, alias: String) async throws -> Envelope {
        // Re-checked under the lock: the state above may be gone. The restore check reads the disk, so it is outside the write.
        let config = try services.store.load()
        if let busy = pendingRestore(services, config: config, alias: alias) { throw busy }

        // a. one ledger write, through the slot state's migrate/project invariants. The refusal is checked again inside it, on
        // the ledger the write reads, so nothing is dropped from a device that became busy.
        let now = services.clock.now()
        let removed = try await dropRecords(services, alias: alias, now: now)

        // b. the files, for every app folder present (not just the ledger's paths).
        let (dirsDeleted, skipped) = try deleteDirectories(services.home, alias: alias)

        // c. the config entry, last.
        let fromConfig = try await services.store.update { config in config.devices.removeValue(forKey: alias) != nil }

        let kept = backupCount(services, alias: alias)
        var warnings: [JSONValue] = []
        if removed.installsPresent > 0 {
            warnings.append(
                CanaryCommand.warning(
                    "INSTALLS_LEFT_ON_DEVICE",
                    "\(removed.installsPresent) install(s) were recorded present; they are forgotten, not uninstalled, and stay on the device until their profiles expire.",
                    "Remove them on the device if they are not wanted."))
        }
        if kept > 0 {
            warnings.append(
                CanaryCommand.warning(
                    "BACKUPS_KEPT",
                    "\(kept) app-data backup folder(s) were kept under backups/ for this alias; they hold session tokens.",
                    "Delete them yourself when they are no longer needed."))
        }
        if skipped > 0 {
            warnings.append(
                CanaryCommand.warning(
                    "DIRECTORY_SKIPPED",
                    "\(skipped) folder(s) of this alias sit behind a link and were left alone.",
                    "Check profiles/free and builds/signed under $SIDELOAD_HOME."))
        }
        var summary = removed.json
        summary["alias"] = .string(alias)
        summary["fromConfig"] = .bool(fromConfig)
        summary["dirsDeleted"] = .number(Double(dirsDeleted))
        return .result(
            command, ["removed": .object(summary), "backupsKept": .number(Double(kept)), "warnings": .array(warnings)])
    }

    private static func dropRecords(_ services: Services, alias: String, now: Date) async throws -> Counts {
        var counted = Counts()
        try await SlotState.write(services, point: "device-remove.records") { ledger in
            if let busy = refusal(ledger.slots, alias: alias, now: now) { throw busy }
            var view = ledger
            SlotRule.project(&view)
            counted = counts(view, alias: alias)
            ledger.freeProfiles.removeAll { $0.device == alias }
            ledger.freeSigned.removeAll { $0.device == alias }
            ledger.installs.removeAll { $0.device == alias }
            ledger.slots.removeAll { $0.device == alias }
            // `lent[]` is projected from the slots afterwards; a legacy entry without a slot was reconciled into one above.
        }
        return counted
    }

    // MARK: reading

    static func hasRecords(_ ledger: Ledger, alias: String) -> Bool {
        ledger.freeProfiles.contains { $0.device == alias } || ledger.freeSigned.contains { $0.device == alias }
            || ledger.installs.contains { $0.device == alias } || ledger.slots.contains { $0.device == alias }
            || ledger.lent.contains { $0.device == alias }
    }

    static func counts(_ ledger: Ledger, alias: String) -> Counts {
        let installs = ledger.installs.filter { $0.device == alias }
        return Counts(
            profiles: ledger.freeProfiles.filter { $0.device == alias }.count,
            signedBuilds: ledger.freeSigned.filter { $0.device == alias }.count,
            installs: installs.count, installsPresent: installs.filter(\.present).count,
            slots: ledger.slots.filter { $0.device == alias }.count)
    }

    /// The lab holds a slot, or a lend, return or other operation of this device may still be in flight. `slots` must be
    /// migrated. A lend record that is not yet `lent` is pending whatever its window says (the next snapshot settles it); any
    /// other operation only while inside its window, as the gate reads it.
    static func refusal(_ slots: [LedgerSlot], alias: String, now: Date) -> SideloadError? {
        let mine = slots.filter { $0.device == alias }
        let name = printableAlias(alias)
        if let held = mine.first(where: { $0.lentTo != nil && SlotRule.phase($0) == .lent }) {
            return SideloadError(
                "DEVICE_BUSY", "The lab holds the \(held.app) slot of device \"\(name)\".",
                fix: "The lab returns it with `sideload slot return --device \(name)`; retry after that.",
                data: ["alias": .string(alias), "reason": "lent", "app": .string(held.app)])
        }
        let inWindow = mine.compactMap { slot -> (LedgerSlot, Int)? in
            guard let op = slot.op, let left = SlotRule.remaining(op, now: now) else { return nil }
            return (slot, left)
        }.max { $0.1 < $1.1 }
        if let (slot, left) = inWindow {
            return SideloadError(
                "DEVICE_BUSY",
                "A device operation on \(printableCut(slot.app)) of \"\(name)\" may still be finishing, so nothing is forgotten.",
                fix: "Retry in \(left) seconds, or finish a lend or return with `sideload slot return --device \(name)`.",
                data: [
                    "alias": .string(alias), "reason": "pending", "app": .string(slot.app), "retryAfter": .number(Double(left)),
                ])
        }
        if let stuck = mine.first(where: { $0.lentTo != nil && SlotRule.phase($0).pending }) {
            return SideloadError(
                "DEVICE_BUSY", "A lend or return of \(printableCut(stuck.app)) on \"\(name)\" has not been settled.",
                fix: "Finish it with `sideload slot return --device \(name)`, then retry.",
                data: ["alias": .string(alias), "reason": "pending", "app": .string(stuck.app)])
        }
        return nil
    }

    /// An app-data restore still waiting (`AppDataBackup.pending`, what `PendingRestores` reports) for any app of this alias,
    /// saved or not: a backup is bound to the alias folder and the bundle ID, so a pending one left behind would otherwise be
    /// restored onto a new device saved under the same alias. Read straight from the disk without `PendingRestores`'
    /// settle-window skip: under the lock no return is running. Needs the bundle ID prefix; without a valid one the check
    /// cannot run, and backups present refuse (`restore_unknown`) rather than being skipped.
    static func pendingRestore(_ services: Services, config: Config, alias: String) -> SideloadError? {
        let name = printableAlias(alias)
        guard let prefix = config.bundleIdPrefix, CanaryCommand.isValidPrefix(prefix),
            Config.isFreeBundleId(prefix + ".free.x", prefix: prefix)
        else {
            guard backupCount(services, alias: alias) > 0 else { return nil }
            return SideloadError(
                "DEVICE_BUSY",
                "Saved app-data backups exist for device \"\(name)\", and bundleIdPrefix in config.json is missing or invalid, so whether a restore is waiting cannot be checked.",
                fix: "Set \"bundleIdPrefix\" in $SIDELOAD_HOME/config.json, then retry.",
                data: ["alias": .string(alias), "reason": "restore_unknown"])
        }
        for app in ProvisionApp.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let found = AppDataBackup.pending(
                services, alias: alias, app: app.rawValue, bundleId: prefix + ".free." + app.suffix)
            if case .found = found {
                return SideloadError(
                    "DEVICE_BUSY", "Saved app data of \(app.rawValue) on device \"\(name)\" is waiting to be restored.",
                    fix: config.devices[alias] != nil
                        ? "The owner runs `sideload slot restore --device \(name) --app \(app.rawValue) --yes`; retry after that."
                        : "This alias is no longer saved, so `slot restore` cannot run for it. If the data is not wanted, the owner deletes backups/\(name)/\(app.rawValue) by hand; then retry.",
                    data: ["alias": .string(alias), "reason": "restore_pending", "app": .string(app.rawValue)])
            }
        }
        return nil
    }

    /// Folders directly under `backups/<alias>/<app>/`, one per backup. Names only: nothing inside is opened, and links are
    /// not followed or counted.
    static func backupCount(_ services: Services, alias: String) -> Int {
        let root = services.home.backups + "/" + alias
        guard isRealDirectory(services.home.backups), isRealDirectory(root) else { return 0 }
        var total = 0
        for app in names(in: root) {
            let appDir = root + "/" + app
            guard isRealDirectory(appDir) else { continue }
            total += names(in: appDir).filter { isRealDirectory(appDir + "/" + $0) }.count
        }
        return total
    }

    // MARK: files

    /// The folders `profiles/free/<app>/<alias>` and `builds/signed/<app>/<alias>` for every `<app>` folder present. Every
    /// parent must be a real folder (`lstat`), so nothing outside the home is reached; the alias entry itself, if a link, is
    /// listed to be unlinked, never followed. `links` counts the app folders and roots skipped for being links (a stray regular
    /// file such as `.DS_Store` is ignored).
    static func aliasFolders(_ home: Paths, alias: String) -> (paths: [String], links: Int) {
        var paths: [String] = []
        var links = 0
        for root in [home.freeProfiles, home.signedBuilds] {
            guard let parent = realParents(of: root, home: home.home) else {
                if behindLink(root, home: home.home) { links += 1 }
                continue
            }
            for app in names(in: parent) {
                let appDir = parent + "/" + app
                guard isRealDirectory(appDir) else {
                    if isLink(appDir) { links += 1 }
                    continue
                }
                let target = appDir + "/" + alias
                if exists(target) { paths.append(target) }
            }
        }
        return (paths, links)
    }

    /// Deletes what `aliasFolders` lists. Returns the entries deleted and the links skipped.
    private static func deleteDirectories(_ home: Paths, alias: String) throws -> (deleted: Int, skipped: Int) {
        let found = aliasFolders(home, alias: alias)
        var deleted = 0
        for target in found.paths {
            do {
                try FileManager.default.removeItem(atPath: target)
            } catch {
                throw SideloadError(
                    "DEVICE_REMOVE_INCOMPLETE", "A folder of this alias could not be deleted.",
                    fix: "Check the permissions under $SIDELOAD_HOME, then re-run `sideload device remove`; the ledger records are already gone.")
            }
            deleted += 1
        }
        return (deleted, found.links)
    }

    /// `root` when it and every folder between the home and it are real folders, else nil.
    private static func realParents(of root: String, home: String) -> String? {
        guard root.hasPrefix(home + "/") else { return nil }
        var current = home
        for part in root.dropFirst(home.count).split(separator: "/") {
            current += "/" + part
            guard isRealDirectory(current) else { return nil }
        }
        return root
    }

    static func names(in path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    static func isLink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
    }

    /// Whether `path` is cut off by a link: it, or a folder between the home and it, is one.
    private static func behindLink(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        var current = home
        for part in path.dropFirst(home.count).split(separator: "/") {
            current += "/" + part
            if isLink(current) { return true }
        }
        return false
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}

extension DeviceRemove.Counts {
    var json: [String: JSONValue] {
        [
            "profiles": .number(Double(profiles)), "signedBuilds": .number(Double(signedBuilds)),
            "installs": .number(Double(installs)), "installsPresent": .number(Double(installsPresent)),
            "slots": .number(Double(slots)),
        ]
    }
}
