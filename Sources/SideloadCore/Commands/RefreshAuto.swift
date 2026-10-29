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
        let run = RefreshRun(services: services, options: RefreshOptions(), steps: steps, timeZone: timeZone, mode: .auto(context))
        return await run.executeAuto(context)
    }
}

extension RefreshRun {
    /// One opted-in device: the apps that passed the install gates, and what became of the rest.
    private struct DevicePlan {
        let alias: String
        let saved: SavedDevice
        var candidates: [FreeTarget] = []
        var results: [AppResult] = []
    }

    func executeAuto(_ auto: RefreshAutoContext) async -> Envelope {
        let began = services.clock.now()
        let start = wholeSeconds(began)
        let deadline = start.addingTimeInterval(RefreshPolicy.autoDeadline)
        var plans: [DevicePlan] = []
        var failures: [RefreshFailure] = []
        var warnings: [JSONValue] = []
        var runSkips: [String: Int] = [:]

        func finish(reason: String? = nil) -> Envelope {
            var tally = runSkips
            for result in plans.flatMap(\.results) where result.status == .skipped {
                tally[result.code ?? "UNKNOWN", default: 0] += 1
            }
            let all = plans.flatMap(\.results)
            let renewed = all.filter { $0.status == .renewed || $0.status == .renewedNotInstalled }.count
            var line: [String: JSONValue] = [
                "ok": .bool(failures.isEmpty), "durationMs": RefreshLog.int(max(0, Int(services.clock.now().timeIntervalSince(began) * 1000))),
                "devices": RefreshLog.int(plans.count), "renewed": RefreshLog.int(renewed), "failed": RefreshLog.int(failures.count),
                "skipped": .object(tally.mapValues { RefreshLog.int($0) }),
            ]
            if let reason { line["reason"] = .string(RefreshLog.code(reason)) }
            auto.log.record("run", line)
            let data: [String: JSONValue] = [
                "auto": true,
                "devices": .array(
                    plans.map { .object(["alias": .string($0.alias), "results": .array($0.results.map(\.json))]) }),
                "skipped": .object(tally.mapValues { RefreshLog.int($0) }),
                "warnings": .array(warnings),
            ]
            return Envelope(
                ok: failures.isEmpty, command: command, data: data,
                errors: failures.map { .init(code: $0.code, message: $0.message, fix: $0.fix) })
        }

        // 1-3. The whole-run gates, cheapest first: the kill switch, the ledger, the lock. A busy lock is a skip, never a wait.
        var st = stat()
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
                probeError = error
                return true
            }
        }
        if let gate = RefreshPolicy.runGate(killSwitch: killSwitch, ledger: loadLedger(), lockBusy: lockBusy()) {
            log("auto: \(gate.rawValue), nothing to do")
            if gate == .ledgerUnreadable, let ledgerError {
                failures.append(RefreshFailure(error: ledgerError))
            } else if let probeError {
                failures.append(RefreshFailure(error: probeError))
            } else {
                runSkips[gate.rawValue] = 1
            }
            return finish(reason: gate.rawValue)
        }

        // 4. The devices the owner opted in.
        let config: Config
        do {
            config = try services.store.load()
        } catch {
            failures.append(RefreshFailure(error: error))
            return finish(reason: "CONFIG_INVALID")
        }
        let (eligible, invalid) = RefreshPolicy.autoDevices(config.devices)
        for alias in invalid {
            runSkips["CONFIG_INVALID", default: 0] += 1
            auto.log.record("install", ["device": .string(alias), "decision": "skip", "reason": "CONFIG_INVALID"])
        }

        // 5. Per install, against the ledger as it is now.
        for alias in eligible {
            guard let saved = config.devices[alias] else { continue }
            var plan = DevicePlan(alias: alias, saved: saved)
            do {
                let ledger = SlotRule.migrated(try services.ledgerStore.load(), now: start)
                let apps = ProvisionApp.allCases.filter { $0.devicePlatform == saved.platform }
                if apps.isEmpty {
                    runSkips["PLATFORM_MISMATCH", default: 0] += 1
                    continue
                }
                let book = SlotBook(services: services, config: config, alias: alias)
                let pending = book.pending(ledger, now: start) != nil
                let attempts = RefreshPolicy.deviceAttempts(
                    ledger.installs, device: alias, today: RefreshPolicy.dayKey(start, timeZone: timeZone))
                for app in apps {
                    let target = try FreeTarget.resolve(app: app, alias: alias, config: config)
                    let subject = subject(app, ledger, alias: alias)
                    // An app nothing is known about is not an install of this device, so it is not listed.
                    if subject.install == nil, subject.signed == nil, !subject.lent { continue }
                    if let skip = RefreshPolicy.autoGate(
                        subject, slotPending: pending, deviceAttempts: attempts, now: start, timeZone: timeZone)
                    {
                        plan.results.append(skipped(target, skip.rawValue, subject, now: start, auto: auto))
                    } else {
                        plan.candidates.append(target)
                    }
                }
            } catch {
                var failure = RefreshFailure(error: error)
                failure.message = "\(RefreshLog.alias(alias)): \(failure.message)"
                failures.append(failure)
                if RefreshPolicy.stopsWholeRun(failure.code) {
                    plans.append(plan)
                    return finish(reason: failure.code)
                }
                continue
            }
            plans.append(plan)
        }

        // 6. Only now, and only if an app is a candidate, ask devicectl once which devices are there.
        var listed: [ListedDevice] = []
        if plans.contains(where: { !$0.candidates.isEmpty }) {
            log("auto: reading the device list")
            listed = ((try? await services.deviceCtl.listDevices()) ?? nil) ?? []
        }

        // 7. The existing path, device by device.
        var runStop: String?
        for index in plans.indices where !plans[index].candidates.isEmpty {
            let alias = plans[index].alias
            let saved = plans[index].saved
            let candidates = plans[index].candidates
            plans[index].candidates = []
            if let runStop {
                for target in candidates { plans[index].results.append(stopped(target, runStop, now: start, auto: auto)) }
                continue
            }
            guard DeviceList.autoEligible(saved, listed: DeviceList.findSaved(listed, matching: saved)) else {
                for target in candidates {
                    plans[index].results.append(
                        skipped(target, RefreshPolicy.AutoSkip.deviceNotVisible.rawValue, nil, now: start, auto: auto))
                }
                continue
            }

            // The device's app list is read once; an app it does not show is skipped, never put back.
            var presence: [ProvisionApp: RefreshPolicy.Presence] = [:]
            var installBlock: RefreshFailure?
            log("auto: reading the app list of \(RefreshLog.alias(alias))")
            let read = await steps.snapshot(services, alias, candidates[0].bundleId)
            if let snapshot = read.snapshot {
                for target in candidates { presence[target.app] = snapshot.ids.contains(target.bundleId) ? .present : .absent }
            } else {
                installBlock = RefreshFailure(
                    error: read.error ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read."))
            }

            var entries: [(target: FreeTarget, expires: Date)] = []
            do {
                let ledger = SlotRule.migrated(try services.ledgerStore.load(), now: start)
                for target in candidates {
                    let subject = subject(target.app, ledger, alias: alias)
                    switch RefreshPolicy.decide(subject, now: start, within: RefreshPolicy.autoWithin, presence: presence[target.app] ?? .unknown) {
                    case .renew(let baseline): entries.append((target, baseline.expires))
                    case .skip(let code, _): plans[index].results.append(skipped(target, code, subject, now: start, auto: auto))
                    }
                }
            } catch {
                failures.append(RefreshFailure(error: error))
                return finish(reason: "LEDGER_INVALID")
            }
            entries.sort { ($0.expires, $0.target.app.rawValue) < ($1.expires, $1.target.app.rawValue) }

            var deviceStop: String?
            for (target, _) in entries {
                if let stop = runStop ?? deviceStop {
                    plans[index].results.append(stopped(target, stop, now: start, auto: auto))
                    continue
                }
                if Task.isCancelled {
                    let interrupted = RefreshFailure(code: RefreshPolicy.interrupted, message: "The run was interrupted.", fix: nil)
                    failures.append(interrupted)
                    runStop = interrupted.code
                    plans[index].results.append(stopped(target, runStop!, now: start, auto: auto))
                    continue
                }
                if services.clock.now() >= deadline {
                    // No new app after the deadline; the next run picks up what is still due. Not an attempt, not a failure.
                    plans[index].results.append(
                        skipped(target, RefreshPolicy.AutoSkip.deadline.rawValue, nil, now: start, auto: auto))
                    continue
                }

                // Each app is gated again against a fresh read: the lab, or this run's own earlier apps, may have changed it.
                let baseline: RefreshPolicy.Target
                do {
                    let now = wholeSeconds(services.clock.now())
                    let ledger = SlotRule.migrated(try services.ledgerStore.load(), now: now)
                    let subject = subject(target.app, ledger, alias: alias)
                    let book = SlotBook(services: services, config: config, alias: alias)
                    if let skip = RefreshPolicy.autoGate(
                        subject, slotPending: book.pending(ledger, now: now) != nil,
                        deviceAttempts: RefreshPolicy.deviceAttempts(
                            ledger.installs, device: alias, today: RefreshPolicy.dayKey(now, timeZone: timeZone)),
                        now: now, timeZone: timeZone)
                    {
                        plans[index].results.append(skipped(target, skip.rawValue, subject, now: start, auto: auto))
                        continue
                    }
                    guard case .renew(let fresh) = RefreshPolicy.decide(
                        subject, now: now, within: RefreshPolicy.autoWithin, presence: presence[target.app] ?? .unknown)
                    else {
                        plans[index].results.append(
                            skipped(target, RefreshPolicy.notPresent, subject, now: start, auto: auto))
                        continue
                    }
                    baseline = fresh
                } catch {
                    let failure = RefreshFailure(error: error)
                    failures.append(failure)
                    runStop = failure.code
                    plans[index].results.append(stopped(target, runStop!, now: start, auto: auto))
                    continue
                }

                auto.log.record(
                    "install",
                    [
                        "device": .string(RefreshLog.alias(alias)), "app": .string(target.app.rawValue), "decision": "renew",
                        "daysLeft": RefreshLog.int(RefreshPolicy.daysLeft(baseline.expires, now: start)),
                    ])
                let began = services.clock.now()
                var outcome = await renew(target, baseline: baseline, start: start, installBlock: &installBlock, warnings: &warnings)
                var notified = false
                if outcome.trace.busy {
                    // The lab's turn: a logged skip, silent, and the rest of the run (the lock is shared) waits for the next one.
                    outcome.status = .skipped
                    outcome.failure = nil
                    runStop = OperationLock.busyCode
                } else {
                    notified = await notify(outcome, target, auto: auto)
                    if let failure = outcome.failure {
                        failures.append(failure)
                        if RefreshPolicy.stopsWholeRun(failure.code) {
                            runStop = failure.code
                        } else if RefreshPolicy.isFatal(failure.code) {
                            deviceStop = failure.code
                        }
                    }
                }
                record(outcome, target, since: began, notified: notified, auto: auto)
                plans[index].results.append(outcome)
            }
        }
        return finish()
    }

    // MARK: results

    /// A skipped result for an app, logged unless it is the quiet `NOT_DUE`.
    private func skipped(
        _ target: FreeTarget, _ code: String, _ subject: RefreshPolicy.Subject?, now: Date, auto: RefreshAutoContext
    ) -> AppResult {
        let expires = subject.flatMap { $0.install?.profileExpires ?? $0.signed?.profileExpires }
        let result = AppResult.skipped(target.app, code: code, expires: expires, now: now)
        if code != RefreshPolicy.notDue {
            var fields: [String: JSONValue] = [
                "device": .string(RefreshLog.alias(target.alias)), "app": .string(target.app.rawValue), "decision": "skip",
                "reason": .string(RefreshLog.code(code)),
            ]
            if let days = result.daysLeftBefore { fields["daysLeft"] = RefreshLog.int(days) }
            auto.log.record("install", fields)
        }
        return result
    }

    /// An app left alone because the device or the run stopped.
    private func stopped(_ target: FreeTarget, _ code: String, now: Date, auto: RefreshAutoContext) -> AppResult {
        skipped(target, code, nil, now: now, auto: auto)
    }

    /// The log line of one renewal attempt, after its step lines.
    private func record(_ result: AppResult, _ target: FreeTarget, since began: Date, notified: Bool, auto: RefreshAutoContext) {
        var fields: [String: JSONValue] = [
            "device": .string(RefreshLog.alias(target.alias)), "app": .string(target.app.rawValue),
            "decision": .string(result.status.rawValue),
            "durationMs": RefreshLog.int(max(0, Int(services.clock.now().timeIntervalSince(began) * 1000))),
            "notified": .bool(notified),
        ]
        if let code = result.code { fields["code"] = .string(RefreshLog.code(code)) }
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
