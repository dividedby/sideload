import Foundation

// The constants and the write primitive of the slot model (docs/design.md section 18). The rules are in `SlotRule` (pure)
// and the ledger and device pipeline in `SlotBook`.

/// The word a lend record projects to (`lent[].state` and the lab's `state`). Only `lent` holds the slot for the lab;
/// `lending` and `returning` are pending (the device may or may not have changed) and are never free.
enum SlotPhase: String, Sendable, Equatable, CaseIterable {
    case none, lending, lent, returning

    /// From a projected legacy record.
    init(_ record: LedgerLent?) {
        switch record?.state {
        case nil: self = .none
        case LedgerLent.lent?: self = .lent
        case LedgerLent.returning?: self = .returning
        // `lending`, and any state this build does not know: pending, settled by the next snapshot.
        default: self = .lending
        }
    }

    var pending: Bool { self == .lending || self == .returning }
    var holds: Bool { self == .lent }
}

enum SlotOperation: Sendable, Equatable {
    case uninstall, install
}

enum SlotState {
    static let lab = "lab"

    // MARK: windows

    /// How long after an operation is certain to be over a snapshot may still be unreliable: a device can finish a timed-out
    /// install or uninstall after the run that issued it ended.
    static let settleGrace: TimeInterval = 300
    /// The `devicectl --timeout` of each operation, shared with the code that issues them.
    static let installTimeoutSec = 300
    static let uninstallTimeoutSec = 90
    /// What the runner adds on top: `DeviceCtl` allows `timeoutSec + 15`, then SIGTERM grace, reaping and a margin.
    static let runnerAllowance: TimeInterval = 15 + 30

    static func maxDuration(_ operation: SlotOperation) -> TimeInterval {
        Double(operation == .install ? installTimeoutSec : uninstallTimeoutSec) + runnerAllowance
    }

    /// Rounds up, so a stamp is never earlier than the moment it stands for and the window is never short.
    static func wholeSecondsUp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.up))
    }

    /// Whole seconds left (rounded up, never more than the window, which guards a clock that moved backwards), or nil when
    /// the window is over: it ends exactly `window` seconds after `opAt`.
    static func remaining(window: TimeInterval, opAt: Date, now: Date) -> Int? {
        let left = window - now.timeIntervalSince(opAt)
        guard left > 0 else { return nil }
        return Int(min(left, window).rounded(.up))
    }

    // MARK: writes

    /// One ledger write that is durable when it returns; `point` names it for the crash-injection hook
    /// (`Services.afterDurableWrite`). The legacy fields are migrated first (so a write can never drop a record an older build
    /// left) and projected from the slots afterwards (I8), in the same atomic write.
    static func write(_ services: Services, point: String, _ body: (inout Ledger) throws -> Void) async throws {
        let now = services.clock.now()
        try await services.ledgerStore.update { ledger in
            ledger.slots = SlotRule.reconcile(ledger, now: now)
            try body(&ledger)
            SlotRule.project(&ledger)
        }
        try services.afterDurableWrite?(point)
    }
}
