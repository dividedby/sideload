import Foundation

public struct RefreshOptions: Sendable, Equatable {
    public var device: String?
    public var app: String?
    /// Days, as typed (`RefreshPolicy.within` parses it).
    public var within: String?
    public var force: Bool
    /// Owner confirmation; agents must not pass it (the command signs and installs on a real device).
    public var yes: Bool

    public init(device: String? = nil, app: String? = nil, within: String? = nil, force: Bool = false, yes: Bool = false) {
        self.device = device
        self.app = app
        self.within = within
        self.force = force
        self.yes = yes
    }
}

/// What `refresh` calls for each step. The defaults are the real commands, each of which takes `.op.lock` itself, so the
/// lock is held per step and never across the run (a whole-run hold would block the lab for the length of the run, and the
/// steps would conflict with it). Tests replace them.
struct RefreshSteps: Sendable {
    var provision: @Sendable (Services, ProvisionOptions) async -> Envelope = { await ProvisionCommand.run($0, $1) }
    var sign: @Sendable (Services, SignOptions) async -> Envelope = { await SignCommand.run($0, $1) }
    var install: @Sendable (Services, InstallOptions) async -> Envelope = { await InstallCommand.run($0, $1) }
    /// The device's app list (read-only), for the apps that need the device's word that they are there.
    var snapshot: @Sendable (Services, _ alias: String, _ bundleId: String) async -> FreeDeviceCalls.SnapshotRead = {
        services, alias, bundleId in
        await FreeDeviceCalls(services: services, alias: alias, bundleId: bundleId).trySnapshot()
    }
}

/// `refresh --device <alias> [--app <a>] [--within <days>] [--force] --yes`: renews the free-team installs on one saved
/// device that have `--within` days or fewer left (default 5, at most 6), by running `provision`, `sign` and `install`
/// for each (design section 18). It never installs an app the device does not already have, and a lent app gets
/// provision and sign only. A renewal uses no new App ID: `provision` runs without `--renew` first and only a
/// `PROFILE_NOT_RENEWED` is retried once with it; `appIdNew` says per app whether an App ID was spent.
///
/// Owner-run (`--yes`). Each step takes `.op.lock` itself and a busy lock is `OPERATION_IN_PROGRESS` for that app (never
/// waited on). The run makes no ledger write of its own except the per-install refresh fields; it never changes `slots`.
public enum RefreshCommand {
    static let command = "refresh"

    /// The most days `--within` takes (the CLI's help text reads it).
    public static let maxWithin = RefreshPolicy.maxWithin

    public static func run(_ services: Services, _ options: RefreshOptions) async -> Envelope {
        await run(services, options, steps: RefreshSteps(), timeZone: .current)
    }

    static func run(_ services: Services, _ options: RefreshOptions, steps: RefreshSteps, timeZone: TimeZone) async -> Envelope {
        do {
            return try await RefreshRun(services: services, options: options, steps: steps, timeZone: timeZone).execute()
        } catch {
            var envelope = Envelope.from(error, command: command)
            if let alias = options.device, !alias.isEmpty, envelope.data["device"] == nil, DeviceCommand.isValidAlias(alias) {
                var data = envelope.data
                data["device"] = .string(alias)
                envelope = Envelope(ok: false, command: command, data: data, errors: envelope.errors)
            }
            return envelope
        }
    }
}

/// One failure, as an `errors[]` entry and the `code` of an app's result.
private struct RefreshFailure {
    var code: String
    var message: String
    var fix: String?
    var retryAfter: Double?

    init(code: String, message: String, fix: String?, retryAfter: Double? = nil) {
        self.code = code
        self.message = message
        self.fix = fix
        self.retryAfter = retryAfter
    }

    init(error: any Error) {
        self.init(Envelope.from(error, command: RefreshCommand.command))
    }

    /// The message led by the app it is about (the `errors[]` entries of a run name their app).
    func naming(_ app: ProvisionApp) -> RefreshFailure {
        var named = self
        named.message = "\(app.rawValue): \(message)"
        return named
    }

    init(_ envelope: Envelope) {
        let entry = envelope.errors.first
        code = entry?.code ?? "INTERNAL_ERROR"
        message = entry?.message ?? "A step failed without saying why."
        fix = entry?.fix
        if case .number(let seconds)? = envelope.data["retryAfter"] { retryAfter = seconds }
    }
}

private enum Step: String, CaseIterable {
    case provision, sign, install
}

private enum StepState: String {
    case done, skipped, failed
}

/// A `results[].status` of `refresh`; the menu reads the same values.
enum RefreshResultStatus: String {
    case renewed, renewedNotInstalled = "renewed-not-installed", skipped, failed
}

