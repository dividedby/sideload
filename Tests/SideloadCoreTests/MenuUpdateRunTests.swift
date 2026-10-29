import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Update in the menu, the run (design section 12): the chain behind confirm 2 and the reading of both stages. Fakes only.

private final class Calls: Sendable {
    private let lines = Mutex<[String]>([])
    var value: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

private let profileUuid = "0F0F0F0F-1111-2222-3333-444444444444"

private func freeProfile(days: Double) -> LedgerFreeProfile {
    LedgerFreeProfile(
        id: "iphone/apollo", device: "iphone", deviceTail: "…0001", app: "apollo", bundleId: menuBundleId("apollo"),
        profileUuid: profileUuid, created: nil, expires: daysFromNow(days), certFp8: "12345678",
        file: "profiles/free/apollo/iphone/\(profileUuid).mobileprovision")
}

private func signedBuild(version: String = "3.10.0", prefix: String = String(addSha.prefix(8)), uuid: String = profileUuid)
    -> LedgerFreeSigned
{
    var signed = menuSigned("iphone", "apollo", days: 6, uuid: uuid)
    signed.version = version
    signed.sha256Prefix = prefix
    return signed
}

private struct Script: Sendable {
    var fail: [String: Envelope] = [:]
    var alreadyApproved = false
    var signs: LedgerFreeSigned = signedBuild()
    var onStep: @Sendable (String) -> Void = { _ in }
}

private func steps(_ log: Calls, _ script: Script = Script()) -> MenuActionSteps {
    var steps = MenuActionSteps()
    steps.fetch = { _, options in
        let name = options.approve ? "approve" : "fetch"
        log.add(options.approve ? "approve \(options.app ?? "") \(options.version ?? "")" : "fetch \(options.app ?? "")")
        script.onStep(name)
        if let failure = script.fail[name] { return failure }
        return Envelope(
            ok: true, command: "fetch",
            data: [
                "version": "3.10.0", "build": "143", "sha256": .string(addSha), "size": 45_200_000, "minOS": nil,
                "inspectMinOS": "16.0", "alreadyApproved": .bool(script.alreadyApproved), "inspect": ["extensionCount": 2],
            ])
    }
    steps.provision = { services, options in
        log.add("provision renew=\(options.renew)")
        script.onStep("provision")
        if let failure = script.fail["provision"] { return failure }
        try? await services.ledgerStore.update { $0.freeProfiles = [freeProfile(days: 7)] }
        return Envelope(ok: true, command: "provision", data: ["appIdNew": false])
    }
    steps.sign = { services, options in
        log.add("sign \(options.app ?? "") \(options.device ?? "") version=\(options.version ?? "nil")")
        script.onStep("sign")
        if let failure = script.fail["sign"] { return failure }
        try? await services.ledgerStore.update { $0.freeSigned = [script.signs] }
        return Envelope(ok: true, command: "sign", data: ["version": .string(options.version ?? "")])
    }
    steps.install = { _, options in
        log.add("install \(options.app ?? "") \(options.device ?? "")")
        script.onStep("install")
        if let failure = script.fail["install"] { return failure }
        return Envelope(ok: true, command: "install", data: ["warnings": [["code": "W", "message": "A note."]]])
    }
    return steps
}

private struct Ran {
    var calls: [String]
    var outcomes: [MenuActionOutcome]
}

private func run(
    _ action: MenuAction, script: Script = Script(), manifestSha: String? = addSha, ledger body: ((inout Ledger) -> Void)? = nil,
    isCancelled: @escaping @Sendable () -> Bool = { false }
) async throws -> Ran {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = Paths(home: dir.path)
    try paths.ensureHome()
    if let manifestSha {
        var manifest = Manifest()
        manifest.entries = [
            ManifestEntry(
                app: "apollo", version: "3.10.0", file: "apollo/3.10.0/Apollo.ipa", urlHost: "github.com", sha256: manifestSha,
                upstreamDigest: manifestSha, size: 45_200_000, fetchedAt: testNow, approved: false)
        ]
        try ManifestStore(paths: paths).save(manifest)
    }
    // The installed 3.9.0, which an Update goes over.
    try await LedgerStore(paths: paths).update { ledger in
        ledger = menuLedger([("iphone", "apollo", 5)])
        ledger.installs[0].version = "3.9.0"
        body?(&ledger)
    }
    let services = Services(
        runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: FakeKeychain(),
        home: paths)
    let log = Calls()
    let outcomes = Mutex<[MenuActionOutcome]>([])
    await MenuActionRunner.perform(action, services: services, steps: steps(log, script), isCancelled: isCancelled) { outcome in
        outcomes.withLock { $0.append(outcome) }
    }
    return Ran(calls: log.value, outcomes: outcomes.withLock { $0 })
}

private let fetched = MenuFetched(
    version: "3.10.0", build: "143", sha256: addSha, size: 45_200_000, minOS: "16.0", extensionCount: 2, alreadyApproved: false)
private let fetchAction = MenuAction.updateFetch(device: "iphone", app: "apollo", from: "3.9.0")
private let approve = MenuAction.updateApprove(device: "iphone", app: "apollo", from: "3.9.0", fetched: fetched)

private func busy() -> Envelope { .fail("x", code: "OPERATION_IN_PROGRESS", message: "Another run holds the lock.") }

private let signCall = "sign apollo iphone version=3.10.0"
private let installCall = "install apollo iphone"

@Suite("menu update: the run")
struct MenuUpdateRunTests {
    @Test("stage 1 runs fetch alone and hands on to confirm 2 with the installed version it started from")
    func fetchStage() async throws {
        let ran = try await run(fetchAction, manifestSha: nil)
        #expect(ran.calls == ["fetch apollo"])
        #expect(ran.outcomes.count == 1 && ran.outcomes[0].kind == .done)
        #expect(ran.outcomes[0].proceed == approve)
    }

