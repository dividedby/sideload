import Foundation

public struct SlotOptions: Sendable, Equatable {
    /// `lend`, `return` or `restore`.
    public var sub: String?
    /// A saved device alias, or...
    public var device: String?
    /// ...a UDID or CoreDevice ID that must match a saved device (never echoed).
    public var udid: String?
    /// Who the slot is lent to; only `lab`.
    public var to: String?
    /// `restore` only: the app whose backup is pushed back (default: the device's lendable app).
    public var app: String?
    /// `restore` only: the owner's confirmation; agents must not pass it.
    public var yes: Bool

    public init(
        sub: String? = nil, device: String? = nil, udid: String? = nil, to: String? = nil, app: String? = nil, yes: Bool = false
    ) {
        self.sub = sub
        self.device = device
        self.udid = udid
        self.to = to
        self.app = app
        self.yes = yes
    }
}

/// `slot lend --device <alias>|--udid <id> --to lab` and `slot return --device|--udid` (design section 18, agreed with
/// mobile-safari-lab#63). The lab borrows the slot of the device's one owner-configured lendable app
/// (`devices.<d>.lendableApp`): `lend` uninstalls it and records `lent`, `return` reinstalls it from the `freeSigned`
/// build through the `install` path. No `--yes`: the lab runs these (`restore`, the owner's retry of the app-data restore, is `SlotRestore`). Both take `.op.lock` themselves and settle the
/// crash-safe marker first; a saved device only, free scope only. The slot is a record of the unified pending-operation
/// model (`SlotRule`, `SlotBook`): a durable op is written before each device change, a device with an op in flight answers
/// `SLOT_PENDING` to every mutating command, and one evidence rule settles it (the 27-cell table, docs/design.md section 18).
public enum SlotCommand {
    static let command = "slot"
    static let lab = "lab"

    public static func run(_ services: Services, _ options: SlotOptions) async -> Envelope {
        // Owner-only and not a slot operation: it never reaches the lab's debug hook below.
        if options.sub == "restore" { return await SlotRestore.run(services, options) }
        guard options.sub == "lend" || options.sub == "return" else {
            return .fail(
                command, code: "USAGE", message: "Unknown slot subcommand \"\(printableCut(options.sub ?? ""))\".",
                fix: "Use `sideload slot lend --device <alias> --to lab` or `sideload slot return --device <alias>`.")
        }
        let lend = options.sub == "lend"
        let action = options.sub ?? ""
        do {
            if options.app != nil || options.yes {
                throw SideloadError(
                    "USAGE", "slot \(action) does not take \(options.yes ? "--yes" : "--app").",
                    fix: lend ? "sideload slot lend --device <alias> --to lab" : "sideload slot return --device <alias>")
            }
            if lend {
                guard options.to == lab else {
                    throw SideloadError("USAGE", "slot lend needs --to lab.", fix: "sideload slot lend --device <alias> --to lab")
                }
            } else if options.to != nil {
                throw SideloadError("USAGE", "slot return does not take --to.", fix: "sideload slot return --device <alias>")
            }
            let config = try services.store.load()
            let alias = try resolveAlias(options, config: config)
            #if DEBUG
            // Debug builds only: answer as the lab's failure cases do, with no lock, ledger or device (see `forcedAnswer`).
            let forcedApp = config.devices[alias]?.lendableApp.flatMap { $0.isEmpty ? nil : $0 } ?? ProvisionApp.filler.rawValue
            if let forced = try forcedAnswer(
                mode: ProcessInfo.processInfo.environment[forceVariable], sub: action, alias: alias, app: forcedApp)
            {
                throw SlotFailure(error: forced, alias: alias)
            }
            #endif
            do {
                let lock = try OperationLock.acquire(paths: services.home)
                defer { lock.release() }
                return lend
                    ? try await Self.lend(services, config: config, alias: alias)
                    : try await Self.giveBack(services, config: config, alias: alias)
            } catch let error as SideloadError {
                throw SlotFailure(error: error, alias: alias)
            }
        } catch let failure as SlotFailure {
            return fail(failure.error, action: action, extra: ["device": .string(failure.alias)])
        } catch let error as SideloadError {
            return fail(error, action: action)
        } catch {
            return .from(error, command: command)
        }
    }

