import Foundation
import Synchronization
import Testing

@testable import SideloadCore

private final class Calls: Sendable {
    private let lines = Mutex<[String]>([])
    var value: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

private let profileUuid = "0F0F0F0F-1111-2222-3333-444444444444"

private func freeProfile(days: Double, uuid: String = profileUuid) -> LedgerFreeProfile {
    LedgerFreeProfile(
        id: "iphone/apollo", device: "iphone", deviceTail: "…0001", app: "apollo", bundleId: menuBundleId("apollo"),
        profileUuid: uuid, created: nil, expires: daysFromNow(days), certFp8: "12345678",
        file: "profiles/free/apollo/iphone/\(uuid).mobileprovision")
}

private func signedBuild(version: String = "3.9.0", prefix: String = String(addSha.prefix(8)), uuid: String = profileUuid)
    -> LedgerFreeSigned
{
    var signed = menuSigned("iphone", "apollo", days: 6, uuid: uuid)
    signed.version = version
    signed.sha256Prefix = prefix
    return signed
}

/// How the fake commands behave. A step named in `fail` returns that envelope; the others do what the real command leaves behind.
private struct Script: Sendable {
    var fail: [String: Envelope] = [:]
    var approveSha = addSha
    var alreadyApproved = false
    /// `provision` answers PROFILE_NOT_RENEWED this many times before it works.
    var notRenewed = 0
    /// What `sign` records, when it succeeds.
    var signs: LedgerFreeSigned = signedBuild()
    var onStep: @Sendable (String) -> Void = { _ in }
}

private func steps(_ log: Calls, _ script: Script = Script()) -> MenuActionSteps {
    var steps = MenuActionSteps()
    let provisions = Mutex(0)
    steps.fetch = { _, options in
        let name = options.approve ? "approve" : "fetch"
        log.add(options.approve ? "approve \(options.app ?? "") \(options.version ?? "")" : "fetch \(options.app ?? "")")
        script.onStep(name)
        if let failure = script.fail[name] { return failure }
        return Envelope(
            ok: true, command: "fetch",
            data: [
                "version": "3.9.0", "build": "142", "sha256": .string(script.approveSha), "size": 45_200_000, "minOS": nil,
                "inspectMinOS": "16.0", "alreadyApproved": .bool(script.alreadyApproved), "inspect": ["extensionCount": 2],
            ])
    }
    steps.provision = { services, options in
        log.add("provision \(options)")
        script.onStep("provision")
        if let failure = script.fail["provision"] { return failure }
        let n = provisions.withLock { value -> Int in
            value += 1
            return value
        }
        if n <= script.notRenewed {
            return .fail("provision", code: "PROFILE_NOT_RENEWED", message: "Xcode reused the profile.", fix: "Wait.")
        }
        try? await services.ledgerStore.update { $0.freeProfiles = [freeProfile(days: 7)] }
        return Envelope(ok: true, command: "provision", data: ["appIdNew": true])
    }
    steps.sign = { services, options in
        log.add("sign \(options.app ?? "") \(options.device ?? "") yes=\(options.yes) version=\(options.version ?? "nil")")
        script.onStep("sign")
        if let failure = script.fail["sign"] { return failure }
        try? await services.ledgerStore.update { $0.freeSigned = [script.signs] }
        return Envelope(ok: true, command: "sign", data: ["version": .string(options.version ?? "")])
    }
    steps.install = { _, options in
        log.add("install \(options)")
        script.onStep("install")
        if let failure = script.fail["install"] { return failure }
        return Envelope(ok: true, command: "install", data: ["warnings": [["code": "W", "message": "A note."]]])
    }
    return steps
}

private struct RunResult2 {
    var calls: [String]
    var outcomes: [MenuActionOutcome]
}

/// A home with a manifest (Apollo 3.9.0 at `addSha`, unless `entry` says otherwise) and the ledger `body` shapes.
private func run(
    _ action: MenuAction, script: Script = Script(), manifestSha: String? = addSha, ledger body: ((inout Ledger) -> Void)? = nil,
    isCancelled: @escaping @Sendable () -> Bool = { false }
) async throws -> RunResult2 {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = Paths(home: dir.path)
    try paths.ensureHome()
    if let manifestSha {
        var manifest = Manifest()
        manifest.entries = [
            ManifestEntry(
                app: "apollo", version: "3.9.0", file: "apollo/3.9.0/Apollo.ipa", urlHost: "github.com", sha256: manifestSha,
                upstreamDigest: manifestSha, size: 45_200_000, fetchedAt: testNow, approved: false)
        ]
        try ManifestStore(paths: paths).save(manifest)
    }
    if let body { try await LedgerStore(paths: paths).update { body(&$0) } }
    let services = Services(
        runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: FakeKeychain(),
        home: paths)
    let log = Calls()
    let outcomes = Mutex<[MenuActionOutcome]>([])
    await MenuActionRunner.perform(action, services: services, steps: steps(log, script), isCancelled: isCancelled) { outcome in
        outcomes.withLock { $0.append(outcome) }
    }
    return RunResult2(calls: log.value, outcomes: outcomes.withLock { $0 })
}

private let approve = MenuAction.addApprove(device: "iphone", app: "apollo", fetched: addFetched)

private func busy() -> Envelope { .fail("x", code: "OPERATION_IN_PROGRESS", message: "Another run holds the lock.") }

private let provisionCall = "provision \(ProvisionOptions(app: "apollo", device: "iphone", yes: true))"
private let installCall = "install \(InstallOptions(app: "apollo", device: "iphone", yes: true))"
private let renewCall = "provision \(ProvisionOptions(app: "apollo", device: "iphone", renew: true, yes: true))"
private let signCall = "sign apollo iphone yes=true version=3.9.0"

@Suite("menu add app: the run")
struct MenuAddRunTests {
    @Test("stage 1 runs fetch alone: no approval, no other command, and hands on to the approval confirm")
    func fetchStage() async throws {
        let ran = try await run(.addFetch(device: "iphone", app: "apollo"), manifestSha: nil)
        #expect(ran.calls == ["fetch apollo"])
        #expect(ran.outcomes.count == 1 && ran.outcomes[0].kind == .done)
        #expect(ran.outcomes[0].proceed == .addApprove(device: "iphone", app: "apollo", fetched: addFetched))
    }

