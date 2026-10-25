import Foundation
import Testing

@testable import SideloadCore

private let utc = TimeZone(identifier: "UTC")!

private func subject(
    _ app: ProvisionApp = .stremioIOS, installDays: Double? = nil, signedDays: Double? = nil, profileDays: Double? = nil,
    sameProfile: Bool = true, present: Bool = true, lent: Bool = false
) -> RefreshPolicy.Subject {
    var install = installDays.map { days -> LedgerInstall in
        var record = installRecord(app, present: present)
        record.profileExpires = daysFromNow(days)
        return record
    }
    install?.present = present
    let signed = signedDays.map { days in
        LedgerFreeSigned(
            id: "iphone/\(app.rawValue)", device: "iphone", app: app.rawValue, bundleId: carrierPrefix + ".free." + app.suffix,
            version: "1", sha256Prefix: "abcd1234", profileUuid: "AAAA", profileExpires: daysFromNow(days), certFp8: "deadbeef",
            signedAt: daysFromNow(-1), path: "builds/signed/x", strippedExtensions: [], droppedEntitlements: [])
    }
    let profile = profileDays.map { days in
        LedgerFreeProfile(
            id: "iphone/\(app.rawValue)", device: "iphone", deviceTail: "AAAA", app: app.rawValue,
            bundleId: carrierPrefix + ".free." + app.suffix, profileUuid: sameProfile ? "AAAA" : "BBBB", created: nil,
            expires: daysFromNow(days), certFp8: "deadbeef", file: "profiles/free/x")
    }
    return RefreshPolicy.Subject(app: app, install: install, signed: signed, profile: profile, lent: lent)
}

@Suite("refresh policy")
struct RefreshPolicyTests {
    // MARK: --within and --force

    @Test("--within: 5 by default, 1 to 6 accepted, --force is 6, anything else (or both together) is a usage error")
    func withinParsing() throws {
        #expect(try RefreshPolicy.within(nil, force: false) == 5)
        #expect(try RefreshPolicy.within("1", force: false) == 1)
        #expect(try RefreshPolicy.within("6", force: false) == 6)
        #expect(try RefreshPolicy.within(nil, force: true) == 6)
        for bad in ["0", "7", "-1", "5.5", "abc", ""] {
            #expect(throws: SideloadError.self, "\(bad)") { try RefreshPolicy.within(bad, force: false) }
        }
        #expect(throws: SideloadError.self) { try RefreshPolicy.within("3", force: true) }
    }

