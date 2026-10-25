import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

func loadFixtureJSON(_ name: String, file: String = #filePath) throws -> JSONValue {
    let url = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

private func text(_ envelope: Envelope) -> String { (try? envelope.printed().text) ?? "" }

private let infoApps = "device info apps"
private let installApp = "device install app"

@Suite("install (free team)")
struct InstallTests {
    // MARK: success paths

    @Test("a first install: snapshot, install, snapshot; the delta is exactly our ID; installs[] is recorded with refresh{} initialised")
    func firstInstall() async throws {
        try await withInstallWorld { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(out.command == "install")
            let json = try out.printed().json
            #expect(json["reinstall"] == false)
            #expect(json["installed"] == true)
            #expect(json["bundleId"] == .string(w.bundleId))
            #expect(json["slots"]?["used"] == 1 && json["slots"]?["free"] == 2 && json["slots"]?["limit"] == 3)
            #expect(json["delta"]?["added"] == 1 && json["delta"]?["removed"] == 0)
            #expect(w.runner.deviceCalls == [infoApps, installApp, infoApps])
            #expect(w.runner.deviceApps.keys.contains(w.bundleId))

            // The install call carries the signed app and the saved device's ID, in the free scope.
            let call = try #require(w.runner.installCalls.first)
            #expect(call.args.last == w.signedApp)
            #expect(call.args.contains(savedCoreId("1")))

            let record = try #require(try w.ledger().installs.first)
            #expect(record.id == "iphone/stremio-ios" && record.device == "iphone" && record.app == "stremio-ios")
            #expect(record.bundleId == w.bundleId && record.team == "free" && record.present)
            #expect(record.deviceTail == Redactor.tail4(savedUdid("1")))
            #expect(record.version == "1.2.3" && record.sha256Prefix == "abcd1234")
            #expect(record.installedAt == testNow && record.signedAt == daysFromNow(-1))
            #expect(record.profileUuid == "0F0F0F0F-1111-2222-3333-444444444444" && record.profileCreated == daysFromNow(-2))
            #expect(record.profileExpires == daysFromNow(5))
            #expect(record.strippedExtensions == [LedgerStrippedExtension(path: "PlugIns/W.appex", bundleId: "x.widget")])
            #expect(record.droppedEntitlements == ["aps-environment"])
            #expect(record.refresh.lastResult == "installed" && record.refresh.consecutiveFailures == 0)
            #expect(record.refresh.attemptsByDay.isEmpty && !record.refresh.suspended && record.refresh.nextEligible == nil)
            try w.expectClean(out)
        }
    }

    @Test("a reinstall is slot-neutral: a full device (3 of 3) still takes it, and the delta is none")
    func reinstallOnFullDevice() async throws {
        let script = DeviceScript(initial: [stremioId: true, wdaId: true, sideStoreId: true])
        try await withInstallWorld(script: script) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            let json = try out.printed().json
            #expect(json["reinstall"] == true)
            #expect(json["slots"]?["used"] == 3 && json["slots"]?["free"] == 0)
            #expect(json["delta"]?["added"] == 0 && json["delta"]?["removed"] == 0)
            #expect(w.installs.count == 1)
        }
    }

    @Test("an app installed by hand has no installs[] record; install treats it as a slot-neutral reinstall and records it")
    func manuallyInstalledApollo() async throws {
        let script = DeviceScript(initial: [apolloId: true, wdaId: true, sideStoreId: true])
        try await withInstallWorld(app: .apollo, script: script) { w in
            #expect(w.installs.isEmpty)
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            let json = try out.printed().json
            #expect(json["reinstall"] == true)
            #expect(json["delta"]?["added"] == 0)
            #expect(w.runner.deviceCalls == [infoApps, installApp, infoApps])
            let record = try #require(try w.ledger().installs.first)
            #expect(record.id == "iphone/apollo" && record.bundleId == apolloId && record.present)
            try w.expectClean(out)
        }
    }

    @Test("exit 0 without the bundle in the output is settled by the second snapshot")
    func silentSuccess() async throws {
        try await withInstallWorld(script: DeviceScript(install: .silentSuccess)) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(w.installs.first?.present == true)
        }
    }

    @Test("a manual install clears a suspension and keeps the day counters")
    func manualSuccessClearsSuspension() async throws {
        try await withInstallWorld(ledger: { ledger in
            var refresh = LedgerInstallRefresh(consecutiveFailures: 3, attemptsByDay: ["2026-10-18": 2], suspended: true)
            refresh.lastCode = "PROFILE_NOT_RENEWED"
            ledger.installs = [installRecord(.stremioIOS, refresh: refresh)]
        }) { w in
            #expect(await w.install().ok)
            let refresh = try #require(try w.ledger().installs.first).refresh
            #expect(!refresh.suspended && refresh.consecutiveFailures == 0 && refresh.lastCode == nil)
            #expect(refresh.attemptsByDay == ["2026-10-18": 2])
        }
    }

    @Test("the install intent keeps a suspension: a run killed before the install is known does not clear it")
    func intentKeepsSuspension() async throws {
        try await withInstallWorld(ledger: { ledger in
            var refresh = LedgerInstallRefresh(consecutiveFailures: 3, suspended: true)
            refresh.lastCode = "PROFILE_NOT_RENEWED"
            ledger.installs = [installRecord(.stremioIOS, present: false, refresh: refresh)]
        }) { w in
            _ = await runSlotCommand(.install, w, crashAt: "install.intent")
            let refresh = try #require(try w.ledger().installs.first).refresh
            #expect(refresh.suspended && refresh.consecutiveFailures == 3 && refresh.lastCode == "PROFILE_NOT_RENEWED")
        }
    }

    // MARK: slots

    @Test("a full device refuses a NEW app with FREE_APP_LIMIT before the install runs (reserved slots counted)")
    func fullByReserve() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [apolloId: true]), reserved: 2) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            #expect(json(out)["slots"]?["used"] == 3)
            #expect(w.runner.deviceCalls == [infoApps])
            #expect(w.installs.isEmpty)
            try w.expectClean(out)
        }
    }

    @Test("other free-team apps found by their profiles count against the limit")
    func fullByUnmanagedDevApps() async throws {
        let script = DeviceScript(initial: [apolloId: true, wdaId: true, sideStoreId: true, "com.example.user": false])
        try await withInstallWorld(script: script, reserved: 1) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            #expect(json(out)["slots"]?["managed"] == 1 && json(out)["slots"]?["unmanaged"] == 2)
            #expect(w.runner.installCalls.isEmpty)
        }
    }

    @Test("the reserve and a free-team app it stands for are not counted twice")
    func noDoubleCount() async throws {
        let script = DeviceScript(initial: [apolloId: true, wdaId: true])
        try await withInstallWorld(script: script, reserved: 1) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["slots"]?["used"] == 3, "apollo + WebDriverAgent + the new app")
        }
    }

    @Test("an out-of-range reserve in config is CONFIG_INVALID and nothing is installed")
    func invalidReserve() async throws {
        try await withInstallWorld(reserved: 0) { w in
            try await w.store.update { config in
                config.devices["iphone"] = SavedDevice(
                    udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios", freeSlotsReserved: 9)
            }
            #expect(await w.install().errorCodes == ["CONFIG_INVALID"])
            #expect(w.runner.installCalls.isEmpty)
        }
    }

    // MARK: delta

    @Test("a first install that also adds another app is UNEXPECTED_APP_DELTA, a hard stop (counts only)")
    func unexpectedDeltaAdded() async throws {
        try await withInstallWorld(script: DeviceScript(alsoAdded: ["com.example.stray": false])) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["UNEXPECTED_APP_DELTA"])
            let json = try out.printed().json
            #expect(json["addedCount"] == 2 && json["removedCount"] == 0)
            #expect(!text(out).contains("com.example.stray"))
            #expect(w.installs.first?.present == true, "the app did land, so it is recorded")
        }
    }

    @Test("a reinstall that makes another app vanish is UNEXPECTED_APP_DELTA")
    func unexpectedDeltaRemoved() async throws {
        let script = DeviceScript(initial: [stremioId: true, "com.example.other": false], alsoRemovedOnInstall: ["com.example.other"])
        try await withInstallWorld(script: script) { w in
            #expect(await w.install().errorCodes == ["UNEXPECTED_APP_DELTA"])
        }
    }

    @Test("a snapshot that fails before stops with SNAPSHOT_FAILED and no install; one that fails after keeps the install pending")
    func snapshotFailures() async throws {
        try await withInstallWorld(script: DeviceScript(snapshotFailures: [1])) { w in
            #expect(await w.install().errorCodes == ["SNAPSHOT_FAILED"])
            #expect(w.runner.installCalls.isEmpty)
        }
        try await withInstallWorld(script: DeviceScript(snapshotFailures: [2])) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["SNAPSHOT_FAILED"])
            // The result is not known: nothing is claimed ("installed" is not printed), the intent stays and reads present.
            #expect(json(out)["installed"] == nil && json(out)["uncertain"] == true && json(out)["pending"] == true)
            #expect(w.installs.count == 1 && w.installs.first?.present == true && w.installs.first?.opAt != nil)
        }
    }

    // MARK: failures of the install itself

    @Test("installd's real slots-full failure is FREE_APP_LIMIT; ours are listed, foreign IDs only counted or labelled")
    func installdLimit() async throws {
        let json = try loadFixtureJSON("install-free-app-limit.json")
        try await withInstallWorld(script: DeviceScript(install: .fail(json: json))) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            let printed = try out.printed()
            let list = try #require(printed.json["installdList"])
            #expect(list["total"] == 3 && list["webDriverAgent"] == 1 && list["sideStore"] == 1 && list["other"] == 1)
            #expect(list["ours"] == [])
            #expect(printed.json["slots"]?["used"] == 3, "the installd list widens the preflight's count")
            #expect(printed.json["unmanagedListed"] == 3)
            #expect(out.errors.first?.fix?.contains("--reserved 3") == true)
            for foreign in ["christianselig", "msl-wda", "SideStore.SideStore"] {
                #expect(!printed.text.contains(foreign), "echoed \(foreign)")
            }
            #expect(w.installs.isEmpty)
            try w.expectClean(out)
        }
    }

    @Test("devicectl failures classify: locked, untrusted developer, not paired, timeout, unknown")
    func installFailures() async throws {
        func failure(_ behaviour: InstallBehaviour) async throws -> Envelope {
            var result: Envelope?
            try await withInstallWorld(script: DeviceScript(install: behaviour)) { w in
                result = await w.install()
                // A timed-out install may still land, so it reads present; any other failure records nothing.
                if case .timeout = behaviour { #expect(w.installs.map(\.present) == [true]) } else { #expect(w.installs.isEmpty) }
                try w.expectClean(try #require(result))
            }
            return try #require(result)
        }
        let locked = try await failure(.fail(json: try loadFixtureJSON("install-locked.json")))
        #expect(locked.errorCodes == ["DEVICE_LOCKED"])

        let untrusted = try await failure(
            .fail(json: ["info": ["outcome": "failed"], "error": ["message": "The profile has not been explicitly trusted by the user."]]))
        #expect(untrusted.errorCodes == ["UNTRUSTED_DEVELOPER"])
        #expect(untrusted.errors.first?.fix?.contains("Settings › General › VPN & Device Management") == true)

        let unpaired = try await failure(.fail(json: nil, stderr: "ERROR: The device is not paired with this computer."))
        #expect(unpaired.errorCodes == ["DEVICE_NOT_PAIRED"])

        let timeout = try await failure(.timeout)
        #expect(timeout.errorCodes == ["TIMEOUT"])
        #expect(timeout.errors.first?.fix?.contains("slot-neutral") == true)

        let unknown = try await failure(.fail(json: ["info": ["outcome": "failed"], "error": ["code": 1234567]]))
        #expect(unknown.errorCodes == ["INSTALL_FAILED"])
    }

    // MARK: guard and profile

    @Test("a guard failure stops before the device is touched")
    func guardFailure() async throws {
        try await withInstallWorld(script: DeviceScript(reportedTeam: Team.paid)) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["WRONG_TEAM"])
            #expect(w.runner.deviceCalls.isEmpty)
            #expect(w.installs.isEmpty)
        }
        try await withInstallWorld(embeddedTeam: Team.paid) { w in
            #expect(await w.install().errorCodes == ["WRONG_TEAM"])
            #expect(w.runner.deviceCalls.isEmpty)
        }
        try await withInstallWorld(script: DeviceScript(leaf: try certDER(TestCerts.other))) { w in
            #expect(await w.install().errorCodes == ["GUARD_FAILED"], "signed with something other than the pinned certificate")
            #expect(w.runner.deviceCalls.isEmpty)
        }
    }

    @Test("an expired profile is PROFILE_EXPIRED, from the ledger or from the app's embedded profile, and the device is not touched")
    func expiredProfile() async throws {
        try await withInstallWorld(profileDays: -1) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["PROFILE_EXPIRED"])
            #expect(out.errors.first?.fix?.contains("provision") == true)
            #expect(w.runner.deviceCalls.isEmpty)
        }
        try await withInstallWorld(profileDays: 5, embeddedDays: -1) { w in
            #expect(await w.install().errorCodes == ["PROFILE_EXPIRED"])
            #expect(w.runner.deviceCalls.isEmpty)
        }
    }

    @Test("nothing signed is NOT_SIGNED; a tampered record is refused")
    func notSigned() async throws {
        try await withInstallWorld(signed: false) { w in
            #expect(await w.install().errorCodes == ["NOT_SIGNED"])
            #expect(w.runner.deviceCalls.isEmpty)
        }
        try await withInstallWorld(ledger: { $0.freeSigned[0].path = "builds/signed/stremio-ios/iphone/../../../../elsewhere.app" }) { w in
            #expect(await w.install().errorCodes == ["NOT_SIGNED"])
        }
        try await withInstallWorld(ledger: { $0.freeSigned[0].bundleId = wdaId }) { w in
            #expect(await w.install().errorCodes == ["NOT_SIGNED"])
            #expect(w.runner.deviceCalls.isEmpty)
        }
    }

    // MARK: order, marker, lock

    @Test("order: usage, app, config, device, platform, --yes; none of them takes the lock or reads the keychain")
    func orderBeforeLock() async throws {
        try await withInstallWorld { w in
            #expect(await InstallCommand.run(w.services, InstallOptions(app: nil, device: "iphone", yes: true)).errorCodes == ["USAGE"])
            #expect(await w.install(app: "nope").errorCodes == ["USAGE"])
            #expect(await w.install(device: "nope").errorCodes == ["DEVICE_NOT_SAVED"])
            #expect(await w.install(app: "stremio-tvos").errorCodes == ["PLATFORM_MISMATCH"])
            let unconfirmed = await w.install(yes: false)
            #expect(unconfirmed.errorCodes == ["CONFIRM_REQUIRED"])
            #expect(json(unconfirmed)["bundleId"] == .string(w.bundleId))
            #expect(w.keychain.readCount == 0 && w.runner.calls.isEmpty)
            try await w.store.update { $0.bundleIdPrefix = nil }
            #expect(await w.install().errorCodes == ["CONFIG_MISSING"])
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("a busy .op.lock is OPERATION_IN_PROGRESS and nothing else runs")
    func busyLock() async throws {
        try await withInstallWorld { w in
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            #expect(await w.install().errorCodes == ["OPERATION_IN_PROGRESS"])
            #expect(w.runner.calls.isEmpty && w.keychain.readCount == 0)
        }
    }

    @Test("an in-flight marker whose identity set changed stops everything: FREE_CERT_CHANGED, suspended, no device call")
    func markerChanged() async throws {
        try await withInstallWorld(ledger: { $0.freeProvisionInFlight = LedgerFreeInFlight(beforeFp8: ["00000000"], startedAt: testNow, app: "stremio-ios", device: "iphone") }) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_CERT_CHANGED"])
            #expect(w.runner.calls.isEmpty)
            let ledger = try w.ledger()
            #expect(ledger.freeProvisionInFlight == nil && ledger.freeSuspended?.code == "FREE_CERT_CHANGED")
        }
    }

    @Test("an in-flight marker with an unchanged identity set is cleared and the install goes on")
    func markerUnchanged() async throws {
        let free = try freeKeychainCert()
        let marker = LedgerFreeInFlight(beforeFp8: [LedgerSync.fp8(free.reference)], startedAt: testNow, app: "stremio-ios", device: "iphone")
        try await withInstallWorld(ledger: { $0.freeProvisionInFlight = marker }) { w in
            #expect(await w.install().ok)
            #expect((try? w.ledger())?.freeProvisionInFlight == nil)
        }
    }

    @Test("a locked keychain is KEYCHAIN_LOCKED and the marker is left alone")
    func keychainLocked() async throws {
        try await withInstallWorld(keychain: [nil]) { w in
            #expect(await w.install().errorCodes == ["KEYCHAIN_LOCKED"])
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("no pin, or the pinned identity gone, stops before the guard")
    func pinProblems() async throws {
        try await withInstallWorld(keychain: [[]]) { w in
            #expect(await w.install().errorCodes == ["FREE_IDENTITY_MISSING"])
            #expect(w.runner.calls.isEmpty)
        }
        try await withInstallWorld { w in
            try await w.store.update { $0.extra["freeTeam"] = nil }
            #expect(await w.install().errorCodes == ["FREE_IDENTITY_NOT_PINNED"])
        }
    }

    @Test("a slot lent to the lab is not installed by a plain install")
    func lentSlot() async throws {
        let lent = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1))
        try await withInstallWorld(ledger: { $0.lent = [lent] }) { w in
            #expect(await w.install().errorCodes == ["APP_LENT"])
            #expect(w.runner.deviceCalls.isEmpty)
        }
    }

    // MARK: WebDriverAgent and atvloadly can never be named

    @Test("WebDriverAgent's and atvloadly's bundle IDs are refused by DeviceCtl's free scope for install, uninstall and launch")
    func deviceCtlRefuses() async throws {
        try await withInstallWorld { w in
            for foreign in [wdaId, atvloadlyId, sideStoreId, "io.github.dividedby.canary"] {
                for words in [["device", "uninstall", "app"], ["device", "process", "launch"]] {
                    do {
                        _ = try await w.services.deviceCtl.run(words, deviceAlias: "iphone", positional: [foreign], scope: .free(bundleId: foreign))
                        Issue.record("\(words) \(foreign) was allowed")
                    } catch {
                        #expect(errorCode(of: error) == "BUNDLE_ID_NOT_ALLOWED")
                    }
                    // Our scope with a foreign positional is refused too.
                    do {
                        _ = try await w.services.deviceCtl.run(words, deviceAlias: "iphone", positional: [foreign], scope: .free(bundleId: w.bundleId))
                        Issue.record("\(words) \(foreign) was allowed under our scope")
                    } catch {
                        #expect(errorCode(of: error) == "BUNDLE_ID_NOT_ALLOWED")
                    }
                }
                do {
                    _ = try await w.services.deviceCtl.run(["device", "install", "app"], deviceAlias: "iphone", positional: ["/x/y.app"], scope: .free(bundleId: foreign))
                    Issue.record("install \(foreign) was allowed")
                } catch {
                    #expect(errorCode(of: error) == "BUNDLE_ID_NOT_ALLOWED")
                }
            }
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("their IDs cannot be named at any CLI entry point, and a tampered config or ledger naming them reaches no device")
    func cliRefuses() async throws {
        let lentWda = LedgerLent(app: wdaId, device: "iphone", to: "lab", since: daysFromNow(-1))
        try await withInstallWorld(script: DeviceScript(initial: [wdaId: true]), lendable: wdaId, ledger: { $0.lent = [lentWda] }) { w in
            for foreign in [wdaId, atvloadlyId] {
                for argv in [
                    ["install", "--app", foreign, "--device", "iphone", "--yes"],
                    ["app", "remove", "--app", foreign, "--device", "iphone", "--yes"],
                    ["device", "lendable", "--alias", "iphone", "--app", foreign, "--yes"],
                ] {
                    let out = await run(argv: argv, services: w.services)
                    #expect(out.errorCodes == ["USAGE"], "\(argv)")
                }
            }
            // A ledger that says WebDriverAgent was lent: return refuses and installs nothing.
            let back = await run(argv: ["slot", "return", "--device", "iphone"], services: w.services)
            #expect(back.errorCodes == ["RETURN_FAILED"])
            #expect(w.runner.deviceCalls.isEmpty)
            #expect(!w.runner.deviceArgv.contains(wdaId))
            #expect(w.runner.deviceApps.keys.contains(wdaId))
        }
        // A config whose lendable app is WebDriverAgent: nothing to lend.
        try await withInstallWorld(script: DeviceScript(initial: [wdaId: true]), lendable: wdaId) { w in
            let lend = await run(argv: ["slot", "lend", "--device", "iphone", "--to", "lab"], services: w.services)
            #expect(lend.errorCodes == ["NO_LENDABLE_APP"])
            #expect(w.runner.deviceCalls.isEmpty)
        }
    }
}

/// An `installs[]` record for tests.
func installRecord(
    _ app: ProvisionApp, alias: String = "iphone", present: Bool = true, refresh: LedgerInstallRefresh = LedgerInstallRefresh()
) -> LedgerInstall {
    LedgerInstall(
        id: "\(alias)/\(app.rawValue)", device: alias, deviceTail: "AAAA", app: app.rawValue,
        bundleId: carrierPrefix + ".free." + app.suffix, profileUuid: "0F0F0F0F-1111-2222-3333-444444444444",
        profileCreated: daysFromNow(-2), profileExpires: daysFromNow(5), certFp8: "deadbeef", version: "1.2.3",
        sha256Prefix: "abcd1234", signedAt: daysFromNow(-1), installedAt: daysFromNow(-1), strippedExtensions: [],
        droppedEntitlements: [], present: present, refresh: refresh)
}