/// What one app ended as. `failure` is set exactly when `status` is `failed`.
private struct AppResult {
    typealias Status = RefreshResultStatus

    let app: ProvisionApp
    var status: Status
    var steps: [Step: StepState] = [:]
    var code: String?
    var daysLeftBefore: Int?
    var daysLeftAfter: Int?
    var appIdNew: Bool?
    var appIdsLast7Days: Int?
    var renewRetried = false
    var renew: [String: JSONValue] = [:]
    var failure: RefreshFailure?

    /// A policy or consequence skip: nothing was run for the app.
    static func skipped(_ app: ProvisionApp, code: String, expires: Date?, now: Date) -> AppResult {
        var result = AppResult(app: app, status: .skipped)
        result.code = code
        result.daysLeftBefore = expires.map { RefreshPolicy.daysLeft($0, now: now) }
        return result
    }

    /// The app failed before any step ran.
    func failing(_ failure: RefreshFailure) -> AppResult {
        var result = self
        result.code = failure.code
        result.failure = failure
        return result
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["app": .string(app.rawValue), "status": .string(status.rawValue)]
        if !steps.isEmpty {
            object["steps"] = .object(Dictionary(uniqueKeysWithValues: steps.map { ($0.key.rawValue, JSONValue.string($0.value.rawValue)) }))
        }
        if let code { object["code"] = .string(code) }
        if let daysLeftBefore { object["daysLeftBefore"] = .number(Double(daysLeftBefore)) }
        if let daysLeftAfter { object["daysLeftAfter"] = .number(Double(daysLeftAfter)) }
        if let appIdNew { object["appIdNew"] = .bool(appIdNew) }
        if let appIdsLast7Days { object["appIdsLast7Days"] = .number(Double(appIdsLast7Days)) }
        if steps[.provision] != nil { object["renewRetried"] = .bool(renewRetried) }
        if !renew.isEmpty { object["renew"] = .object(renew) }
        if let retry = failure?.retryAfter { object["retryAfter"] = .number(retry) }
        return .object(object)
    }
}

private struct RefreshRun {
    let services: Services
    let options: RefreshOptions
    let steps: RefreshSteps
    let timeZone: TimeZone

    private var command: String { RefreshCommand.command }

    private func log(_ message: String) { services.log("refresh: " + message) }

