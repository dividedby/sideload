import Foundation
import Testing

@testable import SideloadCore

// The pure core of the unified pending-operation model: the 27-cell table, rule (i) at its boundary, the migration of every
// legacy shape, the projection, and the view. No device, no commands.

private let t0 = testNow

private func op(_ kind: LedgerSlotKind, by: LedgerSlotBy = .install, at: Date = t0, window: Int? = nil) -> LedgerSlotOp {
    LedgerSlotOp(kind: kind, by: by, startedAt: at, window: window ?? SlotRule.window(kind))
}

private func slot(
    _ app: String = "stremio-ios", presence: LedgerSlotPresence, lentTo: String? = nil, op: LedgerSlotOp? = nil, since: Date? = nil
) -> LedgerSlot {
    LedgerSlot(device: "iphone", app: app, presence: presence, lentTo: lentTo, since: lentTo == nil ? nil : (since ?? t0), op: op)
}

@Suite("slot rule: the table, rule (i), migration and projection")
struct SlotRuleTests {
    // MARK: the 27 cells

    @Test("the table has exactly the 27 cells of the design, and confirm() returns each one")
    func twentySevenCells() {
        #expect(designCells.count == 27)
        #expect(Set(designCells.map { "\($0.cell.kind)/\($0.cell.result)/\($0.cell.s1)" }).count == 27)
        for row in designCells {
            let got = SlotRule.confirm(row.cell.kind, row.cell.result, row.cell.s1)
            #expect(got.effect == row.effect, "\(row.cell): effect \(got.effect), design \(row.effect)")
            #expect(got.note == row.note, "\(row.cell): note \(String(describing: got.note)), design \(String(describing: row.note))")
        }
    }