    @Test("stage 2 runs approve, provision, sign, install in order, each with exactly its options and the owner's --yes")
    func order() async throws {
        let ran = try await run(approve)
        #expect(ran.calls == ["approve apollo 3.9.0", provisionCall, signCall, installCall])
        let outcome = try #require(ran.outcomes.first)
        #expect(ran.outcomes.count == 1 && outcome.kind == .done && outcome.headline == "Added Apollo 3.9.0 to iphone")
        #expect(outcome.lines.map(\.text) == ["Approved", "Profile ready · new App ID", "Signed", "Installed"])
        #expect(outcome.notes == ["A note."] && outcome.proceed == nil)
    }

    @Test("a profile with 6 days or more left is not provisioned again; a signed build for this version and profile is not signed again")
    func resume() async throws {
        let done = try await run(approve) {
            $0.freeProfiles = [freeProfile(days: 6.5)]
            $0.freeSigned = [signedBuild()]
        }
        #expect(done.calls == ["approve apollo 3.9.0", installCall])
        #expect(done.outcomes[0].lines.map(\.text) == ["Approved", "Profile still fresh", "Signed build is current", "Installed"])

        // 5.9 days is inside the renewal window: provisioned again.
        let near = try await run(approve) {
            $0.freeProfiles = [freeProfile(days: 5.9)]
            $0.freeSigned = [signedBuild()]
        }
        #expect(near.calls.contains(provisionCall))

        // Signed, but another version, another file or another profile: signed again.
        for stale in [
            signedBuild(version: "3.8.0"), signedBuild(prefix: "00000000"),
            signedBuild(uuid: "AAAAAAAA-1111-2222-3333-444444444444"),
        ] {
            let again = try await run(approve) {
                $0.freeProfiles = [freeProfile(days: 6.5)]
                $0.freeSigned = [stale]
            }
            #expect(again.calls == ["approve apollo 3.9.0", signCall, installCall], "\(stale.version) \(stale.sha256Prefix)")
        }
    }

