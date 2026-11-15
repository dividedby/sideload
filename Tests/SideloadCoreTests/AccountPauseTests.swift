import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// The free team's account pause (issue 57): Xcode signed out is one pause for the whole team, not a suspension per install.
// The pure rules, the ledger field, what `provision` writes, and what `status` and the menu say. The auto run's behaviour
// across runs is in RefreshAutoTests.

private let utc = TimeZone(identifier: "UTC")!

@Suite("account pause: the rules")
struct AccountPauseRuleTests {
    @Test("the probe ladder is 1, 2 and 4 hours, then 6 hours for every later probe")
    func ladder() {
        let hours = (0...7).map { RefreshPolicy.accountProbeDelay(probes: $0) / 3600 }
        #expect(hours == [1, 2, 4, 6, 6, 6, 6, 6])
        #expect(RefreshPolicy.accountProbeDelay(probes: -1) == 3600)
    }

    @Test("the first hit makes a pause, each failed probe counts and moves nextProbe up the ladder")
    func pausing() {
        let first = RefreshPolicy.pausing(nil, now: testNow)
        #expect(
            first
                == LedgerAccountPause(
                    code: "ACCOUNT_NOT_SIGNED_IN", since: testNow, probes: 0,
                    nextProbe: testNow.addingTimeInterval(3600)))
        let later = testNow.addingTimeInterval(3600)
        let second = RefreshPolicy.pausing(first, now: later)
        #expect(
            second.since == testNow && second.probes == 1
                && second.nextProbe == later.addingTimeInterval(2 * 3600))
        let third = RefreshPolicy.pausing(second, now: later)
        #expect(third.probes == 2 && third.nextProbe == later.addingTimeInterval(4 * 3600))
        let fourth = RefreshPolicy.pausing(third, now: later)
        let fifth = RefreshPolicy.pausing(fourth, now: later)
        #expect(fifth.probes == 4 && fifth.nextProbe == later.addingTimeInterval(6 * 3600))
    }

    @Test("ACCOUNT_NOT_SIGNED_IN stops the run but is neither permanent nor a cancellation")
    func codeSets() {
        let code = "ACCOUNT_NOT_SIGNED_IN"
        #expect(RefreshPolicy.isFatal(code) && RefreshPolicy.stopsWholeRun(code))
        #expect(!RefreshPolicy.permanentCodes.contains(code))
        #expect(!RefreshPolicy.isCancellation(code))
    }

    @Test(
        "a signed-out attempt is given back and shown as failed, with no backoff, no failure count and no suspension"
    )
    func applying() {
        let day = RefreshPolicy.dayKey(testNow, timeZone: utc)
        let counted = RefreshPolicy.counting(LedgerInstallRefresh(), now: testNow, timeZone: utc)
        #expect(counted.attemptsByDay == [day: 1])
        let out = RefreshPolicy.applying(
            .accountSignedOut, to: counted, now: testNow, timeZone: utc)
        #expect(out.attemptsByDay.isEmpty)
        #expect(out.lastResult == "failed" && out.lastCode == "ACCOUNT_NOT_SIGNED_IN")
        #expect(out.consecutiveFailures == 0 && out.nextEligible == nil && !out.suspended)

        // An earlier failure's counters, and a second attempt that day, stay as they were.
        var before = RefreshPolicy.counting(counted, now: testNow, timeZone: utc)
        before.consecutiveFailures = 2
        before.nextEligible = testNow.addingTimeInterval(3600)
        let kept = RefreshPolicy.applying(
            .accountSignedOut, to: before, now: testNow, timeZone: utc)
        #expect(kept.attemptsByDay == [day: 1] && kept.consecutiveFailures == 2)
        #expect(kept.nextEligible == testNow.addingTimeInterval(3600) && !kept.suspended)
    }
}

@Suite("account pause: the ledger field")
struct AccountPauseLedgerTests {
    @Test("it round-trips, a missing key is nil, and an older ledger without it still loads")
    func roundTrip() async throws {
        try await withTestHome { paths, _ in
            let store = LedgerStore(paths: paths)
            #expect(try store.load().freeAccountPause == nil)
            let pause = LedgerAccountPause(
                code: "ACCOUNT_NOT_SIGNED_IN", since: testNow, probes: 2,
                nextProbe: testNow.addingTimeInterval(4 * 3600))
            try await store.update { $0.freeAccountPause = pause }
            #expect(try store.load().freeAccountPause == pause)
            let raw = try String(contentsOfFile: paths.ledger, encoding: .utf8)
            #expect(raw.contains("\"freeAccountPause\""))
            try await store.update { $0.freeAccountPause = nil }
            #expect(
                !(try String(contentsOfFile: paths.ledger, encoding: .utf8)).contains(
                    "freeAccountPause"))

            let older = #"{"schema":1,"certificates":[],"profiles":[],"exports":[]}"#
            try Data(older.utf8).write(to: URL(fileURLWithPath: paths.ledger))
            #expect(try store.load().freeAccountPause == nil)
        }
    }

    @Test(
        "a ledger written by this version is not lost by a rewrite (the key is modelled, not extra)"
    )
    func notExtra() async throws {
        try await withTestHome { paths, _ in
            let store = LedgerStore(paths: paths)
            try await store.update {
                $0.freeAccountPause = LedgerAccountPause(
                    code: "ACCOUNT_NOT_SIGNED_IN", since: testNow, nextProbe: testNow)
            }
            #expect(try store.load().extra.isEmpty)
            try await store.update { $0.updated = testNow }
            #expect(try store.load().freeAccountPause != nil)
        }
    }
}

