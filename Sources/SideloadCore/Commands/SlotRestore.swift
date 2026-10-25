import Foundation

/// `slot restore --device <alias> [--app <app>] --yes`: the owner's manual retry of the app-data restore that `slot return`
/// could not finish (design section 18, "App data"). Not a slot operation: it writes nothing to the ledger, installs and
/// uninstalls nothing, and the lab never runs it (so the debug hook of `slot` does not apply). It pushes the newest finished
/// backup of the app, when that one is still unrestored and not superseded by a later lend, into the app that is installed
/// now, then relists and compares, exactly as the return does (`AppDataBackup.push`, one 120 s allowance).
///
/// Order: usage, the saved alias, the app, `--yes`, `.op.lock`, the crash-safe marker and keychain (`FreeSession.settle`), the
/// ledger gate (an op in flight answers `SLOT_PENDING`, no device call), no lend record for this app, a pending backup (a local
/// read), then one app-list snapshot that must list the app. The backup is secrets-class: output carries counts and booleans
/// only. The backup is kept either way; a failed run is safe to repeat (a push overwrites).
enum SlotRestore {
    static let action = "restore"
    private static let usage = "sideload slot restore --device <alias> [--app <app>] --yes"

    static func run(_ services: Services, _ options: SlotOptions) async -> Envelope {
        var extra: [String: JSONValue] = [:]
        do {
            guard options.udid == nil, options.to == nil else {
                throw SideloadError("USAGE", "slot restore takes --device <alias>, not --udid or --to.", fix: usage)
            }
            guard let alias = options.device, !alias.isEmpty else {
                throw SideloadError("USAGE", "slot restore needs --device <alias>.", fix: usage)
            }
            let config = try services.store.load()
            guard config.devices[alias] != nil else {
                throw SideloadError(
                    "DEVICE_NOT_SAVED", "No saved device with alias \"\(printableAlias(alias))\".",
                    fix: "Use a saved alias (`sideload device list`).")
            }
            extra["device"] = .string(alias)
            let configured = config.devices[alias]?.lendableApp.flatMap { $0.isEmpty ? nil : $0 }
            guard let appName = options.app.flatMap({ $0.isEmpty ? nil : $0 }) ?? configured else {
                throw SideloadError(
                    "USAGE", "slot restore needs --app <app>: this device has no lendable app configured.", fix: usage)
            }
            let app = try FreeTarget.parseApp(appName)
            let target = try FreeTarget.resolve(app: app, alias: alias, config: config)
            extra["app"] = .string(app.rawValue)
            guard options.yes else {
                throw SideloadError(
                    "CONFIRM_REQUIRED",
                    "slot restore pushes the saved backup of \(app.rawValue) into the app on the saved device (it overwrites the files the app has there).",
                    fix: "The owner confirms by re-running with --yes. Agents must not pass --yes on their own.",
                    data: target.identity)
            }
            do {
                let lock = try OperationLock.acquire(paths: services.home)
                defer { lock.release() }
                return try await restore(services, target)
            }
        } catch let error as SideloadError {
            return SlotCommand.fail(error, action: action, extra: extra)
        } catch {
            return .from(error, command: SlotCommand.command)
        }
    }

    private static func restore(_ services: Services, _ target: FreeTarget) async throws -> Envelope {
        let now = wholeSeconds(services.clock.now())
        _ = try await FreeSession.settle(services, now: now)
        let book = SlotBook(services: services, config: target.config, alias: target.alias)
        let ledger = try await book.loadMigrated()
        try book.gate(ledger, now: services.clock.now())
        // The lab's slot: while the app is lent (in any phase) its data is not this command's to touch.
        if let lent = book.lentSlot(ledger), lent.app == target.app.rawValue {
            throw SideloadError(
                "ALREADY_LENT", "\(target.app.rawValue) is lent on this device, so there is no app to restore into.",
                fix: "Return it first: sideload slot return --device \(target.alias)")
        }
        let found: (directory: String, manifest: AppDataBackup.Manifest)
        switch AppDataBackup.pending(services, target) {
        case .found(let directory, let manifest):
            found = (directory, manifest)
        case .none(let restored, let superseded, let unreadable):
            let why =
                restored
                ? "The newest backup was already restored."
                : superseded
                    ? "The newest backup belongs to an earlier lend that a later lend replaced."
                    : unreadable ? "The newest backup could not be read." : "There is no backup of this app on this Mac."
            throw SideloadError(
                "NO_PENDING_RESTORE", "\(why) Nothing is waiting to be restored.",
                fix: unreadable
                    ? "The owner checks the backups folder in $SIDELOAD_HOME; the app signs in again otherwise."
                    : "Nothing to do; if the app asks to sign in, the owner signs in again.",
                data: ["restored": .bool(restored), "superseded": .bool(superseded), "unreadable": .bool(unreadable)])
        }

        let calls = FreeDeviceCalls(services: services, alias: target.alias, bundleId: target.bundleId)
        let read = await calls.trySnapshot()
        guard let snapshot = read.snapshot else {
            throw read.error ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read.")
        }
        guard snapshot.ids.contains(target.bundleId) else {
            throw SideloadError(
                "APP_NOT_INSTALLED", "\(target.app.rawValue) is not installed on the device, so there is nowhere to restore to.",
                fix: "Install it first (`sideload slot return --device \(target.alias)` after a lend, or `sideload install`), then run slot restore again.")
        }

        let result = await AppDataBackup.push(services, target: target, calls: calls, found: found)
        var out = target.identity
        out.removeValue(forKey: "bundleId")
        out["action"] = .string(action)
        out.merge(AppDataBackup.restoreFields(result)) { _, new in new }
        guard result.done else {
            // `push` warns INCOMPLETE when a file failed (or did not verify) and UNVERIFIED when only the relisting failed.
            let cause = result.failed > 0 ? "DATA_RESTORE_INCOMPLETE" : "DATA_RESTORE_UNVERIFIED"
            var data = out
            data["cause"] = .string(cause)
            data["kept"] = true
            data["warnings"] = .array(result.warnings)
            throw SideloadError(
                "RESTORE_FAILED", "The app's data was not (or could not be confirmed to be) restored. The backup is kept.",
                fix: "Unlock the device, keep it awake and run `sideload slot restore --device \(target.alias) --app \(target.app.rawValue) --yes` again; a push overwrites, so it is safe to repeat.",
                data: data)
        }
        if !result.warnings.isEmpty { out["warnings"] = .array(result.warnings) }
        return .result(SlotCommand.command, out)
    }
}