    @Test("sign is asked for exactly the confirmed version")
    func signVersion() async throws {
        let ran = try await run(approve)
        #expect(ran.calls.contains("sign apollo iphone yes=true version=3.9.0"))
    }

    @Test("the manifest is read again before anything is approved: another file, no entry or no manifest is not run")
    func hashGate() async throws {
        for sha in [String(repeating: "cd", count: 32), nil] {
            let ran = try await run(approve, manifestSha: sha)
            #expect(ran.calls.isEmpty, "\(sha ?? "no manifest")")
            #expect(ran.outcomes.count == 1 && ran.outcomes[0].headline == "Not run" && ran.outcomes[0].kind == .failed)
        }
        // The same file runs; the approval that comes back must be for the same bytes too.
        var script = Script()
        script.approveSha = String(repeating: "cd", count: 32)
        let swapped = try await run(approve, script: script)
        #expect(swapped.calls == ["approve apollo 3.9.0"])
        #expect(swapped.outcomes[0].lines.last?.issue?.code == "DIGEST_MISMATCH")
    }

    @Test("Cancel stops between steps, like Renew: what finished stays visible, nothing later runs")
    func cancelBetween() async throws {
        for stopAfter in ["approve", "provision", "sign"] {
            let flag = Mutex(false)
            var script = Script()
            script.onStep = { name in if name == stopAfter { flag.withLock { $0 = true } } }
            let ran = try await run(approve, script: script, isCancelled: { flag.withLock { $0 } })
            let all = ["approve", "provision", "sign", "install"]
            #expect(ran.calls.count == all.firstIndex(of: stopAfter)! + 1, "after \(stopAfter): \(ran.calls)")
            #expect(ran.outcomes.count == 1 && ran.outcomes[0].kind == .cancelled && ran.outcomes[0].headline == "Cancelled")
            #expect(ran.outcomes[0].lines.allSatisfy { $0.tone == .good })
            #expect(ran.outcomes[0].lines.count == all.firstIndex(of: stopAfter)! + 1)
            // Install never started, so the device cannot have changed.
            #expect(!ran.outcomes[0].notes.contains(MenuActionOutcome.deviceNote), "after \(stopAfter)")
        }
    }

    @Test("a cancel during install is cancelled with the device note, and the finished steps are kept")
    func cancelInInstall() async throws {
        // The owner's Cancel arrives while the install runs.
        let flag = Mutex(false)
        var script = Script()
        script.fail["install"] = .fail("install", code: "INTERRUPTED", message: "stopped")
        script.onStep = { name in if name == "install" { flag.withLock { $0 = true } } }
        let ran = try await run(approve, script: script, isCancelled: { flag.withLock { $0 } })
        let outcome = try #require(ran.outcomes.first)
        #expect(outcome.kind == .cancelled)
        #expect(outcome.notes.contains(MenuActionOutcome.deviceNote) && outcome.notes.contains(MenuActionOutcome.addKeptNote))
    }

    @Test("a busy lock never waits: before the approval it is the plain busy card, later it is a stop with what is done")
    func busyEach() async throws {
        var script = Script()
        script.fail["approve"] = busy()
        let first = try await run(approve, script: script)
        #expect(first.calls == ["approve apollo 3.9.0"])
        #expect(first.outcomes[0].kind == .busy && first.outcomes[0].headline == MenuActionOutcome.busyHeadline)
        #expect(first.outcomes[0].lines.first?.retry == approve)

        for step in ["provision", "sign", "install"] {
            var script = Script()
            script.fail[step] = busy()
            let ran = try await run(approve, script: script)
            let outcome = try #require(ran.outcomes.first)
            #expect(outcome.kind == .failed && outcome.headline == "Add stopped at \(step)", "\(step)")
            #expect(outcome.lines.last?.issue?.code == "OPERATION_IN_PROGRESS" && outcome.lines.last?.retry != nil)
            #expect(outcome.notes.contains(MenuActionOutcome.addKeptNote))
            // Later steps did not run.
            let order = ["approve", "provision", "sign", "install"]
            #expect(ran.calls.count == order.firstIndex(of: step)! + 1, "\(step): \(ran.calls)")
            // Before sign finished the retry is Add app's confirm, which knows the version is approved; past it, the row is
            // "Signed · not installed" and the retry is Install.
            if step == "install" {
                #expect(outcome.lines.last?.retry == .install(device: "iphone", app: "apollo"))
            } else if case .addApprove(_, _, let fetched)? = outcome.lines.last?.retry {
                #expect(fetched.alreadyApproved)
            } else {
                Issue.record("expected a retry for \(step)")
            }
        }
    }

