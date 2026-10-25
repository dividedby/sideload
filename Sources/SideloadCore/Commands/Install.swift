import Darwin
import Foundation

public struct InstallOptions: Sendable, Equatable {
    public var app: String?
    public var device: String?
    /// Owner confirmation; agents must not pass it (the command installs on a real device).
    public var yes: Bool

    public init(app: String? = nil, device: String? = nil, yes: Bool = false) {
        self.app = app
        self.device = device
        self.yes = yes
    }
}

/// `install --app <a> --device <d> --yes`: puts the app `sign` left in `builds/signed/` on one saved device with
/// `devicectl` (design section 18, free team only). Order: usage, config, the saved device and its platform,
/// `--yes`, `.op.lock`, then `FreeInstallRun`.
public enum InstallCommand {
    static let command = "install"

    public static func run(_ services: Services, _ options: InstallOptions) async -> Envelope {
        let target: FreeTarget
        do {
            target = try FreeTarget.resolve(
                app: options.app, device: options.device, services: services,
                usageFix: "sideload install --app <\(ProvisionApp.names.joined(separator: "|"))> --device iphone --yes")
        } catch {
            return .from(error, command: command)
        }
        guard options.yes else {
            return .fail(
                command, code: "CONFIRM_REQUIRED",
                message: "install puts \(target.app.rawValue) on the saved device and uses a free-team slot.",
                fix: "The owner confirms by re-running with --yes. Agents must not pass --yes on their own.",
                data: target.identity)
        }
        do {
            let lock = try OperationLock.acquire(paths: services.home)
            defer { lock.release() }
            let data = try await FreeInstallRun(services: services, target: target).execute()
            return .result(command, data)
        } catch let error as SideloadError {
            var data = target.identity
            data.merge(error.data) { _, new in new }
            return .fail(command, code: error.code, message: error.message, fix: error.fix, data: data)
        } catch {
            return .from(error, command: command)
        }
    }
}

/// The install itself, with `.op.lock` already held by the caller (`install`, and `slot return` through the same path).
/// Split so `slot return` can interleave its pipeline (`SlotBook`): `checks` (pin, lent check, signed record, guard; no
/// device), `plan` (the slot preflight against a snapshot), `perform` (the intent hook, the install and the snapshot after,
/// never throwing for a device outcome). `execute` is the plain `install` flow over the three.
struct FreeInstallRun: Sendable {
    let services: Services
    let target: FreeTarget

    private var calls: FreeDeviceCalls { FreeDeviceCalls(services: services, alias: target.alias, bundleId: target.bundleId) }

    private func log(_ message: String) { services.log(message) }

    /// What `checks` leaves: the signed record and app, the clock reading it used.
    struct Checked: Sendable {
        let signed: LedgerFreeSigned
        let appPath: String
        let now: Date
    }

    /// What `plan` adds: the reserve, the snapshot and the slot arithmetic.
    struct Plan: Sendable {
        let checked: Checked
        let reserved: Int
        let before: AppSnapshot
        let reinstall: Bool
        let usage: AppSnapshot.Usage
        let usedOutside: SlotBook.OutsideUse
        /// The free-team profile read of this command (nil: not read), so the slots printed after the install use it too.
        let profiles: FreeTeamProfiles?
    }

    /// What the install did, as data: the device outcome never throws.
    struct Outcome: Sendable {
        /// The install's failure (enriched for `FREE_APP_LIMIT`); nil when it reported success, including an exit 0 that did
        /// not name the bundle (`unnamed`).
        var opFailure: SideloadError?
        /// The call's result as the table of `SlotRule` reads it: `unknown` for every shape of `FreeDeviceCalls.uncertain`,
        /// for an exit 0 that does not name the bundle, and for a call that threw.
        var result: SlotRule.Result
        var unnamed: Bool
        var read: FreeDeviceCalls.SnapshotRead
        let bundleId: String

        var after: AppSnapshot? { read.snapshot }
        var afterError: SideloadError? { read.error }
        var afterTakenAt: Date { read.takenAt }
        var reading: SlotRule.Reading { SlotRule.Reading(read.snapshot, bundleId: bundleId) }
    }

