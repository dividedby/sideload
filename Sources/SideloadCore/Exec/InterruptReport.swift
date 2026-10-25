import Synchronization

/// What a running command can tell the signal handler to put in its `INTERRUPTED` object (`provision --renew` has
/// moved files into `tmp/` by the time its 10-minute build runs, and a Ctrl-C then must still say so). Inert until a
/// command calls `set`; the CLI wires one shared instance into `Services`, tests get a fresh one. Same pattern as
/// `HoldSignal`: the handler only reads.
public final class InterruptReport: Sendable {
    public typealias Report = @Sendable () -> [String: JSONValue]

    private let report = Mutex<Report?>(nil)

    public init() {}

    /// Registers what to report; replaces an earlier registration.
    public func set(_ report: @escaping Report) {
        self.report.withLock { $0 = report }
    }

    /// The registered report, evaluated outside the lock (it may take locks of its own). Nil when none was set.
    public func current() -> [String: JSONValue]? {
        let report = self.report.withLock { $0 }
        return report?()
    }
}