@Suite("account pause: provision writes it")
struct AccountPauseProvisionTests {
    private static let signedOut = BuildScript(
        result: RunResult(code: 65, stderr: "error: No Account for Team \"6ZU5Z6ZKK7\"."))

    @Test("the first ACCOUNT_NOT_SIGNED_IN creates the pause; the second counts a probe")
    func createsThenBumps() async throws {
        try await withProvisionWorld(build: Self.signedOut) { (w: ProvisionWorld) async throws in
            #expect(try w.ledger().freeAccountPause == nil)
            let first = await w.run()
            #expect(first.errors.first?.code == "ACCOUNT_NOT_SIGNED_IN")
            let pause = try #require(try w.ledger().freeAccountPause)
            #expect(pause.code == "ACCOUNT_NOT_SIGNED_IN" && pause.since == testNow)
            #expect(pause.probes == 0 && pause.nextProbe == testNow.addingTimeInterval(3600))
            #expect(try w.ledger().freeSuspended == nil)

            let second = await w.run()
            #expect(second.errors.first?.code == "ACCOUNT_NOT_SIGNED_IN")
            let bumped = try #require(try w.ledger().freeAccountPause)
            #expect(bumped.since == pause.since && bumped.probes == 1)
            #expect(bumped.nextProbe == testNow.addingTimeInterval(2 * 3600))
        }
    }

    @Test("another failure does not make a pause")
    func otherFailure() async throws {
        let failing = BuildScript(result: RunResult(code: 65, stderr: "error: x"))
        try await withProvisionWorld(build: failing) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "PROVISION_FAILED")
            #expect(try w.ledger().freeAccountPause == nil)
        }
    }

    @Test(
        "a success clears the pause and the suspensions that ACCOUNT_NOT_SIGNED_IN set, and no other field or install"
    )
    func successClears() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            var legacy = LedgerInstallRefresh(
                lastResult: "failed", lastCode: "ACCOUNT_NOT_SIGNED_IN",
                consecutiveFailures: 3, nextEligible: testNow.addingTimeInterval(7200),
                attemptsByDay: ["2026-10-19": 2], suspended: true)
            legacy.lastAttempt = testNow
            let other = LedgerInstallRefresh(
                lastResult: "failed", lastCode: "GUARD_FAILED", suspended: true)
            try await w.services.ledgerStore.update {
                $0.freeAccountPause = LedgerAccountPause(
                    code: "ACCOUNT_NOT_SIGNED_IN", since: daysFromNow(-1), probes: 3,
                    nextProbe: daysFromNow(-0.5))
                $0.installs = [
                    installRecord(.stremioIOS, refresh: legacy),
                    installRecord(.apollo, refresh: other),
                ]
            }
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["accountPauseCleared"] == true)
            let ledger = try w.ledger()
            #expect(ledger.freeAccountPause == nil)
            let cleared = try #require(ledger.installs.first { $0.app == "stremio-ios" }).refresh
            #expect(!cleared.suspended)
            #expect(cleared.lastCode == "ACCOUNT_NOT_SIGNED_IN")
            #expect(cleared.consecutiveFailures == 0 && cleared.nextEligible == nil)
            #expect(cleared.attemptsByDay == legacy.attemptsByDay)
            #expect(try #require(ledger.installs.first { $0.app == "apollo" }).refresh == other)
        }
    }

    @Test("a success with no pause says nothing about one")
    func successWithoutPause() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok && out.data["accountPauseCleared"] == nil)
        }
    }
}

@Suite("account pause: status and the menu")
struct AccountPauseReportTests {
    private func warnings(_ envelope: Envelope) throws -> [JSONValue] {
        try envelope.printed().json["warnings"]?.array ?? []
    }

    @Test(
        "status warns ACCOUNT_SIGNED_OUT with the times while the pause is set, and not otherwise")
    func statusWarning() async throws {
        try await withTestHome { paths, _ in
            let (services, _) = fakeServices(paths)
            let quiet = StatusCommand.run(services)
            #expect(try !warnings(quiet).contains { $0["code"] == "ACCOUNT_SIGNED_OUT" })

            try await LedgerStore(paths: paths).update {
                $0.freeAccountPause = LedgerAccountPause(
                    code: "ACCOUNT_NOT_SIGNED_IN", since: testNow, probes: 1,
                    nextProbe: testNow.addingTimeInterval(7200))
            }
            let out = StatusCommand.run(services)
            let warning = try #require(
                try warnings(out).first { $0["code"] == "ACCOUNT_SIGNED_OUT" })
            let message = warning["message"]?.string ?? ""
            let fix = warning["fix"]?.string ?? ""
            #expect(message.contains(LedgerDates.string(testNow)))
            #expect(fix.contains("Xcode > Settings > Accounts"))
            #expect(fix.contains(LedgerDates.string(testNow.addingTimeInterval(7200))))
            #expect(out.ok)
        }
    }

    @Test("the menu panel carries the same notice")
    func menuNotice() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let (services, _) = fakeServices(paths)
            guard case .ready(let clear) = MenuLoader.loadLocal(services) else {
                Issue.record("expected ready")
                return
            }
            #expect(clear.notices.isEmpty)
            try await LedgerStore(paths: paths).update {
                $0.freeAccountPause = LedgerAccountPause(
                    code: "ACCOUNT_NOT_SIGNED_IN", since: testNow, nextProbe: testNow)
            }
            guard case .ready(let paused) = MenuLoader.loadLocal(services) else {
                Issue.record("expected ready")
                return
            }
            #expect(paused.notices.map(\.code) == ["ACCOUNT_SIGNED_OUT"])
        }
    }
}