    /// The pinned identity, then what `sign` left (the record, the app, the profile's expiry) and the free guard on exactly
    /// that bundle. `identities` are the keychain read of `FreeSession.settle`, which the caller already ran under the lock.
    /// With `allowLent` false a slot lent to the lab for this app is `APP_LENT` (any state: a pending one is not ours either).
    /// The ledger is already migrated by the caller (`SlotBook.loadMigrated`).
    func checks(identities: [KeychainCertificate], allowLent: Bool) async throws -> Checked {
        let app = target.app
        let alias = target.alias
        let now = wholeSeconds(services.clock.now())
        let pinned = try FreeSession.pinned(identities, config: target.config, app: app.rawValue, alias: alias, now: now)

        let ledger = try services.ledgerStore.load()
        if !allowLent, ledger.slots.contains(where: { $0.device == alias && $0.app == app.rawValue && $0.lentTo != nil }) {
            throw SideloadError(
                "APP_LENT", "The slot for \(app.rawValue) is lent to the lab, so it is not installed here.",
                fix: "Run `sideload slot return --device \(alias)` (the lab does this when it is done).")
        }
        let (signed, appPath) = try target.requireSigned(ledger, home: services.home.home, now: now)

        // The free guard must pass on exactly this bundle, before the device is touched.
        log("install: checking the signed app")
        let verdict = await Guard.run(
            context: .free(
                FreeSigning(
                    bundleId: target.bundleId, bundleIdPrefix: target.prefix, pinnedCertificate: pinned.reference, now: now,
                    scratchRoot: services.home.tmp)),
            runner: services.runner, app: appPath, udid: target.udid)
        guard verdict.passed else {
            let expired = verdict.code == "PROFILE_INVALID" && (verdict.facts?.profileExpires.map { $0 <= now } ?? false)
            throw SideloadError(
                expired ? "PROFILE_EXPIRED" : verdict.code ?? "GUARD_FAILED",
                verdict.reason ?? "The signed app failed the free-team guard.",
                fix: "Nothing was installed. The owner runs \(app.resignSteps(device: target.alias)) again.",
                data: ["guard": .string(verdict.code ?? "GUARD_FAILED")])
        }
        return Checked(signed: signed, appPath: appPath, now: now)
    }

    /// The slot preflight: a new app needs a free slot, a reinstall is slot-neutral. "New" is what the device says, not
    /// the ledger (an app installed by hand is a reinstall here). `usedOutside` is the other used records on this device
    /// that the snapshot does not show (`SlotBook.usedOutsideSnapshot`); the app being installed or returned is never in
    /// it, because a return is that slot coming back. The count itself is `AppSnapshot.Usage`.
    func plan(_ checked: Checked, before: AppSnapshot, usedOutside: SlotBook.OutsideUse, profiles: FreeTeamProfiles?) throws -> Plan {
        let reserved = try target.reserved()
        let reinstall = before.ids.contains(target.bundleId)
        let usage = before.usage(prefix: target.prefix, reserved: reserved, outside: usedOutside, profiles: profiles)
        if !reinstall, usage.used >= FreeSlots.limit {
            let basis =
                usage.profilesRead
                ? "other free-team apps found by their installed profiles"
                : "the reserve (the device's profile list could not be read)"
            throw SideloadError(
                "FREE_APP_LIMIT",
                "Our apps, \(basis) and the slots lent to the lab fill \(usage.used) of \(FreeSlots.limit) free-team slots (\(usage.managed) managed, \(usage.unmanaged) other, \(reserved) reserved, \(usage.lent) lent to the lab, \(usage.pending) pending). TestFlight and other developer-built apps are not counted. Nothing was installed.",
                fix: "The owner frees a slot with `sideload app remove`, or lowers `device slots --reserved` if it is higher than the free-profile apps that are not ours.",
                data: ["slots": usage.json(), "reinstall": false])
        }
        return Plan(
            checked: checked, reserved: reserved, before: before, reinstall: reinstall, usage: usage, usedOutside: usedOutside,
            profiles: profiles)
    }

