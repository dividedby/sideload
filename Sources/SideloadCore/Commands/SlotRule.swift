import Foundation

// The pure core of the unified pending-operation model (docs/design.md section 18). No I/O, no clock reads: every
// function takes the time it needs. `SlotBook` does the ledger and device work around it.
//
// One record per `<device>/<app>` (`LedgerSlot`): presence, who it is lent to, and the device operation that may still be
// in flight. One evidence rule settles it:
//  (i)  a valid snapshot whose `takenAt` is at or after `op.startedAt + window` settles the record (presence comes from
//       the snapshot and the op is cleared);
//  (ii) inside the window, only the snapshot taken in the same run right after the op settles it, and only through
//       `confirm`, the 27-cell table of (op kind x op result x that snapshot).
// The legacy `installs[].present/opAt` and `lent[]` are a projection of the slots, rewritten on every write.

enum SlotRule {
    typealias Kind = LedgerSlotKind

    /// What the device call itself reported. `unknown` is `FreeDeviceCalls.uncertain`: the runner's kill, devicectl's own
    /// timeout, an output overflow, a signal kill, a thrown call, or an exit 0 that does not name the bundle. A spawn error
    /// never ran anything, so it is a definite `failure`.
    enum Result: Sendable, Equatable, CaseIterable {
        case success, failure, unknown
    }

    /// What the snapshot taken right after the op shows about the app.
    enum Reading: Sendable, Equatable, CaseIterable {
        case present, absent, unreadable

        init(_ snapshot: AppSnapshot?, bundleId: String) {
            guard let snapshot else { self = .unreadable; return }
            self = snapshot.ids.contains(bundleId) ? .present : .absent
        }
    }

    /// What a confirmation does to the record: presence becomes present or absent (and the op is cleared), or the record is
    /// kept (the op and its `startedAt` stay, so the window keeps running).
    enum Effect: Sendable, Equatable {
        case present, absent, keep
    }

    /// What the table says besides the effect; the command turns it into its own code or warning.
    enum Note: Sendable, Equatable {
        case installUnconfirmed, installResultUncertain, unexpectedAppDelta, uninstallResultUncertain
    }

    struct Confirmation: Sendable, Equatable {
        let effect: Effect
        let note: Note?
    }

    // MARK: the 27-cell table

    /// Rule (ii). Reaching the op's target state is monotone for an install (present) and an uninstall (absent): nothing left
    /// in flight can undo it, so the target state settles the op even when its result is unknown. A reinstall's target equals
    /// its start state, so only a definite result settles it. An unreadable snapshot never settles anything.
    static func confirm(_ kind: Kind, _ result: Result, _ s1: Reading) -> Confirmation {
        func c(_ effect: Effect, _ note: Note? = nil) -> Confirmation { Confirmation(effect: effect, note: note) }
        if s1 == .unreadable { return c(.keep) }
        let present = s1 == .present
        switch (kind, result) {
        case (.install, .success): return present ? c(.present) : c(.keep, .installUnconfirmed)
        case (.install, .failure): return present ? c(.present, .installResultUncertain) : c(.absent)
        case (.install, .unknown): return present ? c(.present) : c(.keep)
        case (.reinstall, .success): return present ? c(.present) : c(.keep, .unexpectedAppDelta)
        case (.reinstall, .failure): return present ? c(.present) : c(.absent, .unexpectedAppDelta)
        case (.reinstall, .unknown): return c(.keep)
        case (.uninstall, .success): return present ? c(.keep, .unexpectedAppDelta) : c(.absent)
        case (.uninstall, .failure): return present ? c(.present) : c(.absent, .uninstallResultUncertain)
        case (.uninstall, .unknown): return present ? c(.keep) : c(.absent)
        }
    }

    // MARK: windows

    /// The longest the op can run plus the settle grace, in whole seconds: 645 for an install or reinstall, 435 for an
    /// uninstall.
    static func window(_ kind: Kind) -> Int {
        Int((SlotState.maxDuration(kind == .uninstall ? .uninstall : .install) + SlotState.settleGrace).rounded(.up))
    }

    /// The window actually used: `max(stored, current)`, so changed constants never shorten a pending record.
    static func effectiveWindow(_ op: LedgerSlotOp) -> TimeInterval { TimeInterval(max(op.window, window(op.kind))) }

    static func end(of op: LedgerSlotOp) -> Date { op.startedAt.addingTimeInterval(effectiveWindow(op)) }

    /// Whole seconds until the op's window ends, nil when it is over.
    static func remaining(_ op: LedgerSlotOp, now: Date) -> Int? {
        SlotState.remaining(window: effectiveWindow(op), opAt: op.startedAt, now: now)
    }

    static func newOp(_ kind: Kind, by: LedgerSlotBy, at: Date) -> LedgerSlotOp {
        LedgerSlotOp(kind: kind, by: by, startedAt: SlotState.wholeSecondsUp(at), window: window(kind))
    }

