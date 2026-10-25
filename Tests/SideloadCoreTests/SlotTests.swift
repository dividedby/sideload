import Foundation
import Testing

@testable import SideloadCore

private func text(_ envelope: Envelope) -> String { (try? envelope.printed().text) ?? "" }

private let lentToLab = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1))

@Suite("slot lend and return")
struct SlotTests {
    // MARK: lend

    @Test("lend uninstalls the lendable app, records lent{app,device,to,since} and prints {action:lend, app, freed:1}")
    func lend() async throws {
        try await withInstallWorld(
            script: DeviceScript(initial: [stremioId: true, wdaId: true]), lendable: "stremio-ios",
            ledger: { $0.installs = [installRecord(.stremioIOS)] }
        ) { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.ok, "\(out.errors)")
            let printed = json(out)
            #expect(printed["command"] == "slot" && printed["action"] == "lend")
            #expect(printed["app"] == "stremio-ios" && printed["freed"] == 1)
            #expect(w.runner.deviceCalls == ["device info apps", "device uninstall app", "device info apps"])
            #expect(w.runner.deviceApps.keys.sorted() == [wdaId])
            let ledger = try w.ledger()
            #expect(ledger.lent == [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: testNow)])
            #expect(ledger.installs.first?.present == false)
            try w.expectClean(out)
        }
    }

    @Test("lend is idempotent when the slot is already lent to the lab: ok, freed 0, no device call")
    func lendIdempotent() async throws {
        try await withInstallWorld(lendable: "stremio-ios", ledger: { $0.lent = [lentToLab] }) { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.ok)
            #expect(json(out)["freed"] == 0 && json(out)["alreadyLent"] == true)
            #expect(w.runner.calls.isEmpty, "no device call")
            #expect(w.lent == [lentToLab])
        }
    }

    @Test("lend errors: NO_LENDABLE_APP, LENDABLE_NOT_INSTALLED, ALREADY_LENT, OPERATION_IN_PROGRESS")
    func lendErrors() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true])) { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["NO_LENDABLE_APP"])
            #expect(out.errors.first?.fix?.contains("device lendable") == true)
            #expect(w.runner.calls.isEmpty)
        }
        try await withInstallWorld(lendable: "bogus") { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").errorCodes == ["NO_LENDABLE_APP"])
        }
        try await withInstallWorld(script: DeviceScript(initial: [wdaId: true]), lendable: "stremio-ios") { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["LENDABLE_NOT_INSTALLED"])
            #expect(w.runner.deviceCalls == ["device info apps"])
            #expect(w.lent.isEmpty)
        }
        let other = LedgerLent(app: "apollo", device: "iphone", to: "lab", since: daysFromNow(-1))
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios", ledger: { $0.lent = [other] }) { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").errorCodes == ["ALREADY_LENT"])
            #expect(w.runner.deviceCalls.isEmpty)
            #expect(w.runner.deviceApps.keys.contains(stremioId))
        }
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios") { w in
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            #expect(await w.slot("lend", device: "iphone", to: "lab").errorCodes == ["OPERATION_IN_PROGRESS"])
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("lend settles the in-flight marker first and a failed uninstall keeps the slot unlent")
    func lendMarkerAndFailure() async throws {
        let marker = LedgerFreeInFlight(beforeFp8: ["00000000"], startedAt: testNow, app: "stremio-ios", device: "iphone")
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios", ledger: { $0.freeProvisionInFlight = marker }) { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").errorCodes == ["FREE_CERT_CHANGED"])
            #expect(w.runner.calls.isEmpty)
        }
        let locked = try loadFixtureJSON("install-locked.json")
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true], uninstallFailure: locked), lendable: "stremio-ios") { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").errorCodes == ["DEVICE_LOCKED"])
            #expect(w.lent.isEmpty)
        }
    }

    @Test("--udid is accepted only when it matches a saved device (UDID or CoreDevice ID), and is never echoed")
    func udid() async throws {
        let script = DeviceScript(initial: [stremioId: true])
        try await withInstallWorld(script: script, lendable: "stremio-ios") { w in
            let stranger = savedUdid("9")
            let refused = await w.slot("lend", udid: stranger, to: "lab")
            #expect(refused.errorCodes == ["DEVICE_NOT_SAVED"])
            #expect(!text(refused).contains(stranger))
            #expect(w.runner.calls.isEmpty)
            #expect(await w.slot("lend", udid: savedUdid("1").lowercased(), to: "lab").ok, "matches ignoring case")
            let text = try await w.slot("lend", udid: savedUdid("1"), to: "lab").printed().text
            #expect(!text.contains(savedUdid("1")) && !text.contains(savedCoreId("1")))
        }
        try await withInstallWorld(script: script, lendable: "stremio-ios") { w in
            #expect(await w.slot("lend", udid: savedCoreId("1"), to: "lab").ok)
        }
    }

    @Test("usage: exactly one of --device and --udid; lend needs --to lab; return takes no --to; unknown subcommand and device")
    func usage() async throws {
        try await withInstallWorld(lendable: "stremio-ios") { w in
            #expect(await w.slot("lend", to: "lab").errorCodes == ["USAGE"])
            #expect(await w.slot("lend", device: "iphone", udid: savedUdid("1"), to: "lab").errorCodes == ["USAGE"])
            #expect(await w.slot("lend", device: "iphone").errorCodes == ["USAGE"])
            #expect(await w.slot("lend", device: "iphone", to: "someone").errorCodes == ["USAGE"])
            #expect(await w.slot("return", device: "iphone", to: "lab").errorCodes == ["USAGE"])
            #expect(await w.slot("return").errorCodes == ["USAGE"])
            #expect(await w.slot("borrow", device: "iphone").errorCodes == ["USAGE"])
            #expect(await w.slot("lend", device: "nope", to: "lab").errorCodes == ["DEVICE_NOT_SAVED"])
            #expect(w.runner.calls.isEmpty)
        }
    }

    // MARK: return

    @Test("return reinstalls the lent app from the freeSigned build through the install path and clears lent")
    func giveBack() async throws {
        try await withInstallWorld(lendable: "stremio-ios", ledger: { ledger in
            ledger.lent = [lentToLab]
            ledger.installs = [installRecord(.stremioIOS, present: false)]
        }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.ok, "\(out.errors)")
            let printed = json(out)
            #expect(printed["command"] == "slot" && printed["action"] == "return")
            #expect(printed["app"] == "stremio-ios" && printed["reinstalled"] == true)
            #expect(w.runner.deviceCalls == ["device info apps", "device install app", "device info apps"])
            #expect(w.runner.deviceApps.keys.contains(w.bundleId))
            let ledger = try w.ledger()
            #expect(ledger.lent.isEmpty)
            #expect(ledger.installs.first?.present == true)
            try w.expectClean(out)
        }
    }

    @Test("a return whose install fails but whose app is listed afterwards records the build and keeps the refresh suspension")
    func returnFailedListedKeepsSuspension() async throws {
        var refresh = LedgerInstallRefresh(consecutiveFailures: 2, suspended: true)
        refresh.lastCode = "PROFILE_NOT_RENEWED"
        try await withInstallWorld(
            script: DeviceScript(install: .fail(json: nil, stderr: "The device is locked."), landsDespiteFailure: true),
            lendable: "stremio-ios",
            ledger: { ledger in
                ledger.lent = [lentToLab]
                ledger.installs = [installRecord(.stremioIOS, present: false, refresh: refresh)]
            }
        ) { w in
            _ = await w.slot("return", device: "iphone")
            let entry = try #require(try w.ledger().installs.first)
            #expect(entry.present)
            #expect(entry.refresh.suspended && entry.refresh.consecutiveFailures == 2, "only a definite success clears it")
        }
    }

    @Test("return with nothing lent is an ok no-op")
    func nothingLent() async throws {
        try await withInstallWorld(lendable: "stremio-ios") { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.ok)
            #expect(json(out)["reinstalled"] == false && json(out)["nothingLent"] == true)
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("return with an expired profile fails RETURN_FAILED, tells the owner to provision and sign, and keeps lent")
    func returnExpired() async throws {
        try await withInstallWorld(lendable: "stremio-ios", profileDays: -1, ledger: { $0.lent = [lentToLab] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"])
            #expect(out.errors.first?.fix?.contains("provision") == true && out.errors.first?.fix?.contains("sign") == true)
            #expect(json(out)["cause"] == "PROFILE_EXPIRED" && json(out)["lent"] == true)
            #expect(w.lent == [lentToLab])
            #expect(w.runner.deviceCalls == ["device info apps"], "the snapshot settles the record; nothing was reinstalled")
        }
        // The app's own embedded profile expired even though the ledger still says valid.
        try await withInstallWorld(lendable: "stremio-ios", profileDays: 5, embeddedDays: -1, ledger: { $0.lent = [lentToLab] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"] && json(out)["cause"] == "PROFILE_EXPIRED")
            #expect(w.lent == [lentToLab])
        }
    }

    @Test("return keeps lent when the slot was taken meanwhile (FREE_APP_LIMIT) or nothing was signed")
    func returnOtherFailures() async throws {
        let taken = DeviceScript(initial: [apolloId: true, wdaId: true, sideStoreId: true])
        try await withInstallWorld(script: taken, lendable: "stremio-ios", ledger: { $0.lent = [lentToLab] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"] && json(out)["cause"] == "FREE_APP_LIMIT")
            #expect(w.lent == [lentToLab])
            #expect(w.runner.installCalls.isEmpty)
        }
        try await withInstallWorld(lendable: "stremio-ios", signed: false, ledger: { $0.lent = [lentToLab] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"] && json(out)["cause"] == "NOT_SIGNED")
            #expect(w.lent == [lentToLab])
        }
        try await withInstallWorld(lendable: "stremio-ios", ledger: { $0.lent = [lentToLab] }) { w in
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            #expect(await w.slot("return", device: "iphone").errorCodes == ["OPERATION_IN_PROGRESS"])
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("return by --udid, and lend then return round-trips")
    func roundTrip() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios") { w in
            #expect(await w.slot("lend", udid: savedUdid("1"), to: "lab").ok)
            #expect(!w.runner.deviceApps.keys.contains(stremioId))
            #expect(await w.slot("lend", device: "iphone", to: "lab").ok, "a second lend is the idempotent one")
            #expect(await w.slot("return", udid: savedUdid("1")).ok)
            #expect(w.runner.deviceApps.keys.contains(stremioId))
            #expect(w.lent.isEmpty)
            #expect(await w.slot("return", device: "iphone").ok, "returning twice is a no-op")
        }
    }

    @Test("a plain install of a lent app is refused, so it cannot take the lab's slot back")
    func installRefusedWhileLent() async throws {
        try await withInstallWorld(lendable: "stremio-ios", ledger: { $0.lent = [lentToLab] }) { w in
            #expect(await w.install().errorCodes == ["APP_LENT"])
        }
    }

    // MARK: durable intent

    @Test("an uninstall that times out with the app gone records lent, reports freed:1 and the uncertainty")
    func timeoutAppGone() async throws {
        let script = DeviceScript(initial: [stremioId: true], uninstallTimeoutRemoves: true)
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["freed"] == 1)
            #expect(json(out)["warnings"]?.array?.first?["code"] == "UNINSTALL_RESULT_UNCERTAIN")
            #expect(w.lent == [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: testNow, state: "lent")])
            #expect(w.installs.first?.present == false)
        }
    }

    @Test("a timeout with the app still on the device proves nothing (it may yet finish): lending stays and the error is TIMEOUT, uncertain")
    func timeoutAppStillThere() async throws {
        let script = DeviceScript(initial: [stremioId: true], uninstallTimeoutRemoves: false)
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["TIMEOUT"])
            #expect(json(out)["uncertain"] == true && json(out)["state"] == "lending" && json(out)["freed"] == 0)
            #expect(w.lent.map(\.state) == ["lending"])
            #expect(w.installs.first?.present == true)
        }
    }

    @Test("the intent is written before the uninstall runs")
    func intentFirst() async throws {
        let script = DeviceScript(initial: [stremioId: true], uninstallTimeoutRemoves: false)
        try await withInstallWorld(script: script, lendable: "stremio-ios") { w in
            let paths = w.paths
            // A hold on the ledger lock cannot be used with a fake runner, so look at the ledger from inside the uninstall.
            let seen = Box<[LedgerLent]>([])
            let runner = DeviceSimRunnerWatch(inner: w.runner) { spec in
                if spec.args.contains("uninstall") { seen.value = (try? LedgerStore(paths: paths).load().lent) ?? [] }
            }
            var services = w.services
            services.runner = runner
            _ = await SlotCommand.run(services, SlotOptions(sub: "lend", device: "iphone", to: "lab"))
            #expect(seen.value.map(\.state) == ["lending"])
        }
    }

    @Test("a snapshot that also fails keeps the lending record and errors; return then reinstalls the app")
    func snapshotFailureKeepsLending() async throws {
        let script = DeviceScript(initial: [stremioId: true], snapshotFailures: [2], uninstallTimeoutRemoves: true)
        try await withInstallWorld(script: script, lendable: "stremio-ios") { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["TIMEOUT"])
            #expect(json(out)["uncertain"] == true && json(out)["state"] == "lending")
            #expect(w.lent.map(\.state) == ["lending"])
            #expect(!w.runner.deviceApps.keys.contains(stremioId), "the app is gone, and recorded")

            let status = StatusCommand.run(w.services)
            #expect(json(status)["lent"]?.array?.first?["state"] == "lending")

            w.clock.advance(TimeInterval(SlotRule.window(.install)) + 1)  // a timed-out operation is left alone for the window
            let back = await w.slot("return", device: "iphone")
            #expect(back.ok, "\(back.errors)")
            #expect(w.lent.isEmpty)
            #expect(w.runner.deviceApps.keys.contains(stremioId))
        }
    }

    @Test("an uninstall that reports success with no snapshot afterwards claims no slot: lending stays, UNINSTALL_RESULT_UNCERTAIN")
    func successUnconfirmed() async throws {
        let script = DeviceScript(initial: [stremioId: true], snapshotFailures: [2])
        try await withInstallWorld(script: script, lendable: "stremio-ios") { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["UNINSTALL_RESULT_UNCERTAIN"])
            #expect(json(out)["freed"] == 0 && json(out)["state"] == "lending")
            #expect(w.lent.map(\.state) == ["lending"], "no slot is claimed, the intent stays")
            // The next lend, after the window, settles it from a fresh snapshot.
            w.clock.advance(TimeInterval(SlotRule.window(.install)) + 1)
            let again = await w.slot("lend", device: "iphone", to: "lab")
            #expect(again.ok, "\(again.errors)")
            #expect(json(again)["freed"] == 1)
            #expect(w.lent.map(\.state) == ["lent"])
        }
    }

    @Test("lend warns when no other free-team app sideload knows of remains")
    func lendLastFreeApp() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios") { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.ok, "\(out.errors)")
            let codes = json(out)["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
            #expect(codes.contains("LAST_FREE_APP_REMOVED"))
        }
    }

    @Test("lending again settles an earlier lending record: the app is gone, so it becomes lent")
    func resumeLending() async throws {
        let script = DeviceScript(initial: [stremioId: true], snapshotFailures: [2], uninstallTimeoutRemoves: true)
        try await withInstallWorld(script: script, lendable: "stremio-ios") { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").errorCodes == ["TIMEOUT"])
            w.clock.advance(TimeInterval(SlotRule.window(.install)) + 1)
            let again = await w.slot("lend", device: "iphone", to: "lab")
            #expect(again.ok, "\(again.errors)")
            #expect(json(again)["freed"] == 1)
            #expect(json(again)["warnings"]?.array?.first?["code"] == "UNINSTALL_RESULT_UNCERTAIN")
            #expect(w.lent.map(\.state) == ["lent"])
        }
    }

    // MARK: order and redaction

    @Test("already lent to the lab is idempotent even when no lendable app is configured any more")
    func idempotentBeforeLendable() async throws {
        try await withInstallWorld(ledger: { $0.lent = [lentToLab] }) { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["freed"] == 0)
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("a UDID passed to --device is never printed in full")
    func udidAsDevice() async throws {
        try await withInstallWorld(lendable: "stremio-ios") { w in
            let mistaken = savedUdid("1")
            for out in [
                await w.slot("lend", device: mistaken, to: "lab"), await w.slot("return", device: mistaken),
                await w.install(device: mistaken), await w.remove(device: mistaken),
            ] {
                #expect(out.errorCodes == ["DEVICE_NOT_SAVED"])
                #expect(!text(out).contains(mistaken) && text(out).contains(Redactor.tail4(mistaken)))
            }
            #expect(w.runner.calls.isEmpty)
        }
    }

    // MARK: uninstall success that the snapshot contradicts, and return confirmation

    @Test("an uninstall that reports success while the app is still listed is UNEXPECTED_APP_DELTA: kept pending, nothing claimed")
    func lendStillListed() async throws {
        let script = DeviceScript(initial: [stremioId: true], uninstallLeavesApp: true)
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["UNEXPECTED_APP_DELTA"] && json(out)["freed"] == 0 && json(out)["uncertain"] == true)
            #expect(w.lent.map(\.state) == ["lending"], "the op stays: the slot is not free and not the lab's")
            #expect(w.installs.first?.present == true)
        }
    }

    @Test("return clears lent only when the snapshot confirms the app; otherwise the slot stays the lab's (lent, or returning while the install may still land) and it is RETURN_FAILED")
    func returnNotConfirmed() async throws {
        // A pending record whose window is over is settled by the first snapshot: absent, so lent again, then the return runs.
        let lending = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: "lending", opAt: daysFromNow(-1))
        for record in [lentToLab, lending] {
            try await withInstallWorld(script: DeviceScript(installLeavesApp: true), lendable: "stremio-ios", ledger: { $0.lent = [record] }) { w in
                let out = await w.slot("return", device: "iphone")
                #expect(out.errorCodes == ["RETURN_FAILED"])
                #expect(json(out)["lent"] == true)
                // devicectl said success but the app is not listed: the install may still land, so it stays pending.
                #expect(w.lent.map(\.state) == ["returning"] && json(out)["uncertain"] == true)
            }
        }
        // A lending record with no opAt is the fail-safe: nothing runs until its window is over.
        let stateless = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1), state: "lending")
        try await withInstallWorld(lendable: "stremio-ios", ledger: { $0.lent = [stateless] }) { w in
            #expect(await w.slot("return", device: "iphone").errorCodes == ["SLOT_PENDING"])
            #expect(w.runner.deviceCalls.isEmpty)
        }
        // The snapshot after the install fails: the install may have landed, so the record is `returning`, never free.
        try await withInstallWorld(script: DeviceScript(snapshotFailures: [2]), lendable: "stremio-ios", ledger: { $0.lent = [lentToLab] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"] && json(out)["uncertain"] == true)
            #expect(w.lent.map(\.state) == ["returning"])
        }
    }

    // MARK: lend needs a build it can return

    @Test("lend refuses before uninstalling when nothing valid is signed (NOT_SIGNED) or the profile expired (PROFILE_EXPIRED)")
    func lendNeedsSignedBuild() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios", signed: false) { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").errorCodes == ["NOT_SIGNED"])
            #expect(w.runner.deviceCalls == ["device info apps"] && w.lent.isEmpty, "a snapshot, never an uninstall")
            #expect(w.runner.deviceApps.keys.contains(stremioId))
        }
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios", profileDays: -1) { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["PROFILE_EXPIRED"])
            #expect(w.runner.deviceCalls == ["device info apps"] && w.lent.isEmpty)
        }
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios", ledger: { $0.freeSigned[0].path = "builds/signed/stremio-ios/iphone/Missing.app" }) { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").errorCodes == ["NOT_SIGNED"])
            #expect(w.runner.deviceCalls == ["device info apps"])
        }
    }

    // MARK: a lent slot is the lab's

    @Test("while a slot is lent, a NEW app counts it as used (FREE_APP_LIMIT); a return does not count itself")
    func lentSlotCounts() async throws {
        let other = LedgerLent(app: "apollo", device: "iphone", to: "lab", since: daysFromNow(-1))
        // Two free-team apps that are not the lab's, so the lent slot is a third.
        let busy = DeviceScript(initial: [atvloadlyId: true, sideStoreId: true])
        try await withInstallWorld(script: busy, ledger: { $0.lent = [other] }) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            #expect(json(out)["slots"]?["lent"] == 1 && json(out)["slots"]?["used"] == 3)
            #expect(w.runner.installCalls.isEmpty)
        }
        // Without the lend the same device has a free slot.
        try await withInstallWorld(script: busy) { w in
            #expect(await w.install().ok)
        }
        // The app being returned is that slot coming back.
        try await withInstallWorld(script: busy, lendable: "stremio-ios", ledger: { $0.lent = [lentToLab] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.ok, "\(out.errors)")
        }
    }

    @Test("DEVICE_NOT_PAIRED has a generic fix that the canary shares")
    func pairFix() {
        let failure = FreeInstallClassifier.failure(
            .install, exitCode: 1, json: nil, stderr: "device is not paired", timedOut: false, overflow: false, bundleId: stremioId)
        #expect(failure?.code == "DEVICE_NOT_PAIRED" && failure?.fix.contains("Devices and Simulators") == true)
        #expect(CanaryCommand.fix(for: "DEVICE_NOT_PAIRED") == failure?.fix)
    }
}