    @Test("a failure past sign offers Install as its Retry, and Install is available for the row it leaves")
    func retryPastSign() async throws {
        var script = Script()
        script.fail["install"] = .fail("install", code: "DEVICE_LOCKED", message: "Locked.", fix: "Unlock it.")
        let ran = try await run(approve, script: script)
        let retry = try #require(ran.outcomes[0].lines.last?.retry)
        #expect(retry == .install(device: "iphone", app: "apollo"))
        // Add app is off for that row, Install is on.
        var ledger = Ledger()
        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 6)]
        let snapshot = addBuild(ledger: ledger)
        #expect(MenuActions.availability(approve, in: snapshot, now: testNow).reason == "Signed · not installed: use Install")
        #expect(MenuActions.availability(retry, in: snapshot, now: testNow) == .enabled)

        // Before sign the retry is Add app again.
        var early = Script()
        early.fail["sign"] = .fail("sign", code: "SIGNING_FAILED", message: "No.", fix: "Fix.")
        let before = try await run(approve, script: early)
        guard case .addApprove? = before.outcomes[0].lines.last?.retry else {
            Issue.record("expected Add app again, got \(String(describing: before.outcomes[0].lines.last?.retry))")
            return
        }
    }

    @Test("PROFILE_NOT_RENEWED is retried once with renew, like refresh; anything else, or a second one, stops")
    func profileNotRenewed() async throws {
        var once = Script()
        once.notRenewed = 1
        let ok = try await run(approve, script: once)
        #expect(ok.calls == ["approve apollo 3.9.0", provisionCall, renewCall, signCall, installCall])
        #expect(ok.outcomes[0].kind == .done)

        var twice = Script()
        twice.notRenewed = 2
        let stuck = try await run(approve, script: twice)
        #expect(stuck.calls == ["approve apollo 3.9.0", provisionCall, renewCall])
        #expect(stuck.outcomes[0].headline == "Add stopped at provision")
        #expect(stuck.outcomes[0].lines.last?.issue?.code == "PROFILE_NOT_RENEWED")

        var other = Script()
        other.fail["provision"] = .fail("provision", code: "FREE_APP_ID_LIMIT", message: "Limit.", fix: "Wait.")
        let limit = try await run(approve, script: other)
        #expect(limit.calls == ["approve apollo 3.9.0", provisionCall])
    }

    @Test("after sign the signed build must be the confirmed version before install")
    func signedMismatch() async throws {
        var script = Script()
        script.signs = signedBuild(version: "4.0.0")
        let ran = try await run(approve, script: script)
        #expect(ran.calls == ["approve apollo 3.9.0", provisionCall, signCall])
        #expect(ran.outcomes[0].kind == .failed && ran.outcomes[0].lines.last?.issue?.code == "SIGNED_BUILD_MISMATCH")

        var other = Script()
        other.signs = signedBuild(prefix: "00000000")
        let wrongFile = try await run(approve, script: other)
        #expect(!wrongFile.calls.contains(installCall) && wrongFile.outcomes[0].kind == .failed)
    }

    @Test("a failed step stops the run with its code, message and fix; a later step is not tried")
    func failure() async throws {
        var script = Script()
        script.fail["sign"] = .fail("sign", code: "DEVICE_OS_TOO_OLD", message: "Apollo needs OS 17.", fix: "Update the device.")
        let ran = try await run(approve, script: script)
        #expect(ran.calls == ["approve apollo 3.9.0", provisionCall, signCall])
        let outcome = try #require(ran.outcomes.first)
        #expect(outcome.kind == .failed && outcome.headline == "Add stopped at sign")
        #expect(outcome.lines.map(\.text) == ["Approved", "Profile ready · new App ID", "Failed · DEVICE_OS_TOO_OLD"])
        #expect(outcome.lines.last?.issue == MenuIssue(code: "DEVICE_OS_TOO_OLD", message: "Apollo needs OS 17.", fix: "Update the device."))
    }

    @Test("an approval that was given before is reported as such")
    func alreadyApproved() async throws {
        var script = Script()
        script.alreadyApproved = true
        let ran = try await run(approve, script: script)
        #expect(ran.outcomes[0].lines.first?.text == "Already approved")
    }

    @Test("everything from a step goes through the redactor")
    func redacted() async throws {
        let udid = savedUdid("1")
        var script = Script()
        script.fail["install"] = .fail("install", code: "X", message: "device \(udid) failed", fix: "see \(udid)")
        let ran = try await run(approve, script: script)
        let outcome = try #require(ran.outcomes.first)
        let text = (outcome.issues.map { $0.message + ($0.fix ?? "") } + outcome.lines.flatMap { [$0.text, $0.issue?.message ?? "", $0.issue?.fix ?? ""] })
            .joined()
        #expect(!text.contains(udid))
    }
}