    // MARK: settling

    /// Rule (i), and the presence of a record with no op: a valid snapshot taken at `takenAt` says whether the app is there.
    /// A record whose op is still inside its window is returned as it is. A present app clears `lentTo` (I4: a record that
    /// is lent and has no op has the app absent).
    static func settle(_ slot: LedgerSlot, present: Bool, takenAt: Date) -> LedgerSlot {
        if let op = slot.op, takenAt < end(of: op) { return slot }
        var next = slot
        next.op = nil
        next.presence = present ? .present : .absent
        if present {
            next.lentTo = nil
            next.since = nil
        }
        if next != slot { next.seenAt = wholeSeconds(takenAt) }
        return next
    }

    /// Rule (ii): the effect of a confirmation. `keep` leaves the record untouched.
    static func apply(_ effect: Effect, to slot: LedgerSlot, at takenAt: Date) -> LedgerSlot {
        var next = slot
        switch effect {
        case .keep: return slot
        case .present:
            next.presence = .present
            next.lentTo = nil
            next.since = nil
        case .absent:
            next.presence = .absent
        }
        next.op = nil
        next.seenAt = wholeSeconds(takenAt)
        return next
    }

    // MARK: derived values

    /// The slot counts as used unless the app is known absent, nothing is in flight and it is not lent.
    static func used(_ slot: LedgerSlot) -> Bool { !(slot.presence == .absent && slot.op == nil && slot.lentTo == nil) }

    /// The lab holds the slot: lent, nothing in flight, and the app known absent.
    static func holds(_ slot: LedgerSlot) -> Bool { slot.lentTo != nil && slot.op == nil && slot.presence == .absent }

    static func phase(_ slot: LedgerSlot) -> SlotPhase {
        guard slot.lentTo != nil else { return .none }
        if holds(slot) { return .lent }
        if let op = slot.op, op.kind == .install || op.kind == .reinstall { return .returning }
        return .lending
    }

    /// What the legacy `installs[].present` reads: present, unknown or any op in flight all read present.
    static func legacyPresent(_ slot: LedgerSlot) -> Bool { slot.presence != .absent || slot.op != nil }

    // MARK: projection

    /// The legacy `lent[]` entry of a slot: nil unless it is lent.
    static func lentEntry(_ slot: LedgerSlot) -> LedgerLent? {
        guard let to = slot.lentTo else { return nil }
        return LedgerLent(
            app: slot.app, device: slot.device, to: to, since: slot.since ?? slot.op?.startedAt ?? Date(timeIntervalSince1970: 0),
            state: phase(slot).rawValue, opAt: slot.op?.startedAt)
    }

    /// Rewrites `lent[]` and every `installs[]` entry's `present`/`opAt` from `slots` (I8).
    static func project(_ ledger: inout Ledger) {
        ledger.slots.sort { $0.id < $1.id }
        ledger.lent = ledger.slots.compactMap(lentEntry).sorted { ($0.device, $0.app) < ($1.device, $1.app) }
        for i in ledger.installs.indices {
            guard let slot = ledger.slots.first(where: { $0.id == ledger.installs[i].id }) else { continue }
            ledger.installs[i].present = legacyPresent(slot)
            ledger.installs[i].opAt = slot.op?.startedAt
        }
    }

    /// Whether the legacy fields on disk already equal the projection of this slot.
    private static func agrees(_ slot: LedgerSlot, install: LedgerInstall?, lent: LedgerLent?) -> Bool {
        if let install, install.present != legacyPresent(slot) || !sameSecond(install.opAt, slot.op?.startedAt) { return false }
        guard let expected = lentEntry(slot) else { return lent == nil }
        guard let lent else { return false }
        return lent.to == expected.to && lent.state == expected.state && sameSecond(lent.since, expected.since)
            && sameSecond(lent.opAt, expected.opAt)
    }

