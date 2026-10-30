import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import sideload

// `refresh --auto` (design section 18): the pure gates, the log, the notifier and the run itself. The steps are scripted, the
// device list and `osascript` are answered by `AutoRunner` (no real devicectl or notification), the clock moves by hand.

private let utc = TimeZone(identifier: "UTC")!
private let today = RefreshPolicy.dayKey(testNow, timeZone: utc)

// MARK: pure gates

private func subject(
    _ app: ProvisionApp = .stremioIOS, days: Double = 2, present: Bool = true, lent: Bool = false, installed: Bool = true,
    signedVersion: String? = "1.2.3", refresh: LedgerInstallRefresh = LedgerInstallRefresh()
) -> RefreshPolicy.Subject {
    var install = installRecord(app, present: present, refresh: refresh)
    install.profileExpires = daysFromNow(days)
    let signed = signedVersion.map {
        LedgerFreeSigned(
            id: "iphone/\(app.rawValue)", device: "iphone", app: app.rawValue, bundleId: "x", version: $0, sha256Prefix: "abcd1234",
            profileUuid: "u", profileExpires: daysFromNow(days), certFp8: "deadbeef", signedAt: daysFromNow(-1), path: "p",
            strippedExtensions: [], droppedEntitlements: [])
    }
    return RefreshPolicy.Subject(app: app, install: installed ? install : nil, signed: signed, profile: nil, lent: lent)
}

private func gate(
    _ subject: RefreshPolicy.Subject, pending: Bool = false, deviceAttempts: Int = 0, now: Date = testNow
) -> RefreshPolicy.AutoSkip? {
    RefreshPolicy.autoGate(subject, slotPending: pending, deviceAttempts: deviceAttempts, now: now, timeZone: utc)
}

@Suite("refresh --auto: the gates")
struct RefreshAutoGateTests {
    @Test("a recorded, present, due, quiet install passes every gate")
    func passes() {
        #expect(gate(subject()) == nil)
        // Exactly 5 days left is due; an expired profile is due too.
        #expect(gate(subject(days: 5)) == nil)
        #expect(gate(subject(days: -1)) == nil)
    }

    @Test("each per-install gate has its own code")
    func eachGate() {
        #expect(gate(subject(installed: false)) == .notRecorded)
        #expect(gate(subject(present: false, lent: true)) == .lent)
        #expect(gate(subject(present: false)) == .notPresent)
        #expect(gate(subject(refresh: LedgerInstallRefresh(suspended: true))) == .suspended)
        #expect(gate(subject(), pending: true) == .slotPending)
        #expect(gate(subject(signedVersion: "2.0.0")) == .signedVersionDiffers)
        #expect(gate(subject(days: 5.01)) == .notDue)
        #expect(gate(subject(refresh: LedgerInstallRefresh(nextEligible: testNow.addingTimeInterval(1)))) == .backoff)
        #expect(gate(subject(refresh: LedgerInstallRefresh(attemptsByDay: [today: 2]))) == .installCap)
        #expect(gate(subject(), deviceAttempts: 4) == .deviceCap)
        #expect(gate(subject(refresh: LedgerInstallRefresh(lastAttempt: testNow.addingTimeInterval(-299)))) == .recentAttempt)
    }

    @Test("the boundaries: the backoff ends at nextEligible, the gap at 5 minutes, yesterday's attempts do not count")
    func boundaries() {
        #expect(gate(subject(refresh: LedgerInstallRefresh(nextEligible: testNow))) == nil)
        #expect(gate(subject(refresh: LedgerInstallRefresh(lastAttempt: testNow.addingTimeInterval(-300)))) == nil)
        #expect(gate(subject(refresh: LedgerInstallRefresh(attemptsByDay: [today: 1]))) == nil)
        #expect(gate(subject(refresh: LedgerInstallRefresh(attemptsByDay: ["2000-01-01": 9]))) == nil)
        #expect(gate(subject(), deviceAttempts: 3) == nil)
        // No signed record: nothing to compare, so the version gate does not apply.
        #expect(gate(subject(signedVersion: nil)) == nil)
    }

    @Test("the gates run in a fixed order: a lent slot is LENT, not NOT_PRESENT; a suspension beats a pending slot beats a version")
    func order() {
        let everything = LedgerInstallRefresh(
            lastAttempt: testNow, nextEligible: testNow.addingTimeInterval(60), attemptsByDay: [today: 9], suspended: true)
        #expect(gate(subject(days: 30, present: false, lent: true, signedVersion: "9", refresh: everything), pending: true, deviceAttempts: 9) == .lent)
        #expect(gate(subject(days: 30, signedVersion: "9", refresh: everything), pending: true, deviceAttempts: 9) == .suspended)
        var quiet = everything
        quiet.suspended = false
        #expect(gate(subject(days: 30, signedVersion: "9", refresh: quiet), pending: true, deviceAttempts: 9) == .slotPending)
        #expect(gate(subject(days: 30, signedVersion: "9", refresh: quiet), deviceAttempts: 9) == .signedVersionDiffers)
        #expect(gate(subject(days: 30, refresh: quiet), deviceAttempts: 9) == .notDue)
        #expect(gate(subject(refresh: quiet), deviceAttempts: 9) == .backoff)
        quiet.nextEligible = nil
        #expect(gate(subject(refresh: quiet), deviceAttempts: 9) == .installCap)
        quiet.attemptsByDay = [:]
        #expect(gate(subject(refresh: quiet), deviceAttempts: 9) == .deviceCap)
        #expect(gate(subject(refresh: quiet)) == .recentAttempt)
    }

    @Test("the whole-run gates go cheapest first and read nothing once one has stopped the run")
    func runGateOrder() {
        let ledgerReads = Box(0)
        let lockProbes = Box(0)
        func run(kill: Bool, ledger: Ledger?, busy: Bool) -> RefreshPolicy.AutoSkip? {
            RefreshPolicy.runGate(
                killSwitch: kill, ledger: { ledgerReads.value += 1; return ledger }(), lockBusy: { lockProbes.value += 1; return busy }())
        }
        #expect(run(kill: true, ledger: nil, busy: true) == .killSwitch)
        #expect(ledgerReads.value == 0 && lockProbes.value == 0)
        #expect(run(kill: false, ledger: nil, busy: true) == .ledgerUnreadable)
        #expect(ledgerReads.value == 1 && lockProbes.value == 0)
        var suspended = Ledger()
        suspended.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow)
        #expect(run(kill: false, ledger: suspended, busy: true) == .freeCertChanged)
        #expect(lockProbes.value == 0)
        #expect(run(kill: false, ledger: Ledger(), busy: true) == .operationInProgress)
        #expect(lockProbes.value == 1)
        #expect(run(kill: false, ledger: Ledger(), busy: false) == nil)
    }

    @Test("only devices the owner opted in with a valid reserve are acted on; an opted-in one with a bad reserve is reported")
    func devices() throws {
        let good = SavedDevice(udid: savedUdid("1"), platform: "ios", autoRefresh: true, freeSlotsReserved: 1)
        let bad = SavedDevice(udid: savedUdid("2"), platform: "tvos", autoRefresh: true, freeSlotsReserved: 9)
        let off = SavedDevice(udid: savedUdid("3"), platform: "ios", autoRefresh: false, freeSlotsReserved: 0)
        let (eligible, invalid) = RefreshPolicy.autoDevices(["b": good, "a": good, "tv": bad, "off": off, "bad alias!": good])
        #expect(eligible == ["a", "b"] && invalid == ["tv"])
    }

    @Test("a certificate, keychain, account or ledger failure ends the run for every device; a slot or delta failure only its device")
    func stops() {
        for code in ["FREE_CERT_CHANGED", "IDENTITY_CHECK_FAILED", "FREE_IDENTITY_ADDED", "KEYCHAIN_LOCKED", "ACCOUNT_NOT_SIGNED_IN", "LEDGER_INVALID"] {
            #expect(RefreshPolicy.stopsWholeRun(code), "\(code)")
        }
        for code in ["SLOT_PENDING", "UNEXPECTED_APP_DELTA", "SIGN_FAILED", "DEVICE_LOCKED", "VERSION_NOT_AVAILABLE"] {
            #expect(!RefreshPolicy.stopsWholeRun(code), "\(code)")
        }
    }
}