@Suite("menu add app: reading the fetch")
struct MenuAddFetchOutcomeTests {
    private let fetch = MenuAction.addFetch(device: "iphone", app: "apollo")

    private func ok(_ extra: [String: JSONValue] = [:]) -> Envelope {
        var data: [String: JSONValue] = [
            "version": "3.9.0", "build": "142", "sha256": .string(addSha), "size": 45_200_000, "minOS": "15.0",
            "inspectMinOS": "16.0", "alreadyApproved": false, "inspect": ["extensionCount": 2],
        ]
        data.merge(extra) { _, new in new }
        return Envelope(ok: true, command: "fetch", data: data)
    }

    @Test("a fetched version carries its facts to the approval confirm; the stricter minimum OS wins")
    func facts() {
        let outcome = MenuActionOutcome(action: fetch, envelope: ok(), cancelled: false)
        #expect(outcome.kind == .done && outcome.proceed == .addApprove(device: "iphone", app: "apollo", fetched: addFetched))
        let earlier = MenuActionOutcome(action: fetch, envelope: ok(["alreadyApproved": true, "minOS": "17.0"]), cancelled: false)
        guard case .addApprove(_, _, let fetched)? = earlier.proceed else {
            Issue.record("expected the approval")
            return
        }
        #expect(fetched.alreadyApproved && fetched.minOS == "17.0")
    }

    @Test("a Cancel that came too late opens no approval; a failure or a busy lock is a card with a Retry of the fetch")
    func endings() {
        let late = MenuActionOutcome(action: fetch, envelope: ok(), cancelled: true)
        #expect(late.proceed == nil && late.kind == .done)
        // Not a plain success: it says nothing was approved and what to do next.
        #expect(late.headline == "Fetched Apollo 3.9.0 · not approved")
        #expect(late.notes == ["Choose Add app again to approve and install."])

        let failed = MenuActionOutcome(
            action: fetch, envelope: .fail("fetch", code: "DIGEST_MISMATCH", message: "Wrong file.", fix: "Retry."), cancelled: false)
        #expect(failed.kind == .failed && failed.headline == "Fetch failed" && failed.proceed == nil)
        #expect(failed.issues.map(\.code) == ["DIGEST_MISMATCH"] && failed.lines.first?.retry == fetch)

        let held = MenuActionOutcome(action: fetch, envelope: busy(), cancelled: false)
        #expect(held.kind == .busy && held.lines.first?.retry == fetch && held.proceed == nil)

        let cancelled = MenuActionOutcome(
            action: fetch, envelope: .fail("fetch", code: "CANCELLED", message: "fetch was interrupted."), cancelled: true)
        #expect(cancelled.kind == .cancelled && cancelled.notes == ["Nothing was signed or installed."] && cancelled.proceed == nil)
    }

    @Test("an envelope without the version it stored is a failure, never a blank approval")
    func incomplete() {
        let outcome = MenuActionOutcome(
            action: fetch, envelope: Envelope(ok: true, command: "fetch", data: ["sha256": .string(addSha)]), cancelled: false)
        #expect(outcome.kind == .failed && outcome.proceed == nil)
    }
}
