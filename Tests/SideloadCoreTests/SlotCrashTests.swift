import Foundation
import Testing

@testable import SideloadCore

// Crash injection at every durable write of the slot model (`Services.afterDurableWrite`): `migrate` and
// `{install,lend,return,remove}.{settle,intent,final}`. A crash is the hook throwing right after the named ledger write; the
// process is then "dead", so each test checks the invariants against the simulated device, shows that an op left in flight
// gates every mutating command (SLOT_PENDING, no device call, no change), and reruns commands to see that the next run
// settles it.

/// The seeds the crash sweeps start from: a ledger shape and the matching device.
private enum Seed: String, CaseIterable, Sendable {
    /// Stremio installed and recorded present.
    case installed
    /// Stremio not installed, recorded absent.
    case absent
    /// The slot is lent: recorded `lent`, the app is not on the device.
    case lent
    /// An earlier lend left `lending` behind (its window is over); the app is gone / still there.
    case lendingGone, lendingThere
    /// An earlier return left `returning` behind (its window is over); the app is back / not back.
    case returningBack, returningNot
    /// No record at all, nothing installed.
    case fresh

    var device: [String: Bool] {
        switch self {
        case .installed, .lendingThere, .returningBack: [stremioId: true, wdaId: true]
        case .absent, .lent, .lendingGone, .returningNot, .fresh: [wdaId: true]
        }
    }

    func apply(_ ledger: inout Ledger) {
        let past = daysFromNow(-1)
        func lent(_ state: String) -> LedgerLent {
            LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: past, state: state, opAt: state == "lent" ? nil : past)
        }
        switch self {
        case .installed: ledger.installs = [installRecord(.stremioIOS)]
        case .absent: ledger.installs = [installRecord(.stremioIOS, present: false)]
        case .lent: ledger.installs = [installRecord(.stremioIOS, present: false)]; ledger.lent = [lent("lent")]
        case .lendingGone, .lendingThere: ledger.installs = [installRecord(.stremioIOS)]; ledger.lent = [lent("lending")]
        case .returningBack, .returningNot: ledger.installs = [installRecord(.stremioIOS, present: false)]; ledger.lent = [lent("returning")]
        case .fresh: ledger.installs = []
        }
    }
}

private struct CrashCase: Sendable {
    var point: String
    var kind: SlotCommandKind
    var seed: Seed
    var script: DeviceScript? = nil
    /// The lend record's projection and the op on stremio's record when the process died, and whether the app is on the device.
    var crashed: SlotPhase
    var crashedOp: LedgerSlotKind?
    var appAfterCrash: Bool
    var rerun: SlotCommandKind
    var rerunFields: [String: JSONValue]
    var final: SlotPhase
    var appAfterRerun: Bool
}

private let crashCases: [CrashCase] = [
    CrashCase(
        point: "lend.intent", kind: .lend, seed: .installed, crashed: .lending, crashedOp: .uninstall, appAfterCrash: true,
        rerun: .lend, rerunFields: ["freed": 1], final: .lent, appAfterRerun: false),
    CrashCase(
        point: "lend.final", kind: .lend, seed: .installed, crashed: .lent, crashedOp: nil, appAfterCrash: false,
        rerun: .lend, rerunFields: ["freed": 0, "alreadyLent": true], final: .lent, appAfterRerun: false),
    CrashCase(
        point: "lend.settle", kind: .lend, seed: .lendingGone, crashed: .lent, crashedOp: nil, appAfterCrash: false,
        rerun: .lend, rerunFields: ["freed": 0, "alreadyLent": true], final: .lent, appAfterRerun: false),
    CrashCase(
        point: "return.settle", kind: .giveBack, seed: .lendingGone, crashed: .lent, crashedOp: nil, appAfterCrash: false,
        rerun: .giveBack, rerunFields: ["reinstalled": true], final: .none, appAfterRerun: true),
    CrashCase(
        point: "return.intent", kind: .giveBack, seed: .lent, crashed: .returning, crashedOp: .install, appAfterCrash: false,
        rerun: .giveBack, rerunFields: ["reinstalled": true], final: .none, appAfterRerun: true),
    CrashCase(
        point: "return.final", kind: .giveBack, seed: .lent, crashed: .none, crashedOp: nil, appAfterCrash: true,
        rerun: .giveBack, rerunFields: ["nothingLent": true], final: .none, appAfterRerun: true),
    CrashCase(
        point: "remove.settle", kind: .remove, seed: .absent, script: DeviceScript(initial: [stremioId: true, wdaId: true]),
        crashed: .none, crashedOp: nil, appAfterCrash: true, rerun: .remove, rerunFields: ["removed": true], final: .none,
        appAfterRerun: false),
    CrashCase(
        point: "remove.intent", kind: .remove, seed: .installed, crashed: .none, crashedOp: .uninstall, appAfterCrash: true,
        rerun: .remove, rerunFields: ["removed": true], final: .none, appAfterRerun: false),
    CrashCase(
        point: "remove.final", kind: .remove, seed: .installed, crashed: .none, crashedOp: nil, appAfterCrash: false,
        rerun: .remove, rerunFields: ["removed": false], final: .none, appAfterRerun: false),
    CrashCase(
        point: "install.settle", kind: .install, seed: .absent, script: DeviceScript(initial: [stremioId: true, wdaId: true]),
        crashed: .none, crashedOp: nil, appAfterCrash: true, rerun: .install, rerunFields: ["reinstall": true], final: .none,
        appAfterRerun: true),
    CrashCase(
        point: "install.intent", kind: .install, seed: .fresh, crashed: .none, crashedOp: .install, appAfterCrash: false,
        rerun: .install, rerunFields: ["installed": true, "reinstall": false], final: .none, appAfterRerun: true),
    CrashCase(
        point: "install.intent", kind: .install, seed: .installed, crashed: .none, crashedOp: .reinstall, appAfterCrash: true,
        rerun: .install, rerunFields: ["installed": true, "reinstall": true], final: .none, appAfterRerun: true),
    CrashCase(
        point: "install.final", kind: .install, seed: .fresh, crashed: .none, crashedOp: nil, appAfterCrash: true,
        rerun: .install, rerunFields: ["installed": true, "reinstall": true], final: .none, appAfterRerun: true),
    // The migration itself: the legacy shape is rewritten, then the command dies; the next run finds the slots.
    CrashCase(
        point: "migrate", kind: .lend, seed: .lent, crashed: .lent, crashedOp: nil, appAfterCrash: false,
        rerun: .lend, rerunFields: ["alreadyLent": true], final: .lent, appAfterRerun: false),
    CrashCase(
        point: "migrate", kind: .install, seed: .installed, crashed: .none, crashedOp: nil, appAfterCrash: true,
        rerun: .install, rerunFields: ["reinstall": true], final: .none, appAfterRerun: true),
]

