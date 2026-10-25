import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Shared by the slot tests: command runners with crash and thrown-call injection, the independent copy of the design's
// 27-cell table, and the invariants I1 to I9 of docs/design.md section 18, checked against the true state of the simulated
// device.

func json(_ envelope: Envelope) -> JSONValue { (try? envelope.printed().json) ?? .null }

/// The process died right after the named durable write.
struct SimulatedCrash: Error {}

enum SlotCommandKind: Sendable, CaseIterable { case lend, giveBack, remove, install }

extension InstallWorld {
    func bundleId(of app: String) -> String { carrierPrefix + ".free." + (ProvisionApp(rawValue: app)?.suffix ?? "?") }
    var slots: [LedgerSlot] { (try? ledger().slots) ?? [] }
    func slotRecord(_ app: String = "stremio-ios", device: String = "iphone") -> LedgerSlot? {
        slots.first { $0.id == "\(device)/\(app)" }
    }
    /// The ledger's `lent[]` projection of the (single) lend record.
    var lentState: String? { lent.first?.state }
    /// The phase word `status` and the lab read for the device's lend record.
    var phase: SlotPhase { SlotPhase(lent.first { $0.device == "iphone" }) }
}

/// Runs one command. `crashAt` throws `SimulatedCrash` right after that durable write. `thrown` makes a timed-out device op
/// a call that throws before it reaches the runner (the config becomes unreadable for `DeviceCtl` from the intent on, and the
/// device still does what the script says); the config is restored when the command returns. `watch` sees every durable write.
@discardableResult
func runSlotCommand(
    _ kind: SlotCommandKind, _ w: InstallWorld, app: String = "stremio-ios", crashAt: String? = nil, thrown: Bool = false,
    runner override: (any Runner)? = nil, watch: (@Sendable (String) -> Void)? = nil
) async -> Envelope {
    var services = w.services
    if let override { services.runner = override }
    let runner = w.runner
    let configPath = w.paths.config
    let original = thrown ? try? Data(contentsOf: URL(fileURLWithPath: configPath)) : nil
    let id = w.bundleId(of: app)
    services.afterDurableWrite = { point in
        watch?(point)
        if thrown, point.hasSuffix(".intent"), runner.bypassOp(install: point == "install.intent" || point == "return.intent", id: id) {
            try? Data("{".utf8).write(to: URL(fileURLWithPath: configPath))
        }
        if point == crashAt { throw SimulatedCrash() }
    }
    defer { if let original { try? original.write(to: URL(fileURLWithPath: configPath)) } }
    switch kind {
    case .lend: return await SlotCommand.run(services, SlotOptions(sub: "lend", device: "iphone", to: "lab"))
    case .giveBack: return await SlotCommand.run(services, SlotOptions(sub: "return", device: "iphone"))
    case .remove: return await AppCommand.run(services, AppOptions(sub: "remove", app: app, device: "iphone", yes: true))
    case .install: return await InstallCommand.run(services, InstallOptions(app: app, device: "iphone", yes: true))
    }
}

// MARK: the design's table, as an independent copy

/// docs/design.md section 18 / design-slot-unified section 2: kind x result x S1 -> effect and note. Written out cell by
/// cell, not derived from `SlotRule`, so the two can disagree.
typealias Cell = (kind: LedgerSlotKind, result: SlotRule.Result, s1: SlotRule.Reading)

let designCells: [(cell: Cell, effect: SlotRule.Effect, note: SlotRule.Note?)] = {
    typealias R = SlotRule.Result
    typealias S = SlotRule.Reading
    var rows: [(Cell, SlotRule.Effect, SlotRule.Note?)] = []
    func add(_ k: LedgerSlotKind, _ r: R, _ p: (SlotRule.Effect, SlotRule.Note?), _ a: (SlotRule.Effect, SlotRule.Note?), _ u: (SlotRule.Effect, SlotRule.Note?)) {
        rows.append(((k, r, .present), p.0, p.1))
        rows.append(((k, r, .absent), a.0, a.1))
        rows.append(((k, r, .unreadable), u.0, u.1))
    }
    let keep: (SlotRule.Effect, SlotRule.Note?) = (.keep, nil)
    add(.install, .success, (.present, nil), (.keep, .installUnconfirmed), keep)
    add(.install, .failure, (.present, .installResultUncertain), (.absent, nil), keep)
    add(.install, .unknown, (.present, nil), keep, keep)
    add(.reinstall, .success, (.present, nil), (.keep, .unexpectedAppDelta), keep)
    add(.reinstall, .failure, (.present, nil), (.absent, .unexpectedAppDelta), keep)
    add(.reinstall, .unknown, keep, keep, keep)
    add(.uninstall, .success, (.keep, .unexpectedAppDelta), (.absent, nil), keep)
    add(.uninstall, .failure, (.present, nil), (.absent, .uninstallResultUncertain), keep)
    add(.uninstall, .unknown, keep, (.absent, nil), keep)
    return rows.map { (cell: $0.0, effect: $0.1, note: $0.2) }
}()

// MARK: invariants

/// The apps of ours that are on the simulated device, now or once every operation in flight has finished.
func managedOnDevice(_ w: InstallWorld, eventually: Bool) -> Set<String> {
    let apps = eventually ? w.runner.deviceAppsEventually : w.runner.deviceApps
    return Set(apps.keys.filter { Config.isFreeBundleId($0, prefix: carrierPrefix) })
}

