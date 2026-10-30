import Darwin
import Foundation
import Testing

@testable import SideloadCore

// `device remove` (owner-only retirement of a saved device), against the temp homes of `InstallTestSupport`. Nothing here
// touches a device (the fake runner is never asked) or the real `$SIDELOAD_HOME`.

private let uuid = "0F0F0F0F-1111-2222-3333-444444444444"
private let sentinel = "SENTINEL-SESSION-TOKEN-5d02"
private let prefs = "Library/Preferences/io.github.dividedby.free.stremio.plist"

/// The iPhone's records (two installs, one present) and the Apple TV's; `withInstallWorld` adds both signed/profile records.
private func populate(_ ledger: inout Ledger) {
    ledger.installs = [
        installRecord(.stremioIOS), installRecord(.apollo, present: false), installRecord(.stremioTVOS, alias: "appletv"),
    ]
    ledger.freeAppIds = [LedgerFreeAppId(bundleId: stremioId, epochStart: daysFromNow(-3))]
    ledger.extra = ["note": "keep"]
}

/// An alias that exists only in the ledger, as the owner's old `iphone` did.
private func addGhost(_ ledger: inout Ledger) {
    populate(&ledger)
    ledger.installs.append(installRecord(.stremioIOS, alias: "oldphone"))
    ledger.freeProfiles.append(
        LedgerFreeProfile(
            id: "oldphone/stremio-ios", device: "oldphone", deviceTail: "AAAA", app: "stremio-ios", bundleId: stremioId,
            profileUuid: uuid, created: nil, expires: daysFromNow(5), certFp8: "deadbeef",
            file: "profiles/free/stremio-ios/oldphone/\(uuid).mobileprovision"))
    ledger.freeSigned.append(
        LedgerFreeSigned(
            id: "oldphone/stremio-ios", device: "oldphone", app: "stremio-ios", bundleId: stremioId, version: "1.2.3",
            sha256Prefix: "abcd1234", profileUuid: uuid, profileExpires: daysFromNow(5), certFp8: "deadbeef",
            signedAt: daysFromNow(-1), path: "builds/signed/stremio-ios/oldphone/Stremio.app", strippedExtensions: [],
            droppedEntitlements: []))
}

