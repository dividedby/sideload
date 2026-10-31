import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Reinstall previous version in the menu, the run (design section 12): the tail of the Update chain without a fetch or an
// approval, and the reading of its envelope. Fakes only.

private final class Calls: Sendable {
    private let lines = Mutex<[String]>([])
    var value: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

private let profileUuid = "0F0F0F0F-1111-2222-3333-444444444444"
private let oldSha = String(repeating: "38", count: 32)

private func freeProfile(days: Double) -> LedgerFreeProfile {
    LedgerFreeProfile(
        id: "iphone/apollo", device: "iphone", deviceTail: "…0001", app: "apollo", bundleId: menuBundleId("apollo"),
        profileUuid: profileUuid, created: nil, expires: daysFromNow(days), certFp8: "12345678",
        file: "profiles/free/apollo/iphone/\(profileUuid).mobileprovision")
}

private func signedBuild(version: String = "3.8.0", prefix: String = String(oldSha.prefix(8)), uuid: String = profileUuid)
    -> LedgerFreeSigned
{
    var signed = menuSigned("iphone", "apollo", days: 6, uuid: uuid)
    signed.version = version
    signed.sha256Prefix = prefix
    return signed
}

private struct Script: Sendable {
    var fail: [String: Envelope] = [:]
    var signs: LedgerFreeSigned = signedBuild()
    var onStep: @Sendable (String) -> Void = { _ in }
}

private func steps(_ log: Calls, _ script: Script = Script()) -> MenuActionSteps {
    var steps = MenuActionSteps()
    steps.fetch = { _, options in
        log.add("fetch approve=\(options.approve)")
        return Envelope(ok: true, command: "fetch", data: ["sha256": .string(oldSha)])
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

private enum Stored {
    case onDisk, missingFile, pruned, unapproved, otherSha, noManifest
}

private func run(
    _ action: MenuAction, script: Script = Script(), stored: Stored = .onDisk, ledger body: ((inout Ledger) -> Void)? = nil,
    isCancelled: @escaping @Sendable () -> Bool = { false }
) async throws -> Ran {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = Paths(home: dir.path)
    try paths.ensureHome()
    if stored != .noManifest {
        let sha = stored == .otherSha ? String(repeating: "cd", count: 32) : oldSha
        var manifest = Manifest()
        manifest.entries = [
            ManifestEntry(
                app: "apollo", version: "3.8.0", file: "apollo/3.8.0/Apollo.ipa", urlHost: "github.com", sha256: sha,
                upstreamDigest: sha, size: 44_000_000, fetchedAt: testNow, approved: stored != .unapproved,
                prunedAt: stored == .pruned ? testNow : nil)
        ]
        try ManifestStore(paths: paths).save(manifest)
        if stored != .missingFile {
            try FileManager.default.createDirectory(atPath: "\(paths.downloads)/apollo/3.8.0", withIntermediateDirectories: true)
            try Data("ipa".utf8).write(to: URL(fileURLWithPath: "\(paths.downloads)/apollo/3.8.0/Apollo.ipa"))
        }
    }
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

private let old = MenuPrevious(version: "3.8.0", build: "141", sha256: oldSha, size: 44_000_000, minOS: "15.0")
private let action = MenuAction.reinstallPrevious(device: "iphone", app: "apollo", from: "3.9.0", to: old)
private let signCall = "sign apollo iphone version=3.8.0"
private let installCall = "install apollo iphone"

private func busy() -> Envelope { .fail("x", code: "OPERATION_IN_PROGRESS", message: "Another run holds the lock.") }

@Suite("menu reinstall: the run")
struct MenuReinstallRunTests {
    @Test("provision, sign exactly the previous version, install: no fetch and no approval")
    func order() async throws {
        let ran = try await run(action) { $0.freeProfiles = [freeProfile(days: 3)] }
        #expect(ran.calls == ["provision renew=false", signCall, installCall])
        let outcome = try #require(ran.outcomes.first)
        #expect(ran.outcomes.count == 1 && outcome.kind == .done && outcome.headline == "Reinstalled Apollo 3.8.0 on iphone")
        #expect(outcome.lines.map(\.text) == ["Profile ready", "Signed", "Installed"])
        #expect(outcome.notes == ["A note."] && outcome.proceed == nil && outcome.issues.isEmpty)
    }

    @Test("a profile with 6 days or more is reused and a current signed build for the previous version is not signed again")
    func resume() async throws {
        let fresh = try await run(action) { $0.freeProfiles = [freeProfile(days: 6.5)] }
        #expect(fresh.calls == [signCall, installCall])
        #expect(fresh.outcomes[0].lines.map(\.text) == ["Profile still fresh", "Signed", "Installed"])

        let done = try await run(action) {
            $0.freeProfiles = [freeProfile(days: 6.5)]
            $0.freeSigned = [signedBuild()]
        }
        #expect(done.calls == [installCall])
        #expect(done.outcomes[0].lines.map(\.text) == ["Profile still fresh", "Signed build is current", "Installed"])

        // The signed build is the installed version, another file or another profile: signed again for the confirmed one.
        for stale in [
            signedBuild(version: "3.9.0"), signedBuild(prefix: "00000000"), signedBuild(uuid: "AAAAAAAA-1111-2222-3333-444444444444"),
        ] {
            let again = try await run(action) {
                $0.freeProfiles = [freeProfile(days: 6.5)]
                $0.freeSigned = [stale]
            }
            #expect(again.calls == [signCall, installCall], "\(stale.version)")
        }
    }

    @Test("a signed build that is not the confirmed version is never installed")
    func mismatch() async throws {
        for wrong in [signedBuild(version: "3.9.0"), signedBuild(prefix: "00000000")] {
            var script = Script()
            script.signs = wrong
            let ran = try await run(action, script: script) { $0.freeProfiles = [freeProfile(days: 6.5)] }
            let outcome = try #require(ran.outcomes.first)
            #expect(ran.calls == [signCall], "\(wrong.version)")
            #expect(outcome.kind == .failed && outcome.lines.last?.issue?.code == "SIGNED_BUILD_MISMATCH")
            #expect(outcome.lines.allSatisfy { $0.retry == nil })
            #expect(outcome.lines.last?.issue?.fix?.contains("--version 3.8.0") == true)
        }
    }

    @Test("the manifest is read again first: a pruned, unapproved, missing or different file, or no manifest, is not run")
    func gate() async throws {
        for stored in [Stored.missingFile, .pruned, .unapproved, .otherSha, .noManifest] {
            let ran = try await run(action, stored: stored)
            #expect(ran.calls.isEmpty, "\(stored)")
            #expect(ran.outcomes.count == 1 && ran.outcomes[0].headline == "Not run" && ran.outcomes[0].kind == .failed, "\(stored)")
        }
        let different = try await run(action, stored: .otherSha)
        #expect(different.outcomes[0].issues.first?.message == "The stored file for Apollo 3.8.0 changed since you reviewed it.")
    }

    @Test("an install failure keeps the command's text and adds the rollback fix; other steps do not")
    func installFails() async throws {
        var script = Script()
        script.fail["install"] = .fail("install", code: "INSTALL_FAILED", message: "devicectl refused it.", fix: "Check the device.")
        let ran = try await run(action, script: script) { $0.freeProfiles = [freeProfile(days: 6.5)] }
        #expect(ran.calls == [signCall, installCall])
        let outcome = try #require(ran.outcomes.first)
        #expect(outcome.kind == .failed && outcome.headline == "Reinstall stopped at install")
        let issue = try #require(outcome.lines.last?.issue)
        #expect(issue.code == "INSTALL_FAILED" && issue.message == "devicectl refused it.")
        #expect(
            issue.fix
                == "Check the device. iOS may refuse an older build over a newer one. The installed app is unchanged; Renew or Update… returns to the installed or newest version."
        )
        #expect(outcome.lines.last?.retry == action)
        #expect(outcome.notes == [MenuActionOutcome.reinstallKeptNote])

        // No fix of its own: the rollback text stands alone.
        var bare = Script()
        bare.fail["install"] = .fail("install", code: "INSTALL_FAILED", message: "devicectl refused it.")
        let alone = try await run(action, script: bare) { $0.freeProfiles = [freeProfile(days: 6.5)] }
        #expect(alone.outcomes[0].lines.last?.issue?.fix == MenuActionOutcome.rollbackFix)

        // A failure before the install does not talk about iOS refusing a build.
        var early = Script()
        early.fail["sign"] = .fail("sign", code: "DEVICE_OS_TOO_OLD", message: "Too old.", fix: "Update the device.")
        let signFailed = try await run(action, script: early) { $0.freeProfiles = [freeProfile(days: 6.5)] }
        #expect(signFailed.outcomes[0].lines.last?.issue?.fix == "Update the device.")
        #expect(signFailed.outcomes[0].headline == "Reinstall stopped at sign")
    }

    @Test("a busy lock never waits: at the start the plain busy card, later a stop whose Retry is the same confirm")
    func busyEach() async throws {
        var script = Script()
        script.fail["provision"] = busy()
        let first = try await run(action, script: script) { $0.freeProfiles = [freeProfile(days: 3)] }
        #expect(first.calls == ["provision renew=false"])
        #expect(first.outcomes[0].kind == .busy && first.outcomes[0].lines.first?.retry == action)

        for step in ["sign", "install"] {
            var script = Script()
            script.fail[step] = busy()
            let ran = try await run(action, script: script) { $0.freeProfiles = [freeProfile(days: 6.5)] }
            let outcome = try #require(ran.outcomes.first)
            #expect(outcome.kind == .failed && outcome.headline == "Reinstall stopped at \(step)", "\(step)")
            #expect(outcome.lines.last?.issue?.code == "OPERATION_IN_PROGRESS" && outcome.lines.last?.retry == action)
        }
    }

    @Test("Cancel stops between steps, and a cancel during install says the device may have finished")
    func cancel() async throws {
        for stopAfter in ["provision", "sign"] {
            let flag = Mutex(false)
            var script = Script()
            script.onStep = { name in if name == stopAfter { flag.withLock { $0 = true } } }
            let ran = try await run(
                action, script: script, ledger: { $0.freeProfiles = [freeProfile(days: 3)] }, isCancelled: { flag.withLock { $0 } })
            let all = ["provision", "sign", "install"]
            #expect(ran.calls.count == all.firstIndex(of: stopAfter)! + 1, "after \(stopAfter): \(ran.calls)")
            #expect(ran.outcomes[0].kind == .cancelled && ran.outcomes[0].lines.allSatisfy { $0.tone == .good })
            #expect(!ran.outcomes[0].notes.contains(MenuActionOutcome.deviceNote))
            #expect(ran.outcomes[0].notes.contains(MenuActionOutcome.reinstallKeptNote))
        }
        let flag = Mutex(false)
        var script = Script()
        script.fail["install"] = .fail("install", code: "INTERRUPTED", message: "stopped")
        script.onStep = { name in if name == "install" { flag.withLock { $0 = true } } }
        let ran = try await run(
            action, script: script, ledger: { $0.freeProfiles = [freeProfile(days: 6.5)] }, isCancelled: { flag.withLock { $0 } })
        #expect(ran.outcomes[0].kind == .cancelled)
        #expect(ran.outcomes[0].notes.contains(MenuActionOutcome.deviceNote))
    }

    @Test("Update's and Add app's texts are unchanged by the shared tail")
    func updateStillWorks() async throws {
        let fetched = MenuFetched(
            version: "3.8.0", build: "141", sha256: oldSha, size: 44_000_000, minOS: nil, extensionCount: 0, alreadyApproved: true)
        let update = MenuAction.addApprove(device: "iphone", app: "apollo", fetched: fetched)
        let ran = try await run(update) { $0.freeProfiles = [freeProfile(days: 6.5)] }
        #expect(ran.calls == ["fetch approve=true", signCall, installCall])
        #expect(ran.outcomes[0].headline == "Added Apollo 3.8.0 to iphone")
    }
}
