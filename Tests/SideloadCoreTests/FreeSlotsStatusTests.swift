import Foundation
import Testing

@testable import SideloadCore

private func text(_ envelope: Envelope) -> String { (try? envelope.printed().text) ?? "" }

@Suite("free slots: status, device lendable, classifier")
struct FreeSlotsStatusTests {
    // MARK: status

    @Test("status gains lent, slots.devices[] and appIdsLast7Days from the ledger and config alone, with no devicectl call")
    func status() async throws {
        let lent = LedgerLent(app: "apollo", device: "iphone", to: "lab", since: daysFromNow(-1))
        try await withInstallWorld(reserved: 1, ledger: { ledger in
            ledger.installs = [installRecord(.stremioIOS), installRecord(.apollo, present: false)]
            ledger.lent = [lent]
            ledger.freeAppIds = [
                LedgerFreeAppId(bundleId: stremioId, epochStart: daysFromNow(-2)),
                LedgerFreeAppId(bundleId: apolloId, epochStart: daysFromNow(-6)),
                LedgerFreeAppId(bundleId: carrierPrefix + ".free.old", epochStart: daysFromNow(-9)),
            ]
        }) { w in
            let out = StatusCommand.run(w.services)
            #expect(out.ok)
            #expect(w.runner.calls.isEmpty && w.keychain.readCount == 0)
            let printed = json(out)
            #expect(printed["appIdsLast7Days"] == 2 && printed["slots"]?["appIdsLast7Days"] == 2)
            #expect(printed["lent"] == [["app": "apollo", "device": "iphone", "to": "lab", "state": "lent", "since": .string(LedgerDates.string(lent.since)), "holds": true]])
            let devices = try #require(printed["slots"]?["devices"]?.array)
            #expect(devices.compactMap { $0["alias"]?.string } == ["appletv", "iphone"])
            let iphone = try #require(devices.first { $0["alias"] == "iphone" })
            #expect(iphone["limit"] == 3 && iphone["used"] == 3 && iphone["free"] == 0 && iphone["reserved"] == 1)
            #expect(iphone["apps"] == ["stremio-ios"])
            #expect(iphone["lent"] == ["app": "apollo", "state": "lent"] && iphone["pending"] == false)
            let tv = try #require(devices.first { $0["alias"] == "appletv" })
            #expect(tv["used"] == 0 && tv["free"] == 3 && tv["apps"] == [])
            #expect(!text(out).contains(savedUdid("1")))
        }
    }

    @Test("status with an empty ledger has empty lent and zero App IDs")
    func statusEmpty() async throws {
        try await withInstallWorld(signed: false) { w in
            let printed = json(StatusCommand.run(w.services))
            #expect(printed["lent"] == [] && printed["appIdsLast7Days"] == 0)
            #expect(printed["slots"]?["devices"]?.array?.count == 2)
        }
    }

    // MARK: device lendable

    private func lendable(_ w: InstallWorld, alias: String? = "iphone", app: String? = nil, none: Bool = false, yes: Bool = true) async -> Envelope {
        await DeviceCommand.run(w.services, DeviceOptions(sub: "lendable", alias: alias, app: app, none: none, yes: yes))
    }

    @Test("device lendable sets and clears devices.<d>.lendableApp; owner-only; touches no device")
    func lendableConfig() async throws {
        try await withInstallWorld { w in
            let set = await lendable(w, app: "stremio-ios")
            #expect(set.ok, "\(set.errors)")
            #expect(json(set)["device"]?["lendableApp"] == "stremio-ios" && json(set)["command"] == "device lendable")
            #expect(w.device("iphone")?.lendableApp == "stremio-ios")
            // Other keys survive.
            let none = await lendable(w, none: true)
            #expect(none.ok && json(none)["device"]?["lendableApp"] == .null)
            #expect(w.device("iphone")?.lendableApp == nil)
            #expect(w.device("appletv") != nil)
            #expect(w.runner.calls.isEmpty)
            #expect(!text(set).contains(savedUdid("1")))
        }
    }

