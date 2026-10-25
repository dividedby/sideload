import Foundation

// The ledger side of the unified pending-operation model (docs/design.md section 18), for one saved device. Every command
// that acts on the device follows one pipeline, with `.op.lock` held and `FreeSession.settle` already run:
//
//   migrate -> G (gate) -> S0 -> W1 `settle` -> decision and checks -> W2 `begin` -> device op -> S1 -> W3 `finish`
//
// W1, W2 and W3 are durable ledger writes named `<command>.settle`, `<command>.intent` and `<command>.final` for the
// crash-injection hook (`Services.afterDurableWrite`). Nothing here talks to the device.

struct SlotBook: Sendable {
    let services: Services
    let config: Config
    let alias: String

    // MARK: migration

    /// The ledger, migrated: when the `slots` key is missing, or the legacy fields on disk no longer equal its projection
    /// (an older build wrote since), it is rewritten at point `migrate` before anything else reads it.
    func loadMigrated() async throws -> Ledger {
        let ledger = try services.ledgerStore.load()
        guard SlotRule.needsMigration(ledger, now: services.clock.now()) else { return ledger }
        try await SlotState.write(services, point: "migrate") { _ in }
        return try services.ledgerStore.load()
    }

    // MARK: reading

    func slots(_ ledger: Ledger) -> [LedgerSlot] { ledger.slots.filter { $0.device == alias } }

    func slot(_ ledger: Ledger, app: String) -> LedgerSlot? { ledger.slots.first { $0.id == "\(alias)/\(app)" } }

    /// The device's lend record (any state): at most one per device.
    func lentSlot(_ ledger: Ledger) -> LedgerSlot? { slots(ledger).first { $0.lentTo != nil } }

    func target(_ appName: String) -> FreeTarget? {
        ProvisionApp(rawValue: appName).flatMap { try? FreeTarget.resolve(app: $0, alias: alias, config: config) }
    }

    // MARK: gate

    /// The record on this device whose op is still inside its window (the one with the longest wait left), with the seconds.
    func pending(_ ledger: Ledger, now: Date) -> (slot: LedgerSlot, retryAfter: Int)? {
        slots(ledger).compactMap { slot -> (LedgerSlot, Int)? in
            guard let op = slot.op, let left = SlotRule.remaining(op, now: now) else { return nil }
            return (slot, left)
        }.max { $0.1 < $1.1 }.map { (slot: $0.0, retryAfter: $0.1) }
    }

    /// G: while ANY record on the device has an op inside its window, nothing that mutates the device runs (one op per device
    /// keeps the app-set delta checks and the slot counts sound). No device call is made.
    func gate(_ ledger: Ledger, now: Date, extra: [String: JSONValue] = [:]) throws {
        if let (slot, left) = pending(ledger, now: now) { throw Self.pendingError(slot, retryAfter: left, extra: extra) }
    }

    /// The one code every consumer retries on. `state` is the lab's word (`lending` / `returning`) for a lend record and
    /// `pending` for any other op; `op` is the kind in flight.
    static func pendingError(_ slot: LedgerSlot, retryAfter: Int, extra: [String: JSONValue] = [:]) -> SideloadError {
        let state = slot.lentTo == nil ? "pending" : SlotRule.phase(slot).rawValue
        let kind = slot.op?.kind.rawValue ?? "unknown"
        var data: [String: JSONValue] = [
            "retryAfter": .number(Double(retryAfter)), "freed": 0, "state": .string(state), "uncertain": true,
            "lent": .bool(slot.lentTo != nil), "app": .string(slot.app), "op": .string(kind),
        ]
        data.merge(extra) { _, new in new }
        return SideloadError(
            "SLOT_PENDING",
            "A device operation on \(printableCut(slot.app)) (\(kind)) timed out or ended unknown and may still finish, so nothing is claimed and nothing else is changed on this device.",
            fix: "Retry in \(retryAfter) seconds; the slot is not free meanwhile.", data: data)
    }

    // MARK: W1

    struct Settlement: Sendable {
        let before: [LedgerSlot]
        let after: [LedgerSlot]

        func before(_ app: String) -> LedgerSlot? { before.first { $0.app == app } }
        func after(_ app: String) -> LedgerSlot? { after.first { $0.app == app } }
    }

    /// W1: the one settle function. Applies rule (i) with one valid snapshot to every record on the device, and the snapshot's
    /// presence to the records that have no op; writes once, atomically, only when something changes. A record whose op is
    /// still inside its window is untouched (the gate has already refused such a device, so this only matters for a clock
    /// that moved). A return that landed is recorded in `installs[]` as `install` records its own.
    func settle(_ snapshot: AppSnapshot, takenAt: Date, point: String) async throws -> Settlement {
        let ledger = try services.ledgerStore.load()
        let before = slots(ledger)
        var after: [LedgerSlot] = []
        for slot in before {
            guard let target = target(slot.app) else {
                after.append(slot)
                continue
            }
            after.append(SlotRule.settle(slot, present: snapshot.ids.contains(target.bundleId), takenAt: takenAt))
        }
        guard after != before else { return Settlement(before: before, after: after) }
        let changes = zip(before, after).filter { $0.0 != $0.1 }
        try await SlotState.write(services, point: point) { ledger in
            for (_, new) in changes {
                ledger.slots.removeAll { $0.id == new.id }
                ledger.slots.append(new)
                // `installs[]` metadata (profile, expiry, install date) is NOT written here: a record settled by the window
                // does not say which build landed, and an expiry later than the copy on the device is the unsafe direction.
            }
        }
        return Settlement(before: before, after: after)
    }