private let allKinds: [SlotCommandKind] = [.lend, .giveBack, .remove, .install]

@Suite("slot model: crashes at every durable write")
struct SlotCrashTests {
    @Test("a crash after each durable write leaves a settleable state, and the next run settles it")
    func crashes() async throws {
        for c in crashCases {
            let name = "\(c.point) \(c.seed)"
            try await withInstallWorld(
                script: c.script ?? DeviceScript(initial: c.seed.device), lendable: "stremio-ios", ledger: { c.seed.apply(&$0) }
            ) { w in
                let out = await runSlotCommand(c.kind, w, crashAt: c.point)
                #expect(!out.ok, "\(name): the crash must surface")
                #expect(w.phase == c.crashed, "\(name): state after the crash \(String(describing: w.lent.first?.state))")
                #expect(w.slotRecord()?.op?.kind == c.crashedOp, "\(name): op after the crash \(String(describing: w.slotRecord()?.op))")
                #expect((w.runner.deviceApps[stremioId] != nil) == c.appAfterCrash, "\(name): app after the crash")
                try expectSlotModel(w, label: name)
                try expectSlotModel(w, label: name, eventually: true)

                // The process is back. An op that may still finish gates every mutating command: SLOT_PENDING, no device
                // call, nothing changed.
                if c.crashedOp != nil {
                    let calls = w.runner.deviceCalls.count
                    let ledger = try w.ledger()
                    for other in allKinds {
                        let early = await runSlotCommand(other, w)
                        #expect(early.errorCodes == ["SLOT_PENDING"], "\(name): \(other) -> \(early.errorCodes)")
                        #expect(json(early)["freed"] == 0 && json(early)["retryAfter"] != nil)
                    }
                    #expect(w.runner.deviceCalls.count == calls, "\(name): no device call inside the window")
                    #expect(try w.ledger() == ledger, "\(name): the gate changed the ledger")
                    try expectSlotModel(w, label: name)
                }
                w.clock.advance(Double(SlotRule.window(.install)) + 1)
                let again = await runSlotCommand(c.rerun, w)
                #expect(again.ok, "\(name): rerun \(again.errors)")
                for (key, value) in c.rerunFields { #expect(json(again)[key] == value, "\(name): rerun \(key) = \(String(describing: json(again)[key]))") }
                #expect(w.phase == c.final, "\(name): final \(String(describing: w.lent.first?.state))")
                #expect((w.runner.deviceApps[stremioId] != nil) == c.appAfterRerun, "\(name): app after the rerun")
                try expectSlotModel(w, label: name)
                try expectSlotModel(w, label: name, eventually: true)
                try w.expectClean(again)
            }
        }
    }

    @Test("a crash at every write point, from every starting record, then the other commands, never breaks the invariants")
    func everyPointThenEverything() async throws {
        let points: [(String, SlotCommandKind)] = [
            ("migrate", .lend), ("lend.settle", .lend), ("lend.intent", .lend), ("lend.final", .lend),
            ("return.settle", .giveBack), ("return.intent", .giveBack), ("return.final", .giveBack),
            ("remove.settle", .remove), ("remove.intent", .remove), ("remove.final", .remove),
            ("install.settle", .install), ("install.intent", .install), ("install.final", .install),
        ]
        for (point, kind) in points {
            for seed in Seed.allCases {
                let name = "\(point) \(seed)"
                try await withInstallWorld(
                    script: DeviceScript(initial: seed.device), lendable: "stremio-ios", ledger: { seed.apply(&$0) }
                ) { w in
                    _ = await runSlotCommand(kind, w, crashAt: point)
                    try expectSlotModel(w, label: name)
                    try expectSlotModel(w, label: name, eventually: true)
                    for (n, next) in [SlotCommandKind.lend, .giveBack, .remove, .install, .lend, .giveBack].enumerated() {
                        if n % 2 == 1 { w.clock.advance(Double(SlotRule.window(.install)) + 1) }
                        let before = try w.ledger()
                        let out = await runSlotCommand(next, w)
                        expectPendingUntouched(before: before, after: try w.ledger(), at: w.clock.now(), label: name)
                        try expectSlotModel(w, label: "\(name) -> \(next)")
                        try expectSlotModel(w, label: "\(name) -> \(next)", eventually: true)
                        try w.expectClean(out)
                    }
                }
            }
        }
    }

    @Test("a crash after the intent of every command, with the op timing out and landing late, still ends consistent", arguments: TimeoutShape.allCases)
    func crashThenLateLanding(shape: TimeoutShape) async throws {
        // The process dies right after the intent; the op it started finishes later on its own.
        for (point, kind, seed) in [("lend.intent", SlotCommandKind.lend, Seed.installed), ("return.intent", .giveBack, .lent), ("install.intent", .install, .fresh), ("remove.intent", .remove, .installed)] {
            var script = DeviceScript(initial: seed.device)
            script.timeoutShape = shape
            try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { seed.apply(&$0) }) { w in
                _ = await runSlotCommand(kind, w, crashAt: point)
                let uninstall = kind == .lend || kind == .remove
                w.runner.scheduleLanding(stremioId, install: !uninstall, after: 250)
                try expectSlotModel(w, label: "\(point) \(shape)", eventually: true)
                w.clock.advance(Double(SlotRule.window(uninstall ? .uninstall : .install)) + 1)
                let out = await runSlotCommand(kind, w)
                try expectSlotModel(w, label: "\(point) \(shape) after", eventually: true)
                try w.expectClean(out)
            }
        }
    }