    /// `beforeOp` is the durable intent (W2: the op record); if it throws, the device is untouched. After that nothing
    /// throws: the install's failure, its result for the table of `SlotRule`, and a snapshot taken afterwards (or why it
    /// could not be) come back in the `Outcome`.
    func perform(_ plan: Plan, beforeOp: (() async throws -> Void)? = nil) async throws -> Outcome {
        try await beforeOp?()
        log("install: installing")
        var failure: SideloadError?
        var result = SlotRule.Result.success
        var unnamed = false
        do {
            let out = try await calls.call(["device", "install", "app"], timeoutSec: SlotState.installTimeoutSec, positional: [plan.checked.appPath])
            let classified = calls.classify(.install, out)
            if let classified {
                if classified.code == "INSTALL_UNCONFIRMED" {
                    unnamed = true  // exit 0 without naming the bundle: the snapshot decides
                } else {
                    failure = enriched(classified, out: out, usage: plan.usage)
                }
            }
            // devicectl's own timeout, an overflow, a signal kill and an exit 0 that names nothing are as uncertain as the
            // Runner's timeout.
            result = calls.result(classified, uncertain: calls.uncertain(out, classified) || unnamed)
        } catch {
            failure = (error as? SideloadError) ?? SideloadError("INSTALL_FAILED", "The install did not finish.")
            result = .unknown  // a throw (cancellation included) says nothing about whether the install landed
        }
        log("install: snapshot after")
        let read = await calls.trySnapshot()
        return Outcome(opFailure: failure, result: result, unnamed: unnamed, read: read, bundleId: target.bundleId)
    }