    @Test("due at the boundary: within 5 renews at 5 days or fewer, not at 5.5; 6 is the ceiling")
    func dueTable() {
        let cases: [(days: Double, within: Int, due: Bool)] = [
            (5.0, 5, true), (4.9, 5, true), (5.01, 5, false), (5.5, 5, false), (5.5, 6, true), (6.0, 6, true), (6.5, 6, false),
            (0.5, 1, true), (1.5, 1, false), (-1, 5, true),
        ]
        for c in cases {
            #expect(
                RefreshPolicy.isDue(expires: daysFromNow(c.days), now: testNow, within: c.within) == c.due,
                "\(c.days) days left, within \(c.within)")
        }
    }

    // MARK: selection

    @Test("an installed app is renewed when due and skipped when not; the baseline is the device copy")
    func installedSelection() {
        let due = RefreshPolicy.decide(subject(installDays: 3), now: testNow, within: 5, presence: .present)
        #expect(due == .renew(.init(expires: daysFromNow(3), lent: false, recorded: true)))
        let notDue = RefreshPolicy.decide(subject(installDays: 6), now: testNow, within: 5, presence: .present)
        #expect(notDue == .skip(code: "NOT_DUE", expires: daysFromNow(6)))
        // `--force` is within 6.
        #expect(
            RefreshPolicy.decide(subject(installDays: 6), now: testNow, within: 6, presence: .present)
                == .renew(.init(expires: daysFromNow(6), lent: false, recorded: true)))
    }

    @Test("an app the device does not show is skipped NOT_PRESENT, never put back; an unreadable device trusts the ledger")
    func absentApp() {
        #expect(
            RefreshPolicy.decide(subject(installDays: 2), now: testNow, within: 5, presence: .absent)
                == .skip(code: "NOT_PRESENT", expires: daysFromNow(2)))
        #expect(
            RefreshPolicy.decide(subject(installDays: 2, present: false), now: testNow, within: 5, presence: .present)
                == .skip(code: "NOT_PRESENT", expires: daysFromNow(2)))
        if case .renew = RefreshPolicy.decide(subject(installDays: 2), now: testNow, within: 5, presence: .unknown) {
        } else {
            Issue.record("a record the ledger says is present is renewed when the snapshot could not be read")
        }
    }

    @Test("a lent app is judged by its signed copy and never installed; lent without a signed copy is NOT_SIGNED")
    func lentApp() {
        let lent = RefreshPolicy.decide(
            subject(installDays: 1, signedDays: 2, present: false, lent: true), now: testNow, within: 5, presence: .absent)
        #expect(lent == .renew(.init(expires: daysFromNow(2), lent: true, recorded: true)))
        #expect(
            RefreshPolicy.decide(subject(installDays: 1, present: false, lent: true), now: testNow, within: 5, presence: .absent)
                == .skip(code: "NOT_SIGNED", expires: nil))
        #expect(
            RefreshPolicy.decide(subject(signedDays: 6, lent: true), now: testNow, within: 5, presence: .absent)
                == .skip(code: "NOT_DUE", expires: daysFromNow(6)))
    }

    @Test("an app installed by hand (no record) needs a signed copy and the device showing it")
    func handInstalled() {
        let s = subject(signedDays: 2, profileDays: 2)
        #expect(
            RefreshPolicy.decide(s, now: testNow, within: 5, presence: .present)
                == .renew(.init(expires: daysFromNow(2), lent: false, recorded: false)))
        #expect(RefreshPolicy.decide(s, now: testNow, within: 5, presence: .absent) == .skip(code: "NOT_INSTALLED", expires: daysFromNow(2)))
        // The device could not be read but the signed copy is expiring: still a candidate (provision and sign run).
        #expect(
            RefreshPolicy.decide(s, now: testNow, within: 5, presence: .unknown)
                == .renew(.init(expires: daysFromNow(2), lent: false, recorded: false)))
        #expect(RefreshPolicy.decide(subject(), now: testNow, within: 5, presence: .present) == .skip(code: "NOT_INSTALLED", expires: nil))
        // A fresh signed copy says nothing about the device copy (`sign` overwrites it): the install is always due, provision
        // and sign are not.
        let fresh = subject(signedDays: 6, profileDays: 6)
        #expect(
            RefreshPolicy.decide(fresh, now: testNow, within: 5, presence: .present)
                == .renew(.init(expires: daysFromNow(6), lent: false, recorded: false, stale: false)))
        #expect(
            RefreshPolicy.decide(fresh, now: testNow, within: 5, presence: .unknown)
                == .renew(.init(expires: daysFromNow(6), lent: false, recorded: false, stale: false)))
        #expect(
            RefreshPolicy.decide(fresh, now: testNow, within: 5, presence: .absent)
                == .skip(code: "NOT_INSTALLED", expires: daysFromNow(6)))
    }

    @Test("an unrecorded app with a fresh signed copy goes straight to the install")
    func handInstalledInstallOnly() {
        let target = RefreshPolicy.Target(expires: daysFromNow(6), lent: false, recorded: false, stale: false)
        #expect(
            RefreshPolicy.steps(subject(signedDays: 6, profileDays: 6), target: target)
                == .init(provision: false, sign: false, install: true))
        // Even with no profile record at all: the steps are not asked for.
        #expect(RefreshPolicy.steps(subject(signedDays: 6), target: target) == .init(provision: false, sign: false, install: true))
    }

    // MARK: resume

    @Test("steps: all three when nothing was done; a fresh profile skips provision; a signed fresh profile skips sign too")
    func stepResume() {
        let target = RefreshPolicy.Target(expires: daysFromNow(2), lent: false, recorded: true)
        // Nothing done: the profile is the one the device has.
        #expect(
            RefreshPolicy.steps(subject(installDays: 2, signedDays: 2, profileDays: 2), target: target)
                == .init(provision: true, sign: true, install: true))
        // Provision done earlier: a profile more than a day past the device copy, not signed yet.
        #expect(
            RefreshPolicy.steps(subject(installDays: 2, signedDays: 2, profileDays: 7, sameProfile: false), target: target)
                == .init(provision: false, sign: true, install: true))
        // Sign done too: only the install is left.
        #expect(
            RefreshPolicy.steps(subject(installDays: 2, signedDays: 7, profileDays: 7), target: target)
                == .init(provision: false, sign: false, install: true))
        // A profile that moved the expiry by a day or less is not a renewal: provision again.
        #expect(
            RefreshPolicy.steps(subject(installDays: 2, signedDays: 3, profileDays: 3), target: target).provision)
        // No profile record at all.
        #expect(RefreshPolicy.steps(subject(installDays: 2), target: target) == .init(provision: true, sign: true, install: true))
    }

    @Test("steps: a lent app never installs; the filler is signed by provision, so it never signs")
    func stepKinds() {
        let lent = RefreshPolicy.Target(expires: daysFromNow(2), lent: true, recorded: true)
        #expect(
            RefreshPolicy.steps(subject(installDays: 2, signedDays: 2, profileDays: 2, present: false, lent: true), target: lent)
                == .init(provision: true, sign: true, install: false))
        let target = RefreshPolicy.Target(expires: daysFromNow(2), lent: false, recorded: true)
        #expect(
            RefreshPolicy.steps(subject(.filler, installDays: 2, signedDays: 2, profileDays: 2), target: target)
                == .init(provision: true, sign: false, install: true))
        #expect(
            RefreshPolicy.steps(subject(.filler, installDays: 2, signedDays: 7, profileDays: 7), target: target)
                == .init(provision: false, sign: false, install: true))
    }

    // MARK: counters, backoff, suspension

    @Test("the day key is the local calendar day; a day change moves the counter to a new key and old days are pruned")
    func counters() {
        let day = RefreshPolicy.dayKey(testNow, timeZone: utc)
        #expect(day.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
        let tomorrow = RefreshPolicy.dayKey(testNow.addingTimeInterval(86_400), timeZone: utc)
        #expect(day != tomorrow)
        // Another zone can be on another day at the same instant.
        let late = Date(timeIntervalSince1970: 1_792_411_200 + 11 * 3600)
        #expect(
            RefreshPolicy.dayKey(late, timeZone: TimeZone(identifier: "UTC")!)
                != RefreshPolicy.dayKey(late, timeZone: TimeZone(identifier: "Pacific/Auckland")!))

        var refresh = LedgerInstallRefresh(attemptsByDay: ["2000-01-01": 4])
        refresh = RefreshPolicy.counting(refresh, now: testNow, timeZone: utc)
        #expect(refresh.attemptsByDay == [day: 1] && refresh.lastAttempt == testNow)
        refresh = RefreshPolicy.counting(refresh, now: testNow, timeZone: utc)
        #expect(refresh.attemptsByDay == [day: 2])
        refresh = RefreshPolicy.counting(refresh, now: testNow.addingTimeInterval(86_400), timeZone: utc)
        #expect(refresh.attemptsByDay == [day: 2, tomorrow: 1])
        // A week later the first day is gone.
        refresh = RefreshPolicy.counting(refresh, now: testNow.addingTimeInterval(9 * 86_400), timeZone: utc)
        #expect(refresh.attemptsByDay[day] == nil && refresh.attemptsByDay[tomorrow] == nil)
    }

    @Test("the device total is the sum over its installs for the day")
    func deviceTotal() {
        var a = installRecord(.stremioIOS)
        a.refresh.attemptsByDay = ["d": 2, "old": 9]
        var b = installRecord(.apollo)
        b.refresh.attemptsByDay = ["d": 1]
        var other = installRecord(.stremioTVOS, alias: "appletv")
        other.refresh.attemptsByDay = ["d": 4]
        #expect(RefreshPolicy.deviceAttempts([a, b, other], device: "iphone", today: "d") == 3)
    }

    @Test("backoff 30 m, 1, 2, 4, 8, 12 h, then 12 h again")
    func backoffLadder() {
        let hours = (1...8).map { RefreshPolicy.nextEligible(failures: $0, now: testNow).timeIntervalSince(testNow) / 3600 }
        #expect(hours == [0.5, 1, 2, 4, 8, 12, 12, 12])
        #expect(RefreshPolicy.nextEligible(failures: 0, now: testNow).timeIntervalSince(testNow) == 1800)
    }

    @Test("a failure counts and backs off, a permanent one suspends, a success clears, a busy lock gives the attempt back")
    func applyingResults() {
        var refresh = RefreshPolicy.counting(LedgerInstallRefresh(), now: testNow, timeZone: utc)
        let day = RefreshPolicy.dayKey(testNow, timeZone: utc)

        let failed = RefreshPolicy.applying(.failed(code: "DEVICE_LOCKED"), to: refresh, now: testNow, timeZone: utc)
        #expect(failed.lastResult == "failed" && failed.lastCode == "DEVICE_LOCKED" && failed.consecutiveFailures == 1)
        #expect(failed.nextEligible == testNow.addingTimeInterval(1800) && !failed.suspended)
        let again = RefreshPolicy.applying(.failed(code: "DEVICE_LOCKED"), to: failed, now: testNow, timeZone: utc)
        #expect(again.consecutiveFailures == 2 && again.nextEligible == testNow.addingTimeInterval(3600))

        let permanent = RefreshPolicy.applying(.failed(code: "PROFILE_NOT_RENEWED"), to: refresh, now: testNow, timeZone: utc)
        #expect(permanent.suspended)

        let ok = RefreshPolicy.applying(.refreshed, to: permanent, now: testNow, timeZone: utc)
        #expect(ok.lastResult == "refreshed" && ok.lastCode == nil && ok.consecutiveFailures == 0)
        #expect(ok.nextEligible == nil && !ok.suspended)
        #expect(ok.attemptsByDay == [day: 1])

        let busy = RefreshPolicy.applying(.busy, to: refresh, now: testNow, timeZone: utc)
        #expect(busy.attemptsByDay.isEmpty && busy.lastResult == "skipped" && busy.lastCode == "OPERATION_IN_PROGRESS")
        #expect(busy.consecutiveFailures == 0 && busy.nextEligible == nil)
        refresh = RefreshPolicy.counting(refresh, now: testNow, timeZone: utc)
        #expect(RefreshPolicy.applying(.busy, to: refresh, now: testNow, timeZone: utc).attemptsByDay == [day: 1])
    }

    @Test("fatal codes stop the run, the others do not; device availability is neither")
    func fatalTable() {
        for code in [
            "FREE_CERT_CHANGED", "IDENTITY_CHECK_FAILED", "FREE_IDENTITY_MISSING", "FREE_IDENTITY_AMBIGUOUS", "FREE_IDENTITY_NOT_PINNED",
            "KEYCHAIN_LOCKED", "ACCOUNT_NOT_SIGNED_IN", "UNEXPECTED_APP_DELTA", "SLOT_PENDING", "RENEW_CROSS_VOLUME",
            "PROFILE_MOVE_FAILED", "PROFILES_UNREADABLE", "DERIVED_DATA_NOT_CLEARED", "LEDGER_WRITE_FAILED", "WRONG_TEAM",
            "GUARD_FAILED", "INTERRUPTED",
        ] {
            #expect(RefreshPolicy.isFatal(code), "\(code)")
        }
        for code in [
            "PROFILE_NOT_RENEWED", "OPERATION_IN_PROGRESS", "FREE_APP_ID_LIMIT", "FREE_APP_LIMIT", "NOT_SIGNED", "SIGN_FAILED",
            "INSTALL_FAILED", "DEVICE_LOCKED", "DEVICE_NOT_CONNECTED", "DEVICE_NOT_PAIRED", "APP_LENT",
        ] {
            #expect(!RefreshPolicy.isFatal(code), "\(code)")
        }
        #expect(RefreshPolicy.deviceUnavailableCodes == ["DEVICE_LOCKED", "DEVICE_NOT_CONNECTED", "DEVICE_NOT_PAIRED"])
    }
}

@Suite("PostEmit")
struct PostEmitChainTests {
    @Test("add keeps every registration and runs them in order, once")
    func chaining() async {
        let order = Box<[Int]>([])
        let emit = PostEmit()
        emit.add { order.value.append(1) }
        emit.add { order.value.append(2) }
        #expect(emit.isPending)
        await emit.runIfPending()
        #expect(order.value == [1, 2])
        #expect(!emit.isPending)
        emit.add { order.value.append(3) }
        await emit.runIfPending()
        await emit.runIfPending()
        #expect(order.value == [1, 2, 3])
    }
}
