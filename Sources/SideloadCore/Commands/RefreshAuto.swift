import Darwin
import Foundation

extension RefreshCommand {
    /// `refresh --auto`: what the launchd agent runs (design section 18). It takes no option: the opted-in devices, the
    /// window (5 days) and the limits are the policy's. Never waits for `.op.lock`; a busy lock, the kill switch, a
    /// suspension or nothing due is `ok:true`.
    public static func runAuto(_ services: Services) async -> Envelope {
        await runAuto(services, steps: RefreshSteps(), timeZone: .current)
    }

    static func runAuto(_ services: Services, steps: RefreshSteps, timeZone: TimeZone) async -> Envelope {
        let context = RefreshAutoContext(
            log: RefreshLog(paths: services.home, clock: services.clock, run: RefreshLog.newRunId()),
            notifier: Notifier(runner: services.runner))
        return await RefreshRun(services: services, steps: steps, timeZone: timeZone, auto: context).executeAuto()
    }
}

extension RefreshRun {
    /// An app that passed the install gates, with the expiry of the copy the owner has (for the log).
    private struct Candidate {
        let target: FreeTarget
        let expires: Date
    }

    /// One opted-in device: the apps that passed the install gates, and what became of the rest.
    private struct DevicePlan {
        let alias: String
        let saved: SavedDevice
        var candidates: [Candidate] = []
        var results: [AppResult] = []
    }

    /// What the phases share.
    private struct AutoState {
        let began: Date
        /// `began` in whole seconds, the "now" of the gates and of every result.
        let start: Date
        let deadline: Date
        var plans: [DevicePlan] = []
        var failures: [RefreshFailure] = []
        var warnings: [JSONValue] = []
        /// Skips of the whole run or of a whole device, by code (the apps' own are counted from their results).
        var runSkips: [String: Int] = [:]
        /// The code that ends the run for every device still to come.
        var runStop: String?
    }

    /// What the gates make of one app.
    private enum Verdict {
        /// Nothing is known about the app on this device, so it is not an install of it and is not listed.
        case unlisted
        case skip(code: String, expires: Date?)
        case renew(RefreshPolicy.Target)
    }

    func executeAuto() async -> Envelope {
        guard let auto else { return .fail(command, code: "INTERNAL_ERROR", message: "refresh --auto was started without its context.") }
        let began = services.clock.now()
        var state = AutoState(
            began: began, start: wholeSeconds(began), deadline: wholeSeconds(began).addingTimeInterval(RefreshPolicy.autoDeadline))

        if let reason = gateRun(&state) { return finish(state, auto, reason: reason) }
        let config: Config
        do {
            config = try services.store.load()
        } catch {
            state.failures.append(RefreshFailure(error: error))
            return finish(state, auto, reason: RefreshPolicy.AutoSkip.configInvalid.code)
        }
        if let reason = planDevices(&state, config, auto) { return finish(state, auto, reason: reason) }

        // Only now, and only if an app is a candidate, ask devicectl once which devices are there.
        var listed: [ListedDevice] = []
        if state.plans.contains(where: { !$0.candidates.isEmpty }) {
            log("auto: reading the device list")
            listed = ((try? await services.deviceCtl.listDevices()) ?? nil) ?? []
        }
        for index in state.plans.indices where !state.plans[index].candidates.isEmpty {
            if let reason = await runDevice(index, &state, config, listed, auto) { return finish(state, auto, reason: reason) }
        }
        return finish(state, auto, reason: nil)
    }

    // MARK: 1. the whole-run gates