    /// The plain `install`, over the pipeline of `SlotBook`: marker and pin, migrate, the gate, checks, S0, W1 settle,
    /// preflight, the intent (W2: an `install` or `reinstall` op plus this app's `installs[]` metadata), the install, S1, then
    /// W3 applies the table's effect. Throws a `SideloadError` for every stop; returns the output fields on success.
    ///
    /// An install is judged by the table (`SlotRule.confirm`), never by its exit alone and never by presence alone: a
    /// reinstall that ends unknown stays pending whatever S1 shows, because the app was there before it started.
    func execute() async throws -> [String: JSONValue] {
        let app = target.app
        let alias = target.alias
        let now = wholeSeconds(services.clock.now())

        log("install: preflight")
        let identities = try await FreeSession.settle(services, now: now)
        let book = SlotBook(services: services, config: target.config, alias: alias)
        let ledger = try await book.loadMigrated()
        try book.gate(ledger, now: services.clock.now())
        let checked = try await checks(identities: identities, allowLent: false)

        log("install: snapshot before")
        let s0 = await calls.trySnapshot()
        guard let before = s0.snapshot else {
            throw s0.error ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read.")
        }
        // Rule (i) on every record on the device with this snapshot, before slots are counted.
        _ = try await book.settle(before, takenAt: s0.takenAt, point: "install.settle")
        let settledLedger = try services.ledgerStore.load()
        let usedOutside = book.usedOutsideSnapshot(settledLedger, excluding: app.rawValue, snapshot: before)
        let profiles = await calls.freeProfiles()
        let planned = try plan(checked, before: before, usedOutside: usedOutside, profiles: profiles)

        let signed = checked.signed
        let kind: SlotRule.Kind = planned.reinstall ? .reinstall : .install
        // The prior entry is kept so a definite failure can put the ledger back exactly as it was.
        let prior = settledLedger.installs.first { $0.id == target.key }
        let outcome = try await perform(planned) {
            try await book.begin(
                target, kind: kind, by: .install, presence: planned.reinstall ? .present : .absent, since: now, signed: kind == .install ? signed : nil,
                point: "install.intent")
        }
        let confirmation = SlotRule.confirm(kind, outcome.result, outcome.reading)
        let slot = try await book.finish(
            target, effect: confirmation.effect, takenAt: outcome.afterTakenAt, point: "install.final",
            // A first install that did not land puts its intent's entry back. A reinstall wrote no metadata at W2 and writes the
            // new build's only when its install succeeded and the snapshot confirms the app, so a failed or unknown renewal
            // leaves the old copy's profile and expiry exactly as they were.
            restore: kind == .install && confirmation.effect == .absent ? SlotBook.Restore(prior: prior) : nil,
            record: outcome.result == .success ? signed : nil)

        func pendingData(_ base: [String: JSONValue] = [:]) -> [String: JSONValue] {
            var data = base
            data.merge(["uncertain": true, "pending": true, "retryAfter": .number(Double(book.retryAfter(slot)))]) { _, new in new }
            return data
        }
        switch confirmation.effect {
        case .absent:
            // A definite failure and the app is not there: the failure stands (a reinstall that lost the app is a hard stop).
            if confirmation.note == .unexpectedAppDelta {
                throw unexpectedDelta(
                    AppSnapshot.delta(from: before, to: outcome.after ?? before),
                    expectation: "the app is gone after a failed reinstall",
                    extra: ["installed": false, "reinstall": true, "cause": .string(outcome.opFailure?.code ?? "INSTALL_FAILED")])
            }
            throw outcome.opFailure ?? SideloadError("INSTALL_FAILED", "The install did not finish.")
        case .keep:
            if confirmation.note == .installUnconfirmed {
                throw SideloadError(
                    "INSTALL_UNCONFIRMED", "devicectl exited 0 but the app is not on the device.",
                    fix: "The slot reads used while the install may still land; retry in \(book.retryAfter(slot)) seconds (a reinstall is slot-neutral).",
                    data: pendingData())
            }
            if confirmation.note == .unexpectedAppDelta {
                throw unexpectedDelta(
                    AppSnapshot.delta(from: before, to: outcome.after ?? before),
                    expectation: "the app is gone after its reinstall reported success", extra: pendingData(["reinstall": true]))
            }
            if let failure = outcome.opFailure {
                throw SideloadError(
                    failure.code, failure.message,
                    fix: "The install may still land and the slot reads used; retry in \(book.retryAfter(slot)) seconds (a reinstall is slot-neutral).",
                    data: pendingData(failure.data))
            }
            throw SideloadError(
                outcome.after == nil ? "SNAPSHOT_FAILED" : "INSTALL_UNCONFIRMED",
                outcome.after == nil
                    ? "The install's result is not known and the device's app list could not be read afterwards."
                    : "devicectl exited 0 without naming the app and the install is not confirmed.",
                fix: "Unlock the device and retry in \(book.retryAfter(slot)) seconds; the slot reads used meanwhile.",
                data: pendingData())
        case .present:
            // A reinstall that failed definitively while the old copy stays listed is a failure, not a renewal: the slot stays
            // used (P) and the entry keeps the old copy's profile and expiry, so the next refresh still sees it expiring.
            if kind == .reinstall, outcome.result == .failure {
                let failure = outcome.opFailure ?? SideloadError("INSTALL_FAILED", "The reinstall did not finish.")
                var data = failure.data
                data.merge(["reinstall": true, "renewed": false, "installed": false]) { _, new in new }
                throw SideloadError(
                    failure.code, failure.message,
                    fix: failure.fix.map { $0 + " The old copy is still on the device and keeps its old expiry." }
                        ?? "The old copy is still on the device and keeps its old expiry.",
                    data: data)
            }
        }
        guard let after = outcome.after else { throw SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read.") }
        var warnings: [JSONValue] = []
        if outcome.result != .success, let failure = outcome.opFailure {
            warnings.append(
                CanaryCommand.warning(
                    "INSTALL_RESULT_UNCERTAIN",
                    "The install reported a failure (\(failure.code)) but the app is on the device, so it is recorded as installed.",
                    "No action needed."))
        }
        let delta = AppSnapshot.delta(from: before, to: after)
        let expected = planned.reinstall ? delta.isEmpty : (delta.added == [target.bundleId] && delta.removed.isEmpty)
        guard expected else {
            throw unexpectedDelta(
                delta, expectation: planned.reinstall ? "a reinstall should change nothing" : "a first install should add only this app",
                extra: ["installed": true, "recorded": true, "reinstall": .bool(planned.reinstall)])
        }

        let daysLeft = Int((signed.profileExpires.timeIntervalSince(now) / 86_400).rounded(.down))
        return [
            "app": .string(app.rawValue), "device": .string(alias), "bundleId": .string(target.bundleId),
            "version": .string(signed.version), "sha256Prefix": .string(signed.sha256Prefix),
            "installed": true, "reinstall": .bool(planned.reinstall),
            "profile": ["uuid": .string(signed.profileUuid), "daysLeft": .number(Double(daysLeft))],
            "slots": after.usage(prefix: target.prefix, reserved: planned.reserved, outside: usedOutside, profiles: planned.profiles).json(),
            "delta": ["added": .number(Double(delta.added.count)), "removed": .number(Double(delta.removed.count))],
            "warnings": .array(warnings),
        ]
    }

    // MARK: pieces

    /// The failure as an error. installd's own list for `FREE_APP_LIMIT` is reduced (ours by ID, the rest counted) and
    /// is authoritative (installd lists only free-profile apps): it widens `used` and sets `unmanaged`, since the
    /// preflight counts only our apps and the reserve.
    private func enriched(_ failure: FreeInstallFailure, out: FreeDeviceCalls.Outcome, usage: AppSnapshot.Usage) -> SideloadError {
        var error = failure.error
        guard failure.code == "FREE_APP_LIMIT" else { return error }
        var data = error.data
        var used = usage.used
        var unmanaged = usage.unmanaged
        var fix = failure.fix
        if let list = InstalldLimitList.parse(json: out.json, stderr: out.stderr, prefix: target.prefix) {
            used = max(used, list.total)
            unmanaged = max(unmanaged, list.unmanaged)
            data["installdList"] = list.json
            data["unmanagedListed"] = .number(Double(list.unmanaged))
            if list.unmanaged > target.config.devices[target.alias]?.freeSlotsReservedRaw ?? 0 {
                fix += " The device lists \(list.unmanaged) other free-profile app(s): set `device slots --alias \(target.alias) --reserved \(min(list.unmanaged, FreeSlots.limit))` so the preflight counts them."
            }
        }
        data["slots"] = usage.json(used: used, unmanaged: unmanaged)
        error = SideloadError(failure.code, failure.reason, fix: fix, data: data)
        return error
    }
}

extension FreeTarget {
    /// Writes (or replaces) this pair's `installs[]` entry from the `freeSigned` record, in the caller's ledger write. A
    /// manual success clears a suspension and the failure count; the day counters stay. `succeeded` false (the intent,
    /// written before the device call) keeps the refresh state as it was: nothing is known to have succeeded yet.
    func recordInstall(
        into ledger: inout Ledger, signed: LedgerFreeSigned, now: Date, present: Bool, opAt: Date? = nil, succeeded: Bool = true
    ) {
        let created = ledger.freeProfiles.first { $0.id == key && $0.profileUuid == signed.profileUuid }?.created
        var refresh = ledger.installs.first { $0.id == key }?.refresh ?? LedgerInstallRefresh()
        if succeeded {
            refresh.lastAttempt = now
            refresh.lastResult = "installed"
            refresh.lastCode = nil
            refresh.consecutiveFailures = 0
            refresh.nextEligible = nil
            refresh.suspended = false
        }
        let install = LedgerInstall(
            id: key, device: alias, deviceTail: Redactor.tail4(udid), app: app.rawValue, bundleId: signed.bundleId, team: "free",
            profileUuid: signed.profileUuid, profileCreated: created.map(wholeSeconds),
            profileExpires: signed.profileExpires, certFp8: signed.certFp8, version: signed.version,
            sha256Prefix: signed.sha256Prefix, signedAt: signed.signedAt, installedAt: now,
            strippedExtensions: signed.strippedExtensions, droppedEntitlements: signed.droppedEntitlements,
            present: present, refresh: refresh, opAt: opAt)
        ledger.installs.removeAll { $0.id == key }
        ledger.installs.append(install)
        ledger.installs.sort { $0.id < $1.id }
    }