    func execute() async throws -> Envelope {
        guard let alias = options.device, !alias.isEmpty else {
            throw SideloadError(
                "USAGE", "refresh needs --device <alias>.",
                fix: "sideload refresh --device iphone [--app <app>] [--within 1-\(RefreshPolicy.maxWithin) | --force] --yes")
        }
        let within = try RefreshPolicy.within(options.within, force: options.force)
        let config = try services.store.load()
        let targets = try Self.targets(app: options.app, alias: alias, config: config)
        guard options.yes else {
            throw SideloadError(
                "CONFIRM_REQUIRED",
                "refresh re-signs and reinstalls the apps on the saved device that are close to expiring, with the free team's key and a free-team slot's worth of device changes.",
                fix: "The owner confirms by re-running with --yes. Agents must not pass --yes on their own.",
                data: ["device": .string(alias)])
        }

        // Stops that need no work, read-only: a suspension and a pending slot operation.
        let record = ProvisionCommand.RenewRecord.read(services)
        ProvisionCommand.registerInterruptReport(services, record: record)
        let start = wholeSeconds(services.clock.now())
        let ledger = try services.ledgerStore.load()
        if let suspension = ledger.freeSuspended {
            throw SideloadError(
                suspension.code == "IDENTITY_CHECK_FAILED" ? "IDENTITY_CHECK_FAILED" : "FREE_CERT_CHANGED",
                "The free team's signing identities changed earlier (\(suspension.addedFp8.count) added, \(suspension.removedFp8.count) removed), so refresh does nothing.",
                fix: "The owner checks Xcode > Settings > Accounts > Manage Certificates, atvloadly and the lab, then runs `sideload provision` by hand; a successful one clears the suspension. refresh never clears it.",
                data: ["suspended": true, "device": .string(alias)])
        }
        let book = SlotBook(services: services, config: config, alias: alias)
        let migrated = SlotRule.migrated(ledger, now: start)
        if let (slot, left) = book.pending(migrated, now: start) {
            throw SlotBook.pendingError(slot, retryAfter: left, extra: ["device": .string(alias)])
        }

        // The device's app list is read once, and only if an app that is not lent could be due.
        var subjects: [ProvisionApp: RefreshPolicy.Subject] = [:]
        for target in targets { subjects[target.app] = subject(target.app, migrated, alias: alias) }
        let optimistic = targets.map {
            RefreshPolicy.decide(subjects[$0.app]!, now: start, within: within, presence: .present)
        }
        var presence: [ProvisionApp: RefreshPolicy.Presence] = [:]
        var snapshotFailure: SideloadError?
        let needsSnapshot = optimistic.contains { if case .renew(let t) = $0 { return !t.lent } else { return false } }
        if needsSnapshot, let first = targets.first {
            log("reading the device's app list")
            let read = await steps.snapshot(services, alias, first.bundleId)
            if let snapshot = read.snapshot {
                for target in targets { presence[target.app] = snapshot.ids.contains(target.bundleId) ? .present : .absent }
            } else {
                snapshotFailure = read.error ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read.")
            }
        }
        var entries: [(target: FreeTarget, decision: RefreshPolicy.Decision)] = targets.map { target in
            (
                target,
                RefreshPolicy.decide(
                    subjects[target.app]!, now: start, within: within, presence: presence[target.app] ?? .unknown)
            )
        }
        // An app nothing is known about is not listed, unless it was named.
        if options.app == nil {
            entries.removeAll { $0.decision == .skip(code: "NOT_INSTALLED", expires: nil) }
        }
        entries.sort { lhs, rhs in
            (Self.expiry(lhs.decision) ?? .distantFuture, lhs.target.app.rawValue)
                < (Self.expiry(rhs.decision) ?? .distantFuture, rhs.target.app.rawValue)
        }

        var results: [AppResult] = []
        var failures: [RefreshFailure] = []
        var warnings: [JSONValue] = []
        var stop: RefreshFailure?
        // Provision and sign do not need the device; once it is known to be unavailable the installs are skipped.
        var installBlock = snapshotFailure.map { RefreshFailure(error: $0) }
        for (target, decision) in entries {
            switch decision {
            case .skip(let code, let expires):
                results.append(.skipped(target.app, code: code, expires: expires, now: start))
            case .renew(let baseline):
                if let stop {
                    results.append(.skipped(target.app, code: stop.code, expires: baseline.expires, now: start))
                    continue
                }
                if Task.isCancelled {
                    // A due app left unrenewed is a failure, so a run cancelled before any failure is still `ok:false`.
                    let interrupted = RefreshFailure(code: "INTERRUPTED", message: "The run was interrupted.", fix: nil)
                    failures.append(interrupted)
                    stop = interrupted
                    results.append(.skipped(target.app, code: "INTERRUPTED", expires: baseline.expires, now: start))
                    continue
                }
                let outcome = await renew(target, baseline: baseline, start: start, installBlock: &installBlock, warnings: &warnings)
                results.append(outcome)
                if let failure = outcome.failure {
                    failures.append(failure)
                    if RefreshPolicy.isFatal(failure.code) { stop = failure }
                }
            }
        }

        let renewed = results.filter { $0.status == .renewed || $0.status == .renewedNotInstalled }.count
        let skipped = results.filter { $0.status == .skipped }.count
        let live = (try? services.ledgerStore.load()).map {
            FreeAppIdBudget.live($0.freeAppIds, now: services.clock.now()).count
        }
        var data: [String: JSONValue] = [
            "device": .string(alias), "within": .number(Double(within)), "force": .bool(options.force),
            "results": .array(results.map(\.json)),
            "renewed": .number(Double(renewed)), "failed": .number(Double(failures.count)),
            "skipped": .number(Double(skipped)), "warnings": .array(warnings),
        ]
        if let live { data["appIdsLast7Days"] = .number(Double(live)) }
        // The cached profiles an earlier `provision --renew` run left in tmp/ (this run's own are in each app's `renew`).
        data.merge(record.json) { _, new in new }
        return Envelope(
            ok: failures.isEmpty, command: command, data: data,
            errors: failures.map { .init(code: $0.code, message: $0.message, fix: $0.fix) })
    }

    // MARK: selection

    private static func expiry(_ decision: RefreshPolicy.Decision) -> Date? {
        switch decision {
        case .renew(let target): target.expires
        case .skip(_, let expires): expires
        }
    }

    /// The saved device and the apps to look at: the one `--app`, else every app that runs on the device's platform.
    private static func targets(app appName: String?, alias: String, config: Config) throws -> [FreeTarget] {
        if let appName, !appName.isEmpty {
            return [try FreeTarget.resolve(app: try FreeTarget.parseApp(appName), alias: alias, config: config)]
        }
        let device = try config.requireDevice(alias)
        let apps = ProvisionApp.allCases.filter { $0.devicePlatform == device.platform }
        guard !apps.isEmpty else {
            throw SideloadError(
                "PLATFORM_MISMATCH", "The saved device is \(device.platform ?? "of unknown platform"), which none of our apps run on.",
                fix: "Re-save it: sideload device save --alias <alias> --match <device name> --platform ios|tvos --yes")
        }
        return try apps.map { try FreeTarget.resolve(app: $0, alias: alias, config: config) }
    }

