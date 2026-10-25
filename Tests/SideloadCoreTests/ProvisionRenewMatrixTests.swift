import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import sideload

// The `--renew` result and error model: whatever fails, wherever, the envelope says what was moved and every file
// can be accounted for. One parameterized test over every `Fault` (a new case joins it by `CaseIterable`), plus the
// signal path and the durable record of the moves.

/// Every profile file in Xcode's folders and in `tmp/`, as sorted contents: nothing may be deleted or overwritten.
private func profileBytes(_ w: ProvisionWorld) -> [Data] {
    (w.cacheDirs + [w.paths.tmp]).flatMap { dir in
        listing(dir).filter { $0.hasSuffix(".mobileprovision") }.compactMap {
            try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + $0))
        }
    }.sorted { $0.lexicographicallyPrecedes($1) }
}

private func tmpRenewed(_ w: ProvisionWorld) -> Set<String> {
    Set(listing(w.paths.tmp).filter { $0.hasPrefix("renewed-profile-") }.map { "tmp/" + $0 })
}

private func names(_ value: JSONValue?) -> [String] { value?.array?.compactMap(\.string) ?? [] }

/// The accounting every envelope of a renewing run has to satisfy.
private func expectAccounted(_ out: Envelope, _ w: ProvisionWorld, _ scenario: FaultScenario, fault: Fault) async throws {
    let label = "\(fault)"
    let text = try out.printed().text
    #expect(!text.contains(w.paths.home), "no absolute path: \(label)")
    #expect(out.data["movedSoFar"] == nil && out.data["skipped"] == nil, "no old keys: \(label)")
    guard scenario.reachesRenew else {
        for key in ProfileCacheRenewal.Outcome.keys { #expect(out.data[key] == nil, "\(key) before the renewal started: \(label)") }
        return
    }
    for key in ProfileCacheRenewal.Outcome.keys { #expect(out.data[key] != nil, "\(key) missing: \(label)") }
    for key in ["app", "device", "bundleId"] { #expect(out.data[key] != nil, "\(key) missing: \(label)") }

    let movedTo = names(out.data["cachedProfilesMovedTo"]), stray = names(out.data["cachedProfilesStrayInTmp"])
    #expect(out.data["cachedProfilesMoved"] == .number(Double(movedTo.count)), "moved == movedTo.count: \(label)")
    #expect(tmpRenewed(w) == Set(movedTo).union(stray), "what is in tmp/ is exactly what was reported: \(label)")
    for name in movedTo + stray { #expect(name.hasPrefix("tmp/renewed-profile-") && name.hasSuffix(".mobileprovision")) }
    #expect(Set(movedTo).isDisjoint(with: stray), "\(label)")

    // Until the CLI has written the envelope, the ledger still has every move (a stray marked stray, a finished move done,
    // each with its folder label); a successful emit then removes the finished ones and never a stray.
    let recorded = try w.ledger().freeRenewMoves
    #expect(Set(recorded.map(\.to)) == Set(movedTo).union(stray), "every move stays recorded until emitted: \(label)")
    for entry in recorded {
        #expect(entry.state == (stray.contains(entry.to) ? .stray : .done), "\(label)")
        #expect(entry.folder?.hasPrefix("folder-") == true && !entry.from.contains("/"), "\(label)")
    }
    #expect(w.services.postEmit.isPending == !movedTo.isEmpty, "\(label)")
    await w.services.postEmit.runIfPending()
    #expect(Set(try w.ledger().freeRenewMoves.map(\.to)) == Set(stray), "only strays stay after the emit: \(label)")
}

@Suite("provision: --renew failure matrix")
struct ProvisionRenewMatrixTests {
    @Test("every fault, with --renew, reports and accounts for every file", arguments: Fault.allCases)
    func accounted(fault: Fault) async throws {
        try await withFaultWorld(fault) { (w: ProvisionWorld, scenario: FaultScenario) async throws in
            let before = profileBytes(w)
            let out = await runFault(w, scenario, renew: true)
            if let code = scenario.expectedCode {
                #expect(out.errors.first?.code == code, "\(fault): \(out.errors)")
            } else {
                #expect(out.ok, "\(fault): \(out.errors)")
            }
            try await expectAccounted(out, w, scenario, fault: fault)
            #expect(profileBytes(w) == before, "nothing deleted or overwritten: \(fault)")
        }
    }

    @Test("every envelope, whichever step ends the run, lists the moves an earlier run left", arguments: Fault.allCases.filter { !$0.renewOnly })
    func leftoversEverywhere(fault: Fault) async throws {
        try await withFaultWorld(fault, leftover: true) { (w: ProvisionWorld, scenario: FaultScenario) async throws in
            let out = await runFault(w, scenario)
            let listed = try #require(out.data["cachedProfilesFromEarlierRun"]?.array, "\(fault)")
            #expect(listed.count == 1 && listed.first?["to"]?.string == "tmp/renewed-profile-0123456789ab.mobileprovision", "\(fault)")
            #expect(listed.first?["folder"]?.string == "xcode-userdata" && listed.first?["inTmp"] == .bool(false), "\(fault)")
            #expect(out.data["renewRecordUnreadable"] == nil)
            #expect(!(try out.printed().text.contains(w.paths.home)))
        }
    }

    @Test("a missing prefix (CONFIG_MISSING) and a busy lock list them too")
    func leftoversConfigAndLock() async throws {
        try await withFaultWorld(.success, leftover: true) { (w: ProvisionWorld, _: FaultScenario) async throws in
            try await w.store.update { $0.bundleIdPrefix = nil }
            let out = await w.run()
            #expect(out.errors.first?.code == "CONFIG_MISSING")
            #expect(out.data["cachedProfilesFromEarlierRun"]?.array?.count == 1)
        }
        try await withFaultWorld(.success, leftover: true) { (w: ProvisionWorld, _: FaultScenario) async throws in
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            let out = await w.run()
            #expect(out.errors.first?.code == "OPERATION_IN_PROGRESS")
            #expect(out.data["cachedProfilesFromEarlierRun"]?.array?.count == 1)
        }
    }

    @Test("the CLI: parse-level provision envelopes (unknown flag, extra positional, missing value) list them too")
    func leftoversCli() async throws {
        try await withFaultWorld(.success, leftover: true) { (w: ProvisionWorld, _: FaultScenario) async throws in
            for argv in [["provision", "--bogus"], ["provision", "extra"], ["provision", "--app"], ["provision"], ["provision", "--app", "apollo", "--device", "iphone"]] {
                let out = await run(argv: argv, services: w.services)
                #expect(!out.ok && out.command == "provision", "\(argv)")
                #expect(out.data["cachedProfilesFromEarlierRun"]?.array?.count == 1, "\(argv)")
            }
            // A clean ledger adds nothing, and a successful acknowledgement lists what it cleared once.
            let cleared = await run(argv: ["provision", "--renew-ack", "--yes"], services: w.services)
            #expect(cleared.ok && cleared.data["cachedProfilesFromEarlierRun"]?.array?.count == 1)
            let clean = await run(argv: ["provision", "--bogus"], services: w.services)
            #expect(clean.data["cachedProfilesFromEarlierRun"] == nil)
        }
    }

    @Test("the CLI: a home that cannot be prepared (ensureHome fails) still says whether the record could be read")
    func leftoversEnsureHomeFails() async throws {
        try await withFaultWorld(.success) { (w: ProvisionWorld, _: FaultScenario) async throws in
            let notAFolder = w.paths.home + "/file"
            try Data("x".utf8).write(to: URL(fileURLWithPath: notAFolder))
            var services = w.services
            services.home = Paths(home: notAFolder)
            let out = await run(argv: ["provision", "--app", "apollo", "--device", "iphone", "--yes"], services: services)
            #expect(!out.ok && out.command == "provision")
            #expect(out.data["renewRecordUnreadable"] == true)
        }
    }

    @Test("a ledger that cannot be read is said so, not silently skipped")
    func unreadableRecord() async throws {
        try await withFaultWorld(.usage) { (w: ProvisionWorld, scenario: FaultScenario) async throws in
            try Data("not json".utf8).write(to: URL(fileURLWithPath: w.paths.ledger))
            let out = await runFault(w, scenario)
            #expect(out.errors.first?.code == "USAGE")
            #expect(out.data["renewRecordUnreadable"] == true)
            #expect(out.data["cachedProfilesFromEarlierRun"] == nil)
        }
    }

    @Test("settlement waits for the emit: a successful emit removes the finished moves, a failed one leaves them for the next run")
    func settlementAfterEmit() async throws {
        // Emit succeeded: only the stray stays.
        try await withFaultWorld(.moveBackEIO) { (w: ProvisionWorld, scenario: FaultScenario) async throws in
            let out = await runFault(w, scenario, renew: true)
            #expect(out.ok)
            #expect(try w.ledger().freeRenewMoves.count == 2, "file 1 done, file 2 stray: both still recorded before the emit")
            await w.services.postEmit.runIfPending()
            let left = try w.ledger().freeRenewMoves
            #expect(left.count == 1 && left.first?.state == .stray, "a stray is never auto-removed")
            await w.services.postEmit.runIfPending()  // idempotent
            #expect(try w.ledger().freeRenewMoves == left)
        }
        // Emit failed (never ran): both stay, and the next provision reports them.
        try await withFaultWorld(.moveBackEIO) { (w: ProvisionWorld, scenario: FaultScenario) async throws in
            _ = await runFault(w, scenario, renew: true)
            let next = await w.run(ProvisionOptions(app: "stremio-ios", device: "iphone", yes: true))
            let listed = try #require(next.data["cachedProfilesFromEarlierRun"]?.array)
            #expect(listed.count == 2)
            #expect(Set(listed.compactMap { $0["state"]?.string }) == ["done", "stray"])
            #expect(Set(listed.compactMap { $0["folder"]?.string }) == ["folder-1", "folder-2"])
            #expect(listed.allSatisfy { $0["inTmp"] == .bool(true) })
            #expect(!(try next.printed().text.contains(w.paths.home)))
        }
    }

    @Test("a fault that throws does so at its checkpoint, and every checkpoint has a fault")
    func checkpointsCovered() throws {
        #expect(Set(Fault.allCases.compactMap(\.checkpoint)) == Set(ProvisionCheckpoint.allCases))
    }

    @Test("without --renew no envelope has a renewal key, and no step's own data collides with them")
    func noCollision() async throws {
        for fault in Fault.allCases where !fault.renewOnly {
            try await withFaultWorld(fault) { (w: ProvisionWorld, scenario: FaultScenario) async throws in
                let out = await runFault(w, scenario)
                for key in ProfileCacheRenewal.Outcome.keys { #expect(out.data[key] == nil, "\(key): \(fault)") }
                #expect(out.data["cachedProfilesFromEarlierRun"] == nil)
                #expect(try w.ledger().freeRenewMoves.isEmpty)
            }
        }
    }

    // The specific outcomes of the renewal's own faults: file 1 (first folder) moves, file 2 meets the fault.
    static let renewCases: [(Fault, moved: Int, skipped: Int, stray: Int)] = [
        (.success, 2, 0, 0), (.listDir2Fails, 1, 0, 0), (.mkdirTmpFails, 0, 0, 0), (.crossVolumeDev, 0, 0, 0),
        (.forwardEACCES, 1, 0, 0), (.forwardENOENT, 1, 0, 0), (.forwardEXDEV, 1, 0, 0), (.forwardEEXIST, 1, 0, 0),
        (.lstatAfterRenameFails, 1, 1, 0), (.moveBackEEXIST, 1, 1, 1), (.moveBackENOENT, 1, 1, 1),
        (.moveBackEACCES, 1, 1, 1), (.moveBackEXDEV, 1, 1, 1), (.moveBackEIO, 1, 1, 1), (.sealedBeforeFile2, 1, 0, 0),
        (.intentWriteFails, 1, 0, 0),
    ]

    @Test("the renewal's own faults leave the counts, the files and the build as designed")
    func renewFaults() async throws {
        for (fault, moved, skipped, stray) in Self.renewCases {
            try await withFaultWorld(fault) { (w: ProvisionWorld, scenario: FaultScenario) async throws in
                let out = await runFault(w, scenario, renew: true)
                #expect(out.data["cachedProfilesMoved"] == .number(Double(moved)), "\(fault)")
                #expect(out.data["cachedProfilesSkipped"] == .number(Double(skipped)), "\(fault)")
                #expect(names(out.data["cachedProfilesStrayInTmp"]).count == stray, "\(fault)")
                // A renewal that stops early builds nothing; one that ends in a success builds.
                #expect(w.builds.count == (scenario.expectedCode == nil ? 1 : 0), "\(fault)")
                // A file that failed to move is still in Xcode's folder.
                if [.forwardEACCES, .forwardENOENT, .forwardEXDEV, .forwardEEXIST, .sealedBeforeFile2, .intentWriteFails].contains(fault) {
                    #expect(FileManager.default.fileExists(atPath: w.cacheDirs[1] + "/mine2.mobileprovision"), "\(fault)")
                }
                if fault == .lstatAfterRenameFails {
                    #expect(FileManager.default.fileExists(atPath: w.cacheDirs[1] + "/mine2.mobileprovision"), "put back")
                }
                if stray == 1 {
                    #expect(!FileManager.default.fileExists(atPath: w.cacheDirs[1] + "/mine2.mobileprovision"), "\(fault)")
                    #expect(out.ok, "a stray does not fail the run: \(fault)")
                }
            }
        }
    }

    @Test("an interrupted renewal's file is never moved: the sealed progress refuses, and the entry is withdrawn")
    func sealedRefuses() throws {
        let progress = RenewProgress()
        #expect(progress.critical { $0.moved += 1 })
        let sealed = progress.seal()
        #expect(sealed.moved == 1)
        var ran = false
        #expect(!progress.critical { _ in ran = true })
        #expect(!ran)
        #expect(progress.snapshot == sealed)
    }
}

// MARK: the signal path

private final class Capture: Sendable {
    private let lines = Mutex<[String]>([])
    var writes: [String] { lines.withLock { $0 } }
    var writer: Emitter.Writer { { text in self.lines.withLock { $0.append(text) } } }
}

@Suite("provision: --renew and a signal")
struct ProvisionRenewSignalTests {
    @Test("a Ctrl-C during xcodebuild reports what was moved, from the sealed progress")
    func reportsMoved() async throws {
        try await withFaultWorld(.success) { (w: ProvisionWorld, _: FaultScenario) async throws in
            let capture = Capture()
            let interrupt = Interrupt(writer: capture.writer, children: LiveChildren())
            var hooks = ProvisionHooks()
            let services = w.services
            let code = Mutex<Int32?>(nil)
            // The marker write is the last step before xcodebuild: play the handler there.
            hooks.checkpoint = { point in
                guard point == .markerWrite else { return }
                let report = services.interruptReport.current() ?? [:]
                code.withLock { $0 = interrupt.handle(signal: SIGINT, context: report) }
            }
            let out = await ProvisionCommand.run(
                w.services, ProvisionOptions(app: "stremio-ios", device: "iphone", renew: true, yes: true), hooks: hooks)
            #expect(out.ok, "the in-process run goes on; a real handler would have exited")
            #expect(code.withLock { $0 } == 130)

            let object = try decodeJSON(try #require(capture.writes.first))
            #expect(object["ok"] == .bool(false))
            #expect(object["errors"]?.array?.first?["code"]?.string == "INTERRUPTED")
            let message = try #require(object["errors"]?.array?.first?["message"]?.string)
            #expect(message == "Interrupted by SIGINT after provision --renew moved 2 cached profiles into tmp/.")
            let fix = try #require(object["errors"]?.array?.first?["fix"]?.string)
            #expect(fix.contains("Nothing was deleted") && fix.contains("cachedProfilesMovedTo"))
            for key in ProfileCacheRenewal.Outcome.keys { #expect(object[key] != nil, "\(key)") }
            #expect(object["cachedProfilesMoved"] == .number(2))
            #expect(names(object["cachedProfilesMovedTo"]).count == 2)
            for key in ["app", "device", "bundleId"] { #expect(object[key] != nil) }
            #expect(!(capture.writes.first ?? "").contains(w.paths.home))
        }
    }

    @Test("the INTERRUPTED message is worded from the counts: moved, strays only, or nothing moved")
    func wording() throws {
        func message(moved: Int, stray: Int) throws -> String? {
            var outcome = ProfileCacheRenewal.Outcome()
            outcome.moved = moved
            outcome.strayInTmp = (0..<stray).map { "tmp/renewed-profile-00000000000\($0).mobileprovision" }
            let capture = Capture()
            let interrupt = Interrupt(writer: capture.writer, children: LiveChildren())
            _ = interrupt.handle(signal: SIGINT, context: outcome.json.merging(["app": "x"]) { a, _ in a })
            return try decodeJSON(try #require(capture.writes.first))["errors"]?.array?.first?["message"]?.string
        }
        #expect(try message(moved: 1, stray: 0) == "Interrupted by SIGINT after provision --renew moved 1 cached profile into tmp/.")
        #expect(try message(moved: 0, stray: 2) == "Interrupted by SIGINT during provision --renew, which left 2 cached profiles in tmp/ that could not be put back.")
        #expect(try message(moved: 0, stray: 0) == "Interrupted by SIGINT during provision --renew; no cached profiles were moved.")
    }

    @Test("delivered: true only after a full write; false for a failed write and for a reader that went away")
    func delivered() throws {
        signal(SIGPIPE, SIG_IGN)
        let capture = Capture()
        let ok = Interrupt(writer: capture.writer, children: LiveChildren())
        guard case .exit(0) = ok.finishMain(.result("x")) else { Issue.record("expected exit 0"); return }
        #expect(ok.delivered)

        struct Boom: Error {}
        let failing = Interrupt(writer: { _ in throw Boom() }, children: LiveChildren())
        _ = failing.finishMain(.result("x"))
        #expect(!failing.delivered)

        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        close(fds[0])
        defer { close(fds[1]) }
        let broken = Interrupt(stdoutFD: fds[1], children: LiveChildren())
        guard case .exit(0) = broken.finishMain(.result("x")) else { Issue.record("a closed reader is not an error for the exit code"); return }
        #expect(!broken.delivered, "but the object was not delivered")

        var live: [Int32] = [0, 0]
        try #require(pipe(&live) == 0)
        defer { close(live[0]); close(live[1]) }
        let reading = Interrupt(stdoutFD: live[1], children: LiveChildren())
        _ = reading.finishMain(.result("x"))
        #expect(reading.delivered)

        let notYet = Interrupt(writer: capture.writer, children: LiveChildren())
        #expect(!notYet.delivered)
    }

    @Test("a signal during a run WITHOUT --renew carries the moves an earlier run left")
    func leftoversOnSignal() async throws {
        try await withFaultWorld(.success, leftover: true) { (w: ProvisionWorld, _: FaultScenario) async throws in
            let capture = Capture()
            let interrupt = Interrupt(writer: capture.writer, children: LiveChildren())
            var hooks = ProvisionHooks()
            let services = w.services
            hooks.checkpoint = { point in
                guard point == .markerWrite else { return }
                _ = interrupt.handle(signal: SIGINT, context: services.interruptReport.current() ?? [:])
            }
            _ = await ProvisionCommand.run(
                w.services, ProvisionOptions(app: "stremio-ios", device: "iphone", yes: true), hooks: hooks)
            let object = try decodeJSON(try #require(capture.writes.first))
            #expect(object["errors"]?.array?.first?["code"]?.string == "INTERRUPTED")
            #expect(object["errors"]?.array?.first?["message"]?.string == "Interrupted by SIGINT.")
            #expect(object["cachedProfilesFromEarlierRun"]?.array?.count == 1)
            #expect(object["cachedProfilesMoved"] == nil)
        }
    }

    @Test("a signal without a registered report is the plain INTERRUPTED object")
    func plain() throws {
        let capture = Capture()
        let interrupt = Interrupt(writer: capture.writer, children: LiveChildren())
        #expect(interrupt.handle(signal: SIGTERM, context: InterruptReport().current() ?? [:]) == 143)
        let object = try decodeJSON(try #require(capture.writes.first))
        #expect(object["errors"]?.array?.first?["message"]?.string == "Interrupted by SIGTERM.")
        #expect(object["cachedProfilesMoved"] == nil)
    }

    @Test("a run without --renew registers nothing for the handler")
    func notRegistered() async throws {
        try await withFaultWorld(.success) { (w: ProvisionWorld, scenario: FaultScenario) async throws in
            _ = await runFault(w, scenario)
            #expect(w.services.interruptReport.current() == nil)
        }
    }
}

// MARK: the durable record

/// Plays a process that dies at one point: from then on every ledger write fails (a directory sits where the ledger
/// lock file belongs) and no further file is renamed, so the ledger and the folders stay as the "crash" left them.
private final class Crash: Sendable {
    private let dead = Mutex(false)
    private let lockPath: String

    init(lockPath: String) { self.lockPath = lockPath }

    var isDead: Bool { dead.withLock { $0 } }

    func die() {
        dead.withLock { dead in
            guard !dead else { return }
            dead = true
            // The lock file exists by now; a directory in its place makes every later ledger update fail.
            try? FileManager.default.removeItem(atPath: lockPath)
            try? FileManager.default.createDirectory(atPath: lockPath, withIntermediateDirectories: true)
        }
    }

    /// The process is back: ledger writes work again.
    func revive() { try? FileManager.default.removeItem(atPath: lockPath) }
}

@Suite("provision: --renew crash safety")
struct ProvisionRenewDurabilityTests {
    private enum Point { case afterIntent, afterRename }

    /// Runs `--renew` and "crashes" at `point` of the first move; returns with the world as the crash left it.
    private func crashed(_ w: ProvisionWorld, at point: Point) async -> Crash {
        let crash = Crash(lockPath: w.paths.ledgerLock)
        var hooks = ProvisionHooks()
        hooks.renewFS.renameExcl = { [base = hooks.renewFS.renameExcl] from, to in
            if crash.isDead { return EIO }
            let code = base(from, to)
            if point == .afterRename { crash.die() }
            return code
        }
        hooks.renewJournal = { journal in
            var journal = journal
            let base = journal.intent
            journal.intent = { entry in
                let ok = await base(entry)
                if point == .afterIntent { crash.die() }
                return ok
            }
            return journal
        }
        _ = await ProvisionCommand.run(
            w.services, ProvisionOptions(app: "stremio-ios", device: "iphone", renew: true, yes: true), hooks: hooks)
        return crash
    }

    @Test("a crash after the intent write and before the rename is reported by the next run, and kept")
    func crashBeforeRename() async throws {
        try await withFaultWorld(.success) { (w: ProvisionWorld, _: FaultScenario) async throws in
            let crash = await crashed(w, at: .afterIntent)
            #expect(crash.isDead)
            crash.revive()
            let entry = try #require(try w.ledger().freeRenewMoves.first)
            #expect(try w.ledger().freeRenewMoves.count == 1)
            #expect(entry.state == .intent && entry.from == "mine1.mobileprovision" && entry.to.hasPrefix("tmp/renewed-profile-"))
            #expect(FileManager.default.fileExists(atPath: w.cacheDirs[0] + "/mine1.mobileprovision"), "never renamed")

            for _ in 0..<2 {  // kept until the owner clears it, success or not (the second run is PROFILE_NOT_RENEWED)
                let next = await w.run()
                let reported = try #require(next.data["cachedProfilesFromEarlierRun"]?.array)
                #expect(reported.count == 1)
                #expect(reported.first?["from"]?.string == "mine1.mobileprovision")
                #expect(reported.first?["to"]?.string == entry.to)
                #expect(reported.first?["state"]?.string == "intent")
                #expect(reported.first?["folder"]?.string == "folder-1")
                #expect(reported.first?["inTmp"] == .bool(false))
                #expect(!(try next.printed().text.contains(w.paths.home)))
            }
        }
    }

    @Test("a crash after the rename is reported by the next run, with the file in tmp/")
    func crashAfterRename() async throws {
        try await withFaultWorld(.success) { (w: ProvisionWorld, _: FaultScenario) async throws in
            let crash = await crashed(w, at: .afterRename)
            #expect(crash.isDead)
            crash.revive()
            let entry = try #require(try w.ledger().freeRenewMoves.first)
            #expect(entry.state == .intent, "the done mark never got written")
            #expect(!FileManager.default.fileExists(atPath: w.cacheDirs[0] + "/mine1.mobileprovision"), "renamed")
            #expect(FileManager.default.fileExists(atPath: w.paths.home + "/" + entry.to))

            let next = await w.run()
            #expect(next.ok, "\(next.errors)")
            let reported = try #require(next.data["cachedProfilesFromEarlierRun"]?.array)
            #expect(reported.count == 1)
            #expect(reported.first?["to"]?.string == entry.to && reported.first?["inTmp"] == .bool(true))
            // The file is still there: reporting never deletes.
            #expect(FileManager.default.fileExists(atPath: w.paths.home + "/" + entry.to))
        }
    }

    @Test("--renew-ack --yes clears the record and touches no file; without --yes it only asks")
    func acknowledge() async throws {
        try await withFaultWorld(.success) { (w: ProvisionWorld, _: FaultScenario) async throws in
            let crash = await crashed(w, at: .afterRename)
            crash.revive()
            let entry = try #require(try w.ledger().freeRenewMoves.first)
            let before = profileBytes(w)

            let asked = await w.run(ProvisionOptions(yes: false, renewAck: true))
            #expect(asked.errors.first?.code == "CONFIRM_REQUIRED")
            #expect(try w.ledger().freeRenewMoves.count == 1)

            let alone = await w.run(ProvisionOptions(app: "stremio-ios", yes: true, renewAck: true))
            #expect(alone.errors.first?.code == "USAGE")

            let cleared = await w.run(ProvisionOptions(yes: true, renewAck: true))
            #expect(cleared.ok, "\(cleared.errors)")
            #expect(cleared.data["renewMovesAcknowledged"] == 1)
            #expect(cleared.data["cachedProfilesFromEarlierRun"]?.array?.first?["to"]?.string == entry.to)
            #expect(try w.ledger().freeRenewMoves.isEmpty)
            #expect(profileBytes(w) == before, "no file touched")

            let next = await w.run()
            #expect(next.ok && next.data["cachedProfilesFromEarlierRun"] == nil)
        }
    }

    @Test("leftovers ride along on a failing run too, and a run that did not renew has no renewal keys")
    func leftoversOnFailure() async throws {
        try await withFaultWorld(.buildUnknown) { (w: ProvisionWorld, _: FaultScenario) async throws in
            try await w.services.ledgerStore.update {
                $0.freeRenewMoves = [LedgerFreeRenewMove(from: "x.mobileprovision", to: "tmp/renewed-profile-aaaaaaaaaaaa.mobileprovision", at: testNow)]
            }
            let out = await w.run()
            #expect(out.errors.first?.code == "PROVISION_FAILED")
            #expect(out.data["cachedProfilesFromEarlierRun"]?.array?.count == 1)
            for key in ProfileCacheRenewal.Outcome.keys { #expect(out.data[key] == nil, "a run that did not renew has no renewal keys") }
        }
    }

    @Test("a ledger with renew moves round-trips; one without them encodes as before")
    func roundTrip() throws {
        let move = LedgerFreeRenewMove(from: "a.mobileprovision", to: "tmp/renewed-profile-0123456789ab.mobileprovision", at: testNow, state: .stray)
        let ledger = Ledger(freeRenewMoves: [move])
        #expect(try LedgerStore.parse(try LedgerStore.encode(ledger)) == ledger)
        let plain = String(decoding: try LedgerStore.encode(Ledger()), as: UTF8.self)
        #expect(!plain.contains("freeRenewMoves"))
    }
}