// MARK: notifier and log

private final class NoticeRunner: Runner {
    let seen = Mutex<[CommandSpec]>([])
    let result: RunResult
    init(_ result: RunResult = RunResult()) { self.result = result }
    func run(_ spec: CommandSpec) async -> RunResult {
        seen.withLock { $0.append(spec) }
        return result
    }
}

@Suite("refresh --auto: notifier and log")
struct RefreshAutoOutputTests {
    @Test("the message is the last argument, never part of the script, and is cut to aliases, app names, numbers and codes")
    func notifierArguments() async {
        let runner = NoticeRunner()
        let ok = await Notifier(runner: runner).notify("-- stremio-ios @ iphone failed DEVICE_LOCKED, next 14:30, 4 d left\" & (do shell script \"x\") `$(id)`")
        #expect(ok)
        let spec = runner.seen.withLock { $0 }[0]
        #expect(spec.executable == "/usr/bin/osascript" && spec.timeout == .seconds(10))
        let message = spec.args.last ?? ""
        #expect(message == "stremio-ios @ iphone failed DEVICE_LOCKED, next 14:30, 4 d left  do shell script x id")
        #expect(!spec.args.dropLast().contains { $0.contains("shell") || $0.contains("stremio") })
        #expect(spec.args.dropLast().filter { $0 == "-e" }.count == 3)
        #expect(Notifier.sanitised("---x") == "x" && Notifier.sanitised("é/\\;'\n") == "")
        #expect(Notifier.sanitised(String(repeating: "a", count: 500)).count == 160)
    }

    @Test("a notification that fails or times out is only reported, never thrown")
    func notifierFailure() async {
        #expect(await Notifier(runner: NoticeRunner(RunResult(code: 1, stderr: "not allowed"))).notify("x @ y refreshed") == false)
        #expect(await Notifier(runner: NoticeRunner(RunResult(code: nil, timedOut: true))).notify("x @ y refreshed") == false)
        #expect(await Notifier(runner: NoticeRunner(RunResult(code: nil, spawnError: "ENOENT"))).notify("x @ y refreshed") == false)
        #expect(await Notifier(runner: NoticeRunner()).notify("\u{1F600}") == false, "nothing left to say")
    }

    @Test("the texts")
    func texts() {
        #expect(Notifier.refreshed(app: "stremio", alias: "iphone", daysLeft: 7) == "stremio @ iphone refreshed, 7 d left")
        #expect(
            Notifier.failed(app: "stremio", alias: "iphone", code: "DEVICE_LOCKED", next: "14:30", daysLeft: 4)
                == "stremio @ iphone failed DEVICE_LOCKED, next 14:30, 4 d left")
        #expect(Notifier.failed(app: "a", alias: "b", code: "X_Y", next: nil, daysLeft: -2) == "a @ b failed X_Y, 0 d left")
        #expect(Notifier.suspended(app: "a", alias: "b", code: "X_Y").hasPrefix("a @ b suspended after X_Y"))
    }

    @Test("a code that is not a plain code, or holds a device-ID-sized run of hex, is OTHER")
    func logCodes() {
        #expect(RefreshLog.code("DEVICE_LOCKED") == "DEVICE_LOCKED")
        for raw in [savedUdid("1"), savedCoreId("1"), "device iphone is locked", "lower_case", "", "A", "ABCDEF0123456789", "/Users/x/y"] {
            #expect(RefreshLog.code(raw) == "OTHER", "\(raw)")
        }
        #expect(RefreshLog.alias("iphone") == "iphone" && RefreshLog.alias("my phone!") == "?")
    }

    @Test("the log is 0600, one object per line with sorted keys, and rotates at 1 MiB into a single older file")
    func logFileAndRotation() async throws {
        try await withTestHome { paths, _ in
            let log = RefreshLog(paths: paths, clock: FixedClock(testNow), run: "abc12345")
            log.record("run", ["ok": true, "z": 1])
            #expect(modeOf(paths.refreshLog) == 0o600)
            let text = try String(contentsOfFile: paths.refreshLog, encoding: .utf8)
            #expect(text == "{\"event\":\"run\",\"ok\":true,\"run\":\"abc12345\",\"ts\":\"2026-10-19T12:00:00.000Z\",\"z\":1}\n")
            // Fill the file to the limit, then write once more.
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.refreshLog))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: UInt8(ascii: "x"), count: RefreshLog.rotateAt))
            try handle.close()
            log.record("run", ["n": 2])
            #expect(listing(paths.logs).sorted() == ["refresh.jsonl", "refresh.jsonl.1"])
            #expect(try String(contentsOfFile: paths.refreshLog, encoding: .utf8).contains("\"n\":2"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: paths.refreshLog + ".1")).count > RefreshLog.rotateAt)
            #expect(modeOf(paths.refreshLog) == 0o600 && modeOf(paths.refreshLog + ".1") == 0o600)
            // A second rotation replaces the older file rather than adding a third.
            let again = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.refreshLog))
            try again.seekToEnd()
            try again.write(contentsOf: Data(repeating: UInt8(ascii: "y"), count: RefreshLog.rotateAt))
            try again.close()
            log.record("run", ["n": 3])
            #expect(listing(paths.logs).sorted() == ["refresh.jsonl", "refresh.jsonl.1"])
        }
    }

    @Test("record cleans every field itself: aliases, codes, the keys of a tally, plain tokens; nothing that is not a scalar")
    func recordCleans() async throws {
        try await withTestHome { paths, _ in
            let log = RefreshLog(paths: paths, clock: FixedClock(testNow), run: "abc12345")
            log.record(
                "install",
                [
                    "device": .string(savedUdid("1")), "app": "stremio-ios", "reason": "not a code", "code": .string(savedCoreId("1")),
                    "decision": "/Users/someone/x", "skipped": ["KILL_SWITCH": 2, "lower": 1, "bad one": 4, "ok": "no"],
                    "nested": ["a": 1], "list": [1], "n": 3, "flag": true,
                ])
            let data = try #require(try readFile(paths.refreshLog))
            let line = try JSONDecoder().decode(JSONValue.self, from: data)
            #expect(line["device"] == "?" && line["app"] == "stremio-ios" && line["reason"] == "OTHER" && line["code"] == "OTHER")
            #expect(line["decision"] == "?" && line["nested"] == .null && line["list"] == .null)
            #expect(line["n"] == 3 && line["flag"] == true && line["event"] == "install")
            #expect(line["skipped"] == ["KILL_SWITCH": 2, "OTHER": 5])
        }
    }

    @Test("a log that cannot be written never fails the caller")
    func logWriteFailure() throws {
        let log = RefreshLog(paths: Paths(home: "/dev/null/x"), clock: FixedClock(testNow), run: "r")
        log.record("run")
    }
}