/// I2, I4, I5 and I8 against the true device state. `eventually` is I5's "after everything in flight has landed".
func expectSlotModel(
    _ w: InstallWorld, label: String = "", eventually: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let ledger = try w.ledger()
    let now = w.clock.now()
    // I8: after a write, the legacy fields are exactly the projection of the slots. A ledger no command has written yet
    // (a command that stopped before it migrated) is still the legacy shape; the walk checks I8 at every write.
    if !SlotRule.needsMigration(ledger, now: now) {
        var projected = ledger
        SlotRule.project(&projected)
        #expect(projected == ledger, "\(label): I8 the legacy fields differ from project(slots)", sourceLocation: sourceLocation)
    }
    // I4: lent and nothing in flight means the app is known absent.
    for slot in ledger.slots where slot.lentTo != nil && slot.op == nil {
        #expect(slot.presence == .absent, "\(label): I4 \(slot.id) is lent with no op but reads \(slot.presence)", sourceLocation: sourceLocation)
    }
    // I2: at most one op inside its window on a device.
    let open = ledger.slots.filter { $0.device == "iphone" && ($0.op.flatMap { SlotRule.remaining($0, now: now) } != nil) }
    #expect(open.count <= 1, "\(label): I2 \(open.count) ops are inside their window", sourceLocation: sourceLocation)
    // I5: absent with nothing in flight (and so every holds) means the app is not on the device, now and eventually.
    let there = managedOnDevice(w, eventually: eventually)
    for slot in ledger.slots where slot.presence == .absent && slot.op == nil {
        #expect(
            !there.contains(w.bundleId(of: slot.app)),
            "\(label): I5 \(slot.id) reads absent (lentTo \(slot.lentTo ?? "-")) but the app is on the device (eventually \(eventually))",
            sourceLocation: sourceLocation)
    }
    try expectNoFalseRenewal(w, label: label, eventually: eventually, sourceLocation: sourceLocation)
}

/// I6: what `status` shows as free is never more than the true free count once everything in flight has landed.
func expectStatusNeverOptimistic(_ w: InstallWorld, label: String = "", sourceLocation: SourceLocation = #_sourceLocation) throws {
    let status = json(StatusCommand.run(w.services))
    let iphone = status["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" }
    guard case .number(let used)? = iphone?["used"], case .number(let reserved)? = iphone?["reserved"] else {
        Issue.record("\(label): status has no slots for the iphone", sourceLocation: sourceLocation)
        return
    }
    let trulyUsed = Double(managedOnDevice(w, eventually: true).count) + reserved
    #expect(used >= trulyUsed, "\(label): I6 status says used \(used), the device will hold \(trulyUsed)", sourceLocation: sourceLocation)
}

/// Every slot whose op was still inside its window before a command is byte-for-byte the same after it (I3: nothing but that
/// op's own run may settle it, and the gate refuses every other mutating command).
func expectPendingUntouched(
    before: Ledger, after: Ledger, at now: Date, label: String = "", sourceLocation: SourceLocation = #_sourceLocation
) {
    for slot in before.slots where slot.op.flatMap({ SlotRule.remaining($0, now: now) }) != nil {
        #expect(after.slots.first { $0.id == slot.id } == slot, "\(label): I3 \(slot.id) changed inside its window", sourceLocation: sourceLocation)
    }
}

/// I1: at the moment a device mutation reaches the runner, a durable op of the right kind is on disk for exactly one slot,
/// stamped at or after the clock (rounded up).
func opWatcher(_ w: InstallWorld, label: @escaping @Sendable () -> String) -> DeviceSimRunnerWatch {
    let paths = w.paths
    let clock = w.clock
    return DeviceSimRunnerWatch(inner: w.runner) { spec in
        let words = DeviceSimRunner.words(spec)
        guard words == "device install app" || words == "device uninstall app" else { return }
        let ledger = try? LedgerStore(paths: paths).load()
        let now = clock.now()
        let ops = (ledger?.slots ?? []).compactMap { slot in slot.op.map { (slot, $0) } }.filter { SlotRule.remaining($0.1, now: now) != nil }
        #expect(ops.count == 1, "\(label()): I1/I2 \(ops.count) ops on disk when \(words) ran")
        if let (_, op) = ops.first {
            #expect((op.kind == .uninstall) == (words == "device uninstall app"), "\(label()): I1 op kind \(op.kind) for \(words)")
            #expect(op.startedAt >= now && op.startedAt.timeIntervalSince(now) < 1, "\(label()): I1 startedAt is not the rounded-up clock")
        }
    }
}

/// No false renewal: the expiry the ledger records for an app is never later than the expiry of the copy actually on the
/// device (an older expiry is fail-safe, a later one hides an expiring app). `eventually` counts landings still in flight.
func expectNoFalseRenewal(
    _ w: InstallWorld, label: String = "", eventually: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    for entry in try w.ledger().installs {
        guard let copy = w.runner.copyExpiry(entry.bundleId, eventually: eventually) else { continue }
        #expect(
            entry.profileExpires <= copy,
            "\(label): \(entry.app) is recorded to expire \(entry.profileExpires), but the copy on the device expires \(copy) (eventually \(eventually))",
            sourceLocation: sourceLocation)
    }
}
