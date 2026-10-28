import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

private let utc = TimeZone(identifier: "UTC")!

// MARK: helpers

/// Seeds one app's records so it expires in `days`: the install (the device copy), the signed copy and the stored profile all
/// carry that expiry (the state before a renewal). `installed` false leaves no `installs[]` record (installed by hand).
private func seed(
    _ ledger: inout Ledger, _ app: ProvisionApp, days: Double, installed: Bool = true, present: Bool = true,
    refresh: LedgerInstallRefresh = LedgerInstallRefresh()
) {
    let key = "iphone/\(app.rawValue)"
    let expires = daysFromNow(days)
    for i in ledger.freeProfiles.indices where ledger.freeProfiles[i].id == key { ledger.freeProfiles[i].expires = expires }
    for i in ledger.freeSigned.indices where ledger.freeSigned[i].id == key { ledger.freeSigned[i].profileExpires = expires }
    ledger.installs.removeAll { $0.id == key }
    if installed {
        var record = installRecord(app, present: present, refresh: refresh)
        record.profileExpires = expires
        ledger.installs.append(record)
    }
}

private func bundle(_ app: ProvisionApp) -> String { carrierPrefix + ".free." + app.suffix }

/// A world with `apps` signed on the iPhone, each already on the device unless `onDevice` is false.
private func withRefreshWorld(
    _ apps: [ProvisionApp] = [.stremioIOS], onDevice: Bool = true, script base: DeviceScript = DeviceScript(),
    profileDays: Double = 5, ledger tweak: ((inout Ledger) -> Void)? = nil, _ body: (InstallWorld) async throws -> Void
) async throws {
    var script = base
    if onDevice { for app in apps { script.initial[bundle(app)] = true } }
    try await withInstallWorld(
        app: apps[0], alsoSigned: Array(apps.dropFirst()), script: script, profileDays: profileDays, ledger: tweak, body)
}

/// What the scripted steps were asked to do, in order: `provision <app>`, `provision <app> renew`, `sign <app>`, `install <app>`.
private typealias CallLog = Box<[String]>

private func okEnvelope(_ command: String, _ app: String, _ extra: [String: JSONValue] = [:]) -> Envelope {
    var data: [String: JSONValue] = ["app": .string(app)]
    data.merge(extra) { _, new in new }
    return .result(command, data)
}

private func failEnvelope(_ command: String, _ code: String, _ data: [String: JSONValue] = [:]) -> Envelope {
    .fail(command, code: code, message: "\(code) happened.", fix: "Fix \(code).", data: data)
}

private func scripted(
    _ log: CallLog,
    provision: @escaping @Sendable (ProvisionOptions) async -> Envelope = { okEnvelope("provision", $0.app ?? "", ["appIdNew": false]) },
    sign: @escaping @Sendable (SignOptions) async -> Envelope = { okEnvelope("sign", $0.app ?? "") },
    install: @escaping @Sendable (InstallOptions) async -> Envelope = { okEnvelope("install", $0.app ?? "") },
    snapshot: (@Sendable (Services, String, String) async -> FreeDeviceCalls.SnapshotRead)? = nil
) -> RefreshSteps {
    var steps = RefreshSteps()
    steps.provision = { _, options in
        log.value.append("provision \(options.app ?? "")" + (options.renew ? " renew" : ""))
        #expect(options.yes && !options.registerDevice)
        return await provision(options)
    }
    steps.sign = { _, options in
        log.value.append("sign \(options.app ?? "")")
        #expect(options.yes)
        return await sign(options)
    }
    steps.install = { _, options in
        log.value.append("install \(options.app ?? "")")
        #expect(options.yes)
        return await install(options)
    }
    if let snapshot { steps.snapshot = snapshot }
    return steps
}

private func refresh(
    _ w: InstallWorld, _ steps: RefreshSteps, device: String? = "iphone", app: String? = nil, within: String? = nil,
    force: Bool = false, yes: Bool = true
) async -> Envelope {
    await RefreshCommand.run(
        w.services, RefreshOptions(device: device, app: app, within: within, force: force, yes: yes), steps: steps, timeZone: utc)
}

private func results(_ out: Envelope) -> [JSONValue] {
    if case .array(let items)? = out.data["results"] { return items }
    return []
}

private func result(_ out: Envelope, _ app: ProvisionApp) -> JSONValue? {
    results(out).first { $0["app"] == .string(app.rawValue) }
}

private func warnings(_ out: Envelope) -> [String] {
    guard case .array(let items)? = out.data["warnings"] else { return [] }
    return items.compactMap { if case .string(let code)? = $0["code"] { code } else { nil } }
}

private func refreshFields(_ w: InstallWorld, _ app: ProvisionApp) throws -> LedgerInstallRefresh {
    try #require(try w.ledger().installs.first { $0.id == "iphone/\(app.rawValue)" }).refresh
}

private let today = RefreshPolicy.dayKey(testNow, timeZone: utc)

@Suite("refresh (free team)")
struct RefreshTests {
    // MARK: happy path