    @Test("device lendable refusals: no --yes, both or neither of --app and --none, unknown app, wrong platform, unsaved alias")
    func lendableRefusals() async throws {
        try await withInstallWorld { w in
            #expect(await lendable(w, app: "stremio-ios", yes: false).errorCodes == ["CONFIRM_REQUIRED"])
            #expect(w.device("iphone")?.lendableApp == nil)
            #expect(await lendable(w, app: "stremio-ios", none: true).errorCodes == ["USAGE"])
            #expect(await lendable(w).errorCodes == ["USAGE"])
            #expect(await lendable(w, alias: nil, app: "apollo").errorCodes == ["USAGE"])
            #expect(await lendable(w, app: "nope").errorCodes == ["USAGE"])
            #expect(await lendable(w, app: wdaId).errorCodes == ["USAGE"])
            #expect(await lendable(w, app: "stremio-tvos").errorCodes == ["PLATFORM_MISMATCH"])
            #expect(await lendable(w, alias: "nope", app: "apollo").errorCodes == ["DEVICE_NOT_SAVED"])
            let stray = await DeviceCommand.run(w.services, DeviceOptions(sub: "slots", alias: "iphone", reserved: "1", app: "apollo", yes: true))
            #expect(stray.errorCodes == ["USAGE"], "--app belongs to device lendable only")
            #expect(w.device("iphone")?.freeSlotsReserved == 0)
        }
    }

    @Test("lendableApp round-trips through config.json and is omitted when unset")
    func lendableCodable() throws {
        var device = SavedDevice(udid: savedUdid("1"), platform: "ios")
        #expect(!String(decoding: try JSONEncoder().encode(device), as: UTF8.self).contains("lendableApp"))
        device.lendableApp = "apollo"
        let back = try JSONDecoder().decode(SavedDevice.self, from: JSONEncoder().encode(device))
        #expect(back.lendableApp == "apollo")
    }

    // MARK: classifier

    @Test("the real installd slots-full failure classifies as FREE_APP_LIMIT")
    func limitClassification() throws {
        let fixtureJSON = try loadFixtureJSON("install-free-app-limit.json")
        let verdict = InstallClassifier.classify(.init(exitCode: 1, json: fixtureJSON, guardPassed: true, bundleId: stremioId, freeTeam: true))
        #expect(verdict.code == "FREE_APP_LIMIT" && verdict.status == .error)
        // Also from stderr text alone.
        let text = "This device has reached the maximum number of installed apps using a free developer profile: {()}"
        #expect(InstallClassifier.classify(.init(exitCode: 1, stderr: text, guardPassed: true, freeTeam: true)).code == "FREE_APP_LIMIT")
        let failure = FreeInstallClassifier.failure(
            .install, exitCode: 1, json: fixtureJSON, stderr: "", timedOut: false, overflow: false, bundleId: stremioId)
        #expect(failure?.code == "FREE_APP_LIMIT" && failure?.fix.contains("app remove") == true)
        // The canary's own classifications are unchanged.
        #expect(InstallClassifier.classify(.init(exitCode: 1, json: try loadFixtureJSON("install-locked.json"), guardPassed: true)).code == "DEVICE_LOCKED")
    }