    @Test("stage 2 over a profile with under 6 days renews it: approve, provision, sign, install, over the installed app")
    func order() async throws {
        let ran = try await run(approve) { $0.freeProfiles = [freeProfile(days: 3)] }
        #expect(ran.calls == ["approve apollo 3.10.0", "provision renew=false", signCall, installCall])
        let outcome = try #require(ran.outcomes.first)
        #expect(ran.outcomes.count == 1 && outcome.kind == .done && outcome.headline == "Updated Apollo 3.9.0 → 3.10.0 on iphone")
        #expect(outcome.lines.map(\.text) == ["Approved", "Profile ready", "Signed", "Installed"])
        #expect(outcome.notes == ["A note."] && outcome.proceed == nil)
    }

    @Test("a profile with 6 days or more is reused and a current signed build is not signed again")
    func resume() async throws {
        let fresh = try await run(approve) { $0.freeProfiles = [freeProfile(days: 6.5)] }
        #expect(fresh.calls == ["approve apollo 3.10.0", signCall, installCall])
        #expect(fresh.outcomes[0].lines.map(\.text) == ["Approved", "Profile still fresh", "Signed", "Installed"])

        let done = try await run(approve) {
            $0.freeProfiles = [freeProfile(days: 6.5)]
            $0.freeSigned = [signedBuild()]
        }
        #expect(done.calls == ["approve apollo 3.10.0", installCall])
        #expect(done.outcomes[0].lines.map(\.text) == ["Approved", "Profile still fresh", "Signed build is current", "Installed"])

        // The signed build is the installed version, another file or another profile: signed again for the confirmed one.
        for stale in [
            signedBuild(version: "3.9.0"), signedBuild(prefix: "00000000"), signedBuild(uuid: "AAAAAAAA-1111-2222-3333-444444444444"),
        ] {
            let again = try await run(approve) {
                $0.freeProfiles = [freeProfile(days: 6.5)]
                $0.freeSigned = [stale]
            }
            #expect(again.calls == ["approve apollo 3.10.0", signCall, installCall], "\(stale.version)")
        }
    }

    @Test("the manifest is read again before anything is approved: another file or no entry is not run")
    func hashGate() async throws {
        for sha in [String(repeating: "cd", count: 32), nil] {
            let ran = try await run(approve, manifestSha: sha)
            #expect(ran.calls.isEmpty, "\(sha ?? "no manifest")")
            #expect(ran.outcomes.count == 1 && ran.outcomes[0].headline == "Not run" && ran.outcomes[0].kind == .failed)
        }
        var script = Script()
        script.fail["approve"] = Envelope(ok: true, command: "fetch", data: ["sha256": .string(String(repeating: "cd", count: 32))])
        let swapped = try await run(approve, script: script)
        #expect(swapped.calls == ["approve apollo 3.10.0"] && swapped.outcomes[0].lines.last?.issue?.code == "DIGEST_MISMATCH")
    }