// MARK: the run

/// The simulated device plus what `refresh --auto` also reaches for: `devicectl list devices` (answered from `listing`, counted)
/// and `osascript` (recorded).
private final class AutoRunner: Runner {
    let inner: DeviceSimRunner
    private let state = Mutex(State())

    struct State {
        var listing: JSONValue?
        var listCalls = 0
        var notices: [CommandSpec] = []
        var noticeResult = RunResult()
    }

    init(_ inner: DeviceSimRunner, listing: JSONValue?) {
        self.inner = inner
        state.withLock { $0.listing = listing }
    }

    var listCalls: Int { state.withLock { $0.listCalls } }
    var notices: [String] { state.withLock { $0.notices.map { $0.args.last ?? "" } } }
    var noticeSpecs: [CommandSpec] { state.withLock { $0.notices } }
    func setListing(_ listing: JSONValue?) { state.withLock { $0.listing = listing } }
    func setNoticeResult(_ result: RunResult) { state.withLock { $0.noticeResult = result } }

    func run(_ spec: CommandSpec) async -> RunResult {
        if spec.executable == Notifier.executable {
            return state.withLock { value in
                value.notices.append(spec)
                return value.noticeResult
            }
        }
        if spec.executable == "xcrun", spec.args.first == "devicectl", DeviceSimRunner.words(spec) == "list devices" {
            let listing = state.withLock { value -> JSONValue? in
                value.listCalls += 1
                return value.listing
            }
            guard let listing, let flag = spec.args.firstIndex(of: "--json-output"),
                let data = try? JSONEncoder().encode(listing)
            else { return RunResult(code: 1) }
            try? data.write(to: URL(fileURLWithPath: spec.args[flag + 1]))
            return RunResult()
        }
        return await inner.run(spec)
    }
}

private struct AutoWorld {
    let w: InstallWorld
    let runner: AutoRunner
    let services: Services
}

private typealias CallBox = Box<[String]>

private func bundleId(_ app: ProvisionApp) -> String { carrierPrefix + ".free." + app.suffix }

private func seedInstall(
    _ ledger: inout Ledger, _ app: ProvisionApp, days: Double, installed: Bool = true, present: Bool = true,
    refresh: LedgerInstallRefresh = LedgerInstallRefresh()
) {
    let key = "\(app.devicePlatform == "tvos" ? "appletv" : "iphone")/\(app.rawValue)"
    let expires = daysFromNow(days)
    for i in ledger.freeProfiles.indices where ledger.freeProfiles[i].id == key { ledger.freeProfiles[i].expires = expires }
    for i in ledger.freeSigned.indices where ledger.freeSigned[i].id == key { ledger.freeSigned[i].profileExpires = expires }
    ledger.installs.removeAll { $0.id == key }
    if installed {
        var record = installRecord(app, alias: app.devicePlatform == "tvos" ? "appletv" : "iphone", present: present, refresh: refresh)
        record.profileExpires = expires
        ledger.installs.append(record)
    }
}

private let phoneAndTV: JSONValue = deviceListJSON(
    phoneEntryJSON(),
    deviceEntryJSON(name: "Test Apple TV", udid: savedUdid("2"), coreId: savedCoreId("2"), platform: "tvOS"))

/// A world with `apps` signed (and on the device), the iPhone (and the Apple TV, if `optIn` names it) opted in to auto-refresh.
private func withAutoWorld(
    _ apps: [ProvisionApp] = [.stremioIOS], profileDays: Double = 2, optIn: [String] = ["iphone"],
    listing: JSONValue? = phoneAndTV, manifest seedVersions: Bool = true, ledger tweak: ((inout Ledger) -> Void)? = nil,
    snapshotFailures: Set<Int> = [], _ body: (AutoWorld) async throws -> Void
) async throws {
    var script = DeviceScript()
    script.snapshotFailures = snapshotFailures
    for app in apps { script.initial[bundleId(app)] = true }
    try await withInstallWorld(
        app: apps[0], alsoSigned: Array(apps.dropFirst()), script: script, profileDays: profileDays,
        ledger: { ledger in
            for app in apps { seedInstall(&ledger, app, days: profileDays) }
            tweak?(&ledger)
        }
    ) { w in
        try await w.store.update { config in
            for alias in optIn { config.devices[alias]?.autoRefresh = true }
        }
        // The installed version (1.2.3) is a fetched, approved version on disk, as auto-refresh needs it to be.
        if seedVersions {
            try seedManifest(w, apps.filter { $0 != .filler }.map { manifestEntry("1.2.3", app: $0.rawValue, fetchedDays: -9) })
        }
        let runner = AutoRunner(w.runner, listing: listing)
        var services = w.services
        services.runner = runner
        try await body(AutoWorld(w: w, runner: runner, services: services))
    }
}

private func okStep(_ command: String, _ options: String?) -> Envelope {
    .result(command, ["app": .string(options ?? ""), "appIdNew": false])
}

private func failStep(_ code: String) -> Envelope {
    .fail("step", code: code, message: "\(code) happened.", fix: "Fix \(code).")
}

/// Scripted steps that record `provision <app>`, `provision <app> renew`, `sign <app>` and `install <app>`.
private func autoSteps(
    _ log: CallBox,
    provision: @escaping @Sendable (ProvisionOptions) async -> Envelope = { okStep("provision", $0.app) },
    sign: @escaping @Sendable (SignOptions) async -> Envelope = { okStep("sign", $0.app) },
    install: @escaping @Sendable (InstallOptions) async -> Envelope = { okStep("install", $0.app) }
) -> RefreshSteps {
    var steps = RefreshSteps()
    steps.provision = { _, options in
        log.value.append("provision \(options.app ?? "")" + (options.renew ? " renew" : ""))
        #expect(options.yes && !options.registerDevice, "auto never registers a device")
        return await provision(options)
    }
    steps.sign = { _, options in
        log.value.append("sign \(options.app ?? "")")
        return await sign(options)
    }
    steps.install = { _, options in
        log.value.append("install \(options.app ?? "")")
        return await install(options)
    }
    return steps
}

private func auto(_ a: AutoWorld, _ steps: RefreshSteps) async -> Envelope {
    await RefreshCommand.runAuto(a.services, steps: steps, timeZone: utc)
}

private func autoResults(_ out: Envelope, device: String = "iphone") -> [JSONValue] {
    let entry = out.data["devices"]?.array?.first { $0["alias"] == .string(device) }
    return entry?["results"]?.array ?? []
}