    @Test("the installd list keeps only our IDs, counts the rest and labels WebDriverAgent and SideStore")
    func limitList() throws {
        let fixtureJSON = try loadFixtureJSON("install-free-app-limit.json")
        let list = try #require(InstalldLimitList.parse(json: fixtureJSON, stderr: "", prefix: carrierPrefix))
        #expect(list.total == 3 && list.ours.isEmpty && list.webDriverAgent == 1 && list.sideStore == 1 && list.other == 1)
        #expect(list.unmanaged == 3)

        let mixed = "This device has reached the maximum number of installed apps using a free developer profile: {(\n \"6ZU5Z6ZKK7.io.github.dividedby.free.apollo\",\n \"6ZU5Z6ZKK7.com.example.foreign\"\n)}"
        let two = try #require(InstalldLimitList.parse(json: nil, stderr: mixed, prefix: carrierPrefix))
        #expect(two.ours == [apolloId] && two.other == 1 && two.unmanaged == 1)
        let printed = String(decoding: try JSONEncoder().encode(two.json), as: UTF8.self)
        #expect(!printed.contains("foreign"))
        #expect(InstalldLimitList.parse(json: ["note": "nothing here"], stderr: "", prefix: carrierPrefix) == nil)
    }

    @Test("free classification: success is nil; untrusted, not paired, locked, timeout, spawn failure")
    func freeClassifier() throws {
        func fail(_ op: FreeInstallClassifier.Operation = .install, json: JSONValue? = nil, stderr: String = "", timedOut: Bool = false, spawn: String? = nil) -> String? {
            FreeInstallClassifier.failure(op, exitCode: timedOut ? nil : 1, json: json, stderr: stderr, timedOut: timedOut, overflow: false, spawnError: spawn, bundleId: stremioId)?.code
        }
        let ok: JSONValue = ["info": ["outcome": "success"], "result": ["installedApplications": [["bundleID": .string(stremioId)]]]]
        #expect(FreeInstallClassifier.failure(.install, exitCode: 0, json: ok, stderr: "", timedOut: false, overflow: false, bundleId: stremioId) == nil)
        #expect(FreeInstallClassifier.failure(.uninstall, exitCode: 0, json: nil, stderr: "", timedOut: false, overflow: false, bundleId: stremioId) == nil)
        #expect(FreeInstallClassifier.failure(.install, exitCode: 0, json: ["info": ["outcome": "success"]], stderr: "", timedOut: false, overflow: false, bundleId: stremioId)?.code == "INSTALL_UNCONFIRMED")
        #expect(fail(stderr: "Untrusted Developer") == "UNTRUSTED_DEVELOPER")
        #expect(fail(stderr: "Pairing is required to continue") == "DEVICE_NOT_PAIRED")
        #expect(fail(stderr: "the device is locked") == "DEVICE_LOCKED")
        #expect(fail(timedOut: true) == "TIMEOUT")
        #expect(fail(spawn: "ENOENT") == "TOOL_FAILED")
        #expect(fail(.uninstall) == "UNINSTALL_FAILED")
        #expect(fail(.snapshot) == "SNAPSHOT_FAILED")
        #expect(fail(json: ["error": ["code": "0xe8008018"]]) == "INSTALL_FAILED", "the paid-team code is not special on the free path")
    }

    // MARK: app snapshot

    @Test("the snapshot reads bundleIdentifier and builtByDeveloper, and a non-document is not a snapshot")
    func snapshotParsing() {
        let snapshot = AppSnapshot.parse(appsJSON([stremioId: true, wdaId: true, "com.example.user": false]))
        #expect(snapshot?.ids == [stremioId, wdaId, "com.example.user"])
        let usage = snapshot?.usage(prefix: carrierPrefix, reserved: 0)
        #expect(usage?.managed == 1 && usage?.otherDeveloperApps == 1 && usage?.unmanaged == 0 && usage?.used == 1 && usage?.free == 2)
        #expect(AppSnapshot.parse(nil) == nil)
        #expect(AppSnapshot.parse(["result": "oops"]) == nil)
        #expect(AppSnapshot.parse(["info": ["outcome": "success"]]) == nil)
        #expect(AppSnapshot.parse(["info": ["outcome": "success"], "result": ["apps": []]])?.ids == [], "an empty device is valid")
        #expect(AppSnapshot.parse(["result": ["apps": []]]) == nil, "no info.outcome:success")
    }
}