    /// The kill switch, the ledger and the lock, cheapest first. A busy lock is a skip, never a wait. Returns the code the run
    /// ends with, or nil to go on.
    private func gateRun(_ state: inout AutoState) -> String? {
        var st = stat()
        // Any answer but "no such file" counts as the switch being there.
        let killSwitch = lstat(services.home.refreshDisabled, &st) == 0 || errno != ENOENT
        var ledgerError: (any Error)?
        var probeError: (any Error)?
        func loadLedger() -> Ledger? {
            do { return try services.ledgerStore.load() } catch {
                ledgerError = error
                return nil
            }
        }
        func lockBusy() -> Bool {
            do {
                try OperationLock.acquire(paths: services.home).release()
                return false
            } catch let error as SideloadError where error.code == OperationLock.busyCode {
                return true
            } catch {
                // Not busy but not free either (the lock file cannot be opened): the gate stops the run, which is a failure.
                probeError = error
                return true
            }
        }
        guard let gate = RefreshPolicy.runGate(killSwitch: killSwitch, ledger: loadLedger(), lockBusy: lockBusy()) else { return nil }
        log("auto: \(gate.code), nothing to do")
        if gate == .ledgerUnreadable, let ledgerError {
            state.failures.append(RefreshFailure(error: ledgerError))
        } else if let probeError {
            state.failures.append(RefreshFailure(error: probeError))
        } else {
            state.runSkips[gate.code] = 1
        }
        return gate.code
    }

    // MARK: 2. the devices and their installs

    /// The opted-in devices and, per install, the gates against the ledger as it is now. Returns a code only when the run ends.
    private func planDevices(_ state: inout AutoState, _ config: Config, _ auto: RefreshAutoContext) -> String? {
        let (eligible, invalid) = RefreshPolicy.autoDevices(config.devices)
        for alias in invalid { skipDevice(alias, .configInvalid, &state, auto) }
        for alias in eligible {
            guard let saved = config.devices[alias] else { continue }
            var plan = DevicePlan(alias: alias, saved: saved)
            do {
                let apps = ProvisionApp.allCases.filter { $0.devicePlatform == saved.platform }
                if apps.isEmpty {
                    skipDevice(alias, .platformMismatch, &state, auto)
                    continue
                }
                let ledger = try freshLedger(now: state.start)
                for app in apps {
                    let target = try FreeTarget.resolve(app: app, alias: alias, config: config)
                    switch verdict(target, ledger, config, presence: .unknown, now: state.start) {
                    case .unlisted: break
                    case .skip(let code, let expires):
                        plan.results.append(skipped(target, code, expires, now: state.start, auto))
                    case .renew(let baseline): plan.candidates.append(Candidate(target: target, expires: baseline.expires))
                    }
                }
            } catch {
                var failure = RefreshFailure(error: error)
                failure.message = "\(RefreshLog.alias(alias)): \(failure.message)"
                state.failures.append(failure)
                if RefreshPolicy.stopsWholeRun(failure.code) {
                    state.plans.append(plan)
                    return failure.code
                }
                continue
            }
            state.plans.append(plan)
        }
        return nil
    }

    /// A device left out as a whole: counted by code and logged, no app of it is listed.
    private func skipDevice(_ alias: String, _ skip: RefreshPolicy.AutoSkip, _ state: inout AutoState, _ auto: RefreshAutoContext) {
        state.runSkips[skip.code, default: 0] += 1
        auto.log.record("install", ["device": .string(alias), "decision": "skip", "reason": .string(skip.code)])
    }

    /// The migrated ledger as it is now.
    private func freshLedger(now: Date) throws -> Ledger {
        SlotRule.migrated(try services.ledgerStore.load(), now: now)
    }

