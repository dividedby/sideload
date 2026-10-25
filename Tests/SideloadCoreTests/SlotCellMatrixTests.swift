import Foundation
import Testing

@testable import SideloadCore

// The 27 cells of the settle table (kind x op result x the snapshot after it), driven through every command that issues
// that kind of op: install (new app), install (app already there: a reinstall), slot return (an install), slot lend and
// app remove (an uninstall). Each cell is a scripted device; the expected effect comes from `designCells`, the independent
// copy of the design, not from `SlotRule`. Every cell checks the exact device calls, the record, the output, the invariants,
// and (when the op is kept) that the gate holds until the window ends and the next run settles it.

enum CellCommand: String, CaseIterable, Sendable {
    case install, reinstall, giveBack, lend, remove

    var kind: LedgerSlotKind {
        switch self {
        case .install, .giveBack: .install
        case .reinstall: .reinstall
        case .lend, .remove: .uninstall
        }
    }
    var command: SlotCommandKind {
        switch self {
        case .install, .reinstall: .install
        case .giveBack: .giveBack
        case .lend: .lend
        case .remove: .remove
        }
    }
    var lends: Bool { self == .lend || self == .giveBack }
    /// The apps on the device before the command.
    var initial: [String: Bool] {
        switch self {
        case .install, .giveBack: [wdaId: true]
        case .reinstall, .lend, .remove: [stremioId: true, wdaId: true]
        }
    }
}

struct CellCase: Sendable, CustomTestStringConvertible {
    let command: CellCommand
    let result: SlotRule.Result
    let s1: SlotRule.Reading
    let shape: TimeoutShape
    /// An exit 0 that does not name the bundle: an unknown result that is not a timeout.
    let unnamed: Bool

    var testDescription: String { "\(command) \(result)/\(s1) \(unnamed ? "unnamed" : "\(shape)")" }

    var designed: (effect: SlotRule.Effect, note: SlotRule.Note?) {
        // A thrown call leaves `DeviceCtl` unable to read the config, so the snapshot after it fails too.
        let reading = shape == .thrown && result == .unknown ? SlotRule.Reading.unreadable : s1
        let row = designCells.first { $0.cell.kind == command.kind && $0.cell.result == result && $0.cell.s1 == reading }
        return (row?.effect ?? .keep, row?.note)
    }

    static let all: [CellCase] = {
        var out: [CellCase] = []
        for command in CellCommand.allCases {
            for result in SlotRule.Result.allCases {
                for s1 in SlotRule.Reading.allCases {
                    if result != .unknown {
                        out.append(CellCase(command: command, result: result, s1: s1, shape: .runnerKill, unnamed: false))
                        continue
                    }
                    for shape in TimeoutShape.allCases {
                        // A thrown call makes the snapshot after it unreadable, so it only fills that column.
                        if shape == .thrown && s1 != .unreadable { continue }
                        out.append(CellCase(command: command, result: result, s1: s1, shape: shape, unnamed: false))
                    }
                    if command.kind != .uninstall {
                        out.append(CellCase(command: command, result: result, s1: s1, shape: .runnerKill, unnamed: true))
                    }
                }
            }
        }
        return out
    }()

    func script(locked: JSONValue) -> DeviceScript {
        var script = DeviceScript(initial: command.initial)
        script.timeoutShape = shape
        if s1 == .unreadable { script.snapshotFailures = [2] }
        let reinstall = command.kind == .reinstall
        switch command.kind {
        case .install, .reinstall:
            switch result {
            case .success: script.install = .succeed
            case .failure: script.install = .fail(json: locked)
            case .unknown: script.install = unnamed ? .silentSuccess : (s1 == .present && !reinstall ? .timeoutLanding : .timeout)
            }
            switch s1 {
            case .present:
                if result == .failure && !reinstall { script.landsDespiteFailure = true }
            case .absent:
                if reinstall {
                    script.alsoRemovedOnInstall = [stremioId]
                } else if result == .success || unnamed {
                    script.installLeavesApp = true
                }
            case .unreadable: break
            }
        case .uninstall:
            switch result {
            case .success: script.uninstallLeavesApp = s1 == .present
            case .failure:
                script.uninstallFailure = locked
                script.uninstallFailureRemoves = s1 == .absent
            case .unknown: script.uninstallTimeoutRemoves = s1 == .absent
            }
        }
        return script
    }
}

