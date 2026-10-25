import Foundation
import Testing

@testable import SideloadCore

// A device can finish a timed-out install, reinstall or uninstall after the run ended. The op stays on the record for its
// window: every mutating command answers SLOT_PENDING (nothing claimed, no device call), status shows the slot used, and the
// first snapshot at or after the end of the window settles it. The simulated device finishes the operation later by the
// test's clock. The two bugs that motivated the unified model have their regression tests here.

private let infoApps = "device info apps"

private func window(_ kind: LedgerSlotKind) -> Double { Double(SlotRule.window(kind)) }

@Suite("slot model: late completion and the window")
struct SlotGraceTests {
    @Test("a late install after a timed-out return is not settled inside the window, and is after it")
    func lateInstallAfterReturn() async throws {
        let lent = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: "lent")
        let script = DeviceScript(install: .timeout, installLandsAfter: 100)
        try await withInstallWorld(
            script: script, lendable: "stremio-ios",
            ledger: { $0.lent = [lent]; $0.installs = [installRecord(.stremioIOS, present: false)] }
        ) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"] && json(out)["state"] == "returning")
            let record = try #require(w.lent.first)
            #expect(record.state == "returning" && record.opAt == testNow)
            #expect(w.slotRecord()?.op?.window == 645 && SlotRule.window(.install) == 300 + 300 + 15 + 30)

            // The install lands at +100 s. Inside the window a snapshot would show the app, yet nothing settles.
            let end = window(.install)
            for elapsed in [1.0, 99, 150, 299, 301, 644] {
                w.clock.advance(elapsed - (w.clock.now().timeIntervalSince(testNow)))
                let calls = w.runner.deviceCalls.count
                for command in ["return", "lend"] {
                    let early = await w.slot(command, device: "iphone", to: command == "lend" ? "lab" : nil)
                    #expect(early.errorCodes == ["SLOT_PENDING"], "\(command) at +\(elapsed)")
                    #expect(json(early)["freed"] == 0 && json(early)["state"] == "returning" && json(early)["op"] == "install")
                    #expect(json(early)["retryAfter"] == .number(end - elapsed))
                }
                let removed = await w.remove()
                #expect(removed.errorCodes == ["SLOT_PENDING"])
                #expect(w.runner.deviceCalls.count == calls, "no device call inside the window")
                #expect(w.lent.map(\.state) == ["returning"])
                // Status shows it pending, never free.
                let status = json(StatusCommand.run(w.services))
                let iphone = try #require(status["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" })
                #expect(iphone["pending"] == true && iphone["used"] == 1 && iphone["retryAfter"] == .number(end - elapsed))
                #expect(status["lent"]?.array?.first?["holds"] == false)
            }