private func autoResult(_ out: Envelope, _ app: ProvisionApp, device: String = "iphone") -> JSONValue? {
    autoResults(out, device: device).first { $0["app"] == .string(app.rawValue) }
}

private func skippedCount(_ out: Envelope, _ code: String) -> Int {
    if case .number(let n)? = out.data["skipped"]?[code] { return Int(n) }
    return 0
}

private func fields(_ a: AutoWorld, _ app: ProvisionApp = .stremioIOS) throws -> LedgerInstallRefresh {
    try #require(try a.w.ledger().installs.first { $0.id == "iphone/\(app.rawValue)" }).refresh
}

private func logLines(_ a: AutoWorld) throws -> [JSONValue] {
    guard let data = try readFile(a.w.paths.refreshLog) else { return [] }
    return try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
}

private func logged(_ a: AutoWorld, _ event: String) throws -> [JSONValue] {
    try logLines(a).filter { $0["event"] == .string(event) }
}

@Suite("refresh --auto: the run")
struct RefreshAutoTests {
    // MARK: the happy path

    @Test("a due install is provisioned, signed and installed; the owner is told; the envelope, the ledger and the log agree")
    func happyPath() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && out.exitCode == 0 && out.command == "refresh", "\(out.errors)")
            #expect(out.data["auto"] == true)
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios", "install stremio-ios"])
            let item = try #require(autoResult(out, .stremioIOS))
            #expect(item["status"] == "renewed" && item["daysLeftBefore"] == 2)
            #expect(a.runner.listCalls == 1)
            #expect(a.runner.notices == ["stremio-ios @ iphone refreshed, 2 d left"])
            let refresh = try fields(a)
            #expect(refresh.attemptsByDay == [today: 1] && refresh.lastResult == "refreshed" && refresh.consecutiveFailures == 0)

            // One `run` line, an `install` decision, one line per step, and the attempt's result.
            let lines = try logLines(a)
            let runs = try logged(a, "run")
            #expect(runs.count == 1)
            #expect(try logged(a, "install").count == 1)
            #expect(try logged(a, "step").count == 3)
            #expect(Set(lines.compactMap { $0["run"]?.string }).count == 1)
            let result = try #require(try logged(a, "result").first)
            #expect(result["decision"] == "renewed" && result["notified"] == true && result["daysLeft"] == 2)
            #expect(result["newExpires"]?.string?.hasPrefix("2026-10-21") == true)
            #expect(try logged(a, "step").map { $0["step"] } == ["provision", "sign", "install"])
            #expect(runs[0]["ok"] == true && runs[0]["renewed"] == 1)
            #expect(modeOf(a.w.paths.refreshLog) == 0o600)
        }
    }

    @Test("a manual run writes no auto log and says nothing to the owner")
    func manualIsQuiet() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            let log = CallBox([])
            let out = await RefreshCommand.run(
                a.services, RefreshOptions(device: "iphone", yes: true), steps: autoSteps(log), timeZone: utc)
            #expect(out.ok && log.value.count == 3)
            #expect(a.runner.notices.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: a.w.paths.refreshLog))
        }
    }

    // MARK: nothing to do

    @Test("nothing due: ok, NOT_DUE counted, no step, no devicectl call, no notification")
    func nothingDue() async throws {
        try await withAutoWorld(profileDays: 6) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && skippedCount(out, "NOT_DUE") == 1)
            #expect(log.value.isEmpty && a.runner.listCalls == 0 && a.runner.notices.isEmpty && a.w.runner.deviceCalls.isEmpty)
            // Not-due decisions are the quiet ones: only the run line is logged.
            let lines = try logLines(a)
            #expect(lines.map { $0["event"] } == ["run"])
        }
    }

    @Test("a device the owner did not opt in is never looked at")
    func notOptedIn() async throws {
        try await withAutoWorld(profileDays: 2, optIn: []) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && autoResults(out).isEmpty && out.data["devices"]?.array?.isEmpty == true)
            #expect(log.value.isEmpty && a.runner.listCalls == 0)
        }
    }

    @Test("an opted-in device with a reserve out of range is a logged skip, not a failure")
    func invalidReserve() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            var config = try a.w.config()
            config.devices["iphone"] = SavedDevice(
                udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios", autoRefresh: true, freeSlotsReserved: 9)
            let saved = config
            try await a.w.store.update { $0 = saved }
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && skippedCount(out, "CONFIG_INVALID") == 1 && log.value.isEmpty && a.runner.listCalls == 0)
        }
    }

    @Test("the kill switch file: the whole run is a skip before anything else is read, probed or run")
    func killSwitch() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            try Data().write(to: URL(fileURLWithPath: a.w.paths.refreshDisabled))
            // Neither an unreadable ledger nor a held lock changes the answer: the switch is the first gate.
            try Data("{".utf8).write(to: URL(fileURLWithPath: a.w.paths.ledger))
            let held = try OperationLock.acquire(paths: a.w.paths)
            defer { held.release() }
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && skippedCount(out, "KILL_SWITCH") == 1)
            #expect(log.value.isEmpty && a.runner.listCalls == 0 && a.runner.notices.isEmpty)
            #expect(try logged(a, "run")[0]["reason"] == "KILL_SWITCH")
        }
    }

    @Test("a free-team suspension on the ledger: FREE_CERT_CHANGED, a skip; auto never clears it")
    func freeSuspension() async throws {
        try await withAutoWorld(profileDays: 2, ledger: { $0.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow) }) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && skippedCount(out, "FREE_CERT_CHANGED") == 1)
            #expect(log.value.isEmpty && a.runner.listCalls == 0 && a.runner.notices.isEmpty)
            let suspension = try a.w.ledger().freeSuspended
            #expect(suspension != nil)
        }
    }

    @Test("an unreadable ledger is a failure, not a skip: nothing runs and the code says why")
    func unreadableLedger() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            try Data("{".utf8).write(to: URL(fileURLWithPath: a.w.paths.ledger))
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(!out.ok && out.exitCode == 1 && out.errors.first?.code == "LEDGER_INVALID")
            #expect(log.value.isEmpty && a.runner.listCalls == 0)
        }
    }

    @Test("a busy lock is a logged skip, ok, silent, never waited on, and no counter moves")
    func busyLock() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            let before = try a.w.ledger()
            let held = try OperationLock.acquire(paths: a.w.paths)
            defer { held.release() }
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && out.exitCode == 0 && skippedCount(out, "OPERATION_IN_PROGRESS") == 1)
            #expect(log.value.isEmpty && a.runner.listCalls == 0 && a.runner.notices.isEmpty)
            #expect(try a.w.ledger().installs == before.installs)
            #expect(try logged(a, "run")[0]["reason"] == "OPERATION_IN_PROGRESS")
        }
    }

    // MARK: one test per install gate

    enum GateCase: String, CaseIterable, CustomTestStringConvertible {
        case notRecorded = "NOT_RECORDED", lent = "LENT", notPresent = "NOT_PRESENT", suspended = "SUSPENDED"
        case slotPending = "SLOT_PENDING", signedVersionDiffers = "SIGNED_VERSION_DIFFERS", notDue = "NOT_DUE"
        case backoff = "BACKOFF", installCap = "INSTALL_CAP", deviceCap = "DEVICE_CAP", recentAttempt = "RECENT_ATTEMPT"

        var testDescription: String { rawValue }

        var apps: [ProvisionApp] { self == .slotPending || self == .deviceCap ? [.stremioIOS, .apollo] : [.stremioIOS] }

        func seed(_ ledger: inout Ledger) {
            switch self {
            case .notRecorded: seedInstall(&ledger, .stremioIOS, days: 2, installed: false)
            case .lent:
                seedInstall(&ledger, .stremioIOS, days: 2, present: false)
                ledger.lent = [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1))]
            case .notPresent: seedInstall(&ledger, .stremioIOS, days: 2, present: false)
            case .suspended: seedInstall(&ledger, .stremioIOS, days: 2, refresh: LedgerInstallRefresh(suspended: true))
            case .slotPending:
                // The lab is in the middle of lending another app of the same device.
                seedInstall(&ledger, .apollo, days: 2, present: false)
                ledger.lent = [LedgerLent(app: "apollo", device: "iphone", to: "lab", since: daysFromNow(-1), state: LedgerLent.lending, opAt: testNow)]
            case .signedVersionDiffers:
                for i in ledger.freeSigned.indices { ledger.freeSigned[i].version = "9.9.9" }
            case .notDue: seedInstall(&ledger, .stremioIOS, days: 6)
            case .backoff:
                seedInstall(&ledger, .stremioIOS, days: 2, refresh: LedgerInstallRefresh(nextEligible: testNow.addingTimeInterval(600)))
            case .installCap:
                seedInstall(&ledger, .stremioIOS, days: 2, refresh: LedgerInstallRefresh(attemptsByDay: [today: 2]))
            case .deviceCap:
                seedInstall(&ledger, .apollo, days: 30, refresh: LedgerInstallRefresh(attemptsByDay: [today: 4]))
            case .recentAttempt:
                seedInstall(&ledger, .stremioIOS, days: 2, refresh: LedgerInstallRefresh(lastAttempt: testNow.addingTimeInterval(-60)))
            }
        }
    }

    @Test("each install gate skips with its own code: no step, no devicectl, no notification, no counter moved", arguments: GateCase.allCases)
    func gates(_ gateCase: GateCase) async throws {
        try await withAutoWorld(gateCase.apps, profileDays: 2, ledger: { gateCase.seed(&$0) }) { a in
            let before = try a.w.ledger().installs
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && out.exitCode == 0, "\(out.errors)")
            #expect(autoResult(out, .stremioIOS)?["status"] == "skipped")
            #expect(autoResult(out, .stremioIOS)?["code"] == .string(gateCase.rawValue))
            #expect(skippedCount(out, gateCase.rawValue) >= 1)
            #expect(log.value.isEmpty && a.runner.listCalls == 0 && a.runner.notices.isEmpty && a.w.runner.deviceCalls.isEmpty)
            #expect(try a.w.ledger().installs == before)
            if gateCase != .notDue {
                let decisions = try logged(a, "install").filter { $0["app"] == "stremio-ios" }
                #expect(decisions.count == 1 && decisions[0]["decision"] == "skip" && decisions[0]["reason"] == .string(gateCase.rawValue))
            }
        }
    }

    @Test("an app with no record at all is not an install of the device and is not listed")
    func unknownAppUnlisted() async throws {
        try await withAutoWorld([.stremioIOS], profileDays: 6) { a in
            let out = await auto(a, autoSteps(CallBox([])))
            #expect(autoResults(out).map { $0["app"] } == ["stremio-ios"], "apollo and the filler have no record")
        }
    }

    // MARK: the device

    @Test("a device that is not visible is DEVICE_NOT_VISIBLE: not an attempt, not a failure, silent")
    func deviceNotVisible() async throws {
        for listing in [deviceListJSON(), deviceListJSON(phoneEntryJSON(tunnel: "unavailable")), nil] as [JSONValue?] {
            try await withAutoWorld(profileDays: 2, listing: listing) { a in
                let before = try a.w.ledger().installs
                let log = CallBox([])
                let out = await auto(a, autoSteps(log))
                #expect(out.ok && skippedCount(out, "DEVICE_NOT_VISIBLE") == 1)
                let skip = try #require(try logged(a, "install").first)
                #expect(skip["reason"] == "DEVICE_NOT_VISIBLE" && skip["daysLeft"] == 2)
                #expect(log.value.isEmpty && a.runner.listCalls == 1 && a.runner.notices.isEmpty)
                #expect(try a.w.ledger().installs == before)
            }
        }
    }

    @Test("a paired device with no live connection is probed by its app list and renewed when it answers")
    func disconnectedProbed() async throws {
        try await withAutoWorld(profileDays: 2, listing: deviceListJSON(phoneEntryJSON(tunnel: "disconnected"))) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok, "\(out.errors)")
            #expect(autoResult(out, .stremioIOS)?["status"] == "renewed")
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios", "install stremio-ios"])
            #expect(skippedCount(out, "DEVICE_NOT_VISIBLE") == 0)
        }
    }

    @Test("a probe that gets no answer is DEVICE_NOT_VISIBLE: nothing provisioned, not an attempt, silent, the code logged")
    func disconnectedProbeFails() async throws {
        try await withAutoWorld(
            profileDays: 2, listing: deviceListJSON(phoneEntryJSON(tunnel: "disconnected")), snapshotFailures: [1]
        ) { a in
            let before = try a.w.ledger().installs
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && out.errors.isEmpty, "\(out.errors)")
            #expect(autoResult(out, .stremioIOS)?["code"] == "DEVICE_NOT_VISIBLE")
            #expect(skippedCount(out, "DEVICE_NOT_VISIBLE") == 1)
            #expect(log.value.isEmpty && a.runner.notices.isEmpty && a.w.runner.installCalls.isEmpty)
            #expect(try a.w.ledger().installs == before)
            #expect(try fields(a).attemptsByDay.isEmpty)
            let skip = try #require(try logged(a, "install").first { $0["app"] == "stremio-ios" })
            #expect(skip["reason"] == "DEVICE_NOT_VISIBLE" && skip["daysLeft"] == 2)
            #expect(skip["probe"]?.string?.isEmpty == false && skip["probe"] != "OTHER")
        }
    }

    @Test("a connected device whose app list fails is still an attempt (the install is blocked), not DEVICE_NOT_VISIBLE")
    func connectedSnapshotFails() async throws {
        try await withAutoWorld(profileDays: 2, listing: deviceListJSON(phoneEntryJSON()), snapshotFailures: [1]) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(skippedCount(out, "DEVICE_NOT_VISIBLE") == 0)
            #expect(autoResult(out, .stremioIOS)?["status"] != "skipped")
            #expect(log.value.contains("provision stremio-ios"))
            let decisions = try logged(a, "install")
            #expect(decisions.allSatisfy { $0["probe"] == nil })
        }
    }

    @Test("one devicectl listing serves every device, and none is made when nothing is a candidate")
    func oneListing() async throws {
        try await withAutoWorld([.stremioIOS, .apollo, .stremioTVOS], profileDays: 2, optIn: ["iphone", "appletv"]) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok, "\(out.errors)")
            #expect(a.runner.listCalls == 1)
            #expect(Set(log.value.filter { $0.hasPrefix("install") }) == ["install stremio-ios", "install apollo", "install stremio-tvos"])
            #expect(out.data["devices"]?.array?.compactMap { $0["alias"]?.string } == ["appletv", "iphone"])
        }
    }

    @Test("an app the device does not show is NOT_PRESENT and is not put back")
    func absentOnDevice() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            a.w.runner.setApp(bundleId(.stremioIOS), nil)
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok && autoResult(out, .stremioIOS)?["code"] == "NOT_PRESENT")
            #expect(log.value.isEmpty && a.w.runner.installCalls.isEmpty && a.runner.notices.isEmpty)
            let counted = try fields(a).attemptsByDay
            #expect(counted.isEmpty)
        }
    }

    // MARK: failures, caps and backoff

    @Test("a failed renewal is ok:false, exit 1, backed off, counted and notified; the next runs follow the ladder and the caps across days")
    func capsAndBackoffAcrossDays() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            let log = CallBox([])
            let steps = autoSteps(log, provision: { _ in failStep("TIMEOUT") })
            func attempts() -> Int { log.value.filter { $0.hasPrefix("provision") }.count }

            let first = await auto(a, steps)
            #expect(!first.ok && first.exitCode == 1 && first.errors.map(\.code) == ["TIMEOUT"])
            #expect(autoResult(first, .stremioIOS)?["status"] == "failed" && attempts() == 1)
            var f = try fields(a)
            #expect(f.consecutiveFailures == 1 && f.nextEligible == testNow.addingTimeInterval(1800) && !f.suspended)
            #expect(a.runner.notices.count == 1 && a.runner.notices[0].hasPrefix("stremio-ios @ iphone failed TIMEOUT, next 12:30, 2 d left"))

            // Inside the backoff: a skip, and no attempt.
            a.w.clock.advance(600)
            let early = await auto(a, steps)
            #expect(early.ok && autoResult(early, .stremioIOS)?["code"] == "BACKOFF" && attempts() == 1)

            // Past it: the second attempt, then an hour of backoff.
            a.w.clock.advance(1300)
            let second = await auto(a, steps)
            #expect(!second.ok && attempts() == 2)
            f = try fields(a)
            #expect(f.consecutiveFailures == 2 && f.attemptsByDay == [today: 2])
            #expect(f.nextEligible == testNow.addingTimeInterval(1900 + 3600))

            // The backoff is over but the install has had its two attempts for the day.
            a.w.clock.advance(3700)
            let capped = await auto(a, steps)
            #expect(capped.ok && autoResult(capped, .stremioIOS)?["code"] == "INSTALL_CAP" && attempts() == 2)

            // The next local day opens a new count: attempt 3 (2 h of backoff), attempt 4 (4 h), then the cap again.
            a.w.clock.advance(86_400)
            let tomorrow = RefreshPolicy.dayKey(a.w.clock.now(), timeZone: utc)
            #expect(!(await auto(a, steps)).ok && attempts() == 3)
            f = try fields(a)
            #expect(f.consecutiveFailures == 3 && f.attemptsByDay[tomorrow] == 1)
            #expect(f.nextEligible == a.w.clock.now().addingTimeInterval(7200))
            a.w.clock.advance(7200)
            #expect(!(await auto(a, steps)).ok && attempts() == 4)
            f = try fields(a)
            #expect(f.consecutiveFailures == 4 && f.nextEligible == a.w.clock.now().addingTimeInterval(4 * 3600))
            a.w.clock.advance(4 * 3600 + 1)
            let again = await auto(a, steps)
            #expect(again.ok && autoResult(again, .stremioIOS)?["code"] == "INSTALL_CAP" && attempts() == 4)
            // Every attempt was told to the owner, and nothing else was.
            #expect(a.runner.notices.count == 4)
        }
    }

    @Test("the device cap: at most 4 attempts a day across the device's apps, checked again before each app")
    func deviceCap() async throws {
        try await withAutoWorld(
            [.stremioIOS, .apollo, .filler], profileDays: 3,
            ledger: {
                seedInstall(&$0, .stremioIOS, days: 1)
                seedInstall(&$0, .apollo, days: 2)
                seedInstall(&$0, .filler, days: 3)
            }
        ) { a in
            let log = CallBox([])
            let steps = autoSteps(log, provision: { _ in failStep("TIMEOUT") })
            let first = await auto(a, steps)
            #expect(!first.ok && first.errors.count == 3)
            #expect(log.value == ["provision stremio-ios", "provision apollo", "provision filler"])

            a.w.clock.advance(1900)
            let second = await auto(a, steps)
            // The soonest app takes the 4th attempt of the day; the other two are held back by the device cap.
            #expect(log.value.count == 4 && log.value.last == "provision stremio-ios")
            #expect(autoResult(second, .apollo)?["code"] == "DEVICE_CAP" && autoResult(second, .filler)?["code"] == "DEVICE_CAP")
            let counts = try [ProvisionApp.stremioIOS, .apollo, .filler].map { try fields(a, $0).attemptsByDay[today] }
            #expect(counts == [2, 1, 1])
            let installs = try a.w.ledger().installs
            #expect(RefreshPolicy.deviceAttempts(installs, device: "iphone", today: today) == 4)
        }
    }

    @Test("a permanent failure suspends the install and tells the owner so; auto leaves it alone until a manual success")
    func suspendedUntilManualSuccess() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            let log = CallBox([])
            let failing = autoSteps(log, sign: { _ in failStep("GUARD_FAILED") })
            let out = await auto(a, failing)
            #expect(!out.ok && out.errors.map(\.code) == ["GUARD_FAILED"])
            #expect(try fields(a).suspended)
            #expect(a.runner.notices.count == 2)
            #expect(a.runner.notices[0].hasPrefix("stremio-ios @ iphone failed GUARD_FAILED"))
            #expect(a.runner.notices[1].hasPrefix("stremio-ios @ iphone suspended after GUARD_FAILED"))
            #expect(try logged(a, "result")[0]["suspended"] == true)

            // Days later, with the backoff long over and the profile expired, auto still does not touch it.
            let calls = log.value.count
            for _ in 0..<3 {
                a.w.clock.advance(86_400)
                let later = await auto(a, autoSteps(log))
                #expect(later.ok && autoResult(later, .stremioIOS)?["code"] == "SUSPENDED")
            }
            #expect(log.value.count == calls && a.runner.notices.count == 2)

            // A manual success clears it, and auto goes on from there.
            let manual = await RefreshCommand.run(
                a.services, RefreshOptions(device: "iphone", yes: true), steps: autoSteps(log), timeZone: utc)
            let cleared = try fields(a)
            #expect(manual.ok && !cleared.suspended)
            a.w.clock.advance(7200)
            let resumed = await auto(a, autoSteps(log))
            #expect(resumed.ok && autoResult(resumed, .stremioIOS)?["status"] == "renewed")
        }
    }

    @Test("PROFILE_NOT_RENEWED is retried once with --renew, exactly like a manual run, and never registers a device")
    func renewRetry() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            let log = CallBox([])
            let works = autoSteps(log, provision: { $0.renew ? okStep("provision", $0.app) : failStep("PROFILE_NOT_RENEWED") })
            let out = await auto(a, works)
            #expect(out.ok && autoResult(out, .stremioIOS)?["renewRetried"] == true)
            #expect(log.value == ["provision stremio-ios", "provision stremio-ios renew", "sign stremio-ios", "install stremio-ios"])
        }
        try await withAutoWorld(profileDays: 2) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log, provision: { _ in failStep("PROFILE_NOT_RENEWED") }))
            #expect(!out.ok && log.value == ["provision stremio-ios", "provision stremio-ios renew"])
            let refresh = try fields(a)
            #expect(refresh.suspended && refresh.lastCode == "PROFILE_NOT_RENEWED")
            #expect(try logged(a, "step").filter { $0["step"] == "provision" }.count == 1, "one provision step, retry included")
        }
    }

    // MARK: the whole run stops

    @Test("a certificate change stops the run: the rest of the device and the other devices are skipped with its code")
    func certificateChange() async throws {
        try await withAutoWorld([.stremioIOS, .apollo, .stremioTVOS], profileDays: 2, optIn: ["iphone", "appletv"]) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log, provision: { _ in failStep("FREE_CERT_CHANGED") }))
            #expect(!out.ok && out.exitCode == 1 && out.errors.map(\.code) == ["FREE_CERT_CHANGED"])
            // Devices go in alias order, so the Apple TV is first; one provision was asked for and nothing after it.
            #expect(log.value == ["provision stremio-tvos"])
            #expect(autoResult(out, .stremioTVOS, device: "appletv")?["status"] == "failed")
            for app in [ProvisionApp.stremioIOS, .apollo] {
                #expect(autoResult(out, app)?["status"] == "skipped" && autoResult(out, app)?["code"] == "FREE_CERT_CHANGED")
            }
            let counted = try fields(a).attemptsByDay
            #expect(counted.isEmpty)
            // The skips the stop caused say so in the log, and still carry the days left.
            let caused = try logged(a, "install").filter { $0["stopped"] == true }
            #expect(Set(caused.compactMap { $0["app"]?.string }) == ["stremio-ios", "apollo"])
            #expect(caused.allSatisfy { $0["reason"] == "FREE_CERT_CHANGED" && $0["daysLeft"] == 2 })
            #expect(a.runner.notices.count == 2, "told once for the attempt, once for the suspension")
        }
    }

    @Test("a slot operation that shows up mid-run stops that device only")
    func slotPendingMidRun() async throws {
        try await withAutoWorld([.stremioIOS, .apollo, .stremioTVOS], profileDays: 2, optIn: ["iphone", "appletv"]) { a in
            let log = CallBox([])
            let out = await auto(
                a, autoSteps(log, install: { $0.app == "stremio-tvos" ? failStep("SLOT_PENDING") : okStep("install", $0.app) }))
            #expect(!out.ok && out.errors.map(\.code) == ["SLOT_PENDING"])
            #expect(autoResult(out, .stremioIOS)?["status"] == "renewed" && autoResult(out, .apollo)?["status"] == "renewed")
        }
    }

    @Test("a busy lock mid-run is a skip, not a failure: the attempt is given back, nothing is said, the rest waits for the next run")
    func busyMidRun() async throws {
        for step in ["provision", "sign"] {
            try await withAutoWorld(
                [.stremioIOS, .apollo], profileDays: 2,
                ledger: {
                    seedInstall(&$0, .stremioIOS, days: 1)
                    seedInstall(&$0, .apollo, days: 2)
                }
            ) { a in
                let log = CallBox([])
                let busy = autoSteps(
                    log,
                    provision: { step == "provision" ? failStep("OPERATION_IN_PROGRESS") : okStep("provision", $0.app) },
                    sign: { _ in failStep("OPERATION_IN_PROGRESS") })
                let out = await auto(a, busy)
                #expect(out.ok && out.exitCode == 0, "\(step): \(out.errors)")
                #expect(autoResult(out, .stremioIOS)?["status"] == "skipped" && autoResult(out, .stremioIOS)?["code"] == "OPERATION_IN_PROGRESS")
                #expect(autoResult(out, .apollo)?["code"] == "OPERATION_IN_PROGRESS", "the lock is shared, so the run ends")
                #expect(log.value.allSatisfy { $0.hasSuffix("stremio-ios") })
                let refresh = try fields(a)
                #expect(refresh.attemptsByDay.isEmpty && refresh.consecutiveFailures == 0 && refresh.nextEligible == nil)
                #expect(refresh.lastResult == "skipped" && refresh.lastCode == "OPERATION_IN_PROGRESS" && !refresh.suspended)
                #expect(try fields(a, .apollo).attemptsByDay.isEmpty)
                #expect(a.runner.notices.isEmpty)
            }
        }
    }

    @Test("the 20-minute deadline: no new app is started after it; the app that ran counts, the rest are left for the next run")
    func deadline() async throws {
        try await withAutoWorld(
            [.stremioIOS, .apollo], profileDays: 2,
            ledger: {
                seedInstall(&$0, .stremioIOS, days: 1)
                seedInstall(&$0, .apollo, days: 2)
            }
        ) { a in
            let log = CallBox([])
            let clock = a.w.clock
            let slow = autoSteps(
                log,
                provision: { options in
                    clock.advance(RefreshPolicy.autoDeadline + 1)
                    return okStep("provision", options.app)
                })
            let out = await auto(a, slow)
            #expect(out.ok, "\(out.errors)")
            #expect(autoResult(out, .stremioIOS)?["status"] == "renewed")
            #expect(autoResult(out, .apollo)?["code"] == "DEADLINE" && skippedCount(out, "DEADLINE") == 1)
            let skip = try #require(try logged(a, "install").first { $0["reason"] == "DEADLINE" })
            #expect(skip["app"] == "apollo" && skip["daysLeft"] == 2 && skip["stopped"] == nil, "an own skip, with its days left")
            #expect(log.value == ["provision stremio-ios", "sign stremio-ios", "install stremio-ios"])
            let apollo = try fields(a, .apollo)
            #expect(apollo.attemptsByDay.isEmpty && apollo.consecutiveFailures == 0)
            #expect(a.runner.notices.count == 1)
        }
    }

    // MARK: no fallback to another version

    @Test("the installed version is signed even when a newer one is approved")
    func keepsInstalledVersion() async throws {
        try await withAutoWorld(profileDays: 2, manifest: false) { a in
            try seedManifest(a.w, [manifestEntry("1.2.3", fetchedDays: -9), manifestEntry("2.0.0", fetchedDays: -1)])
            let signs = Box<[SignOptions]>([])
            let steps = autoSteps(
                CallBox([]),
                sign: { options in
                    signs.value.append(options)
                    return okStep("sign", options.app)
                })
            let out = await auto(a, steps)
            #expect(out.ok && signs.value.map(\.version) == ["1.2.3"])
        }
    }

    @Test("the installed version is not a fetched, approved version on disk: VERSION_NOT_AVAILABLE, before any step, backed off, told, not suspended")
    func versionRefusal() async throws {
        let cases: [(String, [ManifestEntry], Set<String>)] = [
            ("not in the manifest", [manifestEntry("2.0.0", fetchedDays: -1)], []),
            ("fetched, never approved", [manifestEntry("1.2.3", approved: false, fetchedDays: -9), manifestEntry("2.0.0", fetchedDays: -1)], []),
            ("approved, file gone", [manifestEntry("1.2.3", fetchedDays: -9), manifestEntry("2.0.0", fetchedDays: -1)], ["1.2.3"]),
            ("empty manifest", [], []),
        ]
        for (name, entries, missing) in cases {
            try await withAutoWorld(profileDays: 2, manifest: false) { a in
                try seedManifest(a.w, entries, missing: missing)
                let log = CallBox([])
                let out = await auto(a, autoSteps(log))
                #expect(!out.ok && out.errors.map(\.code) == ["VERSION_NOT_AVAILABLE"], "\(name): \(out.errors)")
                #expect(log.value.isEmpty, "\(name): no provision, no sign, no install")
                #expect(!out.warnings.contains("RENEW_VERSION_CHANGED"), "\(name)")
                let refresh = try fields(a)
                #expect(refresh.lastCode == "VERSION_NOT_AVAILABLE" && refresh.consecutiveFailures == 1 && !refresh.suspended, "\(name)")
                #expect(refresh.nextEligible == testNow.addingTimeInterval(1800) && refresh.attemptsByDay == [today: 1], "\(name)")
                #expect(a.runner.notices.count == 1 && a.runner.notices[0].contains("failed VERSION_NOT_AVAILABLE"), "\(name)")
                let result = try #require(autoResult(out, .stremioIOS))
                #expect(result["steps"]?["provision"] == "skipped" && result["steps"]?["sign"] == "skipped", "\(name)")
            }
        }
    }

    @Test("a renewal that needs no sign step (provision and sign already done) does not need the installed version")
    func installOnlyNeedsNoVersion() async throws {
        try await withAutoWorld(
            profileDays: 5, manifest: false,
            ledger: {
                seedInstall(&$0, .stremioIOS, days: 5)
                var install = installRecord(.stremioIOS)
                install.profileExpires = daysFromNow(1)
                $0.installs = [install]
            }
        ) { a in
            let log = CallBox([])
            let out = await auto(a, autoSteps(log))
            #expect(out.ok, "\(out.errors)")
            #expect(log.value == ["install stremio-ios"])
        }
    }

    // MARK: logs, notices and the command line

    @Test("no device ID, device name or path reaches the log, the envelope or a notification, whatever a step says")
    func nothingIdentifying() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            let leaky = autoSteps(
                CallBox([]),
                provision: { _ in
                    .fail(
                        "provision", code: savedUdid("1"),
                        message: "\(savedUdid("1")) \(savedCoreId("1")) Test iPhone /Users/someone/x", fix: nil)
                })
            let out = await auto(a, leaky)
            let printed = try out.printed().text
            let log = try String(contentsOfFile: a.w.paths.refreshLog, encoding: .utf8)
            for secret in [savedUdid("1"), savedCoreId("1"), "someone"] {
                #expect(!printed.contains(secret), "\(secret)")
            }
            for text in [log, a.runner.notices.joined(separator: "\n")] {
                for secret in [savedUdid("1"), savedCoreId("1"), "Test iPhone", "/Users/", "someone"] {
                    #expect(!text.contains(secret), "\(secret)")
                }
            }
            #expect(try logged(a, "step")[0]["code"] == "OTHER")
            #expect(try logged(a, "result")[0]["code"] == "OTHER")
        }
    }

    @Test("a notification that cannot be delivered changes nothing but notified:false in the log")
    func notificationFailureIgnored() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            a.runner.setNoticeResult(RunResult(code: 1, stderr: "not allowed"))
            let out = await auto(a, autoSteps(CallBox([])))
            #expect(out.ok && a.runner.notices.count == 1)
            let results = try logged(a, "result")
            #expect(results[0]["notified"] == false)
        }
    }

    @Test("one run line per invocation, however it ends")
    func oneRunLinePerInvocation() async throws {
        try await withAutoWorld(profileDays: 2) { a in
            _ = await auto(a, autoSteps(CallBox([])))
            _ = await auto(a, autoSteps(CallBox([])))
            try Data().write(to: URL(fileURLWithPath: a.w.paths.refreshDisabled))
            _ = await auto(a, autoSteps(CallBox([])))
            let runs = try logged(a, "run")
            #expect(runs.count == 3)
            #expect(Set(runs.compactMap { $0["run"]?.string }).count == 3, "each invocation has its own id")
        }
    }

    @Test("through the command line: --auto takes no other option (--print-agent and --binary included), and exit codes follow ok")
    func commandLine() async throws {
        try await withAutoWorld(profileDays: 6) { a in
            for extra in [["--yes"], ["--device", "iphone"], ["--app", "apollo"], ["--within", "3"], ["--force"], ["--print-agent"], ["--binary", "/opt/sl/sideload"]] {
                let out = await run(argv: ["refresh", "--auto"] + extra, services: a.services)
                #expect(!out.ok && out.exitCode == 1 && out.errors.first?.code == "USAGE", "\(extra)")
            }
            let ok = await run(argv: ["refresh", "--auto"], services: a.services)
            #expect(ok.ok && ok.exitCode == 0 && ok.command == "refresh" && ok.data["auto"] == true)
            #expect(ok.data["devices"]?.array?.count == 1 && ok.data["skipped"]?["NOT_DUE"] == 1)
            #expect(ok.data["warnings"]?.array?.isEmpty == true && ok.errors.isEmpty)
            let help = await run(argv: ["help"], services: a.services)
            #expect(help.data["usage"]?.array?.contains("refresh --auto") == true)
        }
    }
}

// MARK: manifest helpers (the same shape RefreshTests uses)

private func manifestEntry(
    _ version: String, app: String = "stremio-ios", approved: Bool = true, fetchedDays: Double = 0
) -> ManifestEntry {
    let digest = String(repeating: "ab", count: 32)
    return ManifestEntry(
        app: app, version: version, file: "\(app)/\(version)/App.ipa", urlHost: "example.test", sha256: digest,
        upstreamDigest: digest, size: 1000, fetchedAt: daysFromNow(fetchedDays), approved: approved,
        approvedAt: approved ? daysFromNow(fetchedDays) : nil)
}

private func seedManifest(_ w: InstallWorld, _ entries: [ManifestEntry], missing: Set<String> = []) throws {
    var manifest = Manifest()
    manifest.entries = entries
    let store = ManifestStore(paths: w.paths)
    try store.save(manifest)
    for entry in entries where !missing.contains(entry.version) {
        let path = try store.path(of: entry)
        try makeDirectories(parentPath(path), mode: 0o700)
        try Data("ipa".utf8).write(to: URL(fileURLWithPath: path))
    }
}

private extension Envelope {
    var warnings: [String] {
        data["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
    }
}