    @Test("Cancel stops between steps, and a cancel during install keeps the finished steps and says the device may have finished")
    func cancel() async throws {
        for stopAfter in ["approve", "provision", "sign"] {
            let flag = Mutex(false)
            var script = Script()
            script.onStep = { name in if name == stopAfter { flag.withLock { $0 = true } } }
            let ran = try await run(
                approve, script: script, ledger: { $0.freeProfiles = [freeProfile(days: 3)] }, isCancelled: { flag.withLock { $0 } })
            let all = ["approve", "provision", "sign", "install"]
            #expect(ran.calls.count == all.firstIndex(of: stopAfter)! + 1, "after \(stopAfter): \(ran.calls)")
            #expect(ran.outcomes[0].kind == .cancelled && ran.outcomes[0].lines.allSatisfy { $0.tone == .good })
            #expect(!ran.outcomes[0].notes.contains(MenuActionOutcome.deviceNote))
            #expect(ran.outcomes[0].notes.contains(MenuActionOutcome.updateKeptNote))
        }
        let flag = Mutex(false)
        var script = Script()
        script.fail["install"] = .fail("install", code: "INTERRUPTED", message: "stopped")
        script.onStep = { name in if name == "install" { flag.withLock { $0 = true } } }
        let ran = try await run(approve, script: script, isCancelled: { flag.withLock { $0 } })
        #expect(ran.outcomes[0].kind == .cancelled)
        #expect(ran.outcomes[0].notes.contains(MenuActionOutcome.deviceNote) && ran.outcomes[0].notes.contains(MenuActionOutcome.updateKeptNote))
    }

    @Test("a busy lock never waits: before the approval the plain busy card, later a stop whose Retry is confirm 2, then Install")
    func busyEach() async throws {
        var script = Script()
        script.fail["approve"] = busy()
        let first = try await run(approve, script: script)
        #expect(first.calls == ["approve apollo 3.10.0"])
        #expect(first.outcomes[0].kind == .busy && first.outcomes[0].lines.first?.retry == approve)

        for step in ["provision", "sign", "install"] {
            var script = Script()
            script.fail[step] = busy()
            let ran = try await run(approve, script: script) { $0.freeProfiles = [freeProfile(days: 3)] }
            let outcome = try #require(ran.outcomes.first)
            #expect(outcome.kind == .failed && outcome.headline == "Update stopped at \(step)", "\(step)")
            #expect(outcome.lines.last?.issue?.code == "OPERATION_IN_PROGRESS")
            #expect(outcome.notes.contains(MenuActionOutcome.updateKeptNote))
            #expect(!outcome.notes.contains(MenuActionOutcome.addKeptNote))
            if step == "install" {
                // Signed: the row has a newer signed build, and Install update finishes it.
                #expect(outcome.lines.last?.retry == .install(device: "iphone", app: "apollo"))
                #expect(outcome.notes.contains("The signed build is kept: Install update on the app's row also finishes it."))
            } else if case .updateApprove(_, _, let from, let again)? = outcome.lines.last?.retry {
                #expect(from == "3.9.0" && again.alreadyApproved && again.version == "3.10.0")
            } else {
                Issue.record("expected confirm 2 again for \(step)")
            }
        }
    }

    @Test("a failure past sign offers Install, which the row it leaves allows; a mismatching signed build offers nothing")
    func retryPastSign() async throws {
        var script = Script()
        script.fail["install"] = .fail("install", code: "DEVICE_LOCKED", message: "Locked.", fix: "Unlock it.")
        let ran = try await run(approve, script: script)
        let retry = try #require(ran.outcomes[0].lines.last?.retry)
        #expect(retry == .install(device: "iphone", app: "apollo"))
        // The ledger the failed run leaves: installed 3.9.0, signed 3.10.0 on the same profile.
        var ledger = menuLedger([("iphone", "apollo", 5)])
        ledger.installs[0].version = "3.9.0"
        ledger.freeSigned = [signedBuild(uuid: "UUID-1")]
        let snapshot = MenuSnapshotBuilder.build(
            MenuInputs(
                now: testNow, canaryStatus: nil, config: addConfig(), ledger: ledger, probe: .listed([menuListed()]),
                deviceApps: addRead("iphone", [menuBundleId("apollo")])))
        #expect(snapshot.devices[0].apps[0].newerSigned)
        #expect(MenuActions.availability(retry, in: snapshot, now: testNow) == .enabled)

        var mismatch = Script()
        mismatch.signs = signedBuild(version: "4.0.0")
        let wrong = try await run(approve, script: mismatch)
        #expect(!wrong.calls.contains(installCall) && wrong.outcomes[0].lines.last?.issue?.code == "SIGNED_BUILD_MISMATCH")
        #expect(wrong.outcomes[0].lines.allSatisfy { $0.retry == nil })
    }