    @Test("an unreadable S1 never settles anything, and a reinstall is never settled by presence alone")
    func structuralProperties() {
        for kind in [LedgerSlotKind.install, .reinstall, .uninstall] {
            for result in SlotRule.Result.allCases {
                #expect(SlotRule.confirm(kind, result, .unreadable).effect == .keep)
            }
        }
        // Reaching the target state is monotone: an unknown result still settles an install at present and an uninstall at absent.
        #expect(SlotRule.confirm(.install, .unknown, .present).effect == .present)
        #expect(SlotRule.confirm(.uninstall, .unknown, .absent).effect == .absent)
        // A reinstall's target equals its start state: only a definite result settles it.
        for s1 in SlotRule.Reading.allCases { #expect(SlotRule.confirm(.reinstall, .unknown, s1).effect == .keep) }
        #expect(SlotRule.confirm(.reinstall, .success, .present).effect == .present)
        #expect(SlotRule.confirm(.reinstall, .failure, .present).effect == .present)
    }

    @Test("apply: present clears op and lentTo, absent keeps lentTo, keep changes nothing")
    func applyEffects() {
        let lending = slot(presence: .present, lentTo: "lab", op: op(.uninstall, by: .lend))
        let present = SlotRule.apply(.present, to: lending, at: t0)
        #expect(present.presence == .present && present.op == nil && present.lentTo == nil && present.since == nil)
        let absent = SlotRule.apply(.absent, to: lending, at: t0)
        #expect(absent.presence == .absent && absent.op == nil && absent.lentTo == "lab" && SlotRule.holds(absent))
        #expect(SlotRule.apply(.keep, to: lending, at: t0) == lending)
    }

    // MARK: rule (i)

    @Test("windows: 645 s for an install or reinstall, 435 s for an uninstall; the effective window is max(stored, current)")
    func windows() {
        #expect(SlotRule.window(.install) == 645 && SlotRule.window(.reinstall) == 645 && SlotRule.window(.uninstall) == 435)
        #expect(SlotRule.effectiveWindow(op(.install, window: 10)) == 645, "a stored window that is too short is raised")
        #expect(SlotRule.effectiveWindow(op(.install, window: 9999)) == 9999, "a longer stored window is kept")
    }

    @Test("rule (i) at the boundary: takenAt = end - 1 keeps the op, takenAt = end settles it from the snapshot")
    func boundary() {
        for kind in [LedgerSlotKind.install, .reinstall, .uninstall] {
            let pending = slot(presence: .unknown, lentTo: "lab", op: op(kind, by: kind == .uninstall ? .lend : .giveBack))
            let end = SlotRule.end(of: pending.op!)
            #expect(end == t0.addingTimeInterval(Double(SlotRule.window(kind))))
            #expect(SlotRule.settle(pending, present: true, takenAt: end.addingTimeInterval(-1)) == pending, "\(kind): inside the window")
            #expect(SlotRule.settle(pending, present: false, takenAt: end.addingTimeInterval(-0.001)) == pending)
            let present = SlotRule.settle(pending, present: true, takenAt: end)
            #expect(present.op == nil && present.presence == .present && present.lentTo == nil, "\(kind): at the end, present")
            let absent = SlotRule.settle(pending, present: false, takenAt: end)
            #expect(absent.op == nil && absent.presence == .absent && absent.lentTo == "lab" && SlotRule.holds(absent), "\(kind): at the end, absent")
            #expect(SlotRule.remaining(pending.op!, now: end.addingTimeInterval(-1)) == 1)
            #expect(SlotRule.remaining(pending.op!, now: end) == nil)
            #expect(SlotRule.remaining(pending.op!, now: t0.addingTimeInterval(-5000)) == SlotRule.window(kind), "a clock moved back cannot extend it")
        }
    }

    @Test("a record with no op takes its presence from the snapshot, and a present app clears a lend (I4)")
    func noOpFollowsSnapshot() {
        let plain = slot(presence: .present)
        #expect(SlotRule.settle(plain, present: false, takenAt: t0).presence == .absent)
        let lent = slot(presence: .absent, lentTo: "lab")
        #expect(SlotRule.settle(lent, present: false, takenAt: t0) == lent, "unchanged evidence changes nothing (no write)")
        let taken = SlotRule.settle(lent, present: true, takenAt: t0)
        #expect(taken.lentTo == nil && taken.presence == .present)
    }

    @Test("used and holds: pending or lent counts as used, never free")
    func usedAndHolds() {
        #expect(!SlotRule.used(slot(presence: .absent)))
        #expect(SlotRule.used(slot(presence: .absent, lentTo: "lab")))
        #expect(SlotRule.used(slot(presence: .absent, op: op(.install))), "an install in flight is used though the app is absent")
        #expect(SlotRule.used(slot(presence: .unknown, op: op(.uninstall))))
        #expect(SlotRule.used(slot(presence: .present)))
        #expect(SlotRule.holds(slot(presence: .absent, lentTo: "lab")))
        #expect(!SlotRule.holds(slot(presence: .absent, lentTo: "lab", op: op(.install, by: .giveBack))))
        #expect(!SlotRule.holds(slot(presence: .present, lentTo: "lab")))
    }

    // MARK: projection

    @Test("project: lent[] and installs[].present/opAt are derived from the slots (I8)")
    func projection() {
        var ledger = Ledger()
        ledger.installs = [installRecord(.stremioIOS, present: false), installRecord(.apollo, present: true)]
        let returning = slot(presence: .absent, lentTo: "lab", op: op(.install, by: .giveBack))
        let lending = slot("apollo", presence: .present, lentTo: "lab", op: op(.uninstall, by: .lend))
        ledger.slots = [returning, lending]
        SlotRule.project(&ledger)
        #expect(ledger.lent.map(\.state) == ["lending", "returning"], "sorted by app: apollo, stremio-ios")
        #expect(ledger.lent.map(\.opAt) == [t0, t0])
        #expect(ledger.installs.first { $0.app == "stremio-ios" }?.present == true, "an op in flight reads present")
        #expect(ledger.installs.first { $0.app == "stremio-ios" }?.opAt == t0)
        ledger.slots = [slot(presence: .absent, lentTo: "lab"), slot("apollo", presence: .absent)]
        SlotRule.project(&ledger)
        #expect(ledger.lent.map(\.state) == ["lent"] && ledger.lent.first?.opAt == nil)
        #expect(ledger.installs.map(\.present) == [false, false] && ledger.installs.allSatisfy { $0.opAt == nil })
    }

    @Test("the legacy state word of a slot: lent only when nothing is in flight and the app is absent; install or reinstall is returning")
    func phaseWords() {
        #expect(SlotRule.phase(slot(presence: .present)) == .none)
        #expect(SlotRule.phase(slot(presence: .absent, lentTo: "lab")) == .lent)
        #expect(SlotRule.phase(slot(presence: .absent, lentTo: "lab", op: op(.install, by: .giveBack))) == .returning)
        #expect(SlotRule.phase(slot(presence: .present, lentTo: "lab", op: op(.reinstall))) == .returning)
        #expect(SlotRule.phase(slot(presence: .present, lentTo: "lab", op: op(.uninstall, by: .lend))) == .lending)
    }

    // MARK: migration (each legacy row)

    private func migrated(installs: [LedgerInstall] = [], lent: [LedgerLent] = [], now: Date = t0.addingTimeInterval(50_000)) -> Ledger {
        SlotRule.migrated(Ledger(installs: installs, lent: lent), now: now)
    }

    @Test("migration: lent{lent} is absent + lentTo, no op")
    func migrateLent() throws {
        let ledger = migrated(lent: [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: t0, state: "lent")])
        let s = try #require(ledger.slots.first)
        #expect(s.presence == .absent && s.lentTo == "lab" && s.since == t0 && s.op == nil && SlotRule.holds(s))
        #expect(ledger.lent.map(\.state) == ["lent"])
    }

