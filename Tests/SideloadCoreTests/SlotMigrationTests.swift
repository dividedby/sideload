import Foundation
import Testing

@testable import SideloadCore

// Today's ledger shapes (`installs[]` + `lent[]`, no `slots`) read by the commands of the unified model: migrated under
// `.op.lock` before the gate, written once at point `migrate`, in memory only for `status`; an older build that writes the
// legacy fields afterwards is migrated again; a hand-installed own ID is recorded slot-neutral.

private let past = daysFromNow(-1)

private func strippedState(_ w: InstallWorld) throws {
    // A `lent` record written before the state machine existed: no `state`, no `opAt`.
    let url = URL(fileURLWithPath: w.paths.ledger)
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var entries = try #require(object["lent"] as? [[String: Any]])
    entries[0]["state"] = nil
    entries[0]["opAt"] = nil
    object["lent"] = entries
    try JSONSerialization.data(withJSONObject: object).write(to: url)
}

@Suite("slot model: migration from today's ledger")
struct SlotMigrationTests {
    @Test("a stateless lent record is the fail-safe: pending for one uninstall window from the first run, then settled by a snapshot")
    func statelessLent() async throws {
        let stateless = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: past)
        try await withInstallWorld(
            script: DeviceScript(initial: [stremioId: true, wdaId: true]), lendable: "stremio-ios",
            ledger: { $0.lent = [stateless]; $0.installs = [installRecord(.stremioIOS)] }
        ) { w in
            try strippedState(w)
            let before = try w.ledger()
            #expect(before.slots.isEmpty && before.lent.first?.state == "lending" && before.lent.first?.opAt == nil)

            // status reads the migrated view in memory and writes nothing.
            let status = json(StatusCommand.run(w.services))
            #expect(status["lent"]?.array?.first?["state"] == "lending" && status["lent"]?.array?.first?["holds"] == false)
            #expect(status["warnings"]?.array?.compactMap { $0["code"]?.string } == ["SLOT_STATE_PENDING"])
            let iphone = try #require(status["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" })
            #expect(iphone["used"] == 1 && iphone["pending"] == true && iphone["retryAfter"] == 435)
            #expect(try w.ledger() == before, "status never writes")

            // The first mutating command migrates (once, durably) and is gated for the whole uninstall window.
            let first = await w.slot("lend", device: "iphone", to: "lab")
            #expect(first.errorCodes == ["SLOT_PENDING"] && json(first)["retryAfter"] == 435 && json(first)["state"] == "lending")
            #expect(w.runner.calls.isEmpty, "no device call")
            let migrated = try #require(w.slotRecord())
            #expect(migrated.presence == .unknown && migrated.op?.kind == .uninstall && migrated.op?.startedAt == testNow && migrated.lentTo == "lab")

            // The window does not slide: a later run counts down from the first.
            w.clock.advance(100)
            let second = await w.slot("return", device: "iphone")
            #expect(second.errorCodes == ["SLOT_PENDING"] && json(second)["retryAfter"] == 335)
            #expect(try w.ledger().slots == [migrated], "the second run changed nothing")

            // After the window a snapshot decides: the app is on the device, so the lend runs afresh.
            w.clock.advance(336)
            let settled = await w.slot("lend", device: "iphone", to: "lab")
            #expect(settled.ok && json(settled)["freed"] == 1 && json(settled)["alreadyLent"] == nil, "\(settled.errors)")
            #expect(w.phase == .lent && w.runner.deviceApps[stremioId] == nil)
            try expectSlotModel(w, eventually: true)
        }
    }

    @Test("legacy lending and returning records with an opAt keep their own window; one whose window is over settles at once")
    func legacyPendingWithOpAt() async throws {
        let recent = testNow.addingTimeInterval(-60)
        for (state, window) in [("lending", 435.0), ("returning", 645.0)] {
            let lent = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: past, state: state, opAt: recent)
            try await withInstallWorld(script: DeviceScript(initial: [wdaId: true]), lendable: "stremio-ios", ledger: { $0.lent = [lent] }) { w in
                let early = await w.slot("lend", device: "iphone", to: "lab")
                #expect(early.errorCodes == ["SLOT_PENDING"] && json(early)["retryAfter"] == .number(window - 60), "\(state)")
                w.clock.advance(window - 60)
                let settled = await w.slot("lend", device: "iphone", to: "lab")
                #expect(settled.ok && json(settled)["alreadyLent"] == (state == "returning" ? true : nil), "\(state): \(settled.errors)")
                #expect(w.phase == .lent)
            }
        }
    }

    @Test("a legacy installs[] entry with an opAt is a reinstall op: remove is gated until its window ends, and present is preserved")
    func legacyInstallOpAt() async throws {
        var uncertain = installRecord(.stremioIOS)
        uncertain.opAt = testNow.addingTimeInterval(-100)
        try await withInstallWorld(script: DeviceScript(initial: [wdaId: true]), ledger: { $0.installs = [uncertain] }) { w in
            let out = await w.remove()
            #expect(out.errorCodes == ["SLOT_PENDING"] && json(out)["retryAfter"] == 545 && json(out)["op"] == "reinstall")
            #expect(w.installs.first?.present == true && w.installs.first?.opAt == testNow.addingTimeInterval(-100))
            #expect(w.slotRecord()?.op?.kind == .reinstall && w.runner.calls.isEmpty)
            w.clock.advance(546)
            let later = await w.remove()
            #expect(later.ok && json(later)["removed"] == false, "the app never landed: \(later.errors)")
            #expect(w.slotRecord()?.presence == .absent && w.installs.first?.present == false)
        }
    }

    @Test("a legacy installs[] entry with present:false and an opAt is pending too: used until its window passes, never free on a guess")
    func legacyAbsentWithOpAt() async throws {
        var odd = installRecord(.stremioIOS, present: false)
        odd.opAt = testNow.addingTimeInterval(-100)
        try await withInstallWorld(script: DeviceScript(initial: [stremioId: true, wdaId: true]), lendable: "stremio-ios", ledger: { $0.installs = [odd] }) { w in
            let status = json(StatusCommand.run(w.services))
            let iphone = try #require(status["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" })
            #expect(iphone["used"] == 1 && iphone["pending"] == true && iphone["apps"] == ["stremio-ios"], "status reads it as used")
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(out.errorCodes == ["SLOT_PENDING"] && json(out)["retryAfter"] == 545 && json(out)["op"] == "reinstall")
            let slot = try #require(w.slotRecord())
            #expect(slot.presence == .unknown && slot.op?.kind == .reinstall && slot.op?.startedAt == odd.opAt)
            #expect(w.installs.first?.present == true, "the projection reads present while an op is open")
            w.clock.advance(546)
            let settled = await w.slot("lend", device: "iphone", to: "lab")
            #expect(settled.ok && json(settled)["freed"] == 1, "the snapshot after the window decides: \(settled.errors)")
        }
    }

    @Test("an older build that writes installs[] or lent[] after the projection is migrated again by the next command")
    func olderBuildWrites() async throws {
        try await withInstallWorld(
            script: DeviceScript(initial: [wdaId: true]), lendable: "stremio-ios",
            ledger: { $0.lent = [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: past, state: "lent")]; $0.installs = [installRecord(.stremioIOS, present: false)] }
        ) { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").ok, "migrates; already lent")
            #expect(w.slotRecord()?.lentTo == "lab")
            // The older build returned the slot (it knows nothing of `slots`): the lend record is gone, the app present.
            try await w.services.ledgerStore.update { ledger in
                ledger.lent = []
                ledger.installs[0].present = true
            }
            w.runner.setApp(stremioId, true)
            let out = await w.slot("return", device: "iphone")
            #expect(out.ok && json(out)["nothingLent"] == true, "the older build's removal of the record wins: \(out.errors)")
            #expect(w.slotRecord()?.lentTo == nil && w.slotRecord()?.presence == .present)
            try expectSlotModel(w, eventually: true)
        }
    }

    @Test("a lent or pending slot with no installs[] or lent[] left is kept as used; an idle one never counts")
    func orphanSlots() {
        var lent = LedgerSlot(device: "iphone", app: "stremio-ios", presence: .absent)
        lent.lentTo = "lab"
        lent.since = past
        var idle = LedgerSlot(device: "iphone", app: "apollo", presence: .absent)
        idle.lentTo = nil
        var ledger = Ledger()
        ledger.slots = [lent, idle]
        let kept = SlotRule.reconcile(ledger, now: testNow)
        #expect(kept.contains { $0.id == lent.id && $0.lentTo == "lab" }, "the lent orphan survives")
        #expect(SlotRule.view(SlotRule.migrated(ledger, now: testNow), alias: "iphone", now: testNow).used == 1)
    }

    @Test("a hand-installed own ID is a recorded reinstall: slot-neutral on a full device, and then recorded present")
    func handInstalledOwnId() async throws {
        // 3 of 3 slots: the app itself, apollo and WebDriverAgent. Nothing is recorded for the app.
        try await withInstallWorld(
            script: DeviceScript(initial: [stremioId: true, apolloId: true, wdaId: true]), ledger: { $0.installs = [] }
        ) { w in
            let out = await w.install()
            #expect(out.ok && json(out)["reinstall"] == true && json(out)["slots"]?["used"] == 3, "\(out.errors)")
            #expect(w.slotRecord()?.presence == .present && w.slotRecord()?.op == nil)
            #expect(w.installs.first { $0.id == w.key }?.present == true)
            try expectSlotModel(w, eventually: true)
        }
        // A new app on the same full device is refused before anything is written to the device.
        try await withInstallWorld(
            script: DeviceScript(initial: [apolloId: true, sideStoreId: true, wdaId: true]), ledger: { $0.installs = [] }
        ) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"] && w.runner.installCalls.isEmpty)
            #expect(w.slotRecord() == nil, "refused before the intent")
        }
    }

    @Test("a lent slot counts toward the install preflight even though its app is gone")
    func lentCountsInPreflight() async throws {
        let lent = LedgerLent(app: "apollo", device: "iphone", to: "lab", since: past, state: "lent")
        try await withInstallWorld(script: DeviceScript(initial: [atvloadlyId: true, sideStoreId: true]), ledger: { $0.lent = [lent]; $0.installs = [] }) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"] && json(out)["slots"]?["lent"] == 1 && json(out)["slots"]?["used"] == 3)
            #expect(w.runner.installCalls.isEmpty)
        }
    }

    @Test("a ledger that never used the free team is byte-identical: no slots key, and no migrate write")
    func untouchedLedger() async throws {
        try await withInstallWorld(script: DeviceScript(initial: [wdaId: true]), lendable: "stremio-ios", ledger: { $0.freeSigned = [] }) { w in
            let before = try Data(contentsOf: URL(fileURLWithPath: w.paths.ledger))
            let out = await w.slot("return", device: "iphone")
            #expect(out.ok && json(out)["nothingLent"] == true)
            #expect(try Data(contentsOf: URL(fileURLWithPath: w.paths.ledger)) == before)
        }
    }
}