    @Test("an app close to expiry is provisioned, signed and installed; no App ID is spent; the fields are recorded")
    func happyPath() async throws {
        try await withRefreshWorld(profileDays: 3, ledger: { seed(&$0, .stremioIOS, days: 3) }) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(out.ok, "\(out.errors)")
            #expect(out.command == "refresh")
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios", "install stremio-ios"])
            let item = try #require(result(out, .stremioIOS))
            #expect(item["status"] == "renewed")
            #expect(item["steps"]?["provision"] == "done" && item["steps"]?["sign"] == "done" && item["steps"]?["install"] == "done")
            #expect(item["appIdNew"] == false && item["renewRetried"] == false)
            #expect(item["daysLeftBefore"] == 3)
            #expect(out.data["renewed"] == 1 && out.data["failed"] == 0)
            #expect(out.data["within"] == 5 && out.data["force"] == false)
            let fields = try refreshFields(w, .stremioIOS)
            #expect(fields.attemptsByDay == [today: 1] && fields.lastAttempt == testNow)
            #expect(fields.lastResult == "refreshed" && fields.lastCode == nil && fields.consecutiveFailures == 0)
            try w.expectClean(out)
        }
    }

    @Test("provision runs without --renew and is asked once; appIdNew from the step is reported with the live count")
    func appIdNewReported() async throws {
        try await withRefreshWorld(profileDays: 3, ledger: { seed(&$0, .stremioIOS, days: 3) }) { w in
            let log = CallLog([])
            let steps = scripted(log, provision: { okEnvelope("provision", $0.app ?? "", ["appIdNew": true]) })
            let out = await refresh(w, steps)
            #expect(out.ok)
            let item = try #require(result(out, .stremioIOS))
            #expect(item["appIdNew"] == true)
            #expect(item["appIdsLast7Days"] == 0)  // the scripted provision wrote no epoch
            #expect(log.value.filter { $0.hasPrefix("provision") } == ["provision stremio-ios"])
        }
    }

    // MARK: selection

    @Test("nothing due: every app is a policy skip, ok, and neither a step nor the device is touched")
    func nothingDue() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo], profileDays: 6,
            ledger: {
                seed(&$0, .stremioIOS, days: 6)
                seed(&$0, .apollo, days: 5.5)
            }
        ) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(out.ok, "\(out.errors)")
            #expect(log.value.isEmpty && w.runner.deviceCalls.isEmpty)
            #expect(results(out).map { $0["status"] } == [.string("skipped"), .string("skipped")])
            #expect(result(out, .stremioIOS)?["code"] == "NOT_DUE" && result(out, .apollo)?["code"] == "NOT_DUE")
            #expect(out.data["skipped"] == 2 && out.data["renewed"] == 0)
            let installs = try w.ledger().installs
            #expect(installs.allSatisfy { $0.refresh.attemptsByDay.isEmpty })
        }
    }

    @Test("--within 6 and --force reach an app with 5.5 days left; --within 7 and --force with --within are usage errors")
    func withinAndForce() async throws {
        try await withRefreshWorld(profileDays: 5.5, ledger: { seed(&$0, .stremioIOS, days: 5.5) }) { w in
            let log = CallLog([])
            #expect(await refresh(w, scripted(log)).data["skipped"] == 1)
            #expect(log.value.isEmpty)

            let six = await refresh(w, scripted(log), within: "6")
            #expect(six.ok && six.data["within"] == 6 && log.value.count == 3)
            log.value = []
            let forced = await refresh(w, scripted(log), force: true)
            #expect(forced.ok && forced.data["within"] == 6 && forced.data["force"] == true && log.value.count == 3)

            for (within, force) in [("7", false), ("0", false), ("3", true)] {
                let bad = await refresh(w, scripted(log), within: within, force: force)
                #expect(!bad.ok && bad.errors.first?.code == "USAGE", "\(within) \(force)")
            }
        }
    }

    @Test("--app limits the run to that app; an app that is not on this device's platform is PLATFORM_MISMATCH")
    func appOption() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo], profileDays: 2,
            ledger: {
                seed(&$0, .stremioIOS, days: 2)
                seed(&$0, .apollo, days: 2)
            }
        ) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log), app: "apollo")
            #expect(out.ok && results(out).count == 1)
            #expect(log.value == ["provision apollo", "sign apollo", "install apollo"])
            let wrong = await refresh(w, scripted(log), app: "stremio-tvos")
            #expect(!wrong.ok && wrong.errors.first?.code == "PLATFORM_MISMATCH")
            let unknown = await refresh(w, scripted(log), app: "bogus")
            #expect(!unknown.ok && unknown.errors.first?.code == "USAGE")
        }
    }

    @Test("an app the device does not show is NOT_PRESENT: refresh does not put it back")
    func absentFromDevice() async throws {
        try await withRefreshWorld(onDevice: false, profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2) }) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(out.ok, "\(out.errors)")
            #expect(log.value.isEmpty)
            #expect(result(out, .stremioIOS)?["status"] == "skipped" && result(out, .stremioIOS)?["code"] == "NOT_PRESENT")
            #expect(w.runner.installCalls.isEmpty)
        }
    }

    @Test("soonest expiry first, and a failure in the middle does not stop the third")
    func middleFailureContinues() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo, .filler], profileDays: 4,
            ledger: {
                seed(&$0, .filler, days: 3)
                seed(&$0, .apollo, days: 2)
                seed(&$0, .stremioIOS, days: 1)
            }
        ) { w in
            let log = CallLog([])
            let steps = scripted(log, sign: { $0.app == "apollo" ? failEnvelope("sign", "SIGN_FAILED") : okEnvelope("sign", $0.app ?? "") })
            let out = await refresh(w, steps)
            #expect(!out.ok)
            #expect(results(out).compactMap { if case .string(let a)? = $0["app"] { a } else { nil } } == ["stremio-ios", "apollo", "filler"])
            #expect(
                log.value == [
                    "provision stremio-ios", "sign stremio-ios", "install stremio-ios", "provision apollo", "sign apollo",
                    "provision filler", "install filler",
                ])
            #expect(result(out, .stremioIOS)?["status"] == "renewed" && result(out, .filler)?["status"] == "renewed")
            let broken = try #require(result(out, .apollo))
            #expect(broken["status"] == "failed" && broken["code"] == "SIGN_FAILED")
            #expect(broken["steps"]?["provision"] == "done" && broken["steps"]?["sign"] == "failed" && broken["steps"]?["install"] == "skipped")
            #expect(out.errors.map(\.code) == ["SIGN_FAILED"] && out.errors.first?.message.hasPrefix("apollo:") == true)
            #expect(out.errors.first?.fix == "Fix SIGN_FAILED.")
            #expect(out.data["renewed"] == 2 && out.data["failed"] == 1)
            let fields = try refreshFields(w, .apollo)
            #expect(fields.lastResult == "failed" && fields.lastCode == "SIGN_FAILED" && fields.consecutiveFailures == 1)
            #expect(fields.nextEligible == testNow.addingTimeInterval(1800) && !fields.suspended)
        }
    }

    // MARK: PROFILE_NOT_RENEWED

    @Test("PROFILE_NOT_RENEWED retries provision once with --renew; a second failure ends the app and suspends the install")
    func notRenewedTwice() async throws {
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2) }) { w in
            let log = CallLog([])
            let steps = scripted(log, provision: { _ in failEnvelope("provision", "PROFILE_NOT_RENEWED") })
            let out = await refresh(w, steps)
            #expect(!out.ok)
            #expect(log.value == ["provision stremio-ios", "provision stremio-ios renew"])
            let item = try #require(result(out, .stremioIOS))
            #expect(item["status"] == "failed" && item["code"] == "PROFILE_NOT_RENEWED" && item["renewRetried"] == true)
            #expect(item["steps"]?["provision"] == "failed" && item["steps"]?["sign"] == "skipped")
            let fields = try refreshFields(w, .stremioIOS)
            #expect(fields.suspended && fields.lastCode == "PROFILE_NOT_RENEWED")
        }
    }

    @Test("PROFILE_NOT_RENEWED then a --renew that works renews the app and reports the retry and the moved profiles")
    func notRenewedThenRenewed() async throws {
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2) }) { w in
            let log = CallLog([])
            let steps = scripted(
                log,
                provision: { options in
                    options.renew
                        ? okEnvelope("provision", options.app ?? "", ["appIdNew": false, "cachedProfilesMoved": 1, "cachedProfilesMovedTo": ["tmp/renewed-profile-x.mobileprovision"]])
                        : failEnvelope("provision", "PROFILE_NOT_RENEWED")
                })
            let out = await refresh(w, steps)
            #expect(out.ok, "\(out.errors)")
            #expect(log.value == ["provision stremio-ios", "provision stremio-ios renew", "sign stremio-ios", "install stremio-ios"])
            let item = try #require(result(out, .stremioIOS))
            #expect(item["status"] == "renewed" && item["renewRetried"] == true)
            #expect(item["renew"]?["cachedProfilesMoved"] == 1)
        }
    }

    @Test("cached profiles an earlier --renew run left in tmp/ are reported once, at the top level, and the ledger record stays")
    func earlierRenewMovesReportedOnce() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo], profileDays: 4,
            ledger: {
                seed(&$0, .stremioIOS, days: 1)
                seed(&$0, .apollo, days: 2)
                $0.freeRenewMoves = [LedgerFreeRenewMove(from: "a.mobileprovision", to: "tmp/renewed-profile-a.mobileprovision", at: daysFromNow(-1), state: .done)]
            }
        ) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(out.ok)
            guard case .array(let moves)? = out.data["cachedProfilesFromEarlierRun"] else {
                Issue.record("no cachedProfilesFromEarlierRun")
                return
            }
            #expect(moves.count == 1)
            #expect(results(out).allSatisfy { $0["cachedProfilesFromEarlierRun"] == nil })
            let ledger = try w.ledger()
            #expect(ledger.freeRenewMoves.count == 1)
        }
    }

    // MARK: lent

    @Test("a lent app gets provision and sign only: no install call, no device call, renewed-not-installed with APP_LENT")
    func lentApp() async throws {
        try await withRefreshWorld(
            onDevice: false, profileDays: 2,
            ledger: {
                seed(&$0, .stremioIOS, days: 2, present: false)
                $0.lent = [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1))]
            }
        ) { w in
            let log = CallLog([])
            let before = try w.ledger()
            let out = await refresh(w, scripted(log))
            #expect(out.ok, "\(out.errors)")
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios"])
            let item = try #require(result(out, .stremioIOS))
            #expect(item["status"] == "renewed-not-installed")
            #expect(item["steps"]?["install"] == "skipped")
            #expect(warnings(out) == ["APP_LENT"])
            #expect(w.runner.deviceCalls.isEmpty && w.runner.installCalls.isEmpty)
            // The slot model is untouched: refresh writes neither slots nor the lend record.
            let after = try w.ledger()
            #expect(after.slots == before.slots && after.lent == before.lent)
            #expect(after.lent.first?.to == "lab")
            #expect(try refreshFields(w, .stremioIOS).lastResult == "renewed-not-installed", "no copy reached the device")
        }
    }

    @Test("a run cancelled before any app fails is still ok:false with INTERRUPTED, and the due apps are not renewed")
    func cancelledRun() async throws {
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2) }) { w in
            let log = CallLog([])
            // The task cancels itself before refresh starts, so the order is fixed (no race with a cancel from outside).
            let out = await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await refresh(w, scripted(log))
            }.value
            #expect(!out.ok)
            #expect(out.errorCodes == ["INTERRUPTED"])
            #expect(result(out, .stremioIOS)?["status"] == "skipped" && result(out, .stremioIOS)?["code"] == "INTERRUPTED")
            #expect(log.value.isEmpty, "no step ran")
        }
    }

    // MARK: slot gate

    @Test("a pending slot operation stops the run before any work: SLOT_PENDING with retryAfter")
    func pendingUpFront() async throws {
        try await withRefreshWorld(
            profileDays: 2,
            ledger: {
                seed(&$0, .stremioIOS, days: 2, present: false)
                $0.lent = [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: LedgerLent.lending, opAt: testNow)]
            }
        ) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(!out.ok && out.errors.first?.code == "SLOT_PENDING")
            if case .number(let seconds)? = out.data["retryAfter"] { #expect(seconds > 0) } else { Issue.record("no retryAfter") }
            #expect(log.value.isEmpty && w.runner.deviceCalls.isEmpty)
        }
    }

    @Test("SLOT_PENDING from an install stops the device: the app that hit it failed, the rest are skipped with the same code")
    func pendingMidRun() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo], profileDays: 4,
            ledger: {
                seed(&$0, .stremioIOS, days: 1)
                seed(&$0, .apollo, days: 2)
            }
        ) { w in
            let log = CallLog([])
            let steps = scripted(log, install: { _ in failEnvelope("install", "SLOT_PENDING", ["retryAfter": 120]) })
            let out = await refresh(w, steps)
            #expect(!out.ok)
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios", "install stremio-ios"])
            #expect(result(out, .stremioIOS)?["code"] == "SLOT_PENDING" && result(out, .stremioIOS)?["retryAfter"] == 120)
            #expect(result(out, .apollo)?["status"] == "skipped" && result(out, .apollo)?["code"] == "SLOT_PENDING")
            #expect(out.errors.map(\.code) == ["SLOT_PENDING"])
        }
    }

    // MARK: lock

    @Test("a busy lock is OPERATION_IN_PROGRESS for the app, never waited on; the attempt is given back")
    func busyScripted() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo], profileDays: 4,
            ledger: {
                seed(&$0, .stremioIOS, days: 1)
                seed(&$0, .apollo, days: 2)
            }
        ) { w in
            let log = CallLog([])
            let steps = scripted(log, provision: { $0.app == "stremio-ios" ? failEnvelope("provision", "OPERATION_IN_PROGRESS") : okEnvelope("provision", "apollo", ["appIdNew": false]) })
            let out = await refresh(w, steps)
            #expect(!out.ok)
            #expect(result(out, .stremioIOS)?["code"] == "OPERATION_IN_PROGRESS")
            #expect(result(out, .apollo)?["status"] == "renewed")
            let fields = try refreshFields(w, .stremioIOS)
            #expect(fields.attemptsByDay.isEmpty && fields.lastResult == "skipped" && fields.consecutiveFailures == 0)
            #expect(fields.nextEligible == nil)
        }
    }

    @Test("a step failing while the task is cancelled (the menu's Cancel) is INTERRUPTED: the attempt is given back, no failure recorded")
    func cancelledMidStep() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo], profileDays: 4,
            ledger: {
                seed(&$0, .stremioIOS, days: 1)
                seed(&$0, .apollo, days: 2)
            }
        ) { w in
            let log = CallLog([])
            let steps = scripted(
                log,
                provision: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return failEnvelope("provision", "SIGNING_FAILED")
                })
            let out = await refresh(w, steps)
            #expect(!out.ok)
            #expect(result(out, .stremioIOS)?["code"] == "INTERRUPTED")
            #expect(result(out, .apollo)?["status"] == "skipped" && result(out, .apollo)?["code"] == "INTERRUPTED")
            let fields = try refreshFields(w, .stremioIOS)
            #expect(fields.attemptsByDay.isEmpty && fields.lastResult == "skipped" && fields.lastCode == "INTERRUPTED")
            #expect(fields.consecutiveFailures == 0 && fields.nextEligible == nil && !fields.suspended)
            #expect(try refreshFields(w, .apollo).attemptsByDay.isEmpty)
        }
    }

    @Test("a permanent failure that lands while the task is cancelled keeps its own result: counted, backed off, suspended")
    func cancelledButPermanent() async throws {
        try await withRefreshWorld(profileDays: 4, ledger: { seed(&$0, .stremioIOS, days: 1) }) { w in
            let log = CallLog([])
            let steps = scripted(
                log,
                provision: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return failEnvelope("provision", "PROFILE_INVALID")
                })
            let out = await refresh(w, steps)
            #expect(!out.ok)
            #expect(result(out, .stremioIOS)?["code"] == "PROFILE_INVALID")
            let fields = try refreshFields(w, .stremioIOS)
            #expect(fields.lastResult == "failed" && fields.lastCode == "PROFILE_INVALID")
            #expect(fields.consecutiveFailures == 1 && fields.suspended && fields.attemptsByDay == [today: 1])
        }
    }

    @Test("INTERRUPTED from a step while the task is cancelled is the cancellation's own: given back, nothing recorded")
    func cancelledInterrupted() async throws {
        try await withRefreshWorld(profileDays: 4, ledger: { seed(&$0, .stremioIOS, days: 1) }) { w in
            let log = CallLog([])
            let steps = scripted(
                log,
                provision: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return failEnvelope("provision", "INTERRUPTED")
                })
            let out = await refresh(w, steps)
            #expect(result(out, .stremioIOS)?["code"] == "INTERRUPTED")
            let fields = try refreshFields(w, .stremioIOS)
            #expect(fields.lastResult == "skipped" && fields.lastCode == "INTERRUPTED" && fields.consecutiveFailures == 0)
            #expect(fields.attemptsByDay.isEmpty && !fields.suspended)
        }
    }

    @Test("the real steps take .op.lock themselves: with another run holding it, nothing runs and the lock is not waited on")
    func busyRealLock() async throws {
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2) }) { w in
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            let out = await RefreshCommand.run(
                w.services, RefreshOptions(device: "iphone", yes: true), steps: RefreshSteps(), timeZone: utc)
            #expect(!out.ok)
            #expect(out.errors.map(\.code) == ["OPERATION_IN_PROGRESS"])
            let item = try #require(result(out, .stremioIOS))
            #expect(item["steps"]?["provision"] == "failed" && item["steps"]?["sign"] == "skipped")
            #expect(w.runner.installCalls.isEmpty)
            #expect(!w.runner.calls.contains { $0.executable == "xcodebuild" })
        }
    }

    // MARK: certificate

    @Test("FREE_CERT_CHANGED from a step stops the run: the rest are skipped and nothing else is called")
    func certChangedMidRun() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo], profileDays: 4,
            ledger: {
                seed(&$0, .stremioIOS, days: 1)
                seed(&$0, .apollo, days: 2)
            }
        ) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log, provision: { _ in failEnvelope("provision", "FREE_CERT_CHANGED") }))
            #expect(!out.ok)
            #expect(log.value == ["provision stremio-ios"])
            #expect(result(out, .apollo)?["status"] == "skipped" && result(out, .apollo)?["code"] == "FREE_CERT_CHANGED")
            #expect(out.errors.map(\.code) == ["FREE_CERT_CHANGED"])
            let skippedFields = try refreshFields(w, .apollo)
            #expect(skippedFields.attemptsByDay.isEmpty)
        }
    }

    @Test("a free-team suspension on the ledger stops the run up front and refresh never clears it")
    func suspendedUpFront() async throws {
        try await withRefreshWorld(
            profileDays: 2,
            ledger: {
                seed(&$0, .stremioIOS, days: 2)
                $0.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: daysFromNow(-1), addedFp8: ["aaaaaaaa"], removedFp8: [])
            }
        ) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(!out.ok && out.errors.first?.code == "FREE_CERT_CHANGED")
            #expect(log.value.isEmpty && w.runner.deviceCalls.isEmpty)
            let kept = try w.ledger().freeSuspended
            #expect(kept != nil)
        }
    }

    // MARK: resume

    @Test("a rerun after a failed sign skips provision (it would be PROFILE_NOT_RENEWED) and finishes the rest")
    func resumeAfterFailedSign() async throws {
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2) }) { w in
            let log = CallLog([])
            let provisioned: @Sendable (ProvisionOptions) async -> Envelope = { options in
                // What a real provision leaves: a new profile a week out.
                _ = try? await w.services.ledgerStore.update { ledger in
                    for i in ledger.freeProfiles.indices where ledger.freeProfiles[i].id == "iphone/stremio-ios" {
                        ledger.freeProfiles[i].profileUuid = "NEWPROFILE"
                        ledger.freeProfiles[i].expires = daysFromNow(7)
                    }
                }
                return okEnvelope("provision", options.app ?? "", ["appIdNew": false])
            }
            let first = await refresh(w, scripted(log, provision: provisioned, sign: { _ in failEnvelope("sign", "SIGN_FAILED") }))
            #expect(!first.ok)
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios"])

            log.value = []
            let second = await refresh(w, scripted(log))
            #expect(second.ok, "\(second.errors)")
            #expect(log.value == ["sign stremio-ios", "install stremio-ios"])
            let item = try #require(result(second, .stremioIOS))
            #expect(item["steps"]?["provision"] == "skipped" && item["steps"]?["sign"] == "done" && item["steps"]?["install"] == "done")
            let fields = try refreshFields(w, .stremioIOS)
            #expect(fields.attemptsByDay == [today: 2] && fields.lastResult == "refreshed" && fields.consecutiveFailures == 0)
        }
    }

    @Test("a rerun after provision and sign worked but the install did not resumes at the install")
    func resumeAtInstall() async throws {
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2) }) { w in
            _ = try await w.services.ledgerStore.update { ledger in
                for i in ledger.freeProfiles.indices { ledger.freeProfiles[i].expires = daysFromNow(7) }
                for i in ledger.freeSigned.indices { ledger.freeSigned[i].profileExpires = daysFromNow(7) }
            }
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(out.ok)
            #expect(log.value == ["install stremio-ios"])
        }
    }

    // MARK: device availability

    @Test("a locked phone found by the first snapshot: provision and sign still run for every app, no install, ok false")
    func lockedAtSnapshot() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo], profileDays: 4,
            ledger: {
                seed(&$0, .stremioIOS, days: 1)
                seed(&$0, .apollo, days: 2)
            }
        ) { w in
            let log = CallLog([])
            let steps = scripted(
                log,
                snapshot: { _, _, _ in
                    FreeDeviceCalls.SnapshotRead(snapshot: nil, error: SideloadError("DEVICE_LOCKED", "locked", fix: "unlock"), takenAt: testNow)
                })
            let out = await refresh(w, steps)
            #expect(!out.ok)
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios", "provision apollo", "sign apollo"])
            for app in [ProvisionApp.stremioIOS, .apollo] {
                let item = try #require(result(out, app))
                #expect(item["status"] == "failed" && item["code"] == "DEVICE_LOCKED")
                #expect(item["steps"]?["provision"] == "done" && item["steps"]?["sign"] == "done" && item["steps"]?["install"] == "skipped")
            }
            #expect(out.errors.map(\.code) == ["DEVICE_LOCKED", "DEVICE_LOCKED"])
            #expect(out.errors.allSatisfy { $0.fix?.contains("rerun") == true })
        }
    }

    @Test("a locked phone found by an install: the later installs are skipped, their provision and sign still run")
    func lockedAtInstall() async throws {
        try await withRefreshWorld(
            [.stremioIOS, .apollo], profileDays: 4,
            ledger: {
                seed(&$0, .stremioIOS, days: 1)
                seed(&$0, .apollo, days: 2)
            }
        ) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log, install: { _ in failEnvelope("install", "DEVICE_LOCKED") }))
            #expect(!out.ok)
            #expect(
                log.value == ["provision stremio-ios", "sign stremio-ios", "install stremio-ios", "provision apollo", "sign apollo"])
            #expect(result(out, .apollo)?["code"] == "DEVICE_LOCKED" && result(out, .apollo)?["steps"]?["install"] == "skipped")
            #expect(result(out, .stremioIOS)?["steps"]?["install"] == "failed")
        }
    }

    // MARK: installed by hand

    @Test("an app installed by hand (no record) is renewed when it has a signed copy and the device shows it; its install records it")
    func handInstalledRenewed() async throws {
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2, installed: false) }) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(out.ok, "\(out.errors)")
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios", "install stremio-ios"])
            #expect(result(out, .stremioIOS)?["status"] == "renewed" && result(out, .stremioIOS)?["daysLeftBefore"] == 2)
        }
    }

    @Test("a signed app the device does not show is NOT_INSTALLED; one the device could not be asked about fails with the device's code")
    func handInstalledNotConfirmed() async throws {
        try await withRefreshWorld(onDevice: false, profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2, installed: false) }) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(out.ok && result(out, .stremioIOS)?["code"] == "NOT_INSTALLED" && log.value.isEmpty)
        }
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2, installed: false) }) { w in
            let log = CallLog([])
            let steps = scripted(
                log,
                snapshot: { _, _, _ in
                    FreeDeviceCalls.SnapshotRead(snapshot: nil, error: SideloadError("DEVICE_NOT_CONNECTED", "gone"), takenAt: testNow)
                })
            let out = await refresh(w, steps)
            // Provision and sign need no device, so they still run (the signed copy is expiring); the install is skipped.
            #expect(!out.ok && result(out, .stremioIOS)?["status"] == "failed" && result(out, .stremioIOS)?["code"] == "DEVICE_NOT_CONNECTED")
            #expect(result(out, .stremioIOS)?["steps"]?["install"] == "skipped")
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios"])
        }
        // A fresh signed copy and no word from the device: the device copy's expiry is unknown, so still a failure, never a
        // passing skip; nothing is run (the signed copy is not due).
        try await withRefreshWorld(profileDays: 6, ledger: { seed(&$0, .stremioIOS, days: 6, installed: false) }) { w in
            let log = CallLog([])
            let steps = scripted(
                log,
                snapshot: { _, _, _ in
                    FreeDeviceCalls.SnapshotRead(snapshot: nil, error: SideloadError("DEVICE_LOCKED", "locked"), takenAt: testNow)
                })
            let out = await refresh(w, steps)
            #expect(!out.ok && result(out, .stremioIOS)?["status"] == "failed" && result(out, .stremioIOS)?["code"] == "DEVICE_LOCKED")
            #expect(result(out, .stremioIOS)?["steps"]?["install"] == "skipped" && log.value.isEmpty)
        }
    }

    @Test("an unrecorded app, the device unreachable on two runs: both fail with its code; a third run with the device installs it")
    func handInstalledDeviceUnreachableTwice() async throws {
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2, installed: false) }) { w in
            let log = CallLog([])
            let unreachable: @Sendable (Services, String, String) async -> FreeDeviceCalls.SnapshotRead = { _, _, _ in
                FreeDeviceCalls.SnapshotRead(snapshot: nil, error: SideloadError("DEVICE_NOT_CONNECTED", "gone"), takenAt: testNow)
            }
            // What real provision and sign leave behind: a new profile and a signed copy that carries it, six days out.
            let provision: @Sendable (ProvisionOptions) async -> Envelope = { options in
                _ = try? await w.services.ledgerStore.update { ledger in
                    for i in ledger.freeProfiles.indices {
                        ledger.freeProfiles[i].profileUuid = "NEWPROFILE"
                        ledger.freeProfiles[i].expires = daysFromNow(6)
                    }
                }
                return okEnvelope("provision", options.app ?? "", ["appIdNew": false])
            }
            let sign: @Sendable (SignOptions) async -> Envelope = { options in
                _ = try? await w.services.ledgerStore.update { ledger in
                    for i in ledger.freeSigned.indices {
                        ledger.freeSigned[i].profileUuid = "NEWPROFILE"
                        ledger.freeSigned[i].profileExpires = daysFromNow(6)
                    }
                }
                return okEnvelope("sign", options.app ?? "")
            }
            // Run 1: the signed copy is expiring, so provision and sign run; the install cannot.
            let first = await refresh(w, scripted(log, provision: provision, sign: sign, snapshot: unreachable))
            #expect(!first.ok && result(first, .stremioIOS)?["code"] == "DEVICE_NOT_CONNECTED")
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios"])

            // Run 2: the signed copy now reads six days, but the device copy still has two. Not a skip, not ok.
            log.value = []
            let second = await refresh(w, scripted(log, snapshot: unreachable))
            #expect(!second.ok, "a passing skip would hide the app that expires in two days")
            let item = try #require(result(second, .stremioIOS))
            #expect(item["status"] == "failed" && item["code"] == "DEVICE_NOT_CONNECTED")
            #expect(item["steps"]?["provision"] == "skipped" && item["steps"]?["sign"] == "skipped" && item["steps"]?["install"] == "skipped")
            #expect(log.value.isEmpty)
            #expect(second.errors.map(\.code) == ["DEVICE_NOT_CONNECTED"])

            // Run 3: the device is reachable; the real install runs and records the app.
            let third = await refresh(w, scripted(log, install: { options in await InstallCommand.run(w.services, options) }))
            #expect(third.ok, "\(third.errors)")
            #expect(log.value == ["install stremio-ios"])
            #expect(result(third, .stremioIOS)?["steps"]?["install"] == "done")
            let record = try #require(try w.ledger().installs.first)
            #expect(record.profileExpires == daysFromNow(6) && record.present)
        }
    }

    @Test("provision and sign worked but the install was blocked on an unrecorded app: the rerun still installs and records it")
    func handInstalledBlockedInstallThenRerun() async throws {
        // Installed by hand (no record), signed copy and profile expire in 2 days.
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2, installed: false) }) { w in
            let log = CallLog([])
            // What real provision and sign leave: a new profile and a signed copy that carries it, a week out. `sign` overwrites
            // the signed record's expiry, so the ledger now looks fresh although the device still has the old copy.
            let provision: @Sendable (ProvisionOptions) async -> Envelope = { options in
                _ = try? await w.services.ledgerStore.update { ledger in
                    for i in ledger.freeProfiles.indices {
                        ledger.freeProfiles[i].profileUuid = "NEWPROFILE"
                        ledger.freeProfiles[i].expires = daysFromNow(6)
                    }
                }
                return okEnvelope("provision", options.app ?? "", ["appIdNew": false])
            }
            let sign: @Sendable (SignOptions) async -> Envelope = { options in
                _ = try? await w.services.ledgerStore.update { ledger in
                    for i in ledger.freeSigned.indices {
                        ledger.freeSigned[i].profileUuid = "NEWPROFILE"
                        ledger.freeSigned[i].profileExpires = daysFromNow(6)
                    }
                }
                return okEnvelope("sign", options.app ?? "")
            }
            let first = await refresh(w, scripted(log, provision: provision, sign: sign, install: { _ in failEnvelope("install", "DEVICE_LOCKED") }))
            #expect(!first.ok && result(first, .stremioIOS)?["code"] == "DEVICE_LOCKED")
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios", "install stremio-ios"])
            let blocked = try w.ledger()
            #expect(blocked.installs.isEmpty)

            // The rerun: the signed copy now reads fresh, but the device copy is unknown, so the install is still due.
            log.value = []
            let rerun = await refresh(
                w, scripted(log, install: { options in await InstallCommand.run(w.services, options) }))
            #expect(rerun.ok, "\(rerun.errors)")
            #expect(log.value == ["install stremio-ios"])
            let item = try #require(result(rerun, .stremioIOS))
            #expect(item["status"] == "renewed")
            #expect(item["steps"]?["provision"] == "skipped" && item["steps"]?["sign"] == "skipped" && item["steps"]?["install"] == "done")
            #expect(w.runner.installCalls.count == 1)
            let record = try #require(try w.ledger().installs.first)
            #expect(record.profileExpires == daysFromNow(6) && record.present)
            #expect(record.refresh.lastResult == "refreshed")

            // Recorded now, so the normal rules apply: a fresh install is not due.
            log.value = []
            let third = await refresh(w, scripted(log))
            #expect(third.ok && result(third, .stremioIOS)?["code"] == "NOT_DUE" && log.value.isEmpty)
        }
    }

    // MARK: manual run, caps and suspension

    @Test("a manual run past the daily caps or on a suspended install warns, still runs, counts the attempt, and a success clears the suspension")
    func manualRunIgnoresCaps() async throws {
        var refresh0 = LedgerInstallRefresh(consecutiveFailures: 3, attemptsByDay: [today: 2], suspended: true)
        refresh0.lastCode = "PROFILE_NOT_RENEWED"
        refresh0.nextEligible = daysFromNow(1)
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2, refresh: refresh0) }) { w in
            let log = CallLog([])
            let out = await refresh(w, scripted(log))
            #expect(out.ok, "\(out.errors)")
            #expect(log.value.count == 3)
            #expect(Set(warnings(out)) == ["ATTEMPT_CAP_EXCEEDED", "INSTALL_SUSPENDED"])
            let fields = try refreshFields(w, .stremioIOS)
            #expect(fields.attemptsByDay == [today: 3] && !fields.suspended && fields.nextEligible == nil)
            #expect(fields.consecutiveFailures == 0 && fields.lastCode == nil)
        }
    }

    @Test("the counters follow the local day: a run the next day opens a new key; old days are pruned")
    func countersAcrossDays() async throws {
        try await withRefreshWorld(
            profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2, refresh: LedgerInstallRefresh(attemptsByDay: ["2000-01-01": 1])) }
        ) { w in
            let log = CallLog([])
            #expect(await refresh(w, scripted(log)).ok)
            w.clock.advance(86_400)
            #expect(await refresh(w, scripted(log)).ok)
            let tomorrow = RefreshPolicy.dayKey(testNow.addingTimeInterval(86_400), timeZone: utc)
            let counted = try refreshFields(w, .stremioIOS)
            #expect(counted.attemptsByDay == [today: 1, tomorrow: 1])
        }
    }

    // MARK: guards on the command

    @Test("usage and confirmation: --device is required, --yes is required, an unsaved device is DEVICE_NOT_SAVED")
    func frontChecks() async throws {
        try await withRefreshWorld(profileDays: 2, ledger: { seed(&$0, .stremioIOS, days: 2) }) { w in
            let log = CallLog([])
            let noDevice = await refresh(w, scripted(log), device: nil)
            #expect(!noDevice.ok && noDevice.errors.first?.code == "USAGE")
            let noYes = await refresh(w, scripted(log), yes: false)
            #expect(!noYes.ok && noYes.errors.first?.code == "CONFIRM_REQUIRED")
            let unsaved = await refresh(w, scripted(log), device: "nowhere")
            #expect(!unsaved.ok && unsaved.errors.first?.code == "DEVICE_NOT_SAVED")
            #expect(log.value.isEmpty && w.runner.deviceCalls.isEmpty)
            try w.expectClean(noYes)
            // Through the CLI parser: the designed but unbuilt flags answer USAGE.
            for flag in ["--auto", "--print-agent"] {
                let out = await run(argv: ["refresh", flag], services: w.services)
                #expect(!out.ok && out.errors.first?.code == "USAGE", "\(flag)")
            }
            let viaCli = await run(argv: ["refresh", "--device", "iphone"], services: w.services)
            #expect(viaCli.errors.first?.code == "CONFIRM_REQUIRED")
        }
    }

    // MARK: through the real install path

    @Test("with provision and sign already done, the real install path renews the device copy and records the refresh fields")
    func realInstallPath() async throws {
        var stale = LedgerInstallRefresh(consecutiveFailures: 3, suspended: true)
        stale.lastCode = "PROFILE_NOT_RENEWED"
        // The device copy has a day left; the stored profile and the signed copy (same profile) are 5 days out.
        try await withRefreshWorld(
            profileDays: 5,
            ledger: {
                seed(&$0, .stremioIOS, days: 5)
                var install = installRecord(.stremioIOS, refresh: stale)
                install.profileExpires = daysFromNow(1)
                $0.installs = [install]
            }
        ) { w in
            let out = await RefreshCommand.run(
                w.services, RefreshOptions(device: "iphone", yes: true), steps: RefreshSteps(), timeZone: utc)
            #expect(out.ok, "\(out.errors)")
            let item = try #require(result(out, .stremioIOS))
            #expect(item["status"] == "renewed")
            #expect(item["steps"]?["provision"] == "skipped" && item["steps"]?["sign"] == "skipped" && item["steps"]?["install"] == "done")
            #expect(item["daysLeftBefore"] == 1 && item["daysLeftAfter"] == 5)
            #expect(w.runner.installCalls.count == 1)
            let record = try #require(try w.ledger().installs.first)
            #expect(record.profileExpires == daysFromNow(5))
            #expect(record.refresh.lastResult == "refreshed" && !record.refresh.suspended && record.refresh.consecutiveFailures == 0)
            #expect(record.refresh.attemptsByDay == [today: 1] && record.refresh.lastCode == nil)
            // A reinstall is slot-neutral and refresh writes no slot.
            #expect(w.runner.deviceApps.keys.contains(w.bundleId))
            try w.expectClean(out)
        }
    }
}