    private struct SlotFailure: Error {
        let error: SideloadError
        let alias: String
    }

    #if DEBUG
    /// Compiled out of release builds. While this variable is set, `slot lend` and `slot return` answer a failure the lab
    /// has to handle, without taking `.op.lock`, reading the ledger or calling the device (the lab's test harness has no
    /// device): `pending` answers `SLOT_PENDING`; `return-failed` answers `RETURN_FAILED` on `slot return`. Stateless: it
    /// applies on every call while the variable is set. Any other value is `USAGE`, and so is `return-failed` on `lend`.
    static let forceVariable = "SIDELOAD_TEST_FORCE_SLOT"

    /// The error to answer with, or nil when `mode` is unset or empty. `app` is the device's lendable app (or the filler).
    static func forcedAnswer(mode: String?, sub: String, alias: String, app: String) throws -> SideloadError? {
        guard let mode, !mode.isEmpty else { return nil }
        switch mode {
        case "pending":
            let op = LedgerSlotOp(kind: .install, by: .install, startedAt: Date(), window: SlotRule.window(.install))
            let slot = LedgerSlot(device: alias, app: app, presence: .unknown, op: op)
            return SlotBook.pendingError(slot, retryAfter: SlotRule.window(.install))
        case "return-failed":
            guard sub == "return" else {
                throw SideloadError(
                    "USAGE", "\(forceVariable)=return-failed applies to `slot return` only.",
                    fix: "Use \(forceVariable)=pending for `slot lend`.")
            }
            // The shape `giveBack` prints for a definite install failure with the app still lent.
            return SideloadError(
                "RETURN_FAILED", "The device is locked.",
                fix: "Retry `sideload slot return --device \(alias)`.",
                data: [
                    "cause": "DEVICE_LOCKED", "state": .string(LedgerLent.lent), "lent": true, "app": .string(app),
                ])
        default:
            throw SideloadError(
                "USAGE", "Unknown \(forceVariable) value \"\(printableCut(mode))\".", fix: "Use pending or return-failed.")
        }
    }
    #endif

    static func fail(_ error: SideloadError, action: String, extra: [String: JSONValue] = [:]) -> Envelope {
        var data: [String: JSONValue] = ["action": .string(action)]
        data.merge(extra) { _, new in new }
        data.merge(error.data) { _, new in new }
        return .fail(command, code: error.code, message: error.message, fix: error.fix, data: data)
    }

    /// Exactly one of `--device` and `--udid`. A UDID (or CoreDevice ID) is accepted only when it equals a saved device's
    /// ID, ignoring case; any other value is `DEVICE_NOT_SAVED` and is never echoed.
    private static func resolveAlias(_ options: SlotOptions, config: Config) throws -> String {
        let device = options.device.flatMap { $0.isEmpty ? nil : $0 }
        let udid = options.udid.flatMap { $0.isEmpty ? nil : $0 }
        guard (device == nil) != (udid == nil) else {
            throw SideloadError(
                "USAGE", "slot needs exactly one of --device <alias> and --udid <id>.",
                fix: "sideload slot \(options.sub ?? "lend") --device <alias>")
        }
        if let device {
            guard config.devices[device] != nil else {
                throw SideloadError(
                    "DEVICE_NOT_SAVED", "No saved device with alias \"\(printableAlias(device))\".",
                    fix: "Use a saved alias (`sideload device list`).")
            }
            return device
        }
        let wanted = (udid ?? "").lowercased()
        let match = config.devices.keys.sorted().first { alias in
            let saved = config.devices[alias]
            return [saved?.udid, saved?.coreDeviceId].contains { $0?.lowercased() == wanted && !wanted.isEmpty }
        }
        guard let match else {
            throw SideloadError(
                "DEVICE_NOT_SAVED", "That device ID is not a saved device.",
                fix: "Only saved devices are used; the owner saves one with `sideload device save`.")
        }
        return match
    }

    // MARK: lend