    /// The one path every gate decision takes: the install gates (`RefreshPolicy.autoGate`), then `decide` for what the device's
    /// app list adds. `ledger` is the migrated one.
    private func verdict(
        _ target: FreeTarget, _ ledger: Ledger, _ config: Config, presence: RefreshPolicy.Presence, now: Date
    ) -> Verdict {
        let subject = subject(target.app, ledger, alias: target.alias)
        if subject.install == nil, subject.signed == nil, !subject.lent { return .unlisted }
        let expires = subject.install?.profileExpires ?? subject.signed?.profileExpires
        let pending = SlotBook(services: services, config: config, alias: target.alias).pending(ledger, now: now) != nil
        let attempts = RefreshPolicy.deviceAttempts(
            ledger.installs, device: target.alias, today: RefreshPolicy.dayKey(now, timeZone: timeZone))
        if let skip = RefreshPolicy.autoGate(subject, slotPending: pending, deviceAttempts: attempts, now: now, timeZone: timeZone) {
            return .skip(code: skip.code, expires: expires)
        }
        switch RefreshPolicy.decide(subject, now: now, within: RefreshPolicy.autoWithin, presence: presence) {
        case .renew(let baseline): return .renew(baseline)
        case .skip(let code, let expiry): return .skip(code: code, expires: expiry ?? expires)
        }
    }

    // MARK: 3. one device