    @Test("migration: lent{lending, opAt} is unknown + an uninstall op at opAt; lent{returning, opAt} an install op at opAt")
    func migratePending() {
        let opAt = t0.addingTimeInterval(100)
        let lending = migrated(lent: [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: t0, state: "lending", opAt: opAt)])
        #expect(lending.slots.first?.presence == .unknown && lending.slots.first?.op?.kind == .uninstall)
        #expect(lending.slots.first?.op?.startedAt == opAt && lending.slots.first?.op?.window == 435)
        let returning = migrated(lent: [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: t0, state: "returning", opAt: opAt)])
        #expect(returning.slots.first?.op?.kind == .install && returning.slots.first?.op?.startedAt == opAt && returning.slots.first?.op?.window == 645)
        #expect(returning.lent.map(\.state) == ["returning"] && lending.lent.map(\.state) == ["lending"])
    }

    @Test("migration: a stateless lent, a pending one with no opAt, or an unknown state is an uninstall op at now (fail-safe)")
    func migrateFailSafe() throws {
        let now = t0.addingTimeInterval(1234)
        let raw = Data(#"{"app":"stremio-ios","device":"iphone","to":"lab","since":"2026-10-20T00:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stateless = try decoder.decode(LedgerLent.self, from: raw)
        #expect(stateless.state == "lending" && stateless.opAt == nil)
        let cases: [LedgerLent] = [
            stateless,
            LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: t0, state: "lending"),
            LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: t0, state: "sideways", opAt: t0),
        ]
        for lent in cases {
            let ledger = migrated(lent: [lent], now: now)
            let s = try #require(ledger.slots.first, "\(lent.state)")
            #expect(s.presence == .unknown && s.lentTo == "lab" && s.op?.kind == .uninstall && s.op?.startedAt == now, "\(lent.state)")
            // A single wait of up to the uninstall window, then it settles from a snapshot.
            let end = SlotRule.end(of: s.op!)
            #expect(end == now.addingTimeInterval(435))
        }
    }

    @Test("migration: installs{present, opAt} is present + a reinstall op (the strictest kind); installs{present} is present; absent is absent")
    func migrateInstalls() {
        let opAt = t0.addingTimeInterval(7)
        var withOp = installRecord(.stremioIOS)
        withOp.opAt = opAt
        let a = migrated(installs: [withOp])
        #expect(a.slots.first?.presence == .present && a.slots.first?.op?.kind == .reinstall && a.slots.first?.op?.startedAt == opAt)
        #expect(a.slots.first?.op?.by == .install && a.slots.first?.op?.window == 645)
        let b = migrated(installs: [installRecord(.stremioIOS)])
        #expect(b.slots.first?.presence == .present && b.slots.first?.op == nil && b.slots.first?.lentTo == nil)
        let c = migrated(installs: [installRecord(.stremioIOS, present: false)])
        #expect(c.slots.first?.presence == .absent && c.slots.first?.op == nil && !SlotRule.used(c.slots[0]))
        // present:false with an opAt is pending (an operation may be in flight): unknown, a reinstall op, used.
        var pendingAbsent = installRecord(.stremioIOS, present: false)
        pendingAbsent.opAt = opAt
        let d = migrated(installs: [pendingAbsent])
        #expect(d.slots.first?.presence == .unknown && d.slots.first?.op?.kind == .reinstall && d.slots.first?.op?.startedAt == opAt)
        #expect(d.slots.first.map(SlotRule.used) == true)
    }

    @Test("migration: a lend record wins over an installs entry for the same app, and the installs entry is projected from it")
    func migrateBoth() {
        let ledger = migrated(
            installs: [installRecord(.stremioIOS, present: false)],
            lent: [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: t0, state: "lent")])
        #expect(ledger.slots.count == 1 && SlotRule.holds(ledger.slots[0]))
        #expect(ledger.installs.first?.present == false)
        let pending = migrated(
            installs: [installRecord(.stremioIOS, present: true)],
            lent: [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: t0, state: "lending", opAt: t0)])
        #expect(pending.installs.first?.present == true && pending.installs.first?.opAt == t0)
    }

    @Test("migration is idempotent and writes nothing for a ledger that never used the free team")
    func migrationIdempotent() {
        #expect(!SlotRule.needsMigration(Ledger(), now: t0))
        let legacy = Ledger(installs: [installRecord(.stremioIOS)], lent: [LedgerLent(app: "apollo", device: "iphone", to: "lab", since: t0, state: "lent")])
        #expect(SlotRule.needsMigration(legacy, now: t0))
        let once = SlotRule.migrated(legacy, now: t0)
        #expect(!SlotRule.needsMigration(once, now: t0.addingTimeInterval(10_000)), "a second pass changes nothing, so an @now record does not slide")
        #expect(SlotRule.migrated(once, now: t0.addingTimeInterval(10_000)) == once)
    }

    @Test("an older build that wrote installs[] or lent[] after the projection is migrated again, key by key")
    func olderBuildWrites() throws {
        var ledger = SlotRule.migrated(
            Ledger(
                installs: [installRecord(.stremioIOS), installRecord(.apollo)],
                lent: [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: t0, state: "lent")]),
            now: t0)
        #expect(!SlotRule.needsMigration(ledger, now: t0))
        // The older build returned the slot (removed the lend record) and marked apollo absent.
        ledger.lent = []
        ledger.installs = ledger.installs.map { var i = $0; if i.app == "apollo" { i.present = false }; return i }
        #expect(SlotRule.needsMigration(ledger, now: t0))
        let again = SlotRule.migrated(ledger, now: t0)
        let stremio = try #require(again.slots.first { $0.app == "stremio-ios" })
        let apollo = try #require(again.slots.first { $0.app == "apollo" })
        #expect(stremio.lentTo == nil, "the older build's removal of the lend record wins")
        #expect(apollo.presence == .absent, "and its presence")
        #expect(again.lent.isEmpty)
    }

    // MARK: view

    @Test("view: every used record counts, a pending or lent one is never free, retryAfter is the last open window")
    func view() {
        var ledger = Ledger()
        ledger.slots = [
            slot("stremio-ios", presence: .absent, lentTo: "lab", op: op(.install, by: .giveBack)),
            slot("apollo", presence: .present),
            slot("stremio-tvos", presence: .absent),
        ]
        SlotRule.project(&ledger)
        let now = t0.addingTimeInterval(100)
        let v = SlotRule.view(ledger, alias: "iphone", now: now)
        #expect(v.used == 2 && v.apps == ["apollo"] && v.app == "stremio-ios" && v.state == .returning)
        #expect(v.pending && !v.holds && v.retryAfter == 545)
        let quiet = SlotRule.view(ledger, alias: "iphone", now: t0.addingTimeInterval(10_000))
        #expect(quiet.pending && quiet.retryAfter == nil, "an unsettled op past its window is still pending, with nothing to wait for")
        #expect(SlotRule.view(ledger, alias: "appletv", now: now) == SlotRule.View(state: .none, app: nil, holds: false, pending: false, retryAfter: nil, used: 0, apps: []))
    }

    // MARK: the ledger file

    @Test("slots round-trip through ledger.json, unknown enum values read as the safe side, and an empty list is not written")
    func codec() throws {
        var ledger = Ledger()
        #expect(!String(decoding: try LedgerStore.encode(ledger), as: UTF8.self).contains("\"slots\""), "byte-identical for a ledger that never used the free team")
        ledger.slots = [slot(presence: .absent, lentTo: "lab", op: op(.reinstall, by: .giveBack)), slot("apollo", presence: .present)]
        let data = try LedgerStore.encode(ledger)
        #expect(try LedgerStore.parse(data) == ledger)

        let odd = #"""
        {"id":"iphone/x","device":"iphone","app":"x","presence":"sideways","op":{"kind":"mystery","by":"?","startedAt":"2026-10-20T00:00:00Z","window":5}}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LedgerSlot.self, from: Data(odd.utf8))
        #expect(decoded.presence == .unknown, "unknown presence reads as unknown")
        #expect(decoded.op?.kind == .reinstall, "an unknown kind reads as the strictest: only a definite result settles it")
        #expect(SlotRule.effectiveWindow(decoded.op!) == 645, "and its window is raised")
    }
}