    /// The outcome table's rows are in docs/design.md section 18 and `SlotMatrixTests`. In short, the pipeline of `SlotBook`:
    /// the gate (any op in flight on the device is `SLOT_PENDING`, no device call), S0, W1 settle (a pending lend record whose
    /// window is over is settled by that snapshot before anything else), the checks, W2 (an `uninstall` op plus `lentTo`,
    /// durable before the uninstall), the uninstall, S1, then W3 applies the table of `SlotRule`: the ledger says only what
    /// the table allows (`lent` for an app that is gone, nothing claimed otherwise).
    private static func lend(_ services: Services, config: Config, alias: String) async throws -> Envelope {
        // The marker and the keychain come first, before any answer, as for every command that touches the free team.
        let now = wholeSeconds(services.clock.now())
        _ = try await FreeSession.settle(services, now: now)
        let book = SlotBook(services: services, config: config, alias: alias)
        let ledger = try await book.loadMigrated()
        try book.gate(ledger, now: services.clock.now())
        let configured = config.devices[alias]?.lendableApp.flatMap { $0.isEmpty ? nil : $0 }
        let existing = book.lentSlot(ledger)
        // Already lent comes first: it needs no lendable app to be configured any more. L1.
        if let existing {
            guard existing.lentTo == lab, configured == nil || configured == existing.app else {
                throw SideloadError(
                    "ALREADY_LENT", "A slot on this device is already lent (\(printableCut(existing.app)) to \(printableCut(existing.lentTo ?? ""))).",
                    fix: "Return it first: sideload slot return --device \(alias)")
            }
            // L0: the only answer given from the ledger, and only for a state a valid snapshot established.
            if SlotRule.holds(existing) {
                return .result(
                    command,
                    ["action": "lend", "app": .string(existing.app), "device": .string(alias), "freed": 0, "alreadyLent": true])
            }
        }
        guard let name = existing?.app ?? configured else {
            throw SideloadError(
                "NO_LENDABLE_APP", "No app is configured as lendable on this device.",
                fix: "The owner sets one: sideload device lendable --alias \(alias) --app <app> --yes")
        }
        guard let app = ProvisionApp(rawValue: name) else {
            throw SideloadError(
                "NO_LENDABLE_APP", "The configured lendable app is not a known app.",
                fix: "The owner sets one of \(ProvisionApp.names.joined(separator: ", ")): sideload device lendable --alias \(alias) --app <app> --yes")
        }
        let target = try FreeTarget.resolve(app: app, alias: alias, config: config)

        // S0 is also the settle snapshot. L2: when it fails the ledger stays as it is.
        let calls = FreeDeviceCalls(services: services, alias: alias, bundleId: target.bundleId)
        let s0Read = await calls.trySnapshot()
        guard let s0 = s0Read.snapshot else {
            let cause = s0Read.error ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read.")
            guard let existing else { throw cause }
            let word = SlotRule.phase(existing).rawValue
            var data = cause.data
            data.merge(["cause": .string(cause.code), "state": .string(word), "freed": 0, "uncertain": true, "app": .string(app.rawValue)]) { _, new in new }
            throw SideloadError(
                "SLOT_STATE_UNKNOWN", "The slot is recorded as \(word) and the device could not be read to settle it, so no slot is claimed.",
                fix: "Unlock the device and retry `sideload slot lend --device \(alias) --to lab`; the slot is not free meanwhile.", data: data)
        }
        let settled = try await book.settle(s0, takenAt: s0Read.takenAt, point: "lend.settle")
        var out: [String: JSONValue] = ["action": "lend", "app": .string(app.rawValue), "device": .string(alias)]
        if let was = settled.before(app.rawValue), was.lentTo != nil, let landed = settled.after(app.rawValue), SlotRule.holds(landed) {
            if let op = was.op, op.kind == .uninstall {  // L3: the earlier uninstall did land.
                out["freed"] = 1
                out["warnings"] = [
                    CanaryCommand.warning(
                        "UNINSTALL_RESULT_UNCERTAIN",
                        "An earlier uninstall's result was not certain, but the app is no longer on the device, so the slot is recorded as lent.",
                        "No action needed; `slot return` reinstalls the app.")
                ]
            } else {  // L3: a return had started but the app is not on the device.
                out["freed"] = 0
                out["alreadyLent"] = true
                out["warnings"] = [
                    CanaryCommand.warning(
                        "RETURN_NOT_LANDED",
                        "An earlier `slot return` had started but the app is not on the device, so the slot is still lent.",
                        "No action needed; `slot return` reinstalls the app.")
                ]
            }
            return .result(command, out)
        }
        if settled.after(app.rawValue)?.lentTo == nil, !s0.ids.contains(target.bundleId) {  // L5
            throw SideloadError(
                "LENDABLE_NOT_INSTALLED", "\(app.rawValue) is not installed on the device, so there is no slot to free.",
                fix: "Nothing was freed. Check `sideload status` (slots) before assuming a free slot; the owner may need to free one.")
        }

        // L6: nothing is uninstalled that could not be put back: a valid signed build with an unexpired profile must exist.
        let signed = try target.requireSigned(try services.ledgerStore.load(), home: services.home.home, now: now)

        // The app's data is saved before the intent and the uninstall (read-only, no slot operation, never a failure of the
        // lend). The backup belongs to this lend: `since` is what `begin` records for it.
        var data = AppDataBackup.Result(skipped: true)
        if AppDataBackup.isEnabled(config, app: app) {
            data = AppDataBackup.Result()
            if s0.ids.contains(target.bundleId) {
                data = await AppDataBackup.backup(
                    services, target: target, calls: calls, version: signed.record.version, lendSince: existing?.since ?? now)
            }
        }

        // Backups of earlier lends that never got restored are marked superseded, whether or not this lend saved a new one (never
        // a failure of the lend; a resumed lend keeps its own backup: same `since`).
        AppDataBackup.supersedeOlder(services, target, than: existing?.since ?? now)

        // L7: the intent is durable before the uninstall.
        let removal = FreeRemoval(services: services, target: target)
        let outcome = try await removal.perform {
            try await book.begin(
                target, kind: .uninstall, by: .lend, presence: .present, lend: true, since: now, point: "lend.intent")
        }
        let confirmation = SlotRule.confirm(.uninstall, outcome.result, outcome.reading)
        let slot = try await book.finish(
            target, effect: confirmation.effect, takenAt: outcome.afterTakenAt, point: "lend.final")
        func pendingFields(_ base: [String: JSONValue]) -> [String: JSONValue] {
            var data = base
            data.merge([
                "uncertain": true, "state": .string(LedgerLent.lending), "freed": 0, "app": .string(app.rawValue),
                "retryAfter": .number(Double(book.retryAfter(slot))),
            ]) { _, new in new }
            return data
        }
        let lendingFix = "Not lent yet: `sideload slot lend --device \(alias) --to lab` (or `slot return`) settles it from a fresh snapshot once the window is over, and the slot is not free meanwhile."
        switch confirmation.effect {
        case .absent:  // L8
            AppDataBackup.markUninstalled(services, target, since: existing?.since ?? now)
            let after = outcome.after ?? s0
            let delta = AppSnapshot.delta(from: s0, to: after)
            if delta.removed != [target.bundleId] || !delta.added.isEmpty {
                throw unexpectedDelta(
                    delta, expectation: "an uninstall should remove only this app",
                    extra: ["uninstalled": true, "state": .string(LedgerLent.lent), "freed": 1, "app": .string(app.rawValue)])
            }
            out["freed"] = 1
            var warnings: [JSONValue] = []
            if outcome.result != .success {
                warnings.append(
                    CanaryCommand.warning(
                        "UNINSTALL_RESULT_UNCERTAIN",
                        "The uninstall's result was not certain, but the app is no longer on the device, so the slot is recorded as lent.",
                        "No action needed; `slot return` reinstalls the app."))
            }
            if removal.lastFreeApp(before: s0) {
                warnings.append(
                    CanaryCommand.warning(
                        "LAST_FREE_APP_REMOVED",
                        "No other free-team app sideload knows of remains on this device, so the owner's developer trust may be cleared.",
                        "If an app later will not open, trust the developer again in Settings › General › VPN & Device Management."))
            }
            out.merge(AppDataBackup.backupFields(data)) { _, new in new }
            warnings += data.warnings
            if !warnings.isEmpty { out["warnings"] = .array(warnings) }
            return .result(command, out)
        case .present:  // L9: a definite failure and the app is still there; the lend is undone
            guard let failure = outcome.opFailure else {
                throw unexpectedDelta(
                    AppSnapshot.delta(from: s0, to: outcome.after ?? s0),
                    expectation: "the app is still on the device after its uninstall reported success",
                    extra: ["uninstalled": false, "freed": 0])
            }
            var data = failure.data
            data["freed"] = 0
            throw SideloadError(failure.code, failure.message, fix: failure.fix, data: data)
        case .keep:  // L10, L11: nothing is claimed; the op stays pending
            if let failure = outcome.opFailure {
                throw SideloadError(failure.code, failure.message, fix: lendingFix, data: pendingFields(failure.data))
            }
            if confirmation.note == .unexpectedAppDelta {
                throw unexpectedDelta(
                    AppSnapshot.delta(from: s0, to: outcome.after ?? s0),
                    expectation: "the app is still on the device after its uninstall reported success",
                    extra: pendingFields(["uninstalled": false]))
            }
            throw SideloadError(
                "UNINSTALL_RESULT_UNCERTAIN",
                "The uninstall reported success, but the device could not be listed afterwards, so no slot is claimed.",
                fix: lendingFix, data: pendingFields([:]))
        }
    }

