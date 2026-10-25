import Foundation
import Testing

@testable import SideloadCore

private func text(_ envelope: Envelope) -> String { (try? envelope.printed().text) ?? "" }

@Suite("app remove")
struct AppRemoveTests {
    @Test("removes one managed install: snapshot, uninstall of our ID only, snapshot; the ledger says present:false")
    func removes() async throws {
        let script = DeviceScript(initial: [stremioId: true, apolloId: true])
        try await withInstallWorld(script: script, ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.remove()
            #expect(out.ok, "\(out.errors)")
            #expect(out.command == "app remove")
            #expect(json(out)["removed"] == true)
            #expect(json(out)["warnings"] == [])
            #expect(w.runner.deviceCalls == ["device info apps", "device uninstall app", "device info apps"])
            #expect(w.runner.deviceApps.keys.sorted() == [apolloId])
            let uninstall = try #require(w.runner.calls.first { $0.args.contains("uninstall") })
            #expect(uninstall.args.last == w.bundleId)
            #expect(w.installs.first?.present == false)
            #expect(w.installs.count == 1)
            try w.expectClean(out)
        }
    }

    @Test("an out-of-range stored reserve leaves the printed slots unknown after a remove, never a guessed free count")
    func removeInvalidReserveSlotsUnknown() async throws {
        let script = DeviceScript(initial: [stremioId: true, apolloId: true])
        try await withInstallWorld(script: script, ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            try await w.store.update { config in
                let d = config.devices["iphone"]
                config.devices["iphone"] = SavedDevice(
                    udid: d?.udid, coreDeviceId: d?.coreDeviceId, platform: d?.platform, freeSlotsReserved: -1)
            }
            let out = await w.remove()
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["slots"]?["unknown"] == true && json(out)["slots"]?["free"] == .null)
        }
    }

    @Test("removing the last free-team app warns that the developer trust goes with it, and still proceeds")
    func lastFreeApp() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true])) { w in
            let out = await w.remove()
            #expect(out.ok)
            let warnings = json(out)["warnings"]?.array ?? []
            #expect(warnings.first?["code"] == "LAST_FREE_APP_REMOVED")
            #expect(w.runner.deviceApps.isEmpty)
        }
    }

    @Test("no warning while another app that keeps the trust remains: ours, WebDriverAgent or SideStore")
    func notTheLast() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true, apolloId: true])) { w in
            #expect(json(await w.remove())["warnings"] == [])
        }
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true, wdaId: true])) { w in
            #expect(json(await w.remove())["warnings"] == [])
            #expect(w.runner.deviceApps.keys.contains(wdaId), "WebDriverAgent is never touched")
        }
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true, sideStoreId: true])) { w in
            #expect(json(await w.remove())["warnings"] == [])
        }
    }

    @Test("the reserve and unlabelled developer-signed apps do not count as keeping the trust: it warns")
    func warnsOnUncertainTrust() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), reserved: 1) { w in
            #expect(json(await w.remove())["warnings"]?.array?.first?["code"] == "LAST_FREE_APP_REMOVED")
        }
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true, "com.example.devbuild": true])) { w in
            #expect(json(await w.remove())["warnings"]?.array?.first?["code"] == "LAST_FREE_APP_REMOVED")
        }
    }

    @Test("a timeout with the app gone is recorded as removed with UNINSTALL_RESULT_UNCERTAIN")
    func timeoutGone() async throws {
        let script = DeviceScript(initial: [stremioId: true, apolloId: true], uninstallTimeoutRemoves: true)
        try await withInstallWorld(script: script, ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.remove()
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["warnings"]?.array?.first?["code"] == "UNINSTALL_RESULT_UNCERTAIN")
            #expect(w.installs.first?.present == false)
        }
    }

    @Test("a timeout with the app still there is the error, and the ledger says present")
    func timeoutKept() async throws {
        let script = DeviceScript(initial: [stremioId: true], uninstallTimeoutRemoves: false)
        try await withInstallWorld(script: script, ledger: { $0.installs = [installRecord(.stremioIOS, present: false)] }) { w in
            #expect(await w.remove().errorCodes == ["TIMEOUT"])
            #expect(w.installs.first?.present == true)
        }
    }

    @Test("a timeout whose snapshot also fails is an error and changes no record")
    func timeoutUnknown() async throws {
        let script = DeviceScript(initial: [stremioId: true], snapshotFailures: [2], uninstallTimeoutRemoves: true)
        try await withInstallWorld(script: script, ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.remove()
            #expect(out.errorCodes == ["TIMEOUT"] && json(out)["uncertain"] == true)
            #expect(w.installs.first?.present == true)
        }
    }

    @Test("an app that is not on the device is an ok no-op that still marks the ledger")
    func notPresent() async throws {
        try await withInstallWorld(ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.remove()
            #expect(out.ok)
            #expect(json(out)["removed"] == false && json(out)["wasPresent"] == false)
            #expect(w.runner.deviceCalls == ["device info apps"])
            #expect(w.installs.first?.present == false)
        }
    }

    @Test("owner-only: no --yes is CONFIRM_REQUIRED with no lock, keychain or device use")
    func needsYes() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true])) { w in
            let out = await w.remove(yes: false)
            #expect(out.errorCodes == ["CONFIRM_REQUIRED"])
            #expect(w.runner.calls.isEmpty && w.keychain.readCount == 0)
            #expect(w.runner.deviceApps.keys.contains(w.bundleId))
        }
    }

    @Test("usage, unknown app, unsaved device, wrong platform")
    func usage() async throws {
        try await withInstallWorld { w in
            #expect(await AppCommand.run(w.services, AppOptions(sub: "remove", app: nil, device: "iphone", yes: true)).errorCodes == ["USAGE"])
            #expect(await AppCommand.run(w.services, AppOptions(sub: nil, app: "apollo", device: "iphone", yes: true)).errorCodes == ["USAGE"])
            #expect(await AppCommand.run(w.services, AppOptions(sub: "purge", app: "apollo", device: "iphone", yes: true)).errorCodes == ["USAGE"])
            #expect(await w.remove(app: wdaId).errorCodes == ["USAGE"])
            #expect(await w.remove(app: atvloadlyId).errorCodes == ["USAGE"])
            #expect(await w.remove(device: "nope").errorCodes == ["DEVICE_NOT_SAVED"])
            #expect(await w.remove(app: "stremio-tvos").errorCodes == ["PLATFORM_MISMATCH"])
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("a busy lock is OPERATION_IN_PROGRESS and nothing runs")
    func busy() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true])) { w in
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            #expect(await w.remove().errorCodes == ["OPERATION_IN_PROGRESS"])
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("an in-flight marker is settled first: a changed identity set stops with FREE_CERT_CHANGED and removes nothing")
    func marker() async throws {
        let marker = LedgerFreeInFlight(beforeFp8: ["00000000"], startedAt: testNow, app: "stremio-ios", device: "iphone")
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), ledger: { $0.freeProvisionInFlight = marker }) { w in
            #expect(await w.remove().errorCodes == ["FREE_CERT_CHANGED"])
            #expect(w.runner.calls.isEmpty)
            #expect(w.runner.deviceApps.keys.contains(w.bundleId))
        }
    }

    @Test("a failed uninstall is classified and leaves the ledger alone")
    func uninstallFails() async throws {
        let locked = try loadFixtureJSON("install-locked.json")
        let script = DeviceScript(initial: [stremioId: true], uninstallFailure: locked)
        try await withInstallWorld(script: script, ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.remove()
            #expect(out.errorCodes == ["DEVICE_LOCKED"])
            #expect(w.installs.first?.present == true)
            #expect(w.runner.deviceApps.keys.contains(w.bundleId))
        }
    }

    @Test("an uninstall that also takes another app away is UNEXPECTED_APP_DELTA; the ledger still records ours")
    func unexpectedDelta() async throws {
        let script = DeviceScript(initial: [stremioId: true, "com.example.other": false], alsoRemovedOnUninstall: ["com.example.other"])
        try await withInstallWorld(script: script, ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.remove()
            #expect(out.errorCodes == ["UNEXPECTED_APP_DELTA"])
            #expect(w.installs.first?.present == false)
        }
    }

    @Test("an uninstall that reports success while the app is still listed is UNEXPECTED_APP_DELTA and the ledger stays present")
    func stillListed() async throws {
        let script = DeviceScript(initial: [stremioId: true], uninstallLeavesApp: true)
        try await withInstallWorld(script: script, ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            let out = await w.remove()
            #expect(out.errorCodes == ["UNEXPECTED_APP_DELTA"])
            #expect(w.installs.first?.present == true)
        }
    }
}