    // MARK: status

    @Test("status shows a pending record as used, counts it once and warns; a pending plain install is used too")
    func statusPending() async throws {
        for state in ["lending", "returning"] {
            try await withInstallWorld(
                reserved: 1, lendable: "stremio-ios",
                ledger: { ledger in
                    ledger.lent = [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: state, opAt: testNow)]
                    ledger.installs = [installRecord(.stremioIOS), installRecord(.apollo)]
                }
            ) { w in
                let printed = json(StatusCommand.run(w.services))
                let item = try #require(printed["lent"]?.array?.first)
                #expect(item["state"] == .string(state) && item["holds"] == false)
                let iphone = try #require(printed["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" })
                // apollo + the pending record (not stremio twice) + the reserve
                #expect(iphone["used"] == 3 && iphone["free"] == 0 && iphone["pending"] == true)
                #expect(iphone["lent"] == ["app": "stremio-ios", "state": .string(state)])
                #expect(iphone["apps"] == ["apollo"])
                #expect(iphone["retryAfter"] == .number(Double(SlotRule.window(state == "lending" ? .uninstall : .install))))
                let codes = printed["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
                #expect(codes == ["SLOT_STATE_PENDING"])
                #expect(w.runner.calls.isEmpty)
                #expect(try w.ledger().slots.isEmpty, "status never writes: the migration stays in memory")
            }
        }
        try await withInstallWorld(
            lendable: "stremio-ios", ledger: { $0.lent = [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: "lent")] }
        ) { w in
            let printed = json(StatusCommand.run(w.services))
            #expect(printed["lent"]?.array?.first?["holds"] == true)
            let iphone = try #require(printed["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" })
            #expect(iphone["pending"] == false && iphone["used"] == 1 && iphone["retryAfter"] == .null)
            #expect(printed["warnings"] == [])
        }
        // A plain install left pending: the slot is used, the record shows in `apps`, nothing is lent.
        try await withInstallWorld(script: DeviceScript(install: .timeout), ledger: { $0.installs = [] }) { w in
            _ = await w.install()
            let printed = json(StatusCommand.run(w.services))
            let iphone = try #require(printed["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" })
            #expect(iphone["used"] == 1 && iphone["free"] == 2 && iphone["pending"] == true && iphone["apps"] == ["stremio-ios"])
            #expect(iphone["lent"] == .null && printed["lent"] == [])
        }
    }
}