    // MARK: return

    /// Rows T0 to T10 (docs/design.md section 18, `SlotMatrixTests`). A return is complete only when a snapshot lists our
    /// ID; the `install` op is written before the install and stays when the table says `keep`.
    private static func giveBack(_ services: Services, config: Config, alias: String) async throws -> Envelope {
        let book = SlotBook(services: services, config: config, alias: alias)
        var seen = try services.ledgerStore.load()
        let appName = book.lentSlot(SlotRule.migrated(seen, now: services.clock.now()))?.app ?? ""

        func failed(_ error: SideloadError, uncertain: Bool = false) -> SideloadError {
            let ledger = (try? services.ledgerStore.load()).map { SlotRule.migrated($0, now: services.clock.now()) } ?? seen
            let record = book.lentSlot(ledger)
            let state = record.map(SlotRule.phase) ?? .none
            let reprovision = [
                "PROFILE_EXPIRED", "PROFILE_INVALID", "PROFILE_MISSING", "NOT_SIGNED", "DEVICE_NOT_IN_PROFILE",
                "PROFILE_CERT_MISMATCH", "WRONG_TEAM", "GUARD_FAILED",
            ].contains(error.code)
            let fix: String
            if state == .returning || uncertain {
                fix = "The return may or may not have landed, and the slot is not free: `sideload slot return --device \(alias)` (or `slot lend`) settles it from a fresh snapshot once the window is over."
            } else if reprovision {
                fix = "The owner re-signs \(appName) (\(ProvisionApp.resignSteps(app: appName, device: alias))), then runs `sideload slot return --device \(alias)`. The slot stays lent."
            } else {
                fix = error.fix ?? "Retry `sideload slot return --device \(alias)`."
            }
            var data = error.data
            data["cause"] = .string(error.code)
            data["state"] = .string(state.rawValue)
            data["lent"] = .bool(state != .none)
            data["app"] = record == nil ? .null : .string(appName)
            if uncertain { data["uncertain"] = true }
            return SideloadError("RETURN_FAILED", error.message, fix: fix, data: data)
        }
        /// Any `SideloadError` from a step becomes RETURN_FAILED; a simulated crash (not a `SideloadError`) passes through.
        func step<T>(uncertain: Bool = false, _ body: () async throws -> T) async throws -> T {
            do {
                return try await body()
            } catch let error as SideloadError {
                throw failed(error, uncertain: uncertain)
            }
        }

        let now = wholeSeconds(services.clock.now())
        let identities = try await step { try await FreeSession.settle(services, now: now) }  // T1
        let ledger = try await step { try await book.loadMigrated() }
        seen = ledger
        // The gate is not a RETURN_FAILED: it answers SLOT_PENDING like `lend` does, with no device call.
        try book.gate(ledger, now: services.clock.now())
        guard let record = book.lentSlot(ledger) else {  // T0
            return .result(
                command,
                ["action": "return", "device": .string(alias), "app": .null, "reinstalled": false, "nothingLent": true])
        }
        let wasReturning = SlotRule.phase(record) == .returning
        let app = try await step { try FreeTarget.parseApp(record.app) }
        let target = try await step { try FreeTarget.resolve(app: app, alias: alias, config: config) }
        let calls = FreeDeviceCalls(services: services, alias: alias, bundleId: target.bundleId)

        let s0Read = await calls.trySnapshot()  // T2
        guard let s0 = s0Read.snapshot else {
            throw failed(
                s0Read.error ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read."), uncertain: record.op != nil)
        }
        let settled = try await step {
            try await book.settle(s0, takenAt: s0Read.takenAt, point: "return.settle")
        }
        if settled.after(record.app)?.lentTo == nil {  // T3: our ID is on the device
            var out: [String: JSONValue] = ["action": "return", "app": .string(record.app), "device": .string(alias)]
            if wasReturning {
                out["reinstalled"] = true
                out["settled"] = true
            } else {
                out["reinstalled"] = false
                out["alreadyPresent"] = true
            }
            return .result(command, out)
        }

        // T4: absent, recorded `lent`. T5: everything that can fail before the device is touched.
        let run = FreeInstallRun(services: services, target: target)
        let planned = try await step { () async throws -> FreeInstallRun.Plan in
            let checked = try await run.checks(identities: identities, allowLent: true)
            let used = book.usedOutsideSnapshot(try services.ledgerStore.load(), excluding: record.app, snapshot: s0)
            let profiles = await calls.freeProfiles()
            return try run.plan(checked, before: s0, usedOutside: used, profiles: profiles)
        }
        // T6: the intent, then the install.
        let outcome = try await run.perform(planned) {
            try await step {
                try await book.begin(
                    target, kind: .install, by: .giveBack, presence: .absent, since: record.since ?? now, point: "return.intent")
            }
        }
        let confirmation = SlotRule.confirm(.install, outcome.result, outcome.reading)
        let slot = try await step {
            try await book.finish(
                target, effect: confirmation.effect, takenAt: outcome.afterTakenAt, point: "return.final",
                record: planned.checked.signed, succeeded: outcome.result == .success)
        }
        switch confirmation.effect {
        case .present:  // T7: our ID is back and recorded
            let after = outcome.after ?? s0
            let delta = AppSnapshot.delta(from: s0, to: after)
            if delta.added != [target.bundleId] || !delta.removed.isEmpty {
                throw unexpectedDelta(
                    delta, expectation: "a first install should add only this app",
                    extra: ["returned": true, "lent": false, "app": .string(record.app), "installed": true, "recorded": true])
            }
            var out: [String: JSONValue] = [
                "action": "return", "app": .string(record.app), "device": .string(alias), "reinstalled": true,
                "slots": after.usage(
                    prefix: target.prefix, reserved: planned.reserved, outside: planned.usedOutside, profiles: planned.profiles
                ).json(),
            ]
            var warnings: [JSONValue] = []
            if outcome.result != .success, let failure = outcome.opFailure {
                warnings.append(
                    CanaryCommand.warning(
                        "INSTALL_RESULT_UNCERTAIN",
                        "The install reported a failure (\(failure.code)) but the app is back on the device, so the return is recorded.",
                        "No action needed."))
            }
            // The app's data goes back before anything can launch the app; a failure is a warning, never RETURN_FAILED.
            let restored = await AppDataBackup.restore(services, target: target, calls: calls, since: record.since)
            out.merge(AppDataBackup.restoreFields(restored)) { _, new in new }
            warnings += restored.warnings
            if !warnings.isEmpty { out["warnings"] = .array(warnings) }
            return .result(command, out)
        case .absent:  // T8: a definite failure, the app is not there: still lent
            throw failed(
                outcome.opFailure ?? SideloadError("INSTALL_FAILED", "The install did not finish.", fix: "Run `sideload slot return` again."))
        case .keep:  // T8 (success claimed, app not listed), T9, T10: nothing is claimed; the op stays pending
            var error =
                outcome.opFailure
                ?? (outcome.after == nil
                    ? outcome.afterError ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read.")
                    : SideloadError(
                        "INSTALL_UNCONFIRMED", "devicectl reported the install but the app is not on the device.",
                        fix: "Run `sideload slot return` again once the window is over; a reinstall is slot-neutral."))
            var data = error.data
            data["retryAfter"] = .number(Double(book.retryAfter(slot)))
            error = SideloadError(error.code, error.message, fix: error.fix, data: data)
            throw failed(error, uncertain: true)
        }
    }
}