    private static func sameSecond(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): a.timeIntervalSince1970.rounded() == b.timeIntervalSince1970.rounded()
        default: false
        }
    }

    // MARK: migration

    /// The slot a legacy record stands for (docs/design.md section 18). `now` stands in for a pending record with no `opAt`
    /// (fail-safe: a single wait of up to a window).
    static func migrate(install: LedgerInstall?, lent: LedgerLent?, device: String, app: String, now: Date) -> LedgerSlot {
        if let lent {
            func pending(_ kind: Kind, by: LedgerSlotBy, at: Date) -> LedgerSlot {
                LedgerSlot(
                    device: device, app: app, presence: .unknown, lentTo: lent.to, since: lent.since,
                    op: LedgerSlotOp(kind: kind, by: by, startedAt: wholeSecondsUp(at), window: window(kind)))
            }
            switch lent.state {
            case LedgerLent.lent:
                return LedgerSlot(device: device, app: app, presence: .absent, lentTo: lent.to, since: lent.since)
            case LedgerLent.returning: return pending(.install, by: .giveBack, at: lent.opAt ?? now)
            // `lending` (a stateless record decodes as `lending`): a missing `opAt` is the fail-safe `now`.
            case LedgerLent.lending: return pending(.uninstall, by: .lend, at: lent.opAt ?? now)
            // A state this build does not know: pending from now, so a single wait of up to a window.
            default: return pending(.uninstall, by: .lend, at: now)
            }
        }
        guard let install else { return LedgerSlot(device: device, app: app, presence: .absent) }
        // The strictest kind: a reinstall is settled only by a definite result or the window. An `opAt` marks an operation that
        // may be in flight whatever `present` says, so `present:false` with an `opAt` is pending too (presence unknown), never
        // free until a snapshot after the window decides.
        let op = install.opAt.map { LedgerSlotOp(kind: .reinstall, by: .install, startedAt: wholeSecondsUp($0), window: window(.reinstall)) }
        guard install.present || op != nil else { return LedgerSlot(device: device, app: app, presence: .absent) }
        return LedgerSlot(device: device, app: app, presence: install.present ? .present : .unknown, op: op)
    }

    private static func wholeSecondsUp(_ date: Date) -> Date { SlotState.wholeSecondsUp(date) }

    /// The slots of a ledger after migration: a slot whose projection agrees with the legacy fields on disk is kept; any
    /// other key (no slot yet, or an older build wrote `installs`/`lent` since) is rebuilt from the legacy fields. Unchanged
    /// for a ledger that never used the free team.
    static func reconcile(_ ledger: Ledger, now: Date) -> [LedgerSlot] {
        var keys = Set(ledger.slots.map(\.id))
        keys.formUnion(ledger.installs.map(\.id))
        for lent in ledger.lent { keys.insert("\(lent.device)/\(lent.app)") }
        var out: [LedgerSlot] = []
        for key in keys.sorted() {
            let install = ledger.installs.first { $0.id == key }
            let lent = ledger.lent.first { "\($0.device)/\($0.app)" == key }
            if let slot = ledger.slots.first(where: { $0.id == key }), agrees(slot, install: install, lent: lent) {
                out.append(slot)
                continue
            }
            let device: String
            let app: String
            if let install {
                (device, app) = (install.device, install.app)
            } else if let lent {
                (device, app) = (lent.device, lent.app)
            } else {
                // No legacy field to rebuild from. A slot that is lent or has an op still counts as used (fail-safe: an
                // older writer that dropped `lent[]` never frees the slot); any other one is dropped.
                if let slot = ledger.slots.first(where: { $0.id == key }), slot.lentTo != nil || slot.op != nil { out.append(slot) }
                continue
            }
            out.append(migrate(install: install, lent: lent, device: device, app: app, now: now))
        }
        return out
    }

    /// The ledger with its slots migrated and projected, in memory only (what `status` and the menu read).
    static func migrated(_ ledger: Ledger, now: Date) -> Ledger {
        var copy = ledger
        copy.slots = reconcile(ledger, now: now)
        project(&copy)
        return copy
    }

    /// Whether `migrated` differs from what is on disk, i.e. a write at point `migrate` is due.
    static func needsMigration(_ ledger: Ledger, now: Date) -> Bool {
        let next = migrated(ledger, now: now)
        return next.slots != ledger.slots || next.lent != ledger.lent || next.installs != ledger.installs
    }

    // MARK: view

    /// What `status` and the menu read for one device. A used record counts whatever its state, so pending or lent is
    /// never free.
    struct View: Sendable, Equatable {
        let state: SlotPhase
        /// The lent record's app (any state), nil when nothing is lent.
        let app: String?
        let holds: Bool
        /// Any record has an op that is not settled.
        let pending: Bool
        /// Seconds until the last pending window on the device ends; nil when none is inside its window.
        let retryAfter: Int?
        /// Managed slots in use: every used record. The owner's reserve is not in it.
        let used: Int
        /// The used records that are not lent, sorted.
        let apps: [String]
    }

    static func view(_ ledger: Ledger, alias: String, now: Date) -> View {
        let slots = migrated(ledger, now: now).slots.filter { $0.device == alias }
        let lent = slots.first { $0.lentTo != nil }
        let retry = slots.compactMap { $0.op.flatMap { remaining($0, now: now) } }.max()
        return View(
            state: lent.map(phase) ?? .none, app: lent?.app, holds: lent.map(holds) ?? false,
            pending: slots.contains { $0.op != nil }, retryAfter: retry, used: slots.filter(used).count,
            apps: slots.filter { used($0) && $0.lentTo == nil }.map(\.app).sorted())
    }
}