    private func subject(_ app: ProvisionApp, _ ledger: Ledger, alias: String) -> RefreshPolicy.Subject {
        let key = "\(alias)/\(app.rawValue)"
        return RefreshPolicy.Subject(
            app: app, install: ledger.installs.first { $0.id == key }, signed: ledger.freeSigned.first { $0.id == key },
            profile: ledger.freeProfiles.first { $0.id == key },
            lent: ledger.slots.contains { $0.id == key && $0.lentTo != nil })
    }

    // MARK: one app

    private func renew(
        _ target: FreeTarget, baseline: RefreshPolicy.Target, start: Date, installBlock: inout RefreshFailure?,
        warnings: inout [JSONValue]
    ) async -> AppResult {
        let app = target.app
        let alias = target.alias
        var result = AppResult(app: app, status: .failed)
        result.daysLeftBefore = RefreshPolicy.daysLeft(baseline.expires, now: start)

        // The attempt is written before the first step, so a run that dies in the middle still counts.
        let attemptAt = wholeSeconds(services.clock.now())
        do {
            let before = try services.ledgerStore.load()
            warnings.append(contentsOf: Self.counterWarnings(before, target: target, now: attemptAt, timeZone: timeZone))
            let (zone, key) = (timeZone, target.key)
            try await services.ledgerStore.update { ledger in
                guard let index = ledger.installs.firstIndex(where: { $0.id == key }) else { return }
                ledger.installs[index].refresh = RefreshPolicy.counting(ledger.installs[index].refresh, now: attemptAt, timeZone: zone)
            }
        } catch {
            return result.failing(RefreshFailure(error: error).naming(app))
        }

        var failure: RefreshFailure?
        var done = 0
        let plan: RefreshPolicy.StepPlan
        do {
            let ledger = SlotRule.migrated(try services.ledgerStore.load(), now: attemptAt)
            plan = RefreshPolicy.steps(subject(app, ledger, alias: alias), target: baseline)
        } catch {
            return result.failing(RefreshFailure(error: error).naming(app))
        }
        result.steps = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, StepState.skipped) })
        log("\(app.rawValue): provision=\(plan.provision) sign=\(plan.sign) install=\(plan.install)")

        // provision, without --renew first: a renewal that Xcode makes by itself spends no App ID. Only a profile that did
        // not move is retried, once, with the renewal of our own cached copy.
        if plan.provision {
            var envelope = await steps.provision(services, ProvisionOptions(app: app.rawValue, device: alias, yes: true))
            if !envelope.ok, envelope.errors.first?.code == "PROFILE_NOT_RENEWED" {
                result.renewRetried = true
                log("\(app.rawValue): the profile did not move; retrying once with --renew")
                envelope = await steps.provision(services, ProvisionOptions(app: app.rawValue, device: alias, renew: true, yes: true))
            }
            for key in ProfileCacheRenewal.Outcome.keys {
                if let value = envelope.data[key] { result.renew[key] = value }
            }
            if envelope.ok {
                result.steps[.provision] = .done
                done += 1
                if case .bool(let isNew)? = envelope.data["appIdNew"] { result.appIdNew = isNew }
            } else {
                result.steps[.provision] = .failed
                failure = RefreshFailure(envelope)
            }
        }
        if result.appIdNew == nil { result.appIdNew = false }

        if failure == nil, plan.sign {
            let envelope = await steps.sign(services, SignOptions(app: app.rawValue, device: alias, yes: true))
            if envelope.ok {
                result.steps[.sign] = .done
                done += 1
            } else {
                result.steps[.sign] = .failed
                failure = RefreshFailure(envelope)
            }
        }

        if failure == nil, plan.install {
            if let block = installBlock {
                // The device is not available: the rerun resumes at the install, because provision and sign are done.
                failure = RefreshFailure(
                    code: block.code, message: "The install was skipped: \(block.message)",
                    fix: "Unlock the device and keep it connected (or reconnect it), then rerun `sideload refresh --device \(alias) --app \(app.rawValue) --yes`; the rerun resumes at the install.")
            } else {
                let envelope = await steps.install(services, InstallOptions(app: app.rawValue, device: alias, yes: true))
                if envelope.ok {
                    result.steps[.install] = .done
                    done += 1
                } else {
                    result.steps[.install] = .failed
                    let failed = RefreshFailure(envelope)
                    failure = failed
                    if RefreshPolicy.deviceUnavailableCodes.contains(failed.code) { installBlock = failed }
                }
            }
        }

        // What the run did to the ledger's refresh fields, and the numbers after.
        let finished = services.clock.now()
        let outcome: RefreshPolicy.Result
        if let failure {
            result.code = failure.code
            result.failure = failure.naming(app)
            if Task.isCancelled, RefreshPolicy.isCancellation(failure.code) {
                // The menu's Cancel (the CLI is stopped by signals instead): a step that died with the task is not a failure
                // of the app, so it is neither counted nor backed off.
                result.code = "INTERRUPTED"
                outcome = .cancelled
            } else {
                outcome = failure.code == "OPERATION_IN_PROGRESS" && done == 0 ? .busy : .failed(code: failure.code)
            }
        } else {
            result.status = baseline.lent ? .renewedNotInstalled : .renewed
            outcome = baseline.lent ? .renewedNotInstalled : .refreshed
            if baseline.lent {
                warnings.append(
                    CanaryCommand.warning(
                        "APP_LENT",
                        "\(app.rawValue) is lent to the lab, so it was provisioned and signed but not installed.",
                        "Nothing to do: `slot return` puts the renewed copy back.").withApp(app))
            }
        }
        if let ledger = try? services.ledgerStore.load() {
            let key = target.key
            if failure == nil {
                // What the owner has now: the device copy, or for a lent app the signed copy that will go back.
                let installed = ledger.installs.first { $0.id == key }?.profileExpires
                let signed = ledger.freeSigned.first { $0.id == key }?.profileExpires
                if let expires = baseline.lent ? signed : (installed ?? signed) {
                    result.daysLeftAfter = RefreshPolicy.daysLeft(expires, now: finished)
                }
            }
            result.appIdsLast7Days = FreeAppIdBudget.live(ledger.freeAppIds, now: finished).count
        }
        do {
            let (zone, key) = (timeZone, target.key)
            let stamp = wholeSeconds(finished)
            try await services.ledgerStore.update { ledger in
                guard let index = ledger.installs.firstIndex(where: { $0.id == key }) else { return }
                ledger.installs[index].refresh = RefreshPolicy.applying(
                    outcome, to: ledger.installs[index].refresh, now: stamp, timeZone: zone)
            }
        } catch {
            warnings.append(
                CanaryCommand.warning(
                    "REFRESH_STATE_NOT_RECORDED",
                    "The refresh fields of \(app.rawValue) could not be written to the ledger (\(RefreshFailure(error: error).code)).",
                    "The renewal itself is not affected; `sideload doctor` shows whether the ledger is writable.").withApp(app))
        }
        return result
    }

    /// Cap and suspension notices for a manual run: the caps bind the future auto-refresh, not this run.
    private static func counterWarnings(_ ledger: Ledger, target: FreeTarget, now: Date, timeZone: TimeZone) -> [JSONValue] {
        guard let install = ledger.installs.first(where: { $0.id == target.key }) else { return [] }
        var warnings: [JSONValue] = []
        let today = RefreshPolicy.dayKey(now, timeZone: timeZone)
        let mine = install.refresh.attemptsByDay[today] ?? 0
        let device = RefreshPolicy.deviceAttempts(ledger.installs, device: target.alias, today: today)
        if mine >= RefreshPolicy.installDailyCap || device >= RefreshPolicy.deviceDailyCap {
            warnings.append(
                CanaryCommand.warning(
                    "ATTEMPT_CAP_EXCEEDED",
                    "\(target.app.rawValue) has had \(mine) attempt(s) today (\(device) on the device); the daily caps are \(RefreshPolicy.installDailyCap) per app and \(RefreshPolicy.deviceDailyCap) per device.",
                    "A manual run goes on and counts as an attempt; the caps only hold back the automatic refresh.").withApp(target.app))
        }
        if install.refresh.suspended {
            warnings.append(
                CanaryCommand.warning(
                    "INSTALL_SUSPENDED",
                    "\(target.app.rawValue) was suspended after \(install.refresh.lastCode ?? "an earlier failure"); this manual run goes on.",
                    "A successful run clears the suspension.").withApp(target.app))
        }
        return warnings
    }
}

extension JSONValue {
    /// A warning object with the app it is about.
    fileprivate func withApp(_ app: ProvisionApp) -> JSONValue {
        guard case .object(var object) = self else { return self }
        object["app"] = .string(app.rawValue)
        return .object(object)
    }
}
