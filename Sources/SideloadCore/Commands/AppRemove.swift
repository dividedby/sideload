import Foundation

public struct AppOptions: Sendable, Equatable {
    /// The subcommand after `app` (only `remove`).
    public var sub: String?
    public var app: String?
    public var device: String?
    /// Owner confirmation; agents must not pass it.
    public var yes: Bool

    public init(sub: String? = nil, app: String? = nil, device: String? = nil, yes: Bool = false) {
        self.sub = sub
        self.app = app
        self.device = device
        self.yes = yes
    }
}

/// One uninstall of a free-team app we manage, with the device calls around it. Shared by `app remove` and `slot lend`.
/// `.op.lock` is held by the caller, which also owns the before snapshot and every ledger write (`SlotBook`): this type
/// never decides what an uninstall did.
struct FreeRemoval: Sendable {
    let services: Services
    let target: FreeTarget

    /// What the uninstall did, as data: it never throws for a device outcome.
    struct Outcome: Sendable {
        /// The uninstall reported a failure (classified). A failure alone decides nothing; the table of `SlotRule` does.
        var opFailure: SideloadError?
        /// The call's result as the table reads it: `unknown` for every shape of `FreeDeviceCalls.uncertain`.
        var result: SlotRule.Result
        var read: FreeDeviceCalls.SnapshotRead

        var after: AppSnapshot? { read.snapshot }
        var afterError: SideloadError? { read.error }
        var afterTakenAt: Date { read.takenAt }
        var reading: SlotRule.Reading { SlotRule.Reading(read.snapshot, bundleId: bundleId) }
        let bundleId: String
    }

    /// Runs `beforeOp` (the durable intent; if it throws the device is untouched), uninstalls, and takes the snapshot
    /// after. The only throw is `beforeOp`'s.
    func perform(beforeOp: (() async throws -> Void)? = nil) async throws -> Outcome {
        let calls = FreeDeviceCalls(services: services, alias: target.alias, bundleId: target.bundleId)
        try await beforeOp?()
        services.log("uninstalling")
        let (failure, result) = await calls.uninstall()
        let read = await calls.trySnapshot()
        return Outcome(opFailure: failure, result: result, read: read, bundleId: target.bundleId)
    }

    /// True unless something known to keep the developer's trust stays: our other `<prefix>.free.*` installs or an app of a
    /// known free-team signer (WebDriverAgent, SideStore). The reserve and unflagged developer-signed apps do not count:
    /// this errs on the side of warning. The menu snapshot uses it too, for the Remove confirm's trust warning.
    static func isLastFreeApp(bundleId: String, in snapshot: AppSnapshot, prefix: String?) -> Bool {
        let managedOthers = snapshot.managedIds(prefix: prefix).filter { $0 != bundleId }.count
        let signers = snapshot.ids.filter { !Config.isFreeBundleId($0, prefix: prefix) && FreeTeamSigner.label(of: $0) != nil }.count
        return managedOthers + signers == 0
    }
}

/// `app remove --app <a> --device <d> --yes`: uninstalls one sideload-managed install to free a slot (design section 18).
/// Owner-only. Allowlisted to `<prefix>.free.*` (the bundle ID is derived from the app key, so nothing else can be named),
/// takes the shared lock, settles the crash-safe marker, then records an `uninstall` op (written before the device call)
/// that the table of `SlotRule` settles. Never touches anything else on the device.
public enum AppCommand {
    static let command = "app remove"

    public static func run(_ services: Services, _ options: AppOptions) async -> Envelope {
        guard options.sub == "remove" else {
            return .fail(
                "app", code: "USAGE", message: "Unknown app subcommand \"\(printableCut(options.sub ?? ""))\".",
                fix: "Use `sideload app remove --app <app> --device <alias> --yes`.")
        }
        let target: FreeTarget
        do {
            target = try FreeTarget.resolve(
                app: options.app, device: options.device, services: services,
                usageFix: "sideload app remove --app <\(ProvisionApp.names.joined(separator: "|"))> --device iphone --yes")
        } catch {
            return .from(error, command: command)
        }
        guard options.yes else {
            return .fail(
                command, code: "CONFIRM_REQUIRED",
                message: "app remove uninstalls \(target.app.rawValue) from the saved device (its data goes with it).",
                fix: "The owner confirms by re-running with --yes. Agents must not pass --yes on their own.",
                data: target.identity)
        }
        do {
            let lock = try OperationLock.acquire(paths: services.home)
            defer { lock.release() }
            return try await remove(services, target)
        } catch let error as SideloadError {
            var data = target.identity
            data.merge(error.data) { _, new in new }
            return .fail(command, code: error.code, message: error.message, fix: error.fix, data: data)
        } catch {
            return .from(error, command: command)
        }
    }