    /// The existing path for a device whose installs passed the gates: is it there, the app list, then app by app. Returns a code
    /// only when the run ends.
    private func runDevice(
        _ index: Int, _ state: inout AutoState, _ config: Config, _ listed: [ListedDevice], _ auto: RefreshAutoContext
    ) async -> String? {
        let alias = state.plans[index].alias
        let saved = state.plans[index].saved
        let candidates = state.plans[index].candidates
        state.plans[index].candidates = []
        if let stop = state.runStop {
            for candidate in candidates { state.plans[index].results.append(stopped(candidate, stop, state.start, auto)) }
            return nil
        }
        guard DeviceList.autoEligible(saved, listed: DeviceList.findSaved(listed, matching: saved)) else {
            let skip = RefreshPolicy.AutoSkip.deviceNotVisible.code
            for candidate in candidates {
                state.plans[index].results.append(skipped(candidate.target, skip, candidate.expires, now: state.start, auto))
            }
            return nil
        }

        // The device's app list is read once; an app it does not show is skipped, never put back.
        var presence: [ProvisionApp: RefreshPolicy.Presence] = [:]
        var installBlock: RefreshFailure?
        log("auto: reading the app list of \(RefreshLog.alias(alias))")
        let read = await steps.snapshot(services, alias, candidates[0].target.bundleId)
        if let snapshot = read.snapshot {
            for candidate in candidates {
                presence[candidate.target.app] = snapshot.ids.contains(candidate.target.bundleId) ? .present : .absent
            }
        } else {
            installBlock = RefreshFailure(
                error: read.error ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read."))
        }

        var entries: [Candidate] = []
        do {
            let ledger = try freshLedger(now: state.start)
            for candidate in candidates {
                switch verdict(candidate.target, ledger, config, presence: presence[candidate.target.app] ?? .unknown, now: state.start) {
                case .renew(let baseline): entries.append(Candidate(target: candidate.target, expires: baseline.expires))
                case .skip(let code, let expires):
                    state.plans[index].results.append(skipped(candidate.target, code, expires, now: state.start, auto))
                case .unlisted: break
                }
            }
        } catch {
            state.failures.append(RefreshFailure(error: error))
            return RefreshPolicy.AutoSkip.ledgerUnreadable.code
        }
        entries.sort { ($0.expires, $0.target.app.rawValue) < ($1.expires, $1.target.app.rawValue) }

        var deviceStop: String?
        for entry in entries {
            await renewApp(
                entry, index, &state, config, presence: presence[entry.target.app] ?? .unknown, installBlock: &installBlock,
                deviceStop: &deviceStop, auto)
        }
        return nil
    }

    /// One app of a device: the stops and the deadline, a fresh gate, the renewal, then what it means for the rest.
    private func renewApp(
        _ entry: Candidate, _ index: Int, _ state: inout AutoState, _ config: Config, presence: RefreshPolicy.Presence,
        installBlock: inout RefreshFailure?, deviceStop: inout String?, _ auto: RefreshAutoContext
    ) async {
        let target = entry.target
        if let stop = state.runStop ?? deviceStop {
            state.plans[index].results.append(stopped(entry, stop, state.start, auto))
            return
        }
        if Task.isCancelled {
            let interrupted = RefreshFailure(code: RefreshPolicy.interrupted, message: "The run was interrupted.", fix: nil)
            state.failures.append(interrupted)
            state.runStop = interrupted.code
            state.plans[index].results.append(stopped(entry, interrupted.code, state.start, auto))
            return
        }
        if services.clock.now() >= state.deadline {
            // No new app after the deadline; the next run picks up what is still due. Not an attempt, not a failure.
            state.plans[index].results.append(
                skipped(target, RefreshPolicy.AutoSkip.deadline.code, entry.expires, now: state.start, auto))
            return
        }

        // Each app is gated again against a fresh read: the lab, or this run's own earlier apps, may have changed it.
        let baseline: RefreshPolicy.Target
        do {
            let now = wholeSeconds(services.clock.now())
            switch verdict(target, try freshLedger(now: now), config, presence: presence, now: now) {
            case .renew(let fresh): baseline = fresh
            case .skip(let code, let expires):
                state.plans[index].results.append(skipped(target, code, expires, now: state.start, auto))
                return
            case .unlisted:
                state.plans[index].results.append(skipped(target, RefreshPolicy.AutoSkip.notRecorded.code, nil, now: state.start, auto))
                return
            }
        } catch {
            let failure = RefreshFailure(error: error)
            state.failures.append(failure)
            state.runStop = failure.code
            state.plans[index].results.append(stopped(entry, failure.code, state.start, auto))
            return
        }

        auto.log.record(
            "install",
            [
                "device": .string(target.alias), "app": .string(target.app.rawValue), "decision": "renew",
                "daysLeft": RefreshLog.int(RefreshPolicy.daysLeft(baseline.expires, now: state.start)),
            ])
        let began = services.clock.now()
        var outcome = await renew(target, baseline: baseline, start: state.start, installBlock: &installBlock, warnings: &state.warnings)
        var notified = false
        if outcome.trace.busy {
            // The lab's turn: a logged skip, silent, and the rest of the run (the lock is shared) waits for the next one.
            outcome.status = .skipped
            outcome.failure = nil
            state.runStop = OperationLock.busyCode
        } else {
            notified = await notify(outcome, target, auto: auto)
            if let failure = outcome.failure {
                state.failures.append(failure)
                if RefreshPolicy.stopsWholeRun(failure.code) {
                    state.runStop = failure.code
                } else if RefreshPolicy.isFatal(failure.code) {
                    deviceStop = failure.code
                }
            }
        }
        record(outcome, target, since: began, notified: notified, auto: auto)
        state.plans[index].results.append(outcome)
    }

    // MARK: 4. the envelope and the run line

    private func finish(_ state: AutoState, _ auto: RefreshAutoContext, reason: String?) -> Envelope {
        var tally = state.runSkips
        let all = state.plans.flatMap(\.results)
        for result in all where result.status == .skipped { tally[result.code ?? "UNKNOWN", default: 0] += 1 }
        let renewed = all.filter { $0.status == .renewed || $0.status == .renewedNotInstalled }.count
        let counts = JSONValue.object(tally.mapValues { RefreshLog.int($0) })
        var line: [String: JSONValue] = [
            "ok": .bool(state.failures.isEmpty),
            "durationMs": RefreshLog.int(max(0, Int(services.clock.now().timeIntervalSince(state.began) * 1000))),
            "devices": RefreshLog.int(state.plans.count), "renewed": RefreshLog.int(renewed),
            "failed": RefreshLog.int(state.failures.count), "skipped": counts,
        ]
        if let reason { line["reason"] = .string(reason) }
        auto.log.record("run", line)
        let data: [String: JSONValue] = [
            "auto": true,
            "devices": .array(
                state.plans.map { .object(["alias": .string($0.alias), "results": .array($0.results.map(\.json))]) }),
            "skipped": counts,
            "warnings": .array(state.warnings),
        ]
        return Envelope(
            ok: state.failures.isEmpty, command: command, data: data,
            errors: state.failures.map { .init(code: $0.code, message: $0.message, fix: $0.fix) })
    }

    // MARK: results

    /// A skipped result for an app, logged unless it is the quiet `NOT_DUE`. `stopped` marks a skip that a stop of the device or
    /// the run caused, as against one the app's own gates gave.
    private func skipped(
        _ target: FreeTarget, _ code: String, _ expires: Date?, now: Date, stopped: Bool = false, _ auto: RefreshAutoContext
    ) -> AppResult {
        let result = AppResult.skipped(target.app, code: code, expires: expires, now: now)
        if code != RefreshPolicy.notDue {
            var fields: [String: JSONValue] = [
                "device": .string(target.alias), "app": .string(target.app.rawValue), "decision": "skip", "reason": .string(code),
            ]
            if let days = result.daysLeftBefore { fields["daysLeft"] = RefreshLog.int(days) }
            if stopped { fields["stopped"] = true }
            auto.log.record("install", fields)
        }
        return result
    }

    /// An app left alone because the device or the run stopped with `code`.
    private func stopped(_ entry: Candidate, _ code: String, _ now: Date, _ auto: RefreshAutoContext) -> AppResult {
        skipped(entry.target, code, entry.expires, now: now, stopped: true, auto)
    }

    /// The log line of one renewal attempt, after its step lines.
    private func record(_ result: AppResult, _ target: FreeTarget, since began: Date, notified: Bool, auto: RefreshAutoContext) {
        var fields: [String: JSONValue] = [
            "device": .string(target.alias), "app": .string(target.app.rawValue), "decision": .string(result.status.rawValue),
            "durationMs": RefreshLog.int(max(0, Int(services.clock.now().timeIntervalSince(began) * 1000))),
            "notified": .bool(notified),
        ]
        if let code = result.code { fields["code"] = .string(code) }
        if let days = result.daysLeftAfter ?? result.daysLeftBefore { fields["daysLeft"] = RefreshLog.int(days) }
        if let expires = result.trace.newExpires { fields["newExpires"] = .string(ProgressLog.isoTimestamp(expires)) }
        if let next = result.trace.nextEligible, result.status == .failed {
            fields["nextEligible"] = .string(ProgressLog.isoTimestamp(next))
        }
        if result.trace.newlySuspended { fields["suspended"] = true }
        auto.log.record("result", fields)
    }

    // MARK: notification

    /// Tells the owner how an attempt ended, and when it made the install `suspended`. A cancelled attempt says nothing.
    /// True when the attempt's own notification was delivered.
    private func notify(_ result: AppResult, _ target: FreeTarget, auto: RefreshAutoContext) async -> Bool {
        guard !result.trace.cancelled else { return false }
        let app = target.app.rawValue
        let alias = RefreshLog.alias(target.alias)
        let delivered: Bool
        switch result.status {
        case .renewed, .renewedNotInstalled:
            delivered = await auto.notifier.notify(Notifier.refreshed(app: app, alias: alias, daysLeft: result.daysLeftAfter))
        case .failed:
            delivered = await auto.notifier.notify(
                Notifier.failed(
                    app: app, alias: alias, code: RefreshLog.code(result.code ?? "INTERNAL_ERROR"),
                    next: result.trace.nextEligible.map(clockTime), daysLeft: result.daysLeftBefore))
        case .skipped:
            return false
        }
        if result.trace.newlySuspended {
            _ = await auto.notifier.notify(
                Notifier.suspended(app: app, alias: alias, code: RefreshLog.code(result.code ?? "INTERNAL_ERROR")))
        }
        return delivered
    }

    /// `14:30`, in the run's time zone.
    private func clockTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