    // MARK: W2

    /// W2: the durable intent, written BEFORE the device call. Creates or updates this app's record: `op` with a fresh
    /// `startedAt` (the clock at the write, rounded up), the presence the snapshot showed, `lentTo`/`since` for a lend, and
    /// the `installs[]` metadata of a FIRST install (no older copy exists to contradict; a reinstall writes none at W2, see
    /// `finish`). If it throws (or the crash hook does) the device is untouched.
    func begin(
        _ target: FreeTarget, kind: SlotRule.Kind, by: LedgerSlotBy, presence: LedgerSlotPresence, lend: Bool = false,
        since: Date, signed: LedgerFreeSigned? = nil, point: String
    ) async throws {
        let services = services
        try await SlotState.write(services, point: point) { ledger in
            var slot =
                ledger.slots.first { $0.id == target.key }
                ?? LedgerSlot(device: target.alias, app: target.app.rawValue, presence: presence)
            slot.presence = presence
            slot.op = SlotRule.newOp(kind, by: by, at: services.clock.now())
            if lend {
                slot.lentTo = SlotState.lab
                slot.since = slot.since ?? since
            }
            ledger.slots.removeAll { $0.id == slot.id }
            ledger.slots.append(slot)
            if let signed { target.recordInstall(into: &ledger, signed: signed, now: since, present: true, succeeded: false) }
        }
    }

    // MARK: W3

    /// What a definite install failure puts back (applied with whichever settled effect the table gave): this pair's `installs[]` entry as it was before the intent (removed when
    /// there was none).
    struct Restore: Sendable {
        let prior: LedgerInstall?
    }

    /// W3: applies the table's effect to this app's record (rule ii). `keep` writes nothing: the op and its `startedAt` stay,
    /// so the window keeps running. `restore` puts this app's `installs[]` entry back to what it was before the intent; the caller passes it after a definite failure (a first install that did not land, or a renewal that failed, whose new profile facts the device never received);
    /// `record` writes the `installs[]` entry (profile, expiry, install date, and the refresh reset of a manual success) of
    /// the build that the table confirms landed: a return, or an install or reinstall that succeeded. `succeeded` false (a
    /// return confirmed present by the snapshot after a failed or unknown install) records the build but keeps the refresh
    /// state: only a definite success clears a suspension. A reinstall that failed, ended unknown or was settled by the window
    /// leaves the old copy's entry untouched (an older expiry is fail-safe: the next renewal comes sooner). Returns the record afterwards.
    @discardableResult
    func finish(
        _ target: FreeTarget, effect: SlotRule.Effect, takenAt: Date, point: String, restore: Restore? = nil,
        record: LedgerFreeSigned? = nil, succeeded: Bool = true
    ) async throws -> LedgerSlot? {
        if effect != .keep {
            let stamp = wholeSeconds(services.clock.now())
            try await SlotState.write(services, point: point) { ledger in
                guard let slot = ledger.slots.first(where: { $0.id == target.key }) else { return }
                let next = SlotRule.apply(effect, to: slot, at: takenAt)
                ledger.slots.removeAll { $0.id == slot.id }
                ledger.slots.append(next)
                if let restore {
                    ledger.installs.removeAll { $0.id == target.key }
                    if let prior = restore.prior {
                        ledger.installs.append(prior)
                        ledger.installs.sort { $0.id < $1.id }
                    }
                }
                if effect == .present, let record {
                    target.recordInstall(into: &ledger, signed: record, now: stamp, present: true, succeeded: succeeded)
                }
            }
        }
        return slot(try services.ledgerStore.load(), app: target.app.rawValue)
    }

    // MARK: counting

    /// Used records on this device that the snapshot does not show, other than `app` itself, split by what they are.
    struct OutsideUse: Sendable, Equatable {
        /// Records with `lentTo` set: the app is gone but the lab holds the room (and its app lives there).
        var lent = 0
        /// The rest: a pending install of one of our other apps that may still land.
        var pending = 0
        var total: Int { lent + pending }
    }

    /// Records on this device that count as used but are not among the snapshot's managed IDs, other than `app` itself. The
    /// install preflight adds them to what the snapshot shows.
    func usedOutsideSnapshot(_ ledger: Ledger, excluding app: String, snapshot: AppSnapshot) -> OutsideUse {
        var use = OutsideUse()
        for slot in slots(ledger) {
            guard slot.app != app, SlotRule.used(slot) else { continue }
            if let target = target(slot.app), snapshot.ids.contains(target.bundleId) { continue }
            if slot.lentTo != nil { use.lent += 1 } else { use.pending += 1 }
        }
        return use
    }

    /// Seconds left in `slot`'s window, 0 when it is over.
    func retryAfter(_ slot: LedgerSlot?) -> Int {
        guard let op = slot?.op else { return 0 }
        return SlotRule.remaining(op, now: services.clock.now()) ?? 0
    }
}