@Suite("slot model: the 27 cells, through every command")
struct SlotCellMatrixTests {
    @Test("every settle cell, for every command that issues its kind of op", arguments: CellCase.all)
    func cell(_ c: CellCase) async throws {
        let locked = try loadFixtureJSON("install-locked.json")
        let name = c.testDescription
        let designed = c.designed
        try await withInstallWorld(
            script: c.script(locked: locked), lendable: "stremio-ios", profileDays: 6,
            ledger: { ledger in
                switch c.command {
                case .install: break
                case .reinstall:
                    var old = installRecord(.stremioIOS)
                    old.profileUuid = "OLD-COPY"
                    ledger.installs = [old]
                case .remove, .lend: ledger.installs = [installRecord(.stremioIOS)]
                case .giveBack:
                    ledger.installs = [installRecord(.stremioIOS, present: false)]
                    ledger.lent = [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: "lent")]
                }
            }
        ) { w in
            let thrown = c.shape == .thrown && c.result == .unknown
            let out = await runSlotCommand(c.command.command, w, thrown: thrown)
            let printed = json(out)
            let slot = w.slotRecord()

            // The record: exactly what the table says.
            switch designed.effect {
            case .present:
                #expect(slot?.presence == .present && slot?.op == nil && slot?.lentTo == nil, "\(name): P \(String(describing: slot))")
            case .absent:
                #expect(slot?.presence == .absent && slot?.op == nil, "\(name): A \(String(describing: slot))")
                #expect((slot?.lentTo != nil) == c.command.lends, "\(name): lentTo after A")
            case .keep:
                #expect(slot?.op?.kind == c.command.kind, "\(name): the op stays, kind \(String(describing: slot?.op?.kind))")
                #expect(slot?.op.map { $0.startedAt >= testNow } == true, "\(name): startedAt")
                #expect((slot?.lentTo != nil) == c.command.lends, "\(name): lentTo while pending")
                #expect(SlotRule.used(slot ?? LedgerSlot(device: "iphone", app: "x", presence: .absent)), "\(name): a kept op counts as used")
            }
            // The device calls: S0, the op, S1 (a thrown call, and the snapshot after it, never reached the runner).
            let op = c.command.kind == .uninstall ? "device uninstall app" : "device install app"
            #expect(w.runner.deviceCalls == (thrown ? ["device info apps"] : ["device info apps", op, "device info apps"]), "\(name): calls \(w.runner.deviceCalls)")

            // The output.
            switch (c.command, designed.effect) {
            case (.reinstall, .present) where c.result == .failure:
                // P keeps the slot used, but a renewal that failed is a failure, and the entry keeps the old copy's facts.
                #expect(out.errorCodes == ["DEVICE_LOCKED"] && printed["renewed"] == false && printed["installed"] == false, "\(name): \(printed)")
            case (.install, .present), (.reinstall, .present):
                #expect(out.ok, "\(name): \(out.errors)")
                let warnings = printed["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
                #expect(warnings == (c.result != .success && !c.unnamed ? ["INSTALL_RESULT_UNCERTAIN"] : []), "\(name): warnings \(warnings)")

            case (.install, .absent): #expect(out.errorCodes == ["DEVICE_LOCKED"], "\(name): \(out.errorCodes)")
            case (.reinstall, .absent): #expect(out.errorCodes == ["UNEXPECTED_APP_DELTA"], "\(name): \(out.errorCodes)")
            case (.install, .keep), (.reinstall, .keep):
                #expect(!out.ok && printed["uncertain"] == true && printed["pending"] == true && printed["retryAfter"] != nil, "\(name): \(out.errorCodes)")
                if designed.note == .installUnconfirmed { #expect(out.errorCodes == ["INSTALL_UNCONFIRMED"], "\(name)") }
                if designed.note == .unexpectedAppDelta { #expect(out.errorCodes == ["UNEXPECTED_APP_DELTA"], "\(name)") }
                if c.s1 == .unreadable && !thrown && c.result == .success { #expect(out.errorCodes == ["SNAPSHOT_FAILED"], "\(name)") }
                if c.result == .failure && c.s1 == .unreadable { #expect(out.errorCodes == ["DEVICE_LOCKED"], "\(name)") }
            case (.giveBack, .present):
                #expect(out.ok && printed["reinstalled"] == true, "\(name): \(out.errors)")
            case (.giveBack, .absent):
                #expect(out.errorCodes == ["RETURN_FAILED"] && printed["cause"] == "DEVICE_LOCKED" && printed["state"] == "lent", "\(name): \(printed)")
            case (.giveBack, .keep):
                #expect(out.errorCodes == ["RETURN_FAILED"] && printed["uncertain"] == true && printed["state"] == "returning", "\(name): \(printed)")
                #expect(printed["retryAfter"] != nil, "\(name): retryAfter")
            case (.lend, .absent):
                #expect(out.ok && printed["freed"] == 1, "\(name): \(out.errors)")
                let warnings = printed["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
                #expect(warnings.contains("UNINSTALL_RESULT_UNCERTAIN") == (c.result != .success), "\(name): warnings \(warnings)")
                #expect(w.phase == .lent)
            case (.lend, .present):
                #expect(out.errorCodes == ["DEVICE_LOCKED"] && printed["freed"] == 0 && w.lent.isEmpty, "\(name): \(printed)")
            case (.lend, .keep):
                #expect(!out.ok && printed["freed"] == 0 && printed["uncertain"] == true && printed["state"] == "lending", "\(name): \(printed)")
                #expect(printed["retryAfter"] != nil && w.phase == .lending, "\(name): retryAfter")
            case (.remove, .absent):
                #expect(out.ok && printed["removed"] == true, "\(name): \(out.errors)")
                let warnings = printed["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
                #expect(warnings.contains("UNINSTALL_RESULT_UNCERTAIN") == (c.result != .success), "\(name): warnings \(warnings)")
            case (.remove, .present):
                #expect(out.errorCodes == ["DEVICE_LOCKED"], "\(name): \(out.errorCodes)")
            case (.remove, .keep):
                #expect(!out.ok && printed["uncertain"] == true && printed["retryAfter"] != nil, "\(name): \(printed)")
            }
            if designed.note == .unexpectedAppDelta && (c.command == .lend || c.command == .remove) {
                #expect(out.errorCodes == ["UNEXPECTED_APP_DELTA"], "\(name): success claimed with the app listed")
            }
            if c.command == .reinstall {
                // The new build's profile, expiry and install date are recorded only when its install succeeded and the
                // snapshot confirms the app (P). Every other cell leaves the old copy's entry exactly as it was.
                let entry = w.installs.first { $0.id == w.key }
                let renewed = designed.effect == .present && c.result == .success
                #expect(entry?.profileExpires == daysFromNow(renewed ? 6 : 5), "\(name): profileExpires")
                #expect(entry?.profileUuid == (renewed ? "0F0F0F0F-1111-2222-3333-444444444444" : "OLD-COPY"), "\(name): profileUuid")
                #expect(entry?.installedAt == (renewed ? testNow : daysFromNow(-1)), "\(name): installedAt")
            }
            try w.expectClean(out)
            try expectSlotModel(w, label: name)
            try expectSlotModel(w, label: name, eventually: true)

            guard designed.effect == .keep else { return }

            // A kept op: inside the window every mutating command is SLOT_PENDING with no device call and no change, status
            // counts the record as used, and the first run after the window settles it from a snapshot.
            let calls = w.runner.deviceCalls.count
            let ledger = try w.ledger()
            for other in SlotCommandKind.allCases {
                let gated = await runSlotCommand(other, w)
                #expect(gated.errorCodes == ["SLOT_PENDING"], "\(name): \(other) inside the window -> \(gated.errorCodes)")
                #expect(json(gated)["freed"] == 0 && json(gated)["op"] == .string(c.command.kind.rawValue), "\(name): \(other) data")
                try w.expectClean(gated)
            }
            #expect(w.runner.deviceCalls.count == calls, "\(name): no device call inside the window")
            #expect(try w.ledger() == ledger, "\(name): the gate changed the ledger")
            let status = json(StatusCommand.run(w.services))
            let iphone = try #require(status["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" })
            #expect(iphone["used"] != 0 && iphone["pending"] == true && iphone["retryAfter"] != .null, "\(name): status")
            try expectStatusNeverOptimistic(w, label: name)

            w.clock.advance(Double(SlotRule.window(c.command.kind)) + 1)
            let settle = await runSlotCommand(c.command.command, w)
            #expect(settle.errorCodes != ["SLOT_PENDING"], "\(name): the window is over, the next run settles")
            try expectSlotModel(w, label: "\(name) after the window")
            try expectSlotModel(w, label: "\(name) after the window", eventually: true)
            try w.expectClean(settle)
        }
    }

    @Test("a reinstall that fails definitively while the old copy stays listed: not ok, the slot stays used, and the ledger keeps the old copy's facts")
    func failedReinstallKeepsOldCopy() async throws {
        let locked = try loadFixtureJSON("install-locked.json")
        let failures: [(InstallBehaviour, String)] = [
            (.fail(json: locked), "DEVICE_LOCKED"),
            (.fail(json: nil, stderr: "Untrusted Developer"), "UNTRUSTED_DEVELOPER"),
        ]
        for (behaviour, code) in failures {
            // The ledger says the old copy expires in 5 days; sign left a build whose profile lasts 6.
            try await withInstallWorld(
                script: DeviceScript(initial: [stremioId: true, wdaId: true], install: behaviour), profileDays: 6,
                ledger: { $0.installs = [installRecord(.stremioIOS)] }
            ) { w in
                let prior = try #require(w.installs.first)
                let out = await w.install()
                #expect(out.errorCodes == [code] && json(out)["renewed"] == false, "\(code): \(out.errors)")
                let kept = try #require(w.installs.first)
                #expect(kept.profileExpires == prior.profileExpires && kept.installedAt == prior.installedAt, "\(code): the old copy's facts")
                #expect(kept.profileUuid == prior.profileUuid && kept.version == prior.version && kept.signedAt == prior.signedAt)
                #expect(kept.present && kept.opAt == nil)
                let slot = try #require(w.slotRecord())
                #expect(slot.presence == .present && slot.op == nil && SlotRule.used(slot), "\(code): closed, and still used")
                try expectSlotModel(w, eventually: true)
                // A later renewal that works records the new copy.
                w.runner.arm(DeviceScript())
                #expect(await w.install().ok)
                #expect(w.installs.first?.profileExpires == daysFromNow(6))
            }
        }
    }

    @Test("two failed reinstalls in a row, the first leaving its result unknown: the old copy's facts survive both")
    func twoFailedReinstalls() async throws {
        let locked = try loadFixtureJSON("install-locked.json")
        // S1 unreadable after the first (keep), then the window passes and a second fails again.
        try await withInstallWorld(
            script: DeviceScript(initial: [stremioId: true, wdaId: true], snapshotFailures: [2], install: .fail(json: locked)), profileDays: 6,
            ledger: { $0.installs = [installRecord(.stremioIOS)] }
        ) { w in
            let prior = try #require(w.installs.first)
            let first = await w.install()
            #expect(first.errorCodes == ["DEVICE_LOCKED"] && json(first)["pending"] == true)
            #expect(w.slotRecord()?.op?.kind == .reinstall)
            #expect(w.installs.first?.profileExpires == prior.profileExpires && w.installs.first?.installedAt == prior.installedAt)
            w.clock.advance(Double(SlotRule.window(.reinstall)) + 1)
            let second = await w.install()
            #expect(second.errorCodes == ["DEVICE_LOCKED"] && json(second)["renewed"] == false)
            let kept = try #require(w.installs.first)
            #expect(kept.profileExpires == prior.profileExpires && kept.profileUuid == prior.profileUuid && kept.installedAt == prior.installedAt)
            try expectSlotModel(w, eventually: true)
        }
    }

    @Test("a crash at every write point of a reinstall never records the new build before the device has it")
    func reinstallCrashPoints() async throws {
        let locked = try loadFixtureJSON("install-locked.json")
        let scripts: [(String, InstallBehaviour, Set<Int>)] = [
            ("failed", .fail(json: locked), []), ("unknown", .timeout, []), ("failed, S1 unreadable", .fail(json: locked), [2]),
        ]
        // A seed whose entry is stale (present:false while the app is on the device) makes install.settle write too.
        for seed in [true, false] {
            for (label, behaviour, failures) in scripts {
                for point in ["migrate", "install.settle", "install.intent", "install.final"] {
                    try await withInstallWorld(
                        script: DeviceScript(initial: [stremioId: true, wdaId: true], snapshotFailures: failures, install: behaviour),
                        profileDays: 6, ledger: { $0.installs = [installRecord(.stremioIOS, present: seed)] }
                    ) { w in
                        let prior = try #require(w.installs.first)
                        _ = await runSlotCommand(.install, w, crashAt: point)
                        let name = "\(label) \(point) seed \(seed)"
                        #expect(w.installs.first?.profileExpires == prior.profileExpires, "\(name): after the crash")
                        #expect(w.installs.first?.profileUuid == prior.profileUuid && w.installs.first?.installedAt == prior.installedAt, "\(name)")
                        // (The stale seed reads absent until the first snapshot settles it, so I5 is only meaningful after that.)
                        if seed || point != "migrate" { try expectSlotModel(w, label: name, eventually: true) }
                        // The next runs, after the window, still fail: nothing records the new build.
                        w.clock.advance(Double(SlotRule.window(.reinstall)) + 1)
                        _ = await runSlotCommand(.install, w)
                        #expect(w.installs.first?.profileExpires == prior.profileExpires, "\(name): after the rerun")
                        try expectSlotModel(w, label: name + " rerun", eventually: true)
                    }
                }
            }
        }
    }

    @Test("rule (i) through a command: the first snapshot at or after the end of the window settles; one second before does not")
    func windowBoundaryThroughCommands() async throws {
        let window = Double(SlotRule.window(.uninstall))
        for (offset, settles) in [(-1.0, false), (0.0, true)] {
            // A lend whose uninstall timed out with the app gone: pending until the window ends.
            try await withInstallWorld(
                script: DeviceScript(initial: [stremioId: true, wdaId: true], snapshotFailures: [2], uninstallTimeoutRemoves: true),
                lendable: "stremio-ios"
            ) { w in
                let first = await runSlotCommand(.lend, w)
                #expect(!first.ok && w.phase == .lending)
                let started = try #require(w.slotRecord()?.op?.startedAt)
                w.clock.advance(started.addingTimeInterval(window + offset).timeIntervalSince(w.clock.now()))
                let again = await runSlotCommand(.lend, w)
                if settles {
                    #expect(again.ok && json(again)["freed"] == 1, "at the end of the window: \(again.errors)")
                } else {
                    #expect(again.errorCodes == ["SLOT_PENDING"] && json(again)["retryAfter"] == 1, "one second before the end")
                }
            }
        }
    }
}