            w.clock.advance(end + 1 - w.clock.now().timeIntervalSince(testNow))
            let settled = await w.slot("return", device: "iphone")
            #expect(settled.ok, "\(settled.errors)")
            #expect(json(settled)["reinstalled"] == true && json(settled)["settled"] == true)
            #expect(w.lent.isEmpty && w.installs.first?.present == true)
            try expectSlotModel(w)
        }
    }

    @Test("a late uninstall after a timed-out lend is not settled inside the window, and is after it")
    func lateUninstallAfterLend() async throws {
        let script = DeviceScript(initial: [stremioId: true, wdaId: true], uninstallLandsAfter: 100, uninstallTimeoutRemoves: false)
        try await withInstallWorld(script: script, lendable: "stremio-ios") { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["TIMEOUT"] && json(out)["state"] == "lending" && json(out)["freed"] == 0)
            #expect(w.lent.first?.opAt == testNow)

            // At +150 s the app is gone, but a snapshot inside the window settles nothing and nothing is freed.
            w.clock.advance(150)
            #expect(w.runner.deviceApps[stremioId] == nil)
            let calls = w.runner.deviceCalls.count
            let early = await w.slot("lend", device: "iphone", to: "lab")
            #expect(early.errorCodes == ["SLOT_PENDING"] && json(early)["freed"] == 0)
            #expect(json(early)["retryAfter"] == .number(window(.uninstall) - 150))
            #expect((await w.slot("return", device: "iphone")).errorCodes == ["SLOT_PENDING"])
            #expect(w.runner.deviceCalls.count == calls && w.lent.map(\.state) == ["lending"])

            w.clock.advance(window(.uninstall) - 150 + 1)
            let settled = await w.slot("lend", device: "iphone", to: "lab")
            #expect(settled.ok && json(settled)["freed"] == 1, "\(settled.errors)")
            #expect(w.lent.map(\.state) == ["lent"] && w.lent.first?.opAt == nil)
            try expectSlotModel(w)
        }
    }

    @Test("an unreadable result keeps the op too; a definite result leaves no pending record")
    func stampsOnlyUnknown() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true], snapshotFailures: [2]), lendable: "stremio-ios") { w in
            _ = await w.slot("lend", device: "iphone", to: "lab")
            #expect(w.lent.map(\.state) == ["lending"] && w.lent.first?.opAt == testNow)
        }
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios") { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").ok)
            #expect(w.lent.map(\.state) == ["lent"] && w.lent.first?.opAt == nil)
        }
    }

    @Test("a timed-out install of a NEW app reads present: the ledger and status never show an extra free slot")
    func timedOutInstallReadsPresent() async throws {
        for script in [
            DeviceScript(install: .timeout), DeviceScript(snapshotFailures: [2], install: .fail(json: ["info": ["outcome": "failed"]])),
        ] {
            try await withInstallWorld(script: script, ledger: { $0.installs = [] }) { w in
                #expect((await w.install()).ok == false)
                let record = try #require(w.installs.first)
                #expect(record.id == w.key && record.present && record.opAt == testNow)
                let status = json(StatusCommand.run(w.services))
                let iphone = try #require(status["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" })
                #expect(iphone["used"] == 1 && iphone["free"] == 2 && iphone["apps"] == ["stremio-ios"])
            }
        }
        // A failure with a readable snapshot that lacks the app records nothing.
        try await withInstallWorld(script: DeviceScript(install: .fail(json: ["info": ["outcome": "failed"]])), ledger: { $0.installs = [] }) { w in
            #expect((await w.install()).ok == false)
            #expect(w.installs.isEmpty)
        }
    }

    @Test("the probe: a timed-out plain install, then app remove or an absent snapshot, then the late landing: no extra free slot")
    func installProbe() async throws {
        try await withInstallWorld(
            script: DeviceScript(install: .timeout, installLandsAfter: 100), lendable: "stremio-ios", ledger: { $0.installs = [] }
        ) { w in
            #expect((await w.install()).errorCodes == ["TIMEOUT"])
            #expect(w.installs.map(\.present) == [true] && w.installs.first?.opAt == testNow)
            let calls = w.runner.deviceCalls.count

            // Inside the window app remove is SLOT_PENDING with no device call, even after the app has landed.
            for elapsed in [1.0, 150, 299, window(.install) - 1] {
                w.clock.advance(elapsed - w.clock.now().timeIntervalSince(testNow))
                let out = await w.remove()
                #expect(out.errorCodes == ["SLOT_PENDING"] && json(out)["removed"] == false && json(out)["retryAfter"] != nil)
                #expect(w.runner.deviceCalls.count == calls)
                #expect(w.installs.map(\.present) == [true])
            }
            w.clock.advance(window(.install) + 2 - w.clock.now().timeIntervalSince(testNow))
            let removed = await w.remove()
            #expect(removed.ok && json(removed)["removed"] == true, "\(removed.errors)")
            #expect(w.installs.map(\.present) == [false] && w.installs.first?.opAt == nil)
            try expectSlotModel(w, eventually: true)
        }
        // An absent snapshot inside the window cannot clear the install (the app has not landed yet).
        try await withInstallWorld(
            script: DeviceScript(install: .timeout, installLandsAfter: 100), lendable: "stremio-ios", ledger: { $0.installs = [] }
        ) { w in
            _ = await w.install()
            w.clock.advance(10)
            let lend = await w.slot("lend", device: "iphone", to: "lab")  // the gate: no snapshot is even taken
            #expect(lend.errorCodes == ["SLOT_PENDING"])
            #expect(w.installs.map(\.present) == [true], "an absent snapshot cannot clear present inside the window")
            let status = json(StatusCommand.run(w.services))
            let iphone = try #require(status["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" })
            #expect(iphone["used"] == 1)
            w.clock.advance(200)  // landed at +100
            #expect(w.runner.deviceApps[stremioId] != nil)
            try expectSlotModel(w, eventually: true)
        }
    }

    @Test("a return killed mid-install: the window outlasts the install, so no false lent, and the late landing settles cleanly")
    func killedReturn() async throws {
        let lent = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: "lent")
        try await withInstallWorld(lendable: "stremio-ios", ledger: { $0.lent = [lent]; $0.installs = [installRecord(.stremioIOS, present: false)] }) { w in
            // The process dies right after the returning intent; the install it started finishes 320 s later.
            _ = await runSlotCommand(.giveBack, w, crashAt: "return.intent")
            let opAt = try #require(w.lent.first?.opAt)
            #expect(w.lent.first?.state == "returning")
            w.runner.scheduleLanding(stremioId, install: true, after: 320)

            // opAt + 301 s: a 300 s grace would have read the app as absent and recorded a false `lent`.
            w.clock.advance(opAt.timeIntervalSince(w.clock.now()) + 301)
            for command in ["lend", "return"] {
                let out = await w.slot(command, device: "iphone", to: command == "lend" ? "lab" : nil)
                #expect(out.errorCodes == ["SLOT_PENDING"], "\(command)")
            }
            #expect(w.lent.first?.state == "returning")
            w.clock.advance(100)  // +401: the install has landed, still inside the window
            #expect(w.runner.deviceApps[stremioId] != nil)
            #expect((await w.slot("lend", device: "iphone", to: "lab")).errorCodes == ["SLOT_PENDING"])
            try expectSlotModel(w)

            w.clock.advance(window(.install))
            let out = await w.slot("return", device: "iphone")
            #expect(out.ok && json(out)["settled"] == true, "\(out.errors)")
            #expect(w.lent.isEmpty)
            try expectSlotModel(w, eventually: true)
        }
    }

    @Test("startedAt is read from the clock when the op is written, and rounded up, for every command that writes one", arguments: SlotCommandKind.allCases)
    func startedAtIsFresh(kind: SlotCommandKind) async throws {
        try await withInstallWorld(
            script: DeviceScript(initial: [stremioId: true, wdaId: true]), lendable: "stremio-ios",
            ledger: { ledger in
                switch kind {
                case .giveBack:
                    ledger.lent = [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: "lent")]
                    ledger.installs = [installRecord(.stremioIOS, present: false)]
                case .install: ledger.installs = []
                case .lend, .remove: ledger.installs = [installRecord(.stremioIOS)]
                }
            }
        ) { w in
            if kind == .giveBack { w.runner.setApp(stremioId, nil) }
            if kind == .install { w.runner.setApp(stremioId, nil) }
            let clock = w.clock
            // The clock moves 200.4 s while the first snapshot runs: the op is stamped with the later time, rounded up.
            let watch = DeviceSimRunnerWatch(inner: w.runner) { spec in
                if spec.args.contains("apps") && clock.now() == testNow { clock.advance(200.4) }
            }
            var services = w.services
            services.runner = watch
            let point: String
            switch kind {
            case .lend: point = "lend.intent"
            case .giveBack: point = "return.intent"
            case .remove: point = "remove.intent"
            case .install: point = "install.intent"
            }
            services.afterDurableWrite = { if $0 == point { throw SimulatedCrash() } }
            switch kind {
            case .lend: _ = await SlotCommand.run(services, SlotOptions(sub: "lend", device: "iphone", to: "lab"))
            case .giveBack: _ = await SlotCommand.run(services, SlotOptions(sub: "return", device: "iphone"))
            case .remove: _ = await AppCommand.run(services, AppOptions(sub: "remove", app: "stremio-ios", device: "iphone", yes: true))
            case .install: _ = await InstallCommand.run(services, InstallOptions(app: "stremio-ios", device: "iphone", yes: true))
            }
            #expect(w.slotRecord()?.op?.startedAt == testNow.addingTimeInterval(201), "\(kind)")
        }
    }

    @Test("the window ends exactly at the boundary, retryAfter never exceeds it, and a clock moved backwards cannot extend it")
    func boundary() async throws {
        let opAt = testNow
        let end = window(.uninstall)
        let record = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: opAt, state: "lending", opAt: opAt)
        // End to end at the boundary.
        try await withInstallWorld(script: DeviceScript(initial: [wdaId: true]), lendable: "stremio-ios", ledger: { $0.lent = [record] }) { w in
            w.clock.advance(end - 1)
            let before = await w.slot("lend", device: "iphone", to: "lab")
            #expect(before.errorCodes == ["SLOT_PENDING"] && json(before)["retryAfter"] == 1)
            w.clock.advance(1)
            let at = await w.slot("lend", device: "iphone", to: "lab")
            #expect(at.ok, "settles at the boundary")
        }
        try await withInstallWorld(lendable: "stremio-ios", ledger: { $0.lent = [record] }) { w in
            w.clock.advance(-1000)
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["SLOT_PENDING"] && json(out)["retryAfter"] == .number(end))
        }
    }

    // MARK: the two bugs the unified model fixes

    @Test("regression (a): a reinstall that ends unknown, then a lend, then the late landing -- the lend is refused and the ledger never lies")
    func reinstallUnknownThenLendThenLanding() async throws {
        for shape in TimeoutShape.allCases {
            var script = DeviceScript(initial: [stremioId: true, wdaId: true], install: .timeout, installLandsAfter: 400)
            script.timeoutShape = shape
            try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
                let reinstall = await runSlotCommand(.install, w, thrown: shape == .thrown)
                #expect(!reinstall.ok && w.slotRecord()?.op?.kind == .reinstall, "\(shape)")
                #expect(w.runner.deviceApps[stremioId] != nil, "the app was there all along")

                w.clock.advance(60)
                let calls = w.runner.deviceCalls.count
                let lend = await w.slot("lend", device: "iphone", to: "lab")
                #expect(lend.errorCodes == ["SLOT_PENDING"] && json(lend)["op"] == "reinstall" && json(lend)["freed"] == 0, "\(shape)")
                #expect(!w.runner.deviceCalls.suffix(from: calls).contains("device uninstall app"), "\(shape): no uninstall ran")
                try expectSlotModel(w, label: "\(shape) +60", eventually: true)

                w.clock.advance(700 - 60)  // the late landing at +400 has happened; the window (645) is over
                #expect(w.runner.deviceApps[stremioId] != nil)
                let again = await w.slot("lend", device: "iphone", to: "lab")
                #expect(again.ok && json(again)["freed"] == 1, "\(shape): after the window the lend runs normally: \(again.errors)")
                try expectSlotModel(w, label: "\(shape) +700", eventually: true)
                #expect(w.runner.deviceApps[stremioId] == nil && w.phase == .lent)
            }
        }
    }

    @Test("regression (b): a lend or an app remove while an install window is open -- refused, whatever app the install was for", arguments: TimeoutShape.allCases)
    func lendWhileInstallWindowOpen(shape: TimeoutShape) async throws {
        var script = DeviceScript(initial: [stremioId: true, wdaId: true], install: .timeout, installLandsAfter: 100)
        script.timeoutShape = shape
        try await withInstallWorld(
            app: .stremioIOS, alsoSigned: [.apollo], script: script, lendable: "stremio-ios",
            ledger: { $0.installs = [installRecord(.stremioIOS)] }
        ) { w in
            let install = await runSlotCommand(.install, w, app: "apollo", thrown: shape == .thrown)
            #expect(!install.ok && w.slotRecord("apollo")?.op?.kind == .install, "\(shape)")
            w.clock.advance(30)
            let calls = w.runner.deviceCalls.count
            let lend = await w.slot("lend", device: "iphone", to: "lab")
            let remove = await w.remove()
            #expect(lend.errorCodes == ["SLOT_PENDING"] && json(lend)["app"] == "apollo", "\(shape)")
            #expect(remove.errorCodes == ["SLOT_PENDING"], "\(shape)")
            #expect(w.runner.deviceCalls.count == calls)
            try expectSlotModel(w, label: "\(shape)", eventually: true)
            w.clock.advance(window(.install))
            let later = await w.slot("lend", device: "iphone", to: "lab")
            #expect(later.ok, "\(shape): \(later.errors)")
            try expectSlotModel(w, label: "\(shape) after", eventually: true)
            try expectStatusNeverOptimistic(w, label: "\(shape)")
        }
    }
}