    /// The pipeline of `SlotBook`: marker and keychain, migrate, the gate (any op in flight on the device is `SLOT_PENDING`),
    /// snapshot S0, W1 settle, the intent (W2, an `uninstall` op), the uninstall, snapshot S1, then W3 applies the table's
    /// effect: absent is removed, present is the failure, and anything else keeps the op pending.
    private static func remove(_ services: Services, _ target: FreeTarget) async throws -> Envelope {
        let now = wholeSeconds(services.clock.now())
        _ = try await FreeSession.settle(services, now: now)
        let book = SlotBook(services: services, config: target.config, alias: target.alias)
        let ledger = try await book.loadMigrated()
        try book.gate(ledger, now: services.clock.now(), extra: ["removed": false])
        let calls = FreeDeviceCalls(services: services, alias: target.alias, bundleId: target.bundleId)
        let removal = FreeRemoval(services: services, target: target)

        let s0 = await calls.trySnapshot()
        guard let before = s0.snapshot else {
            throw s0.error ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read.")
        }
        // Rule (i) on every record on the device, so the ledger reads what S0 shows before the uninstall can change anything.
        _ = try await book.settle(before, takenAt: s0.takenAt, point: "remove.settle")
        guard before.ids.contains(target.bundleId) else {
            var data = target.identity
            data["removed"] = false
            data["wasPresent"] = false
            data["warnings"] = []
            return .result(command, data)
        }

        let profiles = await calls.freeProfiles()
        let outcome = try await removal.perform {
            try await book.begin(
                target, kind: .uninstall, by: .remove, presence: .present, since: now, point: "remove.intent")
        }
        let confirmation = SlotRule.confirm(.uninstall, outcome.result, outcome.reading)
        let slot = try await book.finish(
            target, effect: confirmation.effect, takenAt: outcome.afterTakenAt, point: "remove.final")

        switch confirmation.effect {
        case .present:
            // A definite failure and the app is still there.
            if let failure = outcome.opFailure { throw failure }
            throw unexpectedDelta(
                AppSnapshot.delta(from: before, to: outcome.after ?? before),
                expectation: "the app is still on the device after its uninstall reported success", extra: ["uninstalled": false])
        case .keep:
            // Nothing is claimed either way: the op stays pending until its window ends.
            var data = outcome.opFailure?.data ?? [:]
            data.merge(["uncertain": true, "retryAfter": .number(Double(book.retryAfter(slot))), "removed": false]) { _, new in new }
            if let failure = outcome.opFailure {
                throw SideloadError(
                    failure.code, failure.message,
                    fix: "The uninstall may still finish and the slot reads used; retry `sideload app remove` in \(book.retryAfter(slot)) seconds.",
                    data: data)
            }
            if confirmation.note == .unexpectedAppDelta {
                data["uninstalled"] = false
                throw unexpectedDelta(
                    AppSnapshot.delta(from: before, to: outcome.after ?? before),
                    expectation: "the app is still on the device after its uninstall reported success", extra: data)
            }
            throw SideloadError(
                "UNINSTALL_RESULT_UNCERTAIN",
                "The uninstall reported success, but the device's app list could not be read afterwards, so it is not known whether the app is gone.",
                fix: "The slot reads used. Retry `sideload app remove` in \(book.retryAfter(slot)) seconds, when the device is awake.",
                data: data)
        case .absent:
            break
        }
        let after = outcome.after ?? before
        let delta = AppSnapshot.delta(from: before, to: after)
        if delta.removed != [target.bundleId] || !delta.added.isEmpty {
            throw unexpectedDelta(delta, expectation: "an uninstall should remove only this app", extra: ["uninstalled": true])
        }

        var warnings: [JSONValue] = []
        if outcome.result != .success {
            warnings.append(
                CanaryCommand.warning(
                    "UNINSTALL_RESULT_UNCERTAIN",
                    "The uninstall's result was not certain\(outcome.opFailure.map { " (\($0.code))" } ?? ""), but the app is no longer on the device, so it is recorded as removed.",
                    "No action needed."))
        }
        if FreeRemoval.isLastFreeApp(bundleId: target.bundleId, in: before, prefix: target.prefix) {
            warnings.append(
                CanaryCommand.warning(
                    "LAST_FREE_APP_REMOVED",
                    "No other free-team app is on this device, so removing \(target.app.rawValue) clears the developer trust: the next app needs trusting again.",
                    "After the next install: Settings › General › VPN & Device Management › trust the developer."))
        }
        var data = target.identity
        data["removed"] = true
        data["wasPresent"] = true
        data["warnings"] = .array(warnings)
        let outside = book.usedOutsideSnapshot(
            (try? services.ledgerStore.load()) ?? ledger, excluding: target.app.rawValue, snapshot: after)
        data["slots"] = slots(after, target, outside: outside, profiles: profiles)
        return .result(command, data)
    }

    private static func slots(
        _ after: AppSnapshot, _ target: FreeTarget, outside: SlotBook.OutsideUse, profiles: FreeTeamProfiles?
    ) -> JSONValue {
        // An out-of-range stored reserve leaves the count unknown (as in `status`), never computed from a guessed 0.
        guard let reserved = try? target.reserved() else { return AppSnapshot.Usage.unknownJSON }
        return after.usage(prefix: target.prefix, reserved: reserved, outside: outside, profiles: profiles).json()
    }
}
