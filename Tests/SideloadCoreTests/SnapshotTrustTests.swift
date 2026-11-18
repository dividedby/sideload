import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// A `devicectl device info apps` read that omits every app the ledger says is installed is not trusted (docs/design.md
// section 18, "Snapshot validity"): re-read once, then never let it mark an app gone, never count the apps it omitted as new,
// and never let lend / remove act on it. The fake device prints a valid, empty list for the numbered reads (`snapshotEmpty`).

private let infoApps = "device info apps"
private let installApp = "device install app"
private let uninstallApp = "device uninstall app"
private let mystery = "io.github.dividedby.free.mystery"

private let bothInstalled: [String: Bool] = [stremioId: true, apolloId: true]

private func bothRecorded(_ ledger: inout Ledger) {
    ledger.installs = [installRecord(.stremioIOS), installRecord(.apollo)]
}

private func presence(_ w: InstallWorld, _ app: String) -> LedgerSlotPresence? {
    w.slotRecord(app)?.presence
}

private func warningCodes(_ out: Envelope) -> [String] {
    json(out)["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
}

@Suite("snapshot trust: a read that contradicts the ledger")
struct SnapshotTrustTests {
    @Test(
        "incident replay: both reads empty, install plans a reinstall, the apps listed again are not new, the other app stays present"
    )
    func incidentReplay() async throws {
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [1, 2])
        try await withInstallWorld(script: script, ledger: bothRecorded) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["reinstall"] == true)
            #expect(warningCodes(out) == ["LEDGER_SNAPSHOT_DISAGREED"])
            #expect(
                json(out)["warnings"]?.array?.first?["data"]?["reappearedCount"] == 2,
                "counts only")
            let check = json(out)["snapshotCheck"]
            #expect(check?["listed"] == 0 && check?["expected"] == 2 && check?["missing"] == 2)
            #expect(check?["resolved"] == false && check?["reread"] == true)
            #expect(w.runner.deviceCalls == [infoApps, infoApps, installApp, infoApps])
            #expect(presence(w, "apollo") == .present && presence(w, "stremio-ios") == .present)
            #expect(w.installs.allSatisfy { $0.present })
            try w.expectClean(out)
        }
    }

    @Test(
        "an empty first read that the re-read corrects is the normal flow, with two reads and no warning"
    )
    func rereadResolves() async throws {
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [1])
        try await withInstallWorld(script: script, ledger: bothRecorded) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["reinstall"] == true && warningCodes(out).isEmpty)
            let check = json(out)["snapshotCheck"]
            #expect(check?["resolved"] == true && check?["missing"] == 2)
            #expect(w.runner.deviceCalls == [infoApps, infoApps, installApp, infoApps])
        }
    }

    @Test("a read that shows any recorded app is believed: no re-read, no check")
    func partialOmissionIsTrusted() async throws {
        let script = DeviceScript(initial: [apolloId: true])
        try await withInstallWorld(script: script, ledger: bothRecorded) { w in
            let out = await w.remove()
            #expect(out.ok && json(out)["wasPresent"] == false)
            #expect(json(out)["snapshotCheck"] == nil)
            #expect(w.runner.deviceCalls == [infoApps])
            #expect(presence(w, "stremio-ios") == .absent && presence(w, "apollo") == .present)
        }
    }

    @Test("a first install is still planned when the ledger does not say the app is there")
    func firstInstallStaysFirst() async throws {
        // Stremio is not recorded; apollo is, and the read omits it twice.
        let script = DeviceScript(initial: [apolloId: true], snapshotEmpty: [1, 2])
        try await withInstallWorld(
            script: script, ledger: { $0.installs = [installRecord(.apollo)] }
        ) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["reinstall"] == false)
            #expect(warningCodes(out) == ["LEDGER_SNAPSHOT_DISAGREED"])
            #expect(presence(w, "apollo") == .present && presence(w, "stremio-ios") == .present)
        }
    }

    @Test("an app the ledger never recorded that appears during the install still hard-stops")
    func unknownFreeAppStillStops() async throws {
        let script = DeviceScript(
            initial: bothInstalled, snapshotEmpty: [1, 2], alsoAdded: [mystery: true])
        try await withInstallWorld(script: script, ledger: bothRecorded) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["UNEXPECTED_APP_DELTA"])
            #expect(json(out)["addedCount"] == 1 && json(out)["removedCount"] == 0)
            try w.expectClean(out)
        }
    }

    @Test(
        "an omitted app is never marked absent, but an app the read shows is still marked present")
    func settleKeepsPresentAndWritesPositiveEvidence() async throws {
        // Apollo is recorded absent and the device lists it; stremio is recorded present and omitted twice.
        let script = DeviceScript(initial: [apolloId: true], snapshotEmpty: [1, 2])
        try await withInstallWorld(
            script: script,
            ledger: {
                $0.installs = [installRecord(.stremioIOS), installRecord(.apollo, present: false)]
            }
        ) { w in
            // The empty reads hide apollo too, so show it to the settle only from the third read: use the book directly.
            let book = SlotBook(services: w.services, config: try w.config(), alias: "iphone")
            let read = await FreeDeviceCalls(
                services: w.services, alias: "iphone", bundleId: stremioId
            ).trySnapshot(expecting: book.expectedPresent(try await book.loadMigrated()))
            #expect(read.contradictsLedger)
            let listed = AppSnapshot(apps: [apolloId: true])
            _ = try await book.settle(
                listed, takenAt: w.clock.now(), point: "install.settle", trusted: false)
            #expect(presence(w, "stremio-ios") == .present, "an omission never writes absent")
            #expect(presence(w, "apollo") == .present, "evidence the app is there still counts")
        }
    }

    @Test(
        "app remove on a contradicting list stops with SNAPSHOT_FAILED: no uninstall, no ledger change"
    )
    func removeFailsClosed() async throws {
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [1, 2])
        try await withInstallWorld(script: script, ledger: bothRecorded) { w in
            let before = SlotRule.migrated(try w.ledger(), now: w.clock.now())
            let out = await w.remove()
            #expect(out.errorCodes == ["SNAPSHOT_FAILED"] && json(out)["removed"] == false)
            #expect(json(out)["snapshotCheck"]?["resolved"] == false)
            #expect(w.runner.deviceCalls == [infoApps, infoApps])
            #expect(try w.ledger().slots == before.slots && w.ledger().installs == before.installs)
            #expect(w.runner.deviceApps.keys.contains(stremioId))
            try w.expectClean(out)
        }
    }

    @Test(
        "slot lend on a contradicting list stops with SNAPSHOT_FAILED: nothing freed, no uninstall, no ledger change"
    )
    func lendFailsClosed() async throws {
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [1, 2])
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: bothRecorded) {
            w in
            let before = SlotRule.migrated(try w.ledger(), now: w.clock.now())
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["SNAPSHOT_FAILED"] && json(out)["freed"] == 0)
            #expect(w.runner.deviceCalls == [infoApps, infoApps])
            #expect(try w.ledger().slots == before.slots && w.lent.isEmpty)
            #expect(w.runner.deviceApps.keys.contains(stremioId))
        }
    }

    @Test(
        "slot return acts on positive evidence only: the omitted app stays present and is not counted as new"
    )
    func returnKeepsRecords() async throws {
        let script = DeviceScript(initial: bothInstalled)
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: bothRecorded) {
            w in
            let lend = await w.slot("lend", device: "iphone", to: "lab")
            #expect(lend.ok, "\(lend.errors)")
            #expect(w.slotRecord("stremio-ios")?.lentTo == "lab")
            // The return's own reads (1 and 2) omit everything on the device, apollo included.
            var next = w.runner.script
            next.snapshotEmpty = [1, 2]
            w.runner.arm(next)
            let out = await w.slot("return", device: "iphone")
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["reinstalled"] == true)
            #expect(warningCodes(out) == ["LEDGER_SNAPSHOT_DISAGREED"])
            #expect(presence(w, "apollo") == .present && presence(w, "stremio-ios") == .present)
            #expect(w.slotRecord("stremio-ios")?.lentTo == nil)
        }
    }

    @Test("a lent slot is not touched by an install on a contradicting list")
    func lentSlotUnchanged() async throws {
        let script = DeviceScript(initial: bothInstalled)
        try await withInstallWorld(
            app: .apollo, alsoSigned: [.stremioIOS], script: script, lendable: "stremio-ios",
            ledger: bothRecorded
        ) { w in
            let lend = await w.slot("lend", device: "iphone", to: "lab")
            #expect(lend.ok, "\(lend.errors)")
            let lentBefore = w.slotRecord("stremio-ios")
            var next = w.runner.script
            next.snapshotEmpty = [1, 2]
            w.runner.arm(next)
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(w.slotRecord("stremio-ios") == lentBefore)
            #expect(presence(w, "apollo") == .present)
        }
    }

    // MARK: the read after the operation (S1)

    @Test(
        "an install whose list after contradicts the ledger twice is uncertain SNAPSHOT_FAILED, not UNEXPECTED_APP_DELTA: the op stays pending and no app is marked absent"
    )
    func afterReadContradictsInstall() async throws {
        // Reads: 1 = S0 (good), 2 = S1 (empty), 3 = its re-read (empty).
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [2, 3])
        try await withInstallWorld(script: script, ledger: bothRecorded) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["SNAPSHOT_FAILED"], "\(out.errors)")
            #expect(json(out)["uncertain"] == true && json(out)["pending"] == true)
            #expect(json(out)["snapshotCheck"]?["resolved"] == false)
            #expect(w.runner.deviceCalls == [infoApps, installApp, infoApps, infoApps])
            #expect(presence(w, "apollo") == .present)
            #expect(presence(w, "stremio-ios") == .present, "kept pending, never written absent")
            #expect(w.slotRecord("stremio-ios")?.op != nil)
            try w.expectClean(out)
        }
    }

    @Test("an empty list after the install that the re-read corrects is the normal flow")
    func afterReadRereadResolves() async throws {
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [2])
        try await withInstallWorld(script: script, ledger: bothRecorded) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(warningCodes(out).isEmpty)
            #expect(w.runner.deviceCalls == [infoApps, installApp, infoApps, infoApps])
        }
    }

    @Test(
        "an uninstall whose list after contradicts the ledger twice is uncertain: the op stays, no other app is marked absent"
    )
    func afterReadContradictsRemove() async throws {
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [2, 3])
        try await withInstallWorld(script: script, ledger: bothRecorded) { w in
            let out = await w.remove()
            #expect(out.errorCodes == ["UNINSTALL_RESULT_UNCERTAIN"], "\(out.errors)")
            #expect(json(out)["uncertain"] == true && json(out)["removed"] == false)
            #expect(w.runner.deviceCalls == [infoApps, uninstallApp, infoApps, infoApps])
            #expect(presence(w, "apollo") == .present)
            #expect(w.slotRecord("stremio-ios")?.op != nil)
        }
    }

    @Test(
        "a lend whose list after contradicts the ledger twice is uncertain: the lend stays pending, the other app stays present"
    )
    func afterReadContradictsLend() async throws {
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [2, 3])
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: bothRecorded) {
            w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["UNINSTALL_RESULT_UNCERTAIN"], "\(out.errors)")
            #expect(json(out)["uncertain"] == true && json(out)["freed"] == 0)
            #expect(w.runner.deviceCalls == [infoApps, uninstallApp, infoApps, infoApps])
            #expect(presence(w, "apollo") == .present)
            #expect(w.slotRecord("stremio-ios")?.op != nil)
            #expect(w.slotRecord("stremio-ios")?.lentTo == "lab")
        }
    }

    @Test(
        "a return whose list after contradicts the ledger twice is RETURN_FAILED with cause SNAPSHOT_FAILED: still lent, the other app stays present"
    )
    func afterReadContradictsReturn() async throws {
        try await withInstallWorld(
            script: DeviceScript(initial: bothInstalled), lendable: "stremio-ios",
            ledger: bothRecorded
        ) { w in
            let lend = await w.slot("lend", device: "iphone", to: "lab")
            #expect(lend.ok, "\(lend.errors)")
            var next = w.runner.script
            next.snapshotEmpty = [2, 3]
            w.runner.arm(next)
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"], "\(out.errors)")
            #expect(json(out)["cause"] == "SNAPSHOT_FAILED" && json(out)["uncertain"] == true)
            #expect(w.slotRecord("stremio-ios")?.lentTo == "lab")
            #expect(presence(w, "apollo") == .present)
        }
    }

    // MARK: the read itself

    private func reads(
        _ w: InstallWorld, expecting: Set<String>, slow: TimeInterval = 0,
        sleeps: Box<[Duration]> = Box([])
    ) async -> FreeDeviceCalls.SnapshotRead {
        var services = w.services
        let clock = w.clock
        services.runner = DeviceSimRunnerWatch(inner: w.runner) { spec in
            if spec.args.starts(with: ["devicectl", "device", "info", "apps"]) {
                clock.advance(slow)
            }
        }
        services.sleep = { sleeps.value.append($0) }
        return await FreeDeviceCalls(services: services, alias: "iphone", bundleId: stremioId)
            .trySnapshot(expecting: expecting)
    }

    @Test("exactly two reads at most, with the 2 s pause between them through the injected sleep")
    func twoReadsAndThePause() async throws {
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [1, 2, 3])
        try await withInstallWorld(script: script) { w in
            let sleeps = Box<[Duration]>([])
            let read = await reads(w, expecting: [stremioId, apolloId], sleeps: sleeps)
            #expect(read.contradictsLedger)
            #expect(w.runner.deviceCalls == [infoApps, infoApps])
            #expect(sleeps.value == [.seconds(2)])
        }
    }

    @Test("a slow first read (over 10 s) is its own pause: the re-read does not wait")
    func slowFirstReadSkipsThePause() async throws {
        let script = DeviceScript(initial: bothInstalled, snapshotEmpty: [1])
        try await withInstallWorld(script: script) { w in
            let sleeps = Box<[Duration]>([])
            let read = await reads(w, expecting: [stremioId, apolloId], slow: 11, sleeps: sleeps)
            #expect(read.check?.resolved == true && read.snapshot?.ids.count == 2)
            #expect(w.runner.deviceCalls == [infoApps, infoApps])
            #expect(sleeps.value.isEmpty)
        }
    }

    @Test("nothing expected, or a read that shows an expected app: one read, no check")
    func noRereadWhenNothingContradicts() async throws {
        try await withInstallWorld(script: DeviceScript(initial: bothInstalled)) { w in
            let none = await reads(w, expecting: [])
            #expect(none.check == nil && w.runner.deviceCalls == [infoApps])
            let some = await reads(w, expecting: [apolloId, mystery])
            #expect(some.check == nil && w.runner.deviceCalls == [infoApps, infoApps])
        }
    }

    @Test("a failed re-read keeps the first read, flagged")
    func failedRereadKeepsFirst() async throws {
        let script = DeviceScript(
            initial: bothInstalled, snapshotFailures: [2], snapshotEmpty: [1])
        try await withInstallWorld(script: script) { w in
            let read = await reads(w, expecting: [stremioId])
            #expect(read.contradictsLedger && read.snapshot?.ids.isEmpty == true)
        }
    }
}