private func write(_ text: String, to path: String) throws {
    try makeDirectories((path as NSString).deletingLastPathComponent, mode: 0o700)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

/// Profile files for every alias, one signed folder the ledger does not know, and two backups for the iPhone.
private func lay(_ w: InstallWorld, aliases: [String] = ["iphone", "appletv"]) throws {
    for alias in aliases {
        for app in ["stremio-ios", "apollo"] {
            try write("profile", to: "\(w.paths.freeProfiles)/\(app)/\(alias)/\(uuid).mobileprovision")
        }
    }
    try write("extra", to: "\(w.paths.signedBuilds)/apollo/iphone/Apollo.app/Info.plist")
    for stamp in ["20261001T000000Z", "20261002T000000Z"] {
        try write(sentinel, to: "\(w.paths.backups)/iphone/stremio-ios/\(stamp)/files/\(prefs)")
    }
    try write(sentinel, to: "\(w.paths.backups)/iphone/stremio-ios/stray-file")
}

private func treeOf(_ root: String) -> [String] {
    ((try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? []).sorted()
}

/// Everything `device remove` may change: both stores' bytes and every file under profiles/, builds/ and backups/.
private struct Snapshot: Equatable {
    var ledger: Data?
    var config: Data?
    var files: [String: [String]]

    init(_ w: InstallWorld) {
        ledger = try? Data(contentsOf: URL(fileURLWithPath: w.paths.ledger))
        config = try? Data(contentsOf: URL(fileURLWithPath: w.paths.config))
        files = ["profiles", "builds", "backups"].reduce(into: [:]) { $0[$1] = treeOf(w.paths.home + "/" + $1) }
    }
}

private extension InstallWorld {
    func removeDevice(_ alias: String? = "iphone", yes: Bool = false, _ tweak: (inout DeviceOptions) -> Void = { _ in }) async -> Envelope {
        var options = DeviceOptions(sub: "remove", alias: alias, yes: yes)
        tweak(&options)
        return await DeviceCommand.run(services, options)
    }
}

private func warningCodes(_ out: Envelope) -> [String] {
    (json(out)["warnings"]?.array ?? []).compactMap { $0["code"]?.string }
}

@Suite("device remove")
struct DeviceRemoveTests {
    // MARK: usage

    @Test("needs --alias, a valid alias, and nothing else but --yes")
    func usage() async throws {
        try await withInstallWorld(ledger: populate) { w in
            try lay(w)
            let before = Snapshot(w)
            #expect(await w.removeDevice(nil, yes: true).errorCodes == ["USAGE"])
            #expect(await w.removeDevice("", yes: true).errorCodes == ["USAGE"])
            for bad in ["../x", "a/b", "..", "-x", "x y", String(repeating: "a", count: 33)] {
                #expect(await w.removeDevice(bad, yes: true).errorCodes == ["USAGE"], "\(bad)")
            }
            #expect(await w.removeDevice { $0.match = "Test iPhone" }.errorCodes == ["USAGE"])
            #expect(await w.removeDevice { $0.platform = "ios" }.errorCodes == ["USAGE"])
            #expect(await w.removeDevice { $0.on = true }.errorCodes == ["USAGE"])
            #expect(await w.removeDevice { $0.off = true }.errorCodes == ["USAGE"])
            #expect(await w.removeDevice { $0.reserved = "1" }.errorCodes == ["USAGE"])
            #expect(await w.removeDevice { $0.app = "apollo" }.errorCodes == ["USAGE"])
            #expect(await w.removeDevice { $0.none = true }.errorCodes == ["USAGE"])
            #expect(Snapshot(w) == before)
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("an alias neither saved nor in the ledger is DEVICE_NOT_SAVED, with or without --yes")
    func unknown() async throws {
        try await withInstallWorld(ledger: populate) { w in
            let before = Snapshot(w)
            for yes in [false, true] {
                let out = await w.removeDevice("nope", yes: yes)
                #expect(out.errorCodes == ["DEVICE_NOT_SAVED"])
                #expect(out.errors.first?.fix == "sideload device list")
            }
            #expect(Snapshot(w) == before)
        }
    }

    // MARK: preview

    @Test("without --yes: CONFIRM_REQUIRED with the counts, and nothing changes")
    func preview() async throws {
        try await withInstallWorld(alsoSigned: [.stremioTVOS], ledger: populate) { w in
            try lay(w)
            let before = Snapshot(w)
            let out = await w.removeDevice()
            #expect(out.errorCodes == ["CONFIRM_REQUIRED"])
            #expect(out.exitCode == 1)
            let preview = try #require(json(out)["preview"])
            #expect(preview["alias"] == "iphone")
            #expect(preview["inConfig"] == true)
            #expect(preview["profiles"] == 1)
            #expect(preview["signedBuilds"] == 1)
            #expect(preview["installs"] == 2)
            #expect(preview["installsPresent"] == 1)
            #expect(preview["slots"] == 2)
            #expect(preview["backups"] == 2, "folders under backups/iphone/<app>/, not the stray file")
            #expect(Snapshot(w) == before)
            #expect(w.runner.calls.isEmpty)
            try w.expectClean(out)
        }
    }

    @Test("the preview does not take the lock")
    func previewNoLock() async throws {
        try await withInstallWorld(ledger: populate) { w in
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            #expect(await w.removeDevice().errorCodes == ["CONFIRM_REQUIRED"])
        }
    }

    // MARK: refusals

    private func expectRefused(
        _ w: InstallWorld, reason: String, fixContains: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let before = Snapshot(w)
        for yes in [false, true] {
            let out = await w.removeDevice(yes: yes)
            #expect(out.errorCodes == ["DEVICE_BUSY"], "yes \(yes): \(out.errors)", sourceLocation: sourceLocation)
            #expect(json(out)["reason"] == .string(reason), sourceLocation: sourceLocation)
            #expect(out.errors.first?.fix?.contains(fixContains) == true, sourceLocation: sourceLocation)
            try w.expectClean(out, sourceLocation: sourceLocation)
        }
        #expect(Snapshot(w) == before, "nothing changed", sourceLocation: sourceLocation)
    }

    @Test("refuses while the lab holds a slot of the device")
    func lent() async throws {
        try await withInstallWorld(ledger: { ledger in
            populate(&ledger)
            ledger.slots = [LedgerSlot(device: "iphone", app: "stremio-ios", presence: .absent, lentTo: "lab", since: testNow)]
            ledger.installs.removeAll { $0.id == "iphone/stremio-ios" }
            SlotRule.project(&ledger)
        }) { w in
            try lay(w)
            try await expectRefused(w, reason: "lent", fixContains: "slot return --device iphone")
        }
    }

    @Test("refuses while a lend or return is pending, inside its window or not yet settled")
    func pendingLendOrReturn() async throws {
        for (kind, by, age) in [
            (LedgerSlotKind.uninstall, LedgerSlotBy.lend, 10.0), (.install, .giveBack, 10.0), (.uninstall, .lend, 100_000.0),
        ] {
            try await withInstallWorld(ledger: { ledger in
                populate(&ledger)
                let op = LedgerSlotOp(
                    kind: kind, by: by, startedAt: testNow.addingTimeInterval(-age), window: SlotRule.window(kind))
                ledger.slots = [
                    LedgerSlot(device: "iphone", app: "stremio-ios", presence: .unknown, lentTo: "lab", since: testNow, op: op)
                ]
                ledger.installs.removeAll { $0.id == "iphone/stremio-ios" }
                SlotRule.project(&ledger)
            }) { w in
                try lay(w)
                try await expectRefused(w, reason: "pending", fixContains: "slot return --device iphone")
            }
        }
    }

    @Test("refuses while any slot operation of the device is inside its window, and not for one past it")
    func opInFlight() async throws {
        try await withInstallWorld(ledger: { ledger in
            populate(&ledger)
            let op = LedgerSlotOp(kind: .reinstall, by: .install, startedAt: testNow, window: SlotRule.window(.reinstall))
            ledger.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .unknown, op: op)]
            ledger.installs.removeAll { $0.id == "iphone/apollo" }
            SlotRule.project(&ledger)
        }) { w in
            try lay(w)
            try await expectRefused(w, reason: "pending", fixContains: "Retry in")
            // Past its window the op is stale: the device is no longer busy.
            w.clock.advance(Double(SlotRule.window(.reinstall)) + 5)
            #expect(await w.removeDevice().errorCodes == ["CONFIRM_REQUIRED"])
        }
    }

    @Test("an op on another device does not refuse this one")
    func otherDeviceBusy() async throws {
        try await withInstallWorld(ledger: { ledger in
            populate(&ledger)
            let op = LedgerSlotOp(kind: .uninstall, by: .lend, startedAt: testNow, window: SlotRule.window(.uninstall))
            ledger.slots = [LedgerSlot(device: "appletv", app: "stremio-tvos", presence: .unknown, lentTo: "lab", since: testNow, op: op)]
            SlotRule.project(&ledger)
        }) { w in
            #expect(await w.removeDevice().errorCodes == ["CONFIRM_REQUIRED"])
        }
    }

    @Test("refuses while a saved app-data restore is waiting, and the fix names slot restore")
    func pendingRestore() async throws {
        var script = DeviceScript(initial: [stremioId: true])
        script.container = [prefs: Data((sentinel + "prefs").utf8)]
        try await withInstallWorld(
            script: script, lendable: "stremio-ios", ledger: { $0.installs = [installRecord(.stremioIOS)] }
        ) { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").ok)
            var failing = script
            failing.dataFaults.copyToFails = [prefs]
            w.runner.arm(failing)
            let back = await w.slot("return", device: "iphone")
            #expect(back.ok && json(back)["dataRestored"] == false, "\(back.errors)")
            try await expectRefused(w, reason: "restore_pending", fixContains: "slot restore --device iphone")
        }
    }

    @Test("a pending restore of an alias that is no longer saved still refuses, and the fix does not suggest slot restore")
    func pendingRestoreUnsavedAlias() async throws {
        var script = DeviceScript(initial: [stremioId: true])
        script.container = [prefs: Data((sentinel + "prefs").utf8)]
        try await withInstallWorld(
            script: script, lendable: "stremio-ios", ledger: { $0.installs = [installRecord(.stremioIOS)] }
        ) { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").ok)
            var failing = script
            failing.dataFaults.copyToFails = [prefs]
            w.runner.arm(failing)
            #expect(await w.slot("return", device: "iphone").ok)
            _ = try await w.store.update { $0.devices.removeValue(forKey: "iphone") }
            try await expectRefused(w, reason: "restore_pending", fixContains: "no longer saved")
        }
    }

    @Test("backups present and no readable bundleIdPrefix: restore_unknown refuses; without backups the check is not needed")
    func restoreUnknown() async throws {
        try await withInstallWorld(ledger: populate) { w in
            try lay(w)
            _ = try await w.store.update { $0.bundleIdPrefix = nil }
            try await expectRefused(w, reason: "restore_unknown", fixContains: "bundleIdPrefix")
            // The Apple TV has no backups.
            #expect(await w.removeDevice("appletv").errorCodes == ["CONFIRM_REQUIRED"])
            _ = try await w.store.update { $0.bundleIdPrefix = "not a prefix!" }
            try await expectRefused(w, reason: "restore_unknown", fixContains: "bundleIdPrefix")
        }
    }

    // MARK: remove

    @Test("--yes drops the alias's records and files, keeps everyone else's and the backups, and forgets present installs")
    func removes() async throws {
        try await withInstallWorld(alsoSigned: [.stremioTVOS], ledger: populate) { w in
            try lay(w)
            let before = try w.ledger()
            let backups = treeOf(w.paths.backups)
            let appletvFiles = treeOf(w.paths.freeProfiles + "/stremio-ios/appletv")

            let out = await w.removeDevice(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(out.command == "device remove")
            let removed = try #require(json(out)["removed"])
            #expect(removed["alias"] == "iphone")
            #expect(removed["fromConfig"] == true)
            #expect(removed["profiles"] == 1 && removed["signedBuilds"] == 1)
            #expect(removed["installs"] == 2 && removed["installsPresent"] == 1 && removed["slots"] == 2)
            // profiles: stremio-ios and apollo; signed: stremio-ios (ledger) and apollo (not in the ledger).
            #expect(removed["dirsDeleted"] == 4)
            #expect(json(out)["backupsKept"] == 2)
            #expect(Set(warningCodes(out)) == ["INSTALLS_LEFT_ON_DEVICE", "BACKUPS_KEPT"])
            try w.expectClean(out)

            let ledger = try w.ledger()
            #expect(!SlotRule.needsMigration(ledger, now: testNow), "slots and the legacy fields agree")
            for device in ledger.freeProfiles.map(\.device) + ledger.freeSigned.map(\.device) + ledger.installs.map(\.device)
                + ledger.slots.map(\.device) + ledger.lent.map(\.device)
            {
                #expect(device == "appletv")
            }
            #expect(ledger.freeProfiles == before.freeProfiles.filter { $0.device == "appletv" })
            #expect(ledger.freeSigned == before.freeSigned.filter { $0.device == "appletv" })
            #expect(ledger.installs == before.installs.filter { $0.device == "appletv" })
            #expect(ledger.slots.map(\.id) == ["appletv/stremio-tvos"])
            #expect(ledger.freeAppIds == before.freeAppIds && ledger.extra == before.extra, "unrelated records are untouched")

            #expect(try w.config().devices["iphone"] == nil)
            #expect(try w.config().devices["appletv"] != nil)
            #expect(treeOf(w.paths.backups) == backups)
            #expect(try String(contentsOfFile: "\(w.paths.backups)/iphone/stremio-ios/20261001T000000Z/files/\(prefs)", encoding: .utf8) == sentinel)
            for root in [w.paths.freeProfiles, w.paths.signedBuilds] {
                for app in treeOf(root) where !app.contains("/") {
                    #expect(!FileManager.default.fileExists(atPath: "\(root)/\(app)/iphone"), "\(root)/\(app)")
                }
            }
            #expect(treeOf(w.paths.freeProfiles + "/stremio-ios/appletv") == appletvFiles)
            #expect(FileManager.default.fileExists(atPath: w.signedAppPath("stremio-tvos", "appletv")))
            #expect(w.runner.calls.isEmpty, "no device call")
        }
    }

    @Test("a device without installs, backups or leftovers removes cleanly with no warnings")
    func quiet() async throws {
        try await withInstallWorld(signed: false) { w in
            let out = await w.removeDevice("appletv", yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["removed"]?["dirsDeleted"] == 0)
            #expect(json(out)["backupsKept"] == 0)
            #expect(json(out)["warnings"] == [])
            let config = try w.config()
            #expect(config.devices["appletv"] == nil)
        }
    }

    @Test("a link under the home is never followed: its target survives, and a linked alias entry is unlinked")
    func linksNotFollowed() async throws {
        try await withInstallWorld(ledger: populate) { w in
            try lay(w)
            let outside = w.paths.home + "-outside"
            try write("keep", to: outside + "/iphone/keep.txt")
            try write("keep", to: outside + "/target/keep.txt")
            defer { try? FileManager.default.removeItem(atPath: outside) }
            // An app folder that is a link, and an alias entry that is a link.
            try FileManager.default.createSymbolicLink(atPath: w.paths.freeProfiles + "/linked", withDestinationPath: outside)
            try makeDirectories(w.paths.signedBuilds + "/filler", mode: 0o700)
            try FileManager.default.createSymbolicLink(
                atPath: w.paths.signedBuilds + "/filler/iphone", withDestinationPath: outside + "/target")

            let out = await w.removeDevice(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(FileManager.default.fileExists(atPath: outside + "/iphone/keep.txt"))
            #expect(FileManager.default.fileExists(atPath: outside + "/target/keep.txt"))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: w.paths.signedBuilds + "/filler/iphone")) == nil)
            #expect(warningCodes(out).contains("DIRECTORY_SKIPPED"))
        }
    }

    @Test("an alias only the ledger knows is cleaned: fromConfig is false and the config is untouched")
    func ledgerOnly() async throws {
        try await withInstallWorld(ledger: addGhost) { w in
            try lay(w, aliases: ["iphone", "oldphone"])
            let configBefore = try w.config().devices.keys.sorted()
            let preview = await w.removeDevice("oldphone")
            #expect(preview.errorCodes == ["CONFIRM_REQUIRED"])
            #expect(json(preview)["preview"]?["inConfig"] == false)

            let out = await w.removeDevice("oldphone", yes: true)
            #expect(out.ok, "\(out.errors)")
            let removed = try #require(json(out)["removed"])
            #expect(removed["fromConfig"] == false)
            #expect(removed["profiles"] == 1 && removed["signedBuilds"] == 1 && removed["installs"] == 1)
            #expect(removed["installsPresent"] == 1 && removed["slots"] == 1 && removed["dirsDeleted"] == 2)
            let ledger = try w.ledger()
            #expect(!ledger.installs.contains { $0.device == "oldphone" } && !ledger.slots.contains { $0.device == "oldphone" })
            #expect(!ledger.freeProfiles.contains { $0.device == "oldphone" } && !ledger.freeSigned.contains { $0.device == "oldphone" })
            #expect(ledger.installs.contains { $0.device == "iphone" }, "other aliases are untouched")
            #expect(try w.config().devices.keys.sorted() == configBefore)
            #expect(FileManager.default.fileExists(atPath: "\(w.paths.freeProfiles)/stremio-ios/iphone"))
            #expect(!FileManager.default.fileExists(atPath: "\(w.paths.freeProfiles)/stremio-ios/oldphone"))
        }
    }

    @Test("a legacy lent record with no slot still counts: a held one refuses a ledger-only alias")
    func legacyLentRefuses() async throws {
        try await withInstallWorld(ledger: { ledger in
            addGhost(&ledger)
            ledger.slots = []
            ledger.lent = [
                LedgerLent(app: "stremio-ios", device: "oldphone", to: "lab", since: testNow, state: LedgerLent.lent, opAt: nil)
            ]
            ledger.installs.removeAll { $0.device == "oldphone" }
        }) { w in
            let out = await w.removeDevice("oldphone", yes: true)
            #expect(out.errorCodes == ["DEVICE_BUSY"] && json(out)["reason"] == "lent", "\(out.errors)")
        }
    }

    @Test("a busy op lock is OPERATION_IN_PROGRESS and nothing changes")
    func busyLock() async throws {
        try await withInstallWorld(ledger: populate) { w in
            try lay(w)
            let before = Snapshot(w)
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            #expect(await w.removeDevice(yes: true).errorCodes == ["OPERATION_IN_PROGRESS"])
            #expect(Snapshot(w) == before)
        }
    }

    @Test("a rerun after success is DEVICE_NOT_SAVED")
    func rerun() async throws {
        try await withInstallWorld(ledger: populate) { w in
            try lay(w)
            #expect(await w.removeDevice(yes: true).ok)
            #expect(await w.removeDevice(yes: true).errorCodes == ["DEVICE_NOT_SAVED"])
            #expect(await w.removeDevice().errorCodes == ["DEVICE_NOT_SAVED"])
        }
    }

    @Test("a run that died after the ledger write finishes on a rerun, since config still names the alias")
    func rerunAfterCrash() async throws {
        try await withInstallWorld(ledger: populate) { w in
            try lay(w)
            // The state after step a: records gone, files and config entry still there.
            try await SlotState.write(w.services, point: "test") { ledger in
                ledger.installs.removeAll { $0.device == "iphone" }
                ledger.slots.removeAll { $0.device == "iphone" }
                ledger.freeProfiles.removeAll { $0.device == "iphone" }
                ledger.freeSigned.removeAll { $0.device == "iphone" }
            }
            let out = await w.removeDevice(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["removed"]?["installs"] == 0)
            #expect(json(out)["removed"]?["dirsDeleted"] == 4)
            #expect(try w.config().devices["iphone"] == nil)
        }
    }

    @Test("a failed folder delete on a ledger-only alias is finished by a rerun, which still accepts the alias")
    func rerunAfterIncomplete() async throws {
        try await withInstallWorld(ledger: addGhost) { w in
            try lay(w, aliases: ["iphone", "oldphone"])
            let locked = w.paths.freeProfiles + "/stremio-ios"
            #expect(chmod(locked, 0o500) == 0)
            defer { _ = chmod(locked, 0o700) }
            let failed = await w.removeDevice("oldphone", yes: true)
            #expect(failed.errorCodes == ["DEVICE_REMOVE_INCOMPLETE"], "\(failed.errors)")
            let ledger = try w.ledger()
            #expect(!ledger.installs.contains { $0.device == "oldphone" }, "the records went first")
            #expect(chmod(locked, 0o700) == 0)
            let again = await w.removeDevice("oldphone", yes: true)
            #expect(again.ok, "\(again.errors)")
            #expect(json(again)["removed"]?["fromConfig"] == false)
            #expect(json(again)["removed"]?["dirsDeleted"] == 1)
            #expect(await w.removeDevice("oldphone", yes: true).errorCodes == ["DEVICE_NOT_SAVED"])
        }
    }

    @Test("an alias with leftover folders only is accepted")
    func leftoverFoldersOnly() async throws {
        try await withInstallWorld(ledger: populate) { w in
            try lay(w, aliases: ["iphone", "ghost"])
            let preview = await w.removeDevice("ghost")
            #expect(preview.errorCodes == ["CONFIRM_REQUIRED"])
            #expect(json(preview)["preview"]?["installs"] == 0)
            let out = await w.removeDevice("ghost", yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["removed"]?["dirsDeleted"] == 2 && json(out)["removed"]?["fromConfig"] == false)
            #expect(await w.removeDevice("ghost", yes: true).errorCodes == ["DEVICE_NOT_SAVED"])
        }
    }

    @Test("stray regular files beside the app folders are ignored: no DIRECTORY_SKIPPED")
    func strayFiles() async throws {
        try await withInstallWorld(ledger: populate) { w in
            try lay(w)
            try write("x", to: w.paths.freeProfiles + "/.DS_Store")
            try write("x", to: w.paths.signedBuilds + "/.DS_Store")
            let out = await w.removeDevice(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(!warningCodes(out).contains("DIRECTORY_SKIPPED"))
            #expect(FileManager.default.fileExists(atPath: w.paths.freeProfiles + "/.DS_Store"))
        }
    }

    // MARK: device save

    @Test("device save's ALIAS_EXISTS points to device remove")
    func aliasExistsFix() async throws {
        let config = Config(devices: ["iphone": SavedDevice(udid: savedUdid("5"), coreDeviceId: savedCoreId("5"), platform: "ios")])
        try await withTestHome(config: config) { paths, _ in
            let (services, _) = fakeServices(paths, route: Route(devices: deviceListJSON(phoneEntryJSON())))
            let out = await DeviceCommand.run(
                services, DeviceOptions(sub: "save", alias: "iphone", match: "Test iPhone", platform: "ios", yes: true))
            #expect(out.errorCodes == ["ALIAS_EXISTS"])
            let fix = try #require(out.errors.first?.fix)
            #expect(fix.contains("Pick another alias"))
            #expect(fix.contains("sideload device remove --alias iphone --yes"))
            #expect(!fix.contains("config.json"))
        }
    }

    @Test("an unknown subcommand lists remove")
    func unknownSubcommand() async throws {
        try await withTestHome { paths, _ in
            let (services, _) = fakeServices(paths)
            let out = await DeviceCommand.run(services, DeviceOptions(sub: "retire"))
            #expect(out.errorCodes == ["USAGE"])
            #expect(out.errors.first?.fix?.contains("lendable|remove") == true)
        }
    }
}

private extension InstallWorld {
    func signedAppPath(_ app: String, _ alias: String) -> String { "\(paths.signedBuilds)/\(app)/\(alias)" }
}