    /// What `sign` left for this device and app, checked: the `freeSigned` record names the one folder `sign` writes for
    /// this bundle ID (`NOT_SIGNED`), the app folder is there, and the profile has not expired (`PROFILE_EXPIRED`). Returns
    /// the record and the app's absolute path. Used by `install` and, before it uninstalls anything, by `slot lend`: an
    /// app that could not be put back must not be taken off the device.
    func requireSigned(_ ledger: Ledger, home: String, now: Date) throws -> (record: LedgerFreeSigned, path: String) {
        let fix = "The owner runs \(app.signStep(device: alias)) first."
        guard let record = ledger.freeSigned.first(where: { $0.id == key }) else {
            throw SideloadError("NOT_SIGNED", "No signed copy of \(app.rawValue) is recorded for this device.", fix: fix)
        }
        // Trusted only as far as it names a signed app `sign` would have written for this bundle ID.
        let folder = "builds/signed/\(app.rawValue)/\(alias)/"
        let name = String(record.path.dropFirst(folder.count))
        guard record.bundleId == bundleId, record.path.hasPrefix(folder), IPAInspector.isPlainName(name),
            !name.hasPrefix("."), name.hasSuffix(".app")
        else {
            throw SideloadError(
                "NOT_SIGNED", "The ledger's record of the signed app is not the one `sign` writes.", fix: fix)
        }
        let path = home + "/" + record.path
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
            throw SideloadError(
                "NOT_SIGNED", "The signed app is gone or is not a plain folder.",
                fix: "The owner runs \(app.signStep(device: alias)) again.")
        }
        if record.profileExpires <= now {
            throw SideloadError(
                "PROFILE_EXPIRED", "The signed app's free profile has expired. Nothing was changed on the device.",
                fix: "The owner runs \(app.resignSteps(device: alias)) again.")
        }
        return (record, path)
    }
}
