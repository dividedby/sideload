import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Every way a device op can end without a known result (the runner's kill, devicectl's own `--timeout`, an output overflow,
// a signal kill, a thrown call) must be handled as uncertain: never a slot claimed free, never an app off the device
// unrecorded. `TimeoutShape` lists them all; `.thrown` is produced by `runSlotCommand(thrown: true)`.

@Suite("slot and install: every unknown-result shape is uncertain")
struct SlotTimeoutShapeTests {
    @Test("FreeDeviceCalls.uncertain names every shape, and a spawn error or a plain failure is not one")
    func uncertainClassification() async throws {
        try await withInstallWorld { w in
            let calls = FreeDeviceCalls(services: w.services, alias: "iphone", bundleId: stremioId)
            func outcome(_ result: RunResult) -> FreeDeviceCalls.Outcome {
                FreeDeviceCalls.Outcome(code: result.code, json: nil, stderr: result.stderr, timedOut: result.timedOut, overflow: result.overflow, spawnError: result.spawnError)
            }
            for shape in TimeoutShape.allCases {
                let out = outcome(shape.result)
                for operation in [FreeInstallClassifier.Operation.install, .uninstall] {
                    let failure = calls.classify(operation, out)
                    #expect(calls.uncertain(out, failure), "\(shape) \(operation)")
                    #expect(calls.result(failure, uncertain: calls.uncertain(out, failure)) == .unknown, "\(shape)")
                }
            }
            let spawn = outcome(RunResult(code: nil, spawnError: "ENOENT"))
            #expect(!calls.uncertain(spawn, calls.classify(.uninstall, spawn)), "a spawn error never ran anything")
            let plain = outcome(RunResult(code: 1, stderr: "the device is locked"))
            let failure = calls.classify(.uninstall, plain)
            #expect(!calls.uncertain(plain, failure) && calls.result(failure, uncertain: false) == .failure)
            let ok = outcome(RunResult())
            #expect(calls.result(calls.classify(.uninstall, ok), uncertain: false) == .success)
        }
    }

    @Test("lend: an uninstall that ends unknown with the app still listed keeps the op; a second lend claims nothing", arguments: TimeoutShape.allCases)
    func lendUnknown(shape: TimeoutShape) async throws {
        var script = DeviceScript(initial: [stremioId: true, wdaId: true], uninstallTimeoutRemoves: false)
        script.timeoutShape = shape
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await runSlotCommand(.lend, w, thrown: shape == .thrown)
            #expect(!out.ok)
            #expect(out.data["freed"] == 0)
            #expect(w.lent.map(\.state) == ["lending"], "\(shape): the intent stays")
            #expect(w.slotRecord()?.op?.kind == .uninstall && w.lent.first?.opAt != nil, "\(shape): stamped, so no snapshot settles it inside the window")
            // Inside the window a second lend claims nothing and runs no device op.
            let calls = w.runner.deviceCalls.count
            let again = await w.slot("lend", device: "iphone", to: "lab")
            #expect(again.errorCodes == ["SLOT_PENDING"], "\(shape)")
            #expect(w.runner.deviceCalls.count == calls)
        }
    }

    @Test("return: an install that ends unknown keeps the op, and a late landing is never read as lent", arguments: TimeoutShape.allCases)
    func returnUnknown(shape: TimeoutShape) async throws {
        var script = DeviceScript(initial: [wdaId: true], install: .timeout, installLandsAfter: 120)
        script.timeoutShape = shape
        let lent = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: "lent")
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { $0.lent = [lent] }) { w in
            let out = await runSlotCommand(.giveBack, w, thrown: shape == .thrown)
            #expect(!out.ok)
            #expect(w.lent.map(\.state) == ["returning"], "\(shape)")
            #expect(w.lent.first?.opAt != nil, "\(shape)")
            w.clock.advance(130)  // the install lands
            let lend = await w.slot("lend", device: "iphone", to: "lab")
            #expect(lend.errorCodes == ["SLOT_PENDING"], "\(shape): inside the window nothing is claimed")
            #expect(lend.data["freed"] == 0)
            try expectSlotModel(w, label: "\(shape)", eventually: true)
        }
    }

    @Test("plain install of a new app that ends unknown keeps an install op that reads present; remove inside the window is pending", arguments: TimeoutShape.allCases)
    func installUnknown(shape: TimeoutShape) async throws {
        var script = DeviceScript(initial: [wdaId: true], install: .timeout, installLandsAfter: 60)
        script.timeoutShape = shape
        try await withInstallWorld(script: script) { w in
            let out = await runSlotCommand(.install, w, thrown: shape == .thrown)
            #expect(!out.ok)
            let entry = try #require(w.installs.first { $0.id == w.key }, "\(shape): a new app gets an entry")
            #expect(entry.present && entry.opAt != nil, "\(shape)")
            #expect(w.slotRecord()?.op?.kind == .install)
            let remove = await w.remove()
            #expect(remove.errorCodes == ["SLOT_PENDING"] && json(remove)["removed"] == false, "\(shape)")
        }
    }

    @Test("a reinstall that ends unknown is never settled by presence alone: it stays pending whatever the snapshot shows", arguments: TimeoutShape.allCases)
    func reinstallUnknown(shape: TimeoutShape) async throws {
        var script = DeviceScript(initial: [stremioId: true, wdaId: true], install: .timeout)
        script.timeoutShape = shape
        try await withInstallWorld(script: script, ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await runSlotCommand(.install, w, thrown: shape == .thrown)
            #expect(!out.ok && json(out)["pending"] == true)
            let record = try #require(w.slotRecord(), "\(shape)")
            #expect(record.op?.kind == .reinstall && record.presence == .present, "\(shape): the app is there, the op is not settled")
            #expect(w.runner.deviceApps[stremioId] != nil)
        }
    }

    @Test("plain install: the op is written before the device call (a run killed mid-install leaves it)")
    func installIntentFirst() async throws {
        // The runner checks the ledger at the moment of the install call.
        let probe = Mutex<(kind: LedgerSlotKind?, present: Bool, opAt: Bool)?>(nil)
        try await withInstallWorld(script: DeviceScript(initial: [wdaId: true])) { w in
            w.runner.onInstall = {
                let ledger = try? w.ledger()
                probe.withLock {
                    $0 = (ledger?.slots.first?.op?.kind, ledger?.installs.first { $0.id == w.key }?.present == true, ledger?.installs.first?.opAt != nil)
                }
            }
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(probe.withLock { $0?.kind } == .install && probe.withLock { $0?.present } == true && probe.withLock { $0?.opAt } == true)
            #expect(w.installs.first { $0.id == w.key }?.opAt == nil, "a confirmed install clears the op")
            #expect(w.slotRecord()?.op == nil && w.slotRecord()?.presence == .present)
        }
    }

    @Test("app remove: the op is written before the uninstall, and a confirmed removal clears it")
    func removeIntentFirst() async throws {
        let probe = Mutex<(kind: LedgerSlotKind?, by: LedgerSlotBy?)?>(nil)
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true, wdaId: true]), ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let paths = w.paths
            let runner = DeviceSimRunnerWatch(inner: w.runner) { spec in
                if spec.args.contains("uninstall") {
                    let op = (try? LedgerStore(paths: paths).load())?.slots.first?.op
                    probe.withLock { $0 = (op?.kind, op?.by) }
                }
            }
            var services = w.services
            services.runner = runner
            let out = await AppCommand.run(services, AppOptions(sub: "remove", app: "stremio-ios", device: "iphone", yes: true))
            #expect(out.ok, "\(out.errors)")
            #expect(probe.withLock { $0?.kind } == .uninstall && probe.withLock { $0?.by } == .remove)
            #expect(w.slotRecord()?.op == nil && w.slotRecord()?.presence == .absent)
        }
    }

    @Test("plain install: a definite failure with the app absent puts the ledger back exactly as it was")
    func installDefiniteFailureRestores() async throws {
        let prior = installRecord(.stremioIOS, present: false)
        for start in [[LedgerInstall](), [prior]] {
            try await withInstallWorld(
                script: DeviceScript(initial: [wdaId: true], install: .fail(json: nil, stderr: "boom")), ledger: { $0.installs = start }
            ) { w in
                let out = await w.install()
                #expect(!out.ok)
                #expect(w.installs == start, "the intent was undone")
                #expect(w.slotRecord()?.op == nil && w.slotRecord().map(SlotRule.used) != true)
            }
        }
    }
}