    @Test("a failed step names itself and keeps the earlier ones; everything from a step goes through the redactor")
    func failure() async throws {
        var script = Script()
        let udid = savedUdid("1")
        script.fail["sign"] = .fail("sign", code: "DEVICE_OS_TOO_OLD", message: "Apollo needs OS 17 on \(udid).", fix: "Update the device.")
        let ran = try await run(approve, script: script) { $0.freeProfiles = [freeProfile(days: 3)] }
        let outcome = try #require(ran.outcomes.first)
        #expect(ran.calls == ["approve apollo 3.10.0", "provision renew=false", signCall])
        #expect(outcome.headline == "Update stopped at sign" && outcome.lines.map(\.text) == ["Approved", "Profile ready", "Failed · DEVICE_OS_TOO_OLD"])
        let text = outcome.lines.flatMap { [$0.issue?.message ?? "", $0.issue?.fix ?? ""] }.joined()
        #expect(!text.contains(udid))
    }
}

@Suite("menu update: reading the fetch")
struct MenuUpdateFetchOutcomeTests {
    private func ok() -> Envelope {
        Envelope(
            ok: true, command: "fetch",
            data: [
                "version": "3.10.0", "build": "143", "sha256": .string(addSha), "size": 45_200_000, "minOS": "15.0",
                "inspectMinOS": "16.0", "alreadyApproved": false, "inspect": ["extensionCount": 2],
            ])
    }

    @Test("a fetched version opens confirm 2 with the stricter minimum OS; a Cancel too late opens nothing")
    func facts() {
        let outcome = MenuActionOutcome(action: fetchAction, envelope: ok(), cancelled: false)
        #expect(outcome.kind == .done && outcome.proceed == approve)
        let late = MenuActionOutcome(action: fetchAction, envelope: ok(), cancelled: true)
        #expect(late.proceed == nil && late.kind == .done && late.headline == "Fetched Apollo 3.10.0 · not approved")
        #expect(late.notes == ["Choose Update again to approve and update."])
    }

    @Test("a failure or a busy lock is a card with a Retry of the fetch; Cancel says nothing was signed or installed")
    func endings() {
        let failed = MenuActionOutcome(
            action: fetchAction, envelope: .fail("fetch", code: "FETCH_HTTP_ERROR", message: "HTTP 503.", fix: "Retry later."), cancelled: false)
        #expect(failed.kind == .failed && failed.headline == "Fetch failed" && failed.lines.first?.retry == fetchAction)
        let held = MenuActionOutcome(action: fetchAction, envelope: busy(), cancelled: false)
        #expect(held.kind == .busy && held.lines.first?.retry == fetchAction)
        let cancelled = MenuActionOutcome(
            action: fetchAction, envelope: .fail("fetch", code: "CANCELLED", message: "fetch was interrupted."), cancelled: true)
        #expect(cancelled.kind == .cancelled && cancelled.notes == ["Nothing was signed or installed."] && cancelled.proceed == nil)
        let blank = MenuActionOutcome(
            action: fetchAction, envelope: Envelope(ok: true, command: "fetch", data: ["sha256": .string(addSha)]), cancelled: false)
        #expect(blank.kind == .failed && blank.proceed == nil)
    }

    @Test("Add app's own texts are unchanged")
    func addUnchanged() {
        let add = MenuAction.addFetch(device: "iphone", app: "apollo")
        let late = MenuActionOutcome(action: add, envelope: ok(), cancelled: true)
        #expect(late.notes == ["Choose Add app again to approve and install."])
        if case .addApprove(_, "apollo", let f)? = MenuActionOutcome(action: add, envelope: ok(), cancelled: false).proceed {
            #expect(f.version == "3.10.0")
        } else {
            Issue.record("expected Add app's confirm 2")
        }
    }
}
